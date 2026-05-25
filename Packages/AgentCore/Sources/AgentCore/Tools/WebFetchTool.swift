import Foundation
import MLXLMCommon

struct WebFetchTool: Tool {
    let name = "web_fetch"

    var toolSpec: ToolSpec {
        ToolSpecBuilder.make(
            name: name,
            description: "Fetch a URL over HTTP(S) and return its text. HTML is stripped to readable text.",
            properties: [
                (name: "url", type: "string", description: "Absolute http(s) URL"),
                (name: "limit", type: "integer", description: "Max characters to return (default 20000)"),
            ],
            required: ["url"]
        )
    }

    private static let defaultLimit = 20_000

    nonisolated func run(_ arguments: [String: JSONValue]) async -> String {
        guard let raw = arguments["url"]?.string,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return "Error: 'url' must be an absolute http(s) URL" }
        let limit = arguments["limit"]?.int ?? Self.defaultLimit
        do {
            let (status, contentType, body) = try await WebHTML.get(url)
            if status >= 400 { return "Error: HTTP \(status)" }
            let ct = contentType?.lowercased() ?? ""
            let text = (ct.isEmpty || ct.contains("html") || ct.contains("xml"))
                ? WebHTML.strip(body)
                : body
            if text.count > limit {
                let dropped = text.count - limit
                return String(text.prefix(limit)) + "\n... (\(dropped) more chars)"
            }
            return text.isEmpty ? "(empty body)" : text
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
