import AgentCore
import Foundation

@Observable
@MainActor
final class AppState {
    let engine = InferenceEngine()
    var loop: AgentLoop?
    var cwd: URL?
    var input: String = ""
    var isStreaming = false

    /// Set when the agent loop is suspended awaiting a tool-call approval.
    /// Bound to a sheet in ChatView.
    var pendingApproval: ApprovalRequest?
    private var pendingChoice: CheckedContinuation<ApprovalChoice, Never>?

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
        isStreaming = true
        await loop.send(text)
        isStreaming = false
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
