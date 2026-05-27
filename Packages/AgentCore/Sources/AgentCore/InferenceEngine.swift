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
        case missing
        case downloading
        case loading
        case ready
        case failed(String)
    }

    public enum InferencePhase: String, Equatable {
        case idle
        case prepare
        case prefill
        case decode
    }

    /// Which inference path `stream(...)` dispatches to. Default `.local`.
    public enum Backend: String, Codable, CaseIterable, Sendable {
        case local, api
    }
    public var backend: Backend = .local {
        didSet { recomputeStateForBackend() }
    }
    /// Connection params for `.api` mode. Setting this (e.g. after the user
    /// saves the config sheet) re-evaluates whether the API state is ready.
    public var apiConfig: APIConfig = .init() {
        didSet { recomputeStateForBackend() }
    }

    public var state: LoadState = .idle
    public var inferencePhase: InferencePhase = .idle
    public var tokenCount: Int = 0
    public var contextWindow: Int = 0
    public var downloadProgress: Double = 0
    /// User-controlled chain-of-thought switch. Default off because, on this
    /// machine, thinking burns 3-5K tokens per turn and either truncates
    /// tool-call bodies at `maxTokens=4096` or OOMs Metal at larger budgets.
    /// Read at the start of every `stream(...)` call so flipping it via the
    /// inspector takes effect on the next turn. Only used in `.local` mode.
    public var thinkingEnabled: Bool = false
    private var container: ModelContainer?
    private let modelDirectory: URL
    /// Remembered local-backend state so flipping `.api → .local` restores it
    /// without re-running `load()`.
    private var localState: LoadState = .idle

    nonisolated public static let modelRepository = "mlx-community/gemma-4-26b-a4b-it-4bit"
    nonisolated public static let modelDirectoryName = "gemma-4-26b-a4b-it-4bit"

    public init(modelDirectory: URL? = nil) {
        self.modelDirectory = modelDirectory ?? Self.defaultModelDirectory
    }

    nonisolated public static var defaultModelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalCode", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(modelDirectoryName, isDirectory: true)
    }

    public var modelName: String {
        backend == .api
            ? (apiConfig.model.isEmpty ? "API model" : apiConfig.model)
            : modelDirectory.lastPathComponent
    }
    public var modelPath: URL { modelDirectory }
    public var modelFilesAvailable: Bool { Self.hasUsableModelFiles(at: modelDirectory) }

    public func markModelMissing() {
        state = .missing
        if backend == .local { localState = .missing }
    }

    /// Map the active backend to the unified `state` field the UI reads.
    /// `.local` keeps the most-recently-set `localState` (loading/ready/etc.);
    /// `.api` is purely config-derived (ready iff config is complete).
    private func recomputeStateForBackend() {
        switch backend {
        case .local:
            state = localState
        case .api:
            state = apiConfig.isComplete ? .ready : .missing
        }
    }

    /// Write to `localState` and mirror it to the public `state` when local is
    /// the active backend. Keeps the local-side lifecycle (loading → ready /
    /// failed) intact even when the user is currently viewing API mode.
    private func setLocalState(_ s: LoadState) {
        localState = s
        if backend == .local { state = s }
    }

    public func load() async {
        guard localState != .ready, localState != .loading else { return }
        guard modelFilesAvailable else {
            setLocalState(.missing)
            return
        }
        setLocalState(.loading)
        contextWindow = Self.readContextWindow(at: modelDirectory) ?? 8192
        do {
            container = try await VLMModelFactory.shared.loadContainer(
                from: modelDirectory,
                using: #huggingFaceTokenizerLoader()
            )
            setLocalState(.ready)
        } catch {
            setLocalState(.failed("\(error)"))
        }
    }

    public func downloadAndLoad() async {
        guard localState != .ready, localState != .loading, localState != .downloading else { return }
        guard let repo = HuggingFace.Repo.ID(rawValue: Self.modelRepository) else {
            setLocalState(.failed("Invalid Hugging Face repository: \(Self.modelRepository)"))
            return
        }

        setLocalState(.downloading)
        downloadProgress = 0
        do {
            let root = modelDirectory.deletingLastPathComponent().deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: modelDirectory, withIntermediateDirectories: true)
            let cache = HuggingFace.HubCache(
                cacheDirectory: root
                    .appendingPathComponent(".cache", isDirectory: true)
                    .appendingPathComponent("huggingface", isDirectory: true)
                    .appendingPathComponent("hub", isDirectory: true)
            )
            let client = HuggingFace.HubClient(cache: cache)
            try await client.downloadSnapshot(
                of: repo,
                to: modelDirectory,
                progressHandler: { [weak self] progress in
                    self?.downloadProgress = progress.fractionCompleted
                }
            )
            await load()
        } catch {
            setLocalState(.failed("\(error)"))
        }
    }

    /// Read `text_config.max_position_embeddings` (or the top-level field) from config.json.
    private static func readContextWindow(at modelDirectory: URL) -> Int? {
        guard let data = try? Data(contentsOf: modelDirectory.appendingPathComponent("config.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let txt = root["text_config"] as? [String: Any],
           let n = txt["max_position_embeddings"] as? Int { return n }
        return root["max_position_embeddings"] as? Int
    }

    private static func hasUsableModelFiles(at directory: URL) -> Bool {
        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("config.json").path)
        else { return false }
        guard let files = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return false }
        return files.contains {
            ($0 as? URL)?.pathExtension == "safetensors"
        }
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
        cacheSlot: KVCacheSlot? = nil,
        overrideParams: GenerateParameters? = nil
    ) -> AsyncStream<StreamEvent> {
        switch backend {
        case .api:
            return streamAPI(messages: messages, tools: tools)
        case .local:
            return streamLocal(messages: messages, tools: tools, cacheSlot: cacheSlot, overrideParams: overrideParams)
        }
    }

    /// API path. cacheSlot is unused — KV caching only applies on-device.
    /// Phase flips `.idle → .decode → .idle` so the inspector still shows
    /// streaming activity in the same indicator as local mode.
    private func streamAPI(messages: [Message], tools: [ToolSpec]) -> AsyncStream<StreamEvent> {
        let config = self.apiConfig
        inferencePhase = .decode
        return AsyncStream { continuation in
            let task = Task {
                for await event in streamOpenAI(
                    messages: messages,
                    tools: tools,
                    config: config,
                    onUsage: { [weak self] total in self?.tokenCount = total }
                ) {
                    continuation.yield(event)
                }
                await MainActor.run { self.inferencePhase = .idle }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Renamed from the original `stream` body — preserved as-is below.
    private func streamLocal(
        messages: [Message],
        tools: [ToolSpec],
        cacheSlot: KVCacheSlot? = nil,
        overrideParams: GenerateParameters? = nil
    ) -> AsyncStream<StreamEvent> {
        // Snapshot the toggle now so flipping it mid-turn doesn't change
        // mid-stream. KV cache will detect the prompt-shape change on the
        // next call and re-prefill cleanly via `KVCacheSlot.prefixSkip`.
        let thinking = self.thinkingEnabled
        return AsyncStream { continuation in
            let task = Task { [container, thinking] in
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
                // With thinking disabled (see additionalContext below), each
                // turn is action-only and fits comfortably in 4096 tokens —
                // enough for a write_file body with a ~3K-token parser script
                // or a 100-row CSV in a final summarization. Larger values
                // OOM'd Metal on multi-fetch sessions; smaller values cut
                // write_file bodies short.
                let params = overrideParams
                    ?? GenerateParameters(maxTokens: 4096, temperature: 0.7)
                do {
                    await MainActor.run { self.inferencePhase = .prepare }
                    let lmInput = try await container.prepare(
                        input: UserInput(
                            chat: chat,
                            tools: tools.isEmpty ? nil : tools,
                            additionalContext: ["enable_thinking": thinking]
                        )
                    )
                    let promptTokens = lmInput.text.tokens.asArray(Int.self)
                    let promptCount = promptTokens.count
                    await MainActor.run { self.tokenCount = promptCount }

                    // Trim the input to just the tokens beyond what the cache
                    // already holds. The cache covers `skip` tokens (last
                    // turn's prompt + sampled output); the new prompt's first
                    // `skip` tokens are required to match what's cached, so
                    // re-feeding them would just duplicate work and corrupt
                    // positions. If the slot reports a mismatch we reset it
                    // and fall back to a fresh full prefill.
                    //
                    // Skip the cache path entirely when an image/video is in
                    // play — Gemma 4's image embedding tokens don't map
                    // cleanly to a 1:1 token slice, and this agent doesn't
                    // use images.
                    let canSlice = lmInput.image == nil && lmInput.video == nil
                    var skip = 0
                    if let slot = cacheSlot {
                        if canSlice, let s = slot.prefixSkip(against: promptTokens) {
                            skip = s
                        } else {
                            slot.reset()
                        }
                    }

                    let sliced: LMInput
                    if skip > 0 {
                        sliced = LMInput(
                            text: lmInput.text[0..., skip...],
                            image: lmInput.image,
                            video: lmInput.video
                        )
                    } else {
                        sliced = lmInput
                    }

                    // Drop into the container's serial lock to allocate the cache
                    // (needs the model) and kick off the cache-aware generate.
                    // The returned AsyncStream is sendable and is iterated outside
                    // the lock.
                    await MainActor.run { self.inferencePhase = .prefill }
                    let inputBox = TransferBox(sliced)
                    let toolsForCall: [ToolSpec]? = tools.isEmpty ? nil : tools
                    let stream: AsyncStream<Generation> =
                        try await container.perform { context in
                            // `makePromptCache` is mlx-swift-lm's documented entry
                            // point — it defers to the model's own `newCache` so
                            // we get the right per-layer cache mix (e.g. Gemma 4
                            // uses RotatingKVCache for local-attention layers and
                            // KVCacheSimple for global ones).
                            //
                            // The cache lives in `cacheSlot`; we don't pass it
                            // out of this closure (it isn't `Sendable`). After
                            // streaming completes we read `cacheSlot.currentOffset()`.
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

                    await MainActor.run { self.inferencePhase = .decode }
                    var brokeOnToolCall = false
                    // Debug hook: set LOCALCODE_LOG_CHUNKS=1 to print the raw
                    // chunk boundaries MLX delivers.
                    let logChunks = ProcessInfo.processInfo.environment["LOCALCODE_LOG_CHUNKS"] == "1"
                    for await gen in stream {
                        if Task.isCancelled { break }
                        if let chunk = gen.chunk {
                            if logChunks {
                                FileHandle.standardError.write(
                                    Data("[chunk] \(chunk.debugDescription)\n".utf8))
                            }
                            continuation.yield(.text(chunk))
                        } else if let tc = gen.toolCall {
                            if logChunks {
                                FileHandle.standardError.write(
                                    Data("[toolcall] \(tc.function.name)\n".utf8))
                            }
                            continuation.yield(.toolCall(tc))
                            brokeOnToolCall = true
                            break  // stop generation after first tool call
                        }
                    }

                    // Record what the cache now holds so the next call can
                    // skip the matching head — but only when the stream
                    // completed naturally. Breaking on a tool call leaves
                    // the cache in an indeterminate state (the underlying
                    // generate Task may absorb a token or two after we
                    // return), and on cancellation we also can't trust the
                    // tail, so we reset in both cases. The next turn will
                    // re-prefill from scratch.
                    if Task.isCancelled || brokeOnToolCall {
                        cacheSlot?.reset()
                    } else if canSlice, let slot = cacheSlot,
                              let postOffset = slot.currentOffset() {
                        slot.record(lastPrompt: promptTokens, cachedLength: postOffset)
                    }
                } catch {
                    continuation.yield(.text("\n[error: \(error.localizedDescription)]"))
                }
                await MainActor.run { self.inferencePhase = .idle }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
