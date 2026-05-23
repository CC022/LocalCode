import Foundation

enum SystemPrompt {
    static func make(cwd: URL) -> String {
        """
        You are a coding agent at \(cwd.path). Use the available tools to solve tasks. \
        Act, don't explain. When the task is complete, reply with plain text.
        """
    }
}
