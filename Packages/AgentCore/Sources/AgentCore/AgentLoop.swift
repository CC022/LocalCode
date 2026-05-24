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
}
