import Foundation

/// A code-level registry for AgentLoop extension points.
///
/// Four events fired per agent cycle:
/// - `userPrompt`  → just before the LLM sees a user message. Hooks may
///                   return a replacement string (or nil to pass through).
/// - `preTool`     → before a tool runs. Hooks may return a non-nil reason
///                   to block; first non-nil wins (Permission lives here).
/// - `postTool`    → after a tool returns. Hooks may return a replacement
///                   output (or nil to pass through); chained left-to-right.
/// - `stop`        → when the loop is about to exit. Side-effect only.
///
/// The loop body never grows: new behavior plugs into the registry.
@MainActor
public final class HookRegistry {
    public typealias UserPromptHook = (String) async -> String?
    public typealias PreToolHook    = (AgentToolCall) async -> String?
    public typealias PostToolHook   = (AgentToolCall, String) async -> String?
    public typealias StopHook       = () async -> Void

    private var userPromptHooks: [UserPromptHook] = []
    private var preToolHooks:    [PreToolHook]    = []
    private var postToolHooks:   [PostToolHook]   = []
    private var stopHooks:       [StopHook]       = []

    public init() {}

    public func register(userPrompt hook: @escaping UserPromptHook) { userPromptHooks.append(hook) }
    public func register(preTool    hook: @escaping PreToolHook)    { preToolHooks.append(hook) }
    public func register(postTool   hook: @escaping PostToolHook)   { postToolHooks.append(hook) }
    public func register(stop       hook: @escaping StopHook)       { stopHooks.append(hook) }

    /// Run user-prompt hooks left-to-right, each may replace the text.
    func triggerUserPrompt(_ text: String) async -> String {
        var current = text
        for hook in userPromptHooks {
            if let next = await hook(current) { current = next }
        }
        return current
    }

    /// Run pre-tool hooks; first non-nil return blocks dispatch.
    /// Returns the block reason if blocked, nil to allow.
    func triggerPreTool(_ call: AgentToolCall) async -> String? {
        for hook in preToolHooks {
            if let reason = await hook(call) { return reason }
        }
        return nil
    }

    /// Run post-tool hooks left-to-right, each may replace the output.
    func triggerPostTool(_ call: AgentToolCall, output: String) async -> String {
        var current = output
        for hook in postToolHooks {
            if let next = await hook(call, current) { current = next }
        }
        return current
    }

    /// Fire stop hooks (no return value, used for cleanup/summaries).
    func triggerStop() async {
        for hook in stopHooks { await hook() }
    }
}

/// Out-of-the-box hooks. Compose these into your `HookRegistry` at startup.
public enum BuiltinHooks {

    /// Replace big tool outputs with a head+tail snapshot so they don't
    /// blow up the context window. Defaults to 10k chars (~2.5k tokens).
    public static func truncateLargeOutput(maxChars: Int = 10_000)
        -> HookRegistry.PostToolHook
    {
        { _, output in
            guard output.count > maxChars else { return nil }
            let half = maxChars / 2
            let omitted = output.count - maxChars
            return "\(output.prefix(half))\n\n… [\(omitted) chars omitted] …\n\n\(output.suffix(half))"
        }
    }

    /// Adapt a `Permission` instance into a pre-tool hook. The first hook
    /// that returns non-nil wins, so register Permission first if you want
    /// denials to short-circuit logging hooks.
    public static func permission(_ permission: Permission) -> HookRegistry.PreToolHook {
        { call in
            switch await permission.check(call) {
            case .allow:            return nil
            case .deny(let reason): return reason
            }
        }
    }
}
