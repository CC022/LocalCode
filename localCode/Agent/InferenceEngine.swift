import Foundation
import Hub
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers

@Observable
@MainActor
final class InferenceEngine {
    enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    var state: LoadState = .idle
    private var container: ModelContainer?

    /// Resolves to <repo>/models/gemma-4-26b-a4b-it-4bit at compile time.
    private static var modelDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Agent/
            .deletingLastPathComponent()  // localCode/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("models/gemma-4-26b-a4b-it-4bit")
    }

    func load() async {
        guard state != .ready, state != .loading else { return }
        state = .loading
        do {
            container = try await VLMModelFactory.shared.loadContainer(
                from: Self.modelDirectory,
                using: #huggingFaceTokenizerLoader()
            )
            state = .ready
        } catch {
            state = .failed("\(error)")
        }
    }

    /// Stream assistant text deltas for the given message history.
    func stream(messages: [Message]) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task { [container] in
                guard let container else { continuation.finish(); return }
                let chat: [Chat.Message] = messages.map { msg in
                    switch msg.role {
                    case .system:    .system(msg.text)
                    case .user:      .user(msg.text)
                    case .assistant: .assistant(msg.text)
                    }
                }
                let input = UserInput(chat: chat)
                let params = GenerateParameters(maxTokens: 4096, temperature: 0.7)
                do {
                    let lmInput = try await container.prepare(input: input)
                    let stream = try await container.generate(input: lmInput, parameters: params)
                    for await gen in stream {
                        if Task.isCancelled { break }
                        if let chunk = gen.chunk { continuation.yield(chunk) }
                    }
                } catch {
                    continuation.yield("\n[error: \(error.localizedDescription)]")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
