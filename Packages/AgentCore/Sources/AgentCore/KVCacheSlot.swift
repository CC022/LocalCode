import Foundation
import MLXLMCommon
import Synchronization

/// A holder for a per-session KV cache, persisted across `InferenceEngine.stream`
/// calls so the model only prefills the tail of the chat each turn instead of
/// the entire history. Lifetime is tied to whoever owns the slot (typically an
/// `AgentLoop`); creating a fresh `AgentLoop` discards the old slot and the old
/// cache with it.
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
    private let storage = Mutex<[KVCache]?>(nil)

    public init() {}

    /// Return the existing cache, or allocate one via the closure on first use.
    public func getOrAllocate(_ allocate: () -> [KVCache]) -> [KVCache] {
        storage.withLock { cache in
            if let existing = cache { return existing }
            let fresh = allocate()
            cache = fresh
            return fresh
        }
    }

    /// Drop the cache. Call when the chat history is restarted (the next
    /// generate will allocate a fresh one and prefill from scratch).
    public func reset() {
        storage.withLock { $0 = nil }
    }
}
