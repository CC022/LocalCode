import AgentCore
import Foundation

@Observable
@MainActor
final class AppState {
    /// UserDefaults key for the last-picked working directory. Read by
    /// `LocalCodeApp` at launch to restore the session; written here on every
    /// pick so the value stays in sync (e.g. `@AppStorage` observers update).
    static let workingDirKey = "workingDirPath"
    static let backendKey = "engine.backend"
    static let apiBaseURLKey = "api.baseURL"
    static let apiModelKey = "api.model"
    static let thinkingEnabledKey = "engine.thinkingEnabled"

    /// Whether the API config sheet is currently presented. Toggled from the
    /// inspector's "Configure" button.
    var showAPIConfig = false

    let engine = InferenceEngine()
    var loop: AgentLoop?
    var cwd: URL?
    var input: String = ""
    var isStreaming = false

    /// Set when the agent loop is suspended awaiting a tool-call approval.
    /// Bound to a sheet in ChatView.
    var pendingApproval: ApprovalRequest?
    private var pendingChoice: CheckedContinuation<ApprovalChoice, Never>?

    var showModelDownloadPrompt = false

    /// Drives the right inspector visibility. Toggled by the toolbar's
    /// built-in inspector button (auto-injected by `.inspector`).
    var showTasks = true

    /// When on, the chat view swaps the formatted bubbles for a raw transcript
    /// that shows every message (including system + tool) wrapped in the
    /// model's chat-template role markers, with serialized tool calls and
    /// results inline — i.e. as close as we can get to "what the model sees /
    /// emits" without dropping to token IDs. Toggled from the inspector.
    var developerMode = false
    private var currentSend: Task<Void, Never>?

    var canSend: Bool {
        engine.state == .ready
            && !isStreaming
            && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init() {
        // Restore persisted API config + backend choice. The Keychain lookup
        // is keyed by the saved URL so changing providers later still finds
        // the matching key.
        let savedURL = UserDefaults.standard.string(forKey: Self.apiBaseURLKey)
        let savedModel = UserDefaults.standard.string(forKey: Self.apiModelKey)
        if savedURL != nil || savedModel != nil {
            engine.apiConfig = APIConfig(
                baseURL: savedURL ?? "https://api.openai.com/v1",
                model: savedModel ?? "gpt-4o-mini",
                apiKey: Keychain.load(savedURL ?? "") ?? ""
            )
        }
        if let raw = UserDefaults.standard.string(forKey: Self.backendKey),
           let backend = InferenceEngine.Backend(rawValue: raw) {
            engine.backend = backend
        }
        // Thinking toggle persists across launches. `bool(forKey:)` returns
        // `false` for unset keys, which matches the engine default.
        engine.thinkingEnabled = UserDefaults.standard.bool(forKey: Self.thinkingEnabledKey)

        // Local-side warm-up. Skipped when the user is in API mode at launch —
        // no point spinning Metal if they don't intend to use the local model.
        if engine.backend == .local {
            if engine.modelFilesAvailable {
                Task { await engine.load() }
            } else {
                engine.markModelMissing()
                showModelDownloadPrompt = true
            }
        }
    }

    /// Persist the thinking toggle. Called from the inspector's Display card.
    func setThinkingEnabled(_ b: Bool) {
        engine.thinkingEnabled = b
        UserDefaults.standard.set(b, forKey: Self.thinkingEnabledKey)
    }

    /// Persist the current backend choice. Called from the inspector picker.
    func setBackend(_ b: InferenceEngine.Backend) {
        engine.backend = b
        UserDefaults.standard.set(b.rawValue, forKey: Self.backendKey)
        // Lazy-load the local model on first switch back to local.
        if b == .local, engine.modelFilesAvailable,
           engine.state != .ready, engine.state != .loading {
            Task { await engine.load() }
        }
    }

    func downloadModel() {
        Task { await engine.downloadAndLoad() }
    }

    func pickDirectory(_ url: URL) {
        cwd = url
        UserDefaults.standard.set(url.path, forKey: Self.workingDirKey)
        let permission = Permission { [weak self] request in
            await withCheckedContinuation { (cont: CheckedContinuation<ApprovalChoice, Never>) in
                self?.pendingApproval = request
                self?.pendingChoice = cont
            }
        }
        let hooks = HookRegistry()
        hooks.register(preTool: BuiltinHooks.permission(permission))
        hooks.register(postTool: BuiltinHooks.truncateLargeOutput())
        loop = AgentLoop(cwd: url, engine: engine, hooks: hooks)
    }

    func send() async {
        guard let loop, canSend else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""

        // Slash commands are meta-actions on the chat, not turns for the model.
        // Handled here so they don't reach `AgentLoop.send` and don't appear in
        // the transcript as user messages.
        switch text {
        case "/clear":   clearConversation(); return
        case "/compact": await compactConversation(); return
        default:         break
        }

        isStreaming = true
        let task = Task { await loop.send(text) }
        currentSend = task
        await task.value
        currentSend = nil
        isStreaming = false
    }

    /// Wipe the chat back to the system prompt. Exposed for the inspector's
    /// Clear button; `/clear` in the input bar delegates here too.
    func clearConversation() {
        loop?.clear()
    }

    /// Summarize the chat into a single seed message to reclaim context. Same
    /// flow as `send()` — flips `isStreaming`, tracks the task so Stop works.
    func compactConversation() async {
        guard let loop, !isStreaming else { return }
        isStreaming = true
        let task = Task { await loop.compact() }
        currentSend = task
        await task.value
        currentSend = nil
        isStreaming = false
    }

    func stop() {
        currentSend?.cancel()
    }

    /// Called by ApprovalSheet when the user picks a choice.
    func resolveApproval(_ choice: ApprovalChoice) {
        let cont = pendingChoice
        pendingApproval = nil
        pendingChoice = nil
        cont?.resume(returning: choice)
    }

    /// Format the full chat (including hidden tool_result messages) for debugging.
    /// Each turn emits any thinking block, the assistant/user/system text, and
    /// the tool call + tool result for assistant turns. Without these fields a
    /// dumped transcript can look mysteriously blank — e.g. an assistant turn
    /// that consisted purely of a `load_skill` tool call would render as an
    /// empty `--- ASSISTANT ---` block, hiding the real model behavior.
    func exportTranscript() -> String {
        guard let loop else { return "(no chat yet)" }
        var out = "# LocalCode transcript\ncwd: \(loop.cwd.path)\n"
        for msg in loop.messages {
            let role: String = switch msg.role {
            case .system:    "SYSTEM"
            case .user:      "USER"
            case .assistant: "ASSISTANT"
            case .tool:      "TOOL"
            }
            out += "\n--- \(role) ---\n"
            if let thinking = msg.thinking, !thinking.isEmpty {
                out += "[thinking]\n\(thinking)\n"
            }
            if !msg.text.isEmpty {
                out += "\(msg.text)\n"
            }
            if let call = msg.toolCall {
                out += "[tool_call] \(call.summary)\n"
                if let result = msg.toolResult {
                    let clipped = result.count > 2000
                        ? String(result.prefix(2000)) + "\n…(truncated)"
                        : result
                    out += "[tool_result]\n\(clipped)\n"
                }
            }
        }
        return out
    }
}
