import Foundation
import MLXLMCommon
import Synchronization

/// A per-session KV cache persisted across `InferenceEngine.stream` calls so
/// each turn only prefills the new tail of the chat, not the whole history.
/// Owned by an `AgentLoop`; a fresh loop discards the cache with the slot.
///
/// Trust assumption: re-tokenizing the history through the same chat template
/// reproduces the token IDs the model sampled. Gemma's BPE + its deterministic
/// template holds this in practice; if it broke the symptom is incoherent
/// output, which `reset()` (e.g. /clear) recovers from.
///
/// `@unchecked Sendable` because `KVCache` (an MLX class) isn't Sendable: the
/// contract is that the cache is touched only under the `Mutex` (enforced by
/// `withLock`), so the slot is safe to hand to an off-main generate call.
public final class KVCacheSlot: @unchecked Sendable {
    private struct State {
        var cache: [KVCache]?
        var lastPrompt: [Int]   // full prompt fed last turn; head must still match to reuse
        var cachedLength: Int   // cache[0].offset after last gen (prompt + sampled output)
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
