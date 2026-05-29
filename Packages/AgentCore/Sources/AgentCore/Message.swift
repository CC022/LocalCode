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
        case "load_skill":
            return "load skill \(arguments["name"]?.string ?? "?")"
        case "web_search":
            return "search \"\(arguments["query"]?.string ?? "")\""
        case "web_fetch":
            return "fetch \(arguments["url"]?.string ?? "")"
        case "parse_pdf":
            let p = arguments["path"]?.string ?? ""
            if let pages = arguments["pages"]?.string, !pages.isEmpty {
                return "parse PDF \(p) (pages \(pages))"
            }
            return "parse PDF \(p)"
        case "translate_md":
            let p = arguments["path"]?.string ?? ""
            let lang = arguments["target_language"]?.string ?? "?"
            return "translate \(p) → \(lang)"
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
    public enum Role: Sendable {
        case system, user, assistant, tool

        /// Uppercase label for plain-text transcript dumps. (The chat-template
        /// tag differs — `.assistant` is "model" there — and lives elsewhere.)
        public var label: String {
            switch self {
            case .system:    "SYSTEM"
            case .user:      "USER"
            case .assistant: "ASSISTANT"
            case .tool:      "TOOL"
            }
        }
    }

    public let id = UUID()
    public let role: Role
    public var text: String
    public var toolCall: AgentToolCall? = nil
    public var toolResult: String? = nil
    /// Chain-of-thought content the model emitted inside
    /// `<|channel>thought\n…<channel|>` (Gemma 4 thinking mode). Stripped out
    /// of `text` so the bubble renders only the user-facing response, but
    /// surfaced separately so the UI can show it as muted secondary text.
    public var thinking: String? = nil

    public var isHiddenInUI: Bool { role == .system || role == .tool }

    public static func system(_ text: String) -> Message    { .init(role: .system,    text: text) }
    public static func user(_ text: String) -> Message      { .init(role: .user,      text: text) }
    public static func assistant(_ text: String = "") -> Message { .init(role: .assistant, text: text) }
    public static func tool(_ text: String) -> Message      { .init(role: .tool,      text: text) }
}
