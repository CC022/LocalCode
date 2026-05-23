import Foundation
import MLXLMCommon

struct WriteFileTool: Tool {
    let cwd: URL
    let name = "write_file"

    var toolSpec: ToolSpec {
        ToolSpecBuilder.make(
            name: name,
            description: "Write content to a file, creating parent directories as needed.",
            properties: [
                (name: "path", type: "string", description: "Path relative to the working directory"),
                (name: "content", type: "string", description: "Full file contents to write"),
            ],
            required: ["path", "content"]
        )
    }

    nonisolated func run(_ arguments: [String: JSONValue]) async -> String {
        guard let path = arguments["path"]?.string,
              let content = arguments["content"]?.string
        else { return "Error: missing 'path' or 'content'" }
        do {
            let url = try SafePath.resolve(path, cwd: cwd)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return "Wrote \(content.utf8.count) bytes to \(path)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
