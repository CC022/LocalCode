import Foundation

public struct TodoItem: Identifiable, Sendable, Equatable {
    public enum Status: String, Sendable, Codable { case pending, in_progress, completed }

    public let id = UUID()
    public let content: String
    public let status: Status

    public init(content: String, status: Status) {
        self.content = content
        self.status = status
    }
}
