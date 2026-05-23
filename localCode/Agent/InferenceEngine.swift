import Foundation
import Hub
import HuggingFace
import MLX
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
    var tokenCount: Int = 0
    var contextWindow: Int = 0
    private var container: ModelContainer?

    /// Resolves to <repo>/models/gemma-4-26b-a4b-it-4bit at compile time.
    private static var modelDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Agent/
            .deletingLastPathComponent()  // localCode/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("models/gemma-4-26b-a4b-it-4bit")
    }

    var modelName: String { Self.modelDirectory.lastPathComponent }

    func load() async {
        guard state != .ready, state != .loading else { return }
        state = .loading
        contextWindow = Self.readContextWindow() ?? 8192
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

    /// Read `text_config.max_position_embeddings` (or the top-level field) from config.json.
    private static func readContextWindow() -> Int? {
        guard let data = try? Data(contentsOf: modelDirectory.appendingPathComponent("config.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let txt = root["text_config"] as? [String: Any],
           let n = txt["max_position_embeddings"] as? Int { return n }
        return root["max_position_embeddings"] as? Int
    }

    /// Stream the next assistant turn. Yields text deltas and tool calls in
    /// the order the model emits them.
    func stream(messages: [Message], tools: [ToolSpec]) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in
            let task = Task { [container] in
                guard let container else { continuation.finish(); return }
                let chat: [Chat.Message] = messages.map { msg in
                    switch msg.role {
                    case .system:    .system(msg.text)
                    case .user:      .user(msg.text)
                    case .assistant: .assistant(msg.text)
                    case .tool:      .tool(msg.text)
                    }
                }
                let input = UserInput(
                    chat: chat,
                    tools: tools.isEmpty ? nil : tools
                )
                let params = GenerateParameters(maxTokens: 4096, temperature: 0.7)
                do {
                    let lmInput = try await container.prepare(input: input)
                    let prompt = lmInput.text.tokens.size
                    await MainActor.run { self.tokenCount = prompt }
                    let stream = try await container.generate(input: lmInput, parameters: params)
                    for await gen in stream {
                        if Task.isCancelled { break }
                        if let chunk = gen.chunk {
                            continuation.yield(.text(chunk))
                        } else if let tc = gen.toolCall {
                            continuation.yield(.toolCall(tc))
                            break  // stop generation after first tool call
                        }
                    }
                } catch {
                    continuation.yield(.text("\n[error: \(error.localizedDescription)]"))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
