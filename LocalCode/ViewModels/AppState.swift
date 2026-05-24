import AgentCore
import Foundation

@Observable
@MainActor
final class AppState {
    /// UserDefaults key for the last-picked working directory. Read by
    /// `LocalCodeApp` at launch to restore the session; written here on every
    /// pick so the value stays in sync (e.g. `@AppStorage` observers update).
    static let workingDirKey = "workingDirPath"

    let engine = InferenceEngine()
    var loop: AgentLoop?
    var cwd: URL?
    var input: String = ""
    var isStreaming = false

    /// Set when the agent loop is suspended awaiting a tool-call approval.
    /// Bound to a sheet in ChatView.
    var pendingApproval: ApprovalRequest?
    private var pendingChoice: CheckedContinuation<ApprovalChoice, Never>?

    /// Toggled by the status-bar button. Drives the right inspector.
    var showTasks = true
    private var currentSend: Task<Void, Never>?

    var canSend: Bool {
        engine.state == .ready
            && !isStreaming
            && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init() {
        // Start warming the model immediately — don't wait for the user to pick a folder.
        Task { await engine.load() }
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
        case "/clear":
            loop.clear()
            return
        case "/compact":
            isStreaming = true
            let task = Task { await loop.compact() }
            currentSend = task
            await task.value
            currentSend = nil
            isStreaming = false
            return
        default:
            break
        }

        isStreaming = true
        let task = Task { await loop.send(text) }
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
            out += "\n--- \(role) ---\n\(msg.text)\n"
        }
        return out
    }
}
