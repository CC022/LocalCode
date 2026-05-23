import Foundation
import MLXLMCommon

struct EditFileTool: Tool {
    let cwd: URL
    let name = "edit_file"

    var toolSpec: ToolSpec {
        ToolSpecBuilder.make(
            name: name,
            description: "Replace exact text in a file once.",
            properties: [
                (name: "path", type: "string", description: "Path relative to the working directory"),
                (name: "old_text", type: "string", description: "Exact text to find"),
                (name: "new_text", type: "string", description: "Replacement text"),
            ],
            required: ["path", "old_text", "new_text"]
        )
    }

    nonisolated func run(_ arguments: [String: JSONValue]) async -> String {
        guard let path = arguments["path"]?.string,
              let old = arguments["old_text"]?.string,
              let new = arguments["new_text"]?.string
        else { return "Error: missing 'path', 'old_text', or 'new_text'" }
        do {
            let url = try SafePath.resolve(path, cwd: cwd)
            let text = try String(contentsOf: url, encoding: .utf8)
            guard let range = text.range(of: old) else {
                return "Error: text not found in \(path)"
            }
            let updated = text.replacingCharacters(in: range, with: new)
            try updated.write(to: url, atomically: true, encoding: .utf8)
            return "Edited \(path)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
