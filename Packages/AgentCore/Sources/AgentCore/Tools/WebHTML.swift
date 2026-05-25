import Foundation

/// Shared helpers for the `web_search` / `web_fetch` tools: a tiny URLSession
/// wrapper and a regex-based HTML→text stripper. Native Swift only, no deps.
enum WebHTML {
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// GET `url`, return (status, decoded body). UTF-8 with ISO-8859-1 fallback.
    static func get(_ url: URL, timeout: TimeInterval = 30) async throws -> (status: Int, contentType: String?, body: String) {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        let body = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return (http?.statusCode ?? 0, http?.value(forHTTPHeaderField: "Content-Type"), body)
    }

    /// HTML → readable text: drop script/style blocks, strip tags, decode the
    /// handful of entities people actually hit, collapse whitespace.
    static func strip(_ html: String) -> String {
        var s = html
        for pattern in [#"<script\b[^>]*>[\s\S]*?</script>"#, #"<style\b[^>]*>[\s\S]*?</style>"#] {
            if let re = (try? Regex(pattern))?.ignoresCase() {
                s.replace(re, with: " ")
            }
        }
        if let tag = try? Regex(#"<[^>]+>"#) {
            s.replace(tag, with: " ")
        }
        s = decodeEntities(s)
        if let ws = try? Regex(#"[ \t\u{00A0}]+"#) { s.replace(ws, with: " ") }
        if let nl = try? Regex(#"\n[ \t]*\n(\s*\n)+"#) { s.replace(nl, with: "\n\n") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": " ", "#39": "'",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard let re = try? Regex(#"&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);"#) else { return s }
        var out = s
        out.replace(re) { match in
            let body = String(match.output[0].substring ?? "").dropFirst().dropLast()
            if body.hasPrefix("#x"), let code = UInt32(body.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) {
                return String(Character(scalar))
            }
            if body.hasPrefix("#"), let code = UInt32(body.dropFirst()), let scalar = Unicode.Scalar(code) {
                return String(Character(scalar))
            }
            return namedEntities[String(body)] ?? String(match.output[0].substring ?? "")
        }
        return out
    }
}
