import Foundation
import MLXLMCommon

struct GlobTool: Tool {
    let cwd: URL
    let name = "glob"

    var toolSpec: ToolSpec {
        ToolSpecBuilder.make(
            name: name,
            description: "Find files matching a glob pattern (e.g. '*.swift', 'src/**/*.py'). Returns paths relative to the working directory, one per line.",
            properties: [
                (name: "pattern", type: "string", description: "Glob pattern to match against file paths"),
            ],
            required: ["pattern"]
        )
    }

    nonisolated func run(_ arguments: [String: JSONValue]) async -> String {
        guard let pattern = arguments["pattern"]?.string else { return "Error: missing 'pattern'" }
        let cwd = self.cwd
        return await Task.detached(priority: .userInitiated) {
            GlobTool.search(pattern: pattern, cwd: cwd)
        }.value
    }

    private static func search(pattern: String, cwd: URL) -> String {
        let regex: Regex<AnyRegexOutput>
        do {
            regex = try Regex(globToRegex(pattern))
        } catch {
            return "Error: invalid pattern '\(pattern)'"
        }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: cwd,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return "(no matches)" }

        let rootPath = cwd.standardizedFileURL.path
        var results: [String] = []
        for case let url as URL in enumerator {
            guard let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile,
                  isFile else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath + "/") else { continue }
            let rel = String(full.dropFirst(rootPath.count + 1))
            if (try? regex.wholeMatch(in: rel)) != nil {
                results.append(rel)
            }
            if results.count >= 1000 { break }
        }
        return results.isEmpty ? "(no matches)" : results.sorted().joined(separator: "\n")
    }

    /// Glob → regex: `**` → `.*`, `*` → `[^/]*`, `?` → `[^/]`, regex chars escaped.
    private static func globToRegex(_ glob: String) -> String {
        var out = ""
        var i = glob.startIndex
        while i < glob.endIndex {
            let c = glob[i]
            switch c {
            case "*":
                let next = glob.index(after: i)
                if next < glob.endIndex, glob[next] == "*" {
                    out += ".*"
                    i = glob.index(after: next)
                    continue
                }
                out += "[^/]*"
            case "?": out += "[^/]"
            case ".", "+", "(", ")", "|", "^", "$", "{", "}", "[", "]", "\\":
                out += "\\\(c)"
            default: out.append(c)
            }
            i = glob.index(after: i)
        }
        return out
    }
}
