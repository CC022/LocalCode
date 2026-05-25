import Foundation
import MLXLMCommon

/// DuckDuckGo HTML scraper. No API key, no config — but fragile to DDG markup
/// changes. If DDG ever revamps the page, only the two regexes below and the
/// `uddg` unwrap need to change.
struct WebSearchTool: Tool {
    let name = "web_search"

    var toolSpec: ToolSpec {
        ToolSpecBuilder.make(
            name: name,
            description: "Search the web (via DuckDuckGo) and return the top results as title/url/snippet.",
            properties: [
                (name: "query", type: "string", description: "Search query"),
                (name: "limit", type: "integer", description: "Number of results, 1–10 (default 5)"),
            ],
            required: ["query"]
        )
    }

    private static let resultRegex = #/<a[^>]+class="[^"]*result__a[^"]*"[^>]+href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/#
    private static let snippetRegex = #/<a[^>]+class="[^"]*result__snippet[^"]*"[^>]*>([\s\S]*?)<\/a>/#

    nonisolated func run(_ arguments: [String: JSONValue]) async -> String {
        guard let query = arguments["query"]?.string, !query.isEmpty else {
            return "Error: missing 'query'"
        }
        let limit = max(1, min(arguments["limit"]?.int ?? 5, 10))
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)")
        else { return "Error: invalid query" }

        do {
            let (status, _, html) = try await WebHTML.get(url)
            if status >= 400 { return "Error: HTTP \(status)" }

            let links = html.matches(of: Self.resultRegex)
            let snippets = html.matches(of: Self.snippetRegex)
            guard !links.isEmpty else {
                return "Error: no results (DDG markup may have changed)"
            }

            var lines: [String] = []
            for (i, link) in links.prefix(limit).enumerated() {
                let realURL = unwrapDDG(String(link.output.1))
                let title = WebHTML.strip(String(link.output.2))
                let snippet = i < snippets.count
                    ? WebHTML.strip(String(snippets[i].output.1))
                    : ""
                lines.append("\(i + 1). \(title)\n   \(realURL)\n   \(snippet)")
            }
            return lines.joined(separator: "\n\n")
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    /// DDG wraps outbound URLs as `//duckduckgo.com/l/?uddg=<encoded>&rut=…`.
    /// Pull out the real URL, or return the input untouched if it isn't wrapped.
    private func unwrapDDG(_ href: String) -> String {
        let normalized = href.hasPrefix("//") ? "https:\(href)" : href
        guard let comps = URLComponents(string: normalized),
              comps.host?.contains("duckduckgo.com") == true,
              let uddg = comps.queryItems?.first(where: { $0.name == "uddg" })?.value
        else { return normalized }
        return uddg
    }
}
