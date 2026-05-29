import Foundation

@Observable
@MainActor
public final class AgentLoop {
    public let cwd: URL
    private let engine: InferenceEngine
    private var tools: ToolRegistry
    private let hooks: HookRegistry
    public var messages: [Message]
    public private(set) var todos: [TodoItem] = []
    private var roundsSinceTodo = 0
    /// Persistent KV cache for this session. The cache is lazy-allocated on the
    /// first `engine.stream(...)` call and reused for every subsequent turn so
    /// TTFT stays low as the chat grows. Discarded when this AgentLoop is
    /// deallocated (which happens on `AppState.pickDirectory`).
    private let cacheSlot = KVCacheSlot()

    public init(cwd: URL, engine: InferenceEngine, hooks: HookRegistry) {
        self.cwd = cwd
        self.engine = engine
        self.hooks = hooks
        // Placeholder so the closure below can safely reference `self`.
        self.tools = ToolRegistry([])
        self.messages = [.system(SystemPrompt.make(cwd: cwd))]

        self.tools = ToolRegistry([
            BashTool(cwd: cwd),
            ReadFileTool(cwd: cwd),
            WriteFileTool(cwd: cwd),
            EditFileTool(cwd: cwd),
            GlobTool(cwd: cwd),
            TodoWriteTool(onUpdate: { [weak self] items in
                self?.todos = items
            }),
            LoadSkillTool(),
            WebSearchTool(),
            WebFetchTool(),
            ParsePDFTool(cwd: cwd),
            TranslateMDTool(cwd: cwd, engine: engine),
        ])
    }

    /// Mirrors the Python s05 `while True`: stream → on tool call, dispatch via
    /// hook gates and loop; on plain-text completion, fire stop and return.
    /// Injects a `<reminder>` after 3 tool rounds without a `todo_write` call.
    public func send(_ userText: String) async {
        let text = await hooks.triggerUserPrompt(userText)
        messages.append(.user(text))

        var firstIter = true
        while true {
            if Task.isCancelled {
                messages.append(.assistant("[stopped]"))
                return
            }

            if !firstIter, roundsSinceTodo >= 3 {
                messages.append(.user("<reminder>Update your todos.</reminder>"))
                roundsSinceTodo = 0
            }
            firstIter = false

            let snapshot = messages
            let assistantIdx = messages.count
            messages.append(.assistant(""))

            var buffer = ""
            // Out-of-band reasoning channel used by API backends (e.g.
            // DeepSeek's `delta.reasoning_content`). Stays empty for local
            // mode, where thinking is parsed from `buffer` via GemmaWireFormat.
            var reasoningBuffer = ""
            var pendingCall: AgentToolCall?

            for await event in engine.stream(messages: snapshot, tools: tools.toolSpecs, cacheSlot: cacheSlot) {
                switch event {
                case .text(let delta):
                    buffer += delta
                    // Strip the thought channel + leaked tool-call markers from
                    // the visible text each chunk; surface thinking separately.
                    let live = GemmaWireFormat.parse(buffer, includeOpenThinking: true)
                    messages[assistantIdx].text = live.text
                    // Don't clobber API-emitted reasoning with the (always-nil)
                    // GemmaWireFormat parse on API text.
                    if reasoningBuffer.isEmpty {
                        messages[assistantIdx].thinking = live.thinking
                    }
                case .reasoning(let delta):
                    reasoningBuffer += delta
                    messages[assistantIdx].thinking = reasoningBuffer
                case .toolCall(let mlxCall):
                    pendingCall = AgentToolCall(mlxCall)
                }
            }

            // Cancellation can land mid-stream: the stream finishes with no
            // pending call. Mark the partial turn stopped, not naturally done.
            if Task.isCancelled {
                let live = GemmaWireFormat.parse(buffer, includeOpenThinking: true)
                let suffix = live.text.isEmpty ? "[stopped]" : "\n[stopped]"
                messages[assistantIdx].text = live.text + suffix
                messages[assistantIdx].thinking = reasoningBuffer.isEmpty ? live.thinking : reasoningBuffer
                return
            }

            // Final pass: keep the thought block even when unclosed (the model
            // can stop mid-thinking at maxTokens/EOS; dropping it erases the
            // turn the user watched stream in), and recover a tool call whose
            // `<|tool_call>` opener the detokenizer swallowed — a reproducible
            // Gemma 4 thinking-mode leak (see GemmaWireFormat.tokenize).
            let parsed = GemmaWireFormat.parse(buffer, includeOpenThinking: true)
            messages[assistantIdx].text = parsed.text
            messages[assistantIdx].thinking = reasoningBuffer.isEmpty ? parsed.thinking : reasoningBuffer
            let effectiveCall = pendingCall ?? parsed.toolCall

            guard let call = effectiveCall else {
                // Cache-alignment guard: when the model emitted a
                // `<|channel>thought` block but no tool call, the cache
                // contains [prompt + thought + response] tokens. The next
                // turn's prompt re-renders the assistant turn without the
                // thought (Message.thinking is held off `text` and the
                // chat template's `strip_thinking` macro would strip it
                // anyway), so cached positions [prompt_len .. cachedLength)
                // hold *thought* tokens while the new prompt at the same
                // span holds *response* tokens. KVCacheSlot.prefixSkip
                // only verifies the fed-prompt prefix, so it would slice
                // the new prompt wrong and we'd generate with shifted RoPE
                // and stale K/V. Reset so the next turn re-prefills cleanly.
                if parsed.thinking != nil {
                    cacheSlot.reset()
                }
                await hooks.triggerStop()
                return
            }

            // Surface the pending call to the UI before any hook may suspend
            // (e.g. permission asking the user), so the bubble can host the prompt.
            messages[assistantIdx].toolCall = call

            let output: String
            if let blockReason = await hooks.triggerPreTool(call) {
                output = "Permission denied: \(blockReason)"
            } else {
                let raw = await tools.dispatch(name: call.name, arguments: call.arguments)
                output = await hooks.triggerPostTool(call, output: raw)
            }
            messages[assistantIdx].toolResult = output
            roundsSinceTodo += 1
            if call.name == "todo_write" { roundsSinceTodo = 0 }
            // The result is bundled into the assistant turn's content when we
            // re-render for the next generation (see InferenceEngine.stream).
        }
    }

