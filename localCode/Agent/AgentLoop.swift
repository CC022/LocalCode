import Foundation

@Observable
@MainActor
final class AgentLoop {
    let cwd: URL
    private let engine: InferenceEngine
    private let registry: ToolRegistry
    var messages: [Message]

    init(cwd: URL, engine: InferenceEngine) {
        self.cwd = cwd
        self.engine = engine
        self.registry = ToolRegistry([
            BashTool(cwd: cwd),
            ReadFileTool(cwd: cwd),
            WriteFileTool(cwd: cwd),
            EditFileTool(cwd: cwd),
            GlobTool(cwd: cwd),
        ])
        self.messages = [.system(SystemPrompt.make(cwd: cwd))]
    }

    /// Mirrors the Python s02 `while True`: stream → on tool call, dispatch and loop;
    /// on plain text completion, exit.
    func send(_ userText: String) async {
        messages.append(.user(userText))
        while true {
            let snapshot = messages
            let assistantIdx = messages.count
            messages.append(.assistant(""))

            var buffer = ""
            var pendingCall: AgentToolCall?

            for await event in engine.stream(messages: snapshot, tools: registry.toolSpecs) {
                switch event {
                case .text(let delta):
                    buffer += delta
                    messages[assistantIdx].text = buffer
                case .toolCall(let mlxCall):
                    pendingCall = AgentToolCall(mlxCall)
                }
            }

            guard let call = pendingCall else { return }

            let output = await registry.dispatch(name: call.name, arguments: call.arguments)
            messages[assistantIdx].toolCall = call
            messages[assistantIdx].toolResult = output
            messages.append(.tool(output))
        }
    }
}
