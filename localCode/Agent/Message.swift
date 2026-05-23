import Foundation
import MLXLMCommon

struct AgentToolCall: Equatable, Sendable {
    let name: String
    let arguments: [String: JSONValue]

    init(name: String, arguments: [String: JSONValue]) {
        self.name = name
        self.arguments = arguments
    }

    init(_ mlx: MLXLMCommon.ToolCall) {
        self.name = mlx.function.name
        self.arguments = mlx.function.arguments
    }

    /// Compact human-readable summary for UI labels.
    var summary: String {
        switch name {
        case "bash":
            return "$ \(arguments["command"]?.string ?? "")"
        case "read_file":
            let p = arguments["path"]?.string ?? ""
            if let limit = arguments["limit"]?.int { return "read \(p) (limit \(limit))" }
            return "read \(p)"
        case "write_file":
            let p = arguments["path"]?.string ?? ""
            let n = arguments["content"]?.string?.count ?? 0
            return "write \(p) (\(n) bytes)"
        case "edit_file":
            return "edit \(arguments["path"]?.string ?? "")"
        case "glob":
            return "glob \(arguments["pattern"]?.string ?? "")"
        default:
            return name
        }
    }
}

struct Message: Identifiable, Equatable {
    enum Role { case system, user, assistant, tool }

    let id = UUID()
    let role: Role
    var text: String
    var toolCall: AgentToolCall? = nil
    var toolResult: String? = nil

    var isHiddenInUI: Bool { role == .system || role == .tool }

    static func system(_ text: String) -> Message    { .init(role: .system,    text: text) }
    static func user(_ text: String) -> Message      { .init(role: .user,      text: text) }
    static func assistant(_ text: String = "") -> Message { .init(role: .assistant, text: text) }
    static func tool(_ text: String) -> Message      { .init(role: .tool,      text: text) }
}
