import Foundation
import MLXLMCommon
import Synchronization

/// A holder for a per-session KV cache, persisted across `InferenceEngine.stream`
/// calls so the model only prefills the tail of the chat each turn instead of
/// the entire history. Lifetime is tied to whoever owns the slot (typically an
/// `AgentLoop`); creating a fresh `AgentLoop` discards the old slot and the old
/// cache with it.
///
/// The slot tracks two things alongside the cache itself:
///
/// - `lastPrompt`: the token IDs of the full prompt we fed last turn. Used to
///   verify the head of the next prompt still matches before reusing the cache.
///   If it diverges (rare — would only happen if the system prompt or earlier
///   history was edited), we reset rather than silently corrupt the cache.
/// - `cachedLength`: `cache[0].offset` observed after the last generation, i.e.
///   how many tokens the cache actually holds (prompt + sampled output).
///   The next turn feeds `newPrompt[cachedLength...]` so prefill only covers
///   genuinely new content.
///
/// The "trust" assumption is that re-tokenizing the chat history through the
/// same chat template produces, for the assistant turn, the same token IDs the
/// model sampled. Gemma's BPE tokenizer + deterministic chat template makes
/// this hold in practice. If it ever broke, the symptom would be incoherent
/// output, in which case `reset()` (e.g. via /clear) recovers immediately.
///
/// `[KVCache]` is an array of class instances that the token iterator mutates
/// during generation. Reusing the same array across turns is exactly how
/// `MLXLMCommon.ChatSession` runs — the cache instances accumulate keys/values
/// as more tokens are processed.
///
/// Thread-safety: backed by Swift's `Synchronization.Mutex`, so the same slot
/// is safe to hand to a generate call running off the main actor. The
/// `@unchecked Sendable` is needed because `KVCache` (an MLX class) is not
/// itself Sendable — the contract is that the cache is only touched while the
/// mutex is held, which `withLock` enforces.
public final class KVCacheSlot: @unchecked Sendable {
    private struct State {
        var cache: [KVCache]?
        var lastPrompt: [Int]
        var cachedLength: Int
    }

    private let storage = Mutex<State>(.init(cache: nil, lastPrompt: [], cachedLength: 0))

    public init() {}

    /// Return the existing cache, or allocate one via the closure on first use.
    public func getOrAllocate(_ allocate: () -> [KVCache]) -> [KVCache] {
        storage.withLock { state in
            if let existing = state.cache { return existing }
            let fresh = allocate()
            state.cache = fresh
            return fresh
        }
    }

    /// Read the current `cache[0].offset` if the cache has been allocated.
    /// Used to record `cachedLength` after generation completes without
    /// having to smuggle the non-`Sendable` `[KVCache]?` array out of the
    /// `container.perform` closure that allocated it.
    public func currentOffset() -> Int? {
        storage.withLock { state in state.cache?.first?.offset }
    }

    /// Decide how many tokens at the head of `newPrompt` are already in the
    /// cache and can be skipped during prefill.
    ///
    /// Returns the number of tokens to skip (== `cachedLength`) when the head
    /// of `newPrompt` matches the last full prompt and `newPrompt` is at least
    /// as long as the cache. Returns `nil` otherwise — the caller should
    /// `reset()` the slot and prefill the whole prompt.
    public func prefixSkip(against newPrompt: [Int]) -> Int? {
        storage.withLock { state in
            guard state.cache != nil,
                  !state.lastPrompt.isEmpty,
                  newPrompt.count >= state.cachedLength,
                  newPrompt.count >= state.lastPrompt.count
            else { return nil }
            for i in 0 ..< state.lastPrompt.count {
                if newPrompt[i] != state.lastPrompt[i] { return nil }
            }
            return state.cachedLength
        }
    }

    /// Record what the cache now corresponds to after a successful generation.
    /// `cachedLength` is `cache[0].offset` read post-stream.
    public func record(lastPrompt: [Int], cachedLength: Int) {
        storage.withLock { state in
            state.lastPrompt = lastPrompt
            state.cachedLength = cachedLength
        }
    }

    /// Drop the cache. Call when the chat history is restarted (the next
    /// generate will allocate a fresh one and prefill from scratch).
    public func reset() {
        storage.withLock { state in
            state.cache = nil
            state.lastPrompt = []
            state.cachedLength = 0
        }
    }
}
