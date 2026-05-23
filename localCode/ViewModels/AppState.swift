import Foundation

@Observable
@MainActor
final class AppState {
    let engine = InferenceEngine()
    var loop: AgentLoop?
    var cwd: URL?
    var input: String = ""
    var isStreaming = false

    var canSend: Bool {
        engine.state == .ready
            && !isStreaming
            && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init() {
        // Start warming the model immediately — don't wait for the user to pick a folder.
        Task { await engine.load() }
    }

    func pickDirectory(_ url: URL) {
        cwd = url
        loop = AgentLoop(cwd: url, engine: engine)
    }

    func send() async {
        guard let loop, canSend else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""
        isStreaming = true
        await loop.send(text)
        isStreaming = false
    }

    /// Format the full chat (including hidden tool_result messages) for debugging.
    func exportTranscript() -> String {
        guard let loop else { return "(no chat yet)" }
        var out = "# localCode transcript\ncwd: \(loop.cwd.path)\n"
        for msg in loop.messages {
            let role: String = switch msg.role {
            case .system:    "SYSTEM"
            case .user:      "USER"
            case .assistant: "ASSISTANT"
            case .tool:      "TOOL"
            }
            out += "\n--- \(role) ---\n\(msg.text)\n"
        }
        return out
    }
}