    /// Wipe the chat back to just the system prompt and discard the KV cache.
    /// Triggered by the `/clear` slash command.
    public func clear() {
        messages = [.system(SystemPrompt.make(cwd: cwd))]
        todos = []
        roundsSinceTodo = 0
        cacheSlot.reset()
    }

    /// Summarize the current chat into a single seed message. Runs one
    /// tool-less generation against a *separate* (nil) cache so the persistent
    /// KV — which still matches the pre-compact prompt — isn't polluted, then
    /// replaces `messages` with `[system, summary]` and resets the slot so the
    /// next turn rebuilds prefill against the now-tiny prompt.
    public func compact() async {
        guard messages.count > 1 else { return }   // nothing past the system prompt

        let transcript = renderTranscript()
        let prompt = """
        Summarize this coding-agent conversation so work can continue. Preserve: \
        1) the current goal, 2) key findings and decisions, 3) files read or \
        changed, 4) remaining work, 5) user constraints. Be compact but concrete.

        \(transcript)
        """

        let placeholderIdx = messages.count
        messages.append(.assistant("Compacting conversation…"))

        var summary = ""
        for await event in engine.stream(
            messages: [.user(prompt)],
            tools: [],
            cacheSlot: nil
        ) {
            if case .text(let delta) = event {
                summary += delta
                messages[placeholderIdx].text = "Compacting conversation…\n\n\(summary)"
            }
        }

        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalSummary = trimmed.isEmpty ? "(empty summary)" : trimmed
        messages = [
            .system(SystemPrompt.make(cwd: cwd)),
            .user("[Previous conversation summary]\n\n\(finalSummary)")
        ]
        roundsSinceTodo = 0
        cacheSlot.reset()
    }

    /// Flatten the visible chat into a single string for the summarizer.
    private func renderTranscript() -> String {
        messages.dropFirst().map { m in
            var s = "[\(m.role.label)]\n\(m.text)"
            if let call = m.toolCall { s += "\n[tool_call] \(call.summary)" }
            if let result = m.toolResult {
                s += "\n[tool_result]\n\(result.clipped(to: 2000, withCount: false))"
            }
            return s
        }.joined(separator: "\n\n")
    }
}
