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
            var pendingCall: AgentToolCall?

            for await event in engine.stream(messages: snapshot, tools: tools.toolSpecs, cacheSlot: cacheSlot) {
                switch event {
                case .text(let delta):
                    buffer += delta
                    messages[assistantIdx].text = buffer
                case .toolCall(let mlxCall):
                    pendingCall = AgentToolCall(mlxCall)
                }
            }

            // Cancellation can land mid-stream: the inner Task breaks, the
            // AsyncStream finishes, and we get here with no pending call. Mark
            // the partial assistant turn as stopped instead of treating it as
            // a natural completion.
            if Task.isCancelled {
                let suffix = buffer.isEmpty ? "[stopped]" : "\n[stopped]"
                messages[assistantIdx].text = buffer + suffix
                return
            }

            guard let call = pendingCall else {
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
        messages.dropFirst().map { msg in
            let role: String = switch msg.role {
            case .system:    "SYSTEM"
            case .user:      "USER"
            case .assistant: "ASSISTANT"
            case .tool:      "TOOL"
            }
            var out = "[\(role)]\n\(msg.text)"
            if let call = msg.toolCall {
                out += "\n[tool_call] \(call.summary)"
            }
            if let result = msg.toolResult {
                let clipped = result.count > 2000
                    ? String(result.prefix(2000)) + "\n…(truncated)"
                    : result
                out += "\n[tool_result]\n\(clipped)"
            }
            return out
        }.joined(separator: "\n\n")
    }
}
