import Foundation

@Observable
@MainActor
public final class AgentLoop {
    public let cwd: URL
    private let engine: InferenceEngine
    private let tools: ToolRegistry
    private let hooks: HookRegistry
    public var messages: [Message]

    public init(cwd: URL, engine: InferenceEngine, hooks: HookRegistry) {
        self.cwd = cwd
        self.engine = engine
        self.hooks = hooks
        self.tools = ToolRegistry([
            BashTool(cwd: cwd),
            ReadFileTool(cwd: cwd),
            WriteFileTool(cwd: cwd),
            EditFileTool(cwd: cwd),
            GlobTool(cwd: cwd),
        ])
        self.messages = [.system(SystemPrompt.make(cwd: cwd))]
    }

    /// Mirrors the Python s04 `while True`: stream → on tool call, dispatch via
    /// hook gates and loop; on plain-text completion, fire stop and return.
    public func send(_ userText: String) async {
        let text = await hooks.triggerUserPrompt(userText)
        messages.append(.user(text))

        while true {
            let snapshot = messages
            let assistantIdx = messages.count
            messages.append(.assistant(""))

            var buffer = ""
            var pendingCall: AgentToolCall?

            for await event in engine.stream(messages: snapshot, tools: tools.toolSpecs) {
                switch event {
                case .text(let delta):
                    buffer += delta
                    messages[assistantIdx].text = buffer
                case .toolCall(let mlxCall):
                    pendingCall = AgentToolCall(mlxCall)
                }
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
            // The result is bundled into the assistant turn's content when we
            // re-render for the next generation (see InferenceEngine.stream).
        }
    }
}
