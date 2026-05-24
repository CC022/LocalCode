import Foundation
import MLXLMCommon

public struct AgentToolCall: Equatable, Sendable {
    public let name: String
    public let arguments: [String: JSONValue]

    public init(name: String, arguments: [String: JSONValue]) {
        self.name = name
        self.arguments = arguments
    }

    public init(_ mlx: MLXLMCommon.ToolCall) {
        self.name = mlx.function.name
        self.arguments = mlx.function.arguments
    }

    /// Compact human-readable summary for UI labels.
    public var summary: String {
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
        case "todo_write":
            // `todos` is a JSON-encoded string (see TodoWriteTool for why).
            let count: Int = {
                guard let s = arguments["todos"]?.string,
                      let data = s.data(using: .utf8),
                      let arr = try? JSONSerialization.jsonObject(with: data) as? [Any]
                else { return 0 }
                return arr.count
            }()
            return "update todos (\(count))"
        default:
            return name
        }
    }
}

public struct Message: Identifiable, Equatable {
    public enum Role: Sendable { case system, user, assistant, tool }

    public let id = UUID()
    public let role: Role
    public var text: String
    public var toolCall: AgentToolCall? = nil
    public var toolResult: String? = nil

    public var isHiddenInUI: Bool { role == .system || role == .tool }

    public static func system(_ text: String) -> Message    { .init(role: .system,    text: text) }
    public static func user(_ text: String) -> Message      { .init(role: .user,      text: text) }
    public static func assistant(_ text: String = "") -> Message { .init(role: .assistant, text: text) }
    public static func tool(_ text: String) -> Message      { .init(role: .tool,      text: text) }
}
