import Foundation
import MLXLMCommon

struct WebFetchTool: Tool {
    let name = "web_fetch"

    var toolSpec: ToolSpec {
        ToolSpecBuilder.make(
            name: name,
            description: "Fetch a URL over HTTP(S) and return its text. HTML is stripped to readable text. Pass a larger 'limit' (e.g. 30000) for dense data pages (tables, lists, CSVs).",
            properties: [
                (name: "url", type: "string", description: "Absolute http(s) URL"),
                (name: "limit", type: "integer", description: "Max characters to return (default 16000, max 60000)"),
            ],
            required: ["url"]
        )
    }

    private static let defaultLimit = 16_000
    private static let maxLimit = 60_000

    nonisolated func run(_ arguments: [String: JSONValue]) async -> String {
        guard let raw = arguments["url"]?.string,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return "Error: 'url' must be an absolute http(s) URL" }
        let limit = min(arguments["limit"]?.int ?? Self.defaultLimit, Self.maxLimit)
        do {
            let (status, contentType, body) = try await WebHTML.get(url)
            if status >= 400 { return "Error: HTTP \(status)" }
            let ct = contentType?.lowercased() ?? ""
            let isHTML = ct.isEmpty || ct.contains("html") || ct.contains("xml")
            let text = isHTML ? WebHTML.strip(body) : body

            // Heuristic: if a sizable HTML page strips down to almost nothing,
            // the content is JavaScript-rendered and not retrievable this way.
            // Surface that explicitly so the model can switch sources rather
            // than re-fetching JS shells.
            var prefix = ""
            if isHTML, body.count > 30_000, text.count < 1_500 {
                prefix = "(note: page appears JavaScript-rendered — static HTML had little text. Try a different source, an API endpoint, or a CSV/JSON URL.)\n\n"
            }

            let payload: String
            if text.count > limit {
                let dropped = text.count - limit
                payload = String(text.prefix(limit)) + "\n... (\(dropped) more chars)"
            } else {
                payload = text.isEmpty ? "(empty body)" : text
            }
            return prefix + payload
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
