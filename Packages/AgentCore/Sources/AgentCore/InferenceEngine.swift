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
public final class InferenceEngine {
    public enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    public var state: LoadState = .idle
    public var tokenCount: Int = 0
    public var contextWindow: Int = 0
    private var container: ModelContainer?

    public init() {}

    /// Resolves to <repo>/models/gemma-4-26b-a4b-it-4bit at compile time.
    /// Walks up from `Packages/AgentCore/Sources/AgentCore/InferenceEngine.swift`
    /// (5 levels) to the repo root, then appends `models/...`.
    private static var modelDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AgentCore/ (folder)
            .deletingLastPathComponent()  // Sources/
            .deletingLastPathComponent()  // AgentCore/ (package)
            .deletingLastPathComponent()  // Packages/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("models/gemma-4-26b-a4b-it-4bit")
    }

    public var modelName: String { Self.modelDirectory.lastPathComponent }

    public func load() async {
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
                let chat: [Chat.Message] = messages.compactMap { msg in
                    switch msg.role {
                    case .system: return .system(msg.text)
                    case .user:   return .user(msg.text)
                    case .tool:   return nil    // bundled into the preceding assistant turn
                    case .assistant:
                        var content = msg.text
                        if let call = msg.toolCall {
                            if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
                            content += GemmaWireFormat.serialize(call)
                            if let result = msg.toolResult {
                                content += GemmaWireFormat.serializeResponse(
                                    toolName: call.name, output: result)
                            }
                        }
                        return .assistant(content)
                    }
                }
                let params = GenerateParameters(maxTokens: 4096, temperature: 0.7)
                do {
                    let lmInput = try await container.prepare(
                        input: UserInput(chat: chat, tools: tools.isEmpty ? nil : tools)
                    )
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
