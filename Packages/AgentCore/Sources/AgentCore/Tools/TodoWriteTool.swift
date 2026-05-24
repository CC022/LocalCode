import Foundation
import MLXLMCommon

/// Planning surface for the agent — no execution, just a structured task list
/// that lives in-memory and mirrors into AgentLoop's observable `todos` for
/// the inspector. The list is not persisted to disk; restarting the app or
/// changing working directory resets it.
///
/// `todos` is taken as a **JSON-encoded string** rather than a structured
/// array. The Gemma tool-call parser (`GemmaFunctionParser`) splits arguments
/// on top-level commas without bracket-awareness, so any nested array-of-
/// objects argument breaks during parse. Strings are routed through the
/// escape markers (`<|"|>…<|"|>`), which the parser handles correctly, so we
/// trade schema fidelity for parser compatibility and decode the JSON here.
struct TodoWriteTool: Tool {
    let name = "todo_write"
    /// Called on the main actor after a successful write. Wired by AgentLoop.
    let onUpdate: @MainActor @Sendable ([TodoItem]) -> Void

    var toolSpec: ToolSpec {
        ToolSpecBuilder.make(
            name: name,
            description: "Update the task list for the current session. Pass a JSON-encoded array of {content, status} objects where status is one of 'pending', 'in_progress', or 'completed'. Replaces the full list each call.",
            properties: [
                (name: "todos", type: "string",
                 description: #"JSON array of todo items, e.g. '[{"content":"read main.py","status":"pending"},{"content":"refactor","status":"in_progress"}]'"#),
            ],
            required: ["todos"]
        )
    }

    nonisolated func run(_ arguments: [String: JSONValue]) async -> String {
        guard let jsonStr = arguments["todos"]?.string else {
            return "Error: missing 'todos' (expected JSON string)"
        }
        guard let data = jsonStr.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return "Error: 'todos' must be a JSON array of {content, status} objects"
        }
        var items: [TodoItem] = []
        items.reserveCapacity(raw.count)
        for (i, obj) in raw.enumerated() {
            guard let content = obj["content"] as? String else {
                return "Error: todos[\(i)] missing 'content'"
            }
            guard let statusStr = obj["status"] as? String else {
                return "Error: todos[\(i)] missing 'status'"
            }
            guard let status = TodoItem.Status(rawValue: statusStr) else {
                return "Error: todos[\(i)] has invalid status '\(statusStr)'"
            }
            items.append(TodoItem(content: content, status: status))
        }

        let snapshot = items
        await MainActor.run { onUpdate(snapshot) }

        var lines = ["## Current Tasks"]
        for t in items {
            let icon: String = switch t.status {
            case .pending:     " "
            case .in_progress: "▸"
            case .completed:   "✓"
            }
            lines.append("  [\(icon)] \(t.content)")
        }
        lines.append("Updated \(items.count) tasks")
        return lines.joined(separator: "\n")
    }
}
