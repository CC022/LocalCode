import Foundation
import MLXLMCommon

struct ReadFileTool: Tool {
    let cwd: URL
    let name = "read_file"

    var toolSpec: ToolSpec {
        ToolSpecBuilder.make(
            name: name,
            description: "Read a text file's contents.",
            properties: [
                (name: "path", type: "string", description: "Path relative to the working directory"),
                (name: "limit", type: "integer", description: "Maximum number of lines to return (optional)"),
            ],
            required: ["path"]
        )
    }

    nonisolated func run(_ arguments: [String: JSONValue]) async -> String {
        guard let path = arguments["path"]?.string else { return "Error: missing 'path'" }
        let limit = arguments["limit"]?.int
        do {
            let url = try SafePath.resolve(path, cwd: cwd)
            let text = try String(contentsOf: url, encoding: .utf8)
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if let limit, limit < lines.count {
                let dropped = lines.count - limit
                lines = Array(lines.prefix(limit)) + ["... (\(dropped) more lines)"]
            }
            return lines.joined(separator: "\n")
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
