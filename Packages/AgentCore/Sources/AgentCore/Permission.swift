import Foundation

public enum PermissionDecision: Sendable, Equatable {
    case allow
    case deny(reason: String)
}

public enum ApprovalChoice: Sendable {
    case once      // allow this single call
    case session   // allow this call + identical future calls
    case deny
}

public struct ApprovalRequest: Identifiable, Sendable {
    public let id = UUID()
    public let call: AgentToolCall
    public let reason: String
}

/// Three-gate permission pipeline run before every tool dispatch:
///   1. **Deny list** — hard block on dangerous patterns (`rm -rf /`, `sudo`, …).
///   2. **Rule match** — context-aware "needs approval" rules (destructive
///      shell commands, writes to sensitive paths).
///   3. **User approval** — calls the injected `ask` closure; remembers
///      session-wide "allow always" decisions.
@MainActor
public final class Permission {
    public typealias Ask = @MainActor (ApprovalRequest) async -> ApprovalChoice

    private var sessionAllowed: Set<String> = []
    private let ask: Ask

    public init(ask: @escaping Ask) {
        self.ask = ask
    }

    public func check(_ call: AgentToolCall) async -> PermissionDecision {
        // Gate 1 — hard deny (bash-only, per s03)
        if call.name == "bash",
           let command = call.arguments["command"]?.string,
           let pattern = Self.denyList.first(where: command.contains) {
            return .deny(reason: "'\(pattern)' is on the deny list")
        }

        // Gate 2 — rule match
        guard let reason = Self.ruleReason(for: call) else { return .allow }

        // Session memory short-circuit
        let key = sessionKey(call)
        if sessionAllowed.contains(key) { return .allow }

        // Gate 3 — ask the user
        switch await ask(ApprovalRequest(call: call, reason: reason)) {
        case .once:    return .allow
        case .session: sessionAllowed.insert(key); return .allow
        case .deny:    return .deny(reason: "User denied (\(reason))")
        }
    }

    private static let denyList = [
        "rm -rf /", "sudo", "shutdown", "reboot", "mkfs", "dd if=", "> /dev/sda",
    ]

    /// Returns a human-readable reason if the call should require approval, else nil.
    private static func ruleReason(for call: AgentToolCall) -> String? {
        switch call.name {
        case "bash":
            let cmd = call.arguments["command"]?.string ?? ""
            let destructive = ["rm ", "mv ", "> /etc/", "chmod 777", "git push --force", "git reset --hard"]
            if destructive.contains(where: cmd.contains) { return "Potentially destructive shell command" }
        case "write_file", "edit_file":
            let path = call.arguments["path"]?.string ?? ""
            let sensitive = [".git/", ".env"]
            if sensitive.contains(where: path.hasPrefix) || sensitive.contains(where: path.contains) {
                return "Writing to a sensitive path"
            }
        default: return nil
        }
        return nil
    }

    /// Stable key for "session-allow" memory. Tool name + sorted-arg JSON-ish.
    private func sessionKey(_ call: AgentToolCall) -> String {
        let args = call.arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(String(describing: $0.value))" }
            .joined(separator: ",")
        return "\(call.name)(\(args))"
    }
}
