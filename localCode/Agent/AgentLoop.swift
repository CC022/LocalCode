import Foundation

@Observable
@MainActor
final class AgentLoop {
    let cwd: URL
    private let engine: InferenceEngine
    private let bash: BashTool
    var messages: [Message]

    init(cwd: URL, engine: InferenceEngine) {
        self.cwd = cwd
        self.engine = engine
        self.bash = BashTool(cwd: cwd)
        self.messages = [.system(SystemPrompt.make(cwd: cwd))]
    }

    /// Mirrors the Python s01 `while True` loop: stream → parse → tool → repeat.
    func send(_ userText: String) async {
        messages.append(.user(userText))
        while true {
            let snapshot = messages
            let assistantIdx = messages.count
            messages.append(.assistant(""))

            var buffer = ""
            for await delta in engine.stream(messages: snapshot) {
                buffer += delta
                messages[assistantIdx].text = buffer
            }

            guard let call = ToolParser.extract(buffer) else { return }

            let output = await bash.run(call.command)
            messages[assistantIdx].toolCall = call
            messages[assistantIdx].toolResult = output

            var resultMsg = Message.user(ToolParser.resultMessage(output))
            resultMsg.isHiddenInUI = true
            messages.append(resultMsg)
        }
    }
}
