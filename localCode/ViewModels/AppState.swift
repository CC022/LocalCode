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

    func pickDirectory(_ url: URL) {
        cwd = url
        loop = AgentLoop(cwd: url, engine: engine)
        Task { await engine.load() }
    }

    func send() async {
        guard let loop, canSend else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""
        isStreaming = true
        await loop.send(text)
        isStreaming = false
    }
}
