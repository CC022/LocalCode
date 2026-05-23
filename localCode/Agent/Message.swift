import Foundation

struct ToolCall: Equatable, Sendable {
    let command: String
}

struct Message: Identifiable, Equatable {
    enum Role { case system, user, assistant }

    let id = UUID()
    let role: Role
    var text: String
    var toolCall: ToolCall? = nil
    var toolResult: String? = nil
    var isHiddenInUI: Bool = false

    static func system(_ text: String) -> Message {
        Message(role: .system, text: text, isHiddenInUI: true)
    }
    static func user(_ text: String) -> Message {
        Message(role: .user, text: text)
    }
    static func assistant(_ text: String = "") -> Message {
        Message(role: .assistant, text: text)
    }
}
