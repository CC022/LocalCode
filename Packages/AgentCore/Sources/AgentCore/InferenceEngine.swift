import Foundation
import Hub
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers

/// Pass a non-Sendable value across an isolation boundary, consume-once.
/// `LMInput` is not Sendable and we need to hand it into `container.perform`'s
/// `@Sendable` closure. `MLXLMCommon.SendableBox` is `package`-internal, so
/// we declare a tiny local clone.
private final class TransferBox<T>: @unchecked Sendable {
    private var value: T?
    init(_ value: T) { self.value = value }
    func consume() -> T {
        defer { value = nil }
        return value!
    }
}

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
    ///
    /// Pass `cacheSlot` to reuse a KV cache across turns. The token iterator
    /// then only prefills tokens beyond what's already in the cache (i.e. the
    /// new tail of the chat), which is the difference between sub-second and
    /// many-second TTFT once the history grows. On first use the slot
    /// lazy-allocates from the model. Discard the slot (or call `.reset()`) to
    /// start a fresh prefill.
    func stream(
        messages: [Message],
        tools: [ToolSpec],
        cacheSlot: KVCacheSlot? = nil
    ) -> AsyncStream<StreamEvent> {
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

                    // Drop into the container's serial lock to allocate the cache
                    // (needs the model) and kick off the cache-aware generate.
                    // The returned AsyncStream is sendable and is iterated outside
                    // the lock.
                    let inputBox = TransferBox(lmInput)
                    let toolsForCall: [ToolSpec]? = tools.isEmpty ? nil : tools
                    let stream: AsyncStream<Generation> = try await container.perform { context in
                        // `makePromptCache` is mlx-swift-lm's documented entry
                        // point — it defers to the model's own `newCache` so
                        // we get the right per-layer cache mix (e.g. Gemma 4
                        // uses RotatingKVCache for local-attention layers and
                        // KVCacheSimple for global ones).
                        let cache: [KVCache]? = cacheSlot.map { slot in
                            slot.getOrAllocate {
                                makePromptCache(model: context.model, parameters: params)
                            }
                        }
                        return try MLXLMCommon.generate(
                            input: inputBox.consume(),
                            cache: cache,
                            parameters: params,
                            context: context,
                            tools: toolsForCall
                        )
                    }

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
