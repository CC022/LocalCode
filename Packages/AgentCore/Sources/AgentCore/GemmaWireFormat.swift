import Foundation
import MLXLMCommon

/// The Gemma 4 chat-template wire format, both directions.
///
/// **Grammar** (only the bits this app sends or receives):
///
/// | Wrapper                                       | Body                                                |
/// |-----------------------------------------------|-----------------------------------------------------|
/// | `<\|channel>thought\n…<channel\|>`            | chain-of-thought text                               |
/// | `<\|tool_call>…<tool_call\|>`                 | `[call:]NAME{ARGS}`                                 |
/// | `<\|tool_response>…<tool_response\|>`         | `response:NAME{value:<\|"\|>OUTPUT<\|"\|>}`         |
/// | `<\|"\|>…<\|"\|>`                             | escaped string inside `ARGS`                        |
///
/// `ARGS` is a comma-separated list of `key:value` pairs. A value is one of:
/// escaped string, `true`/`false`/`null`, integer, double, balanced `[…]`,
/// balanced `{…}`, or a bare word (treated as string).
///
/// **Why we own parsing** — MLX's streaming `ToolCallProcessor` reproducibly
/// swallows the `<|tool_call>` *opening* token when Gemma's thinking channel
/// is active, dumping the body into the text stream with only a `<tool_call|>`
/// closer surviving. We recover that case in `tokenize` by walking back over
/// the most recent text segment.
public enum GemmaWireFormat {

    // MARK: - Public API

    public struct ParsedTurn: Equatable {
        public let thinking: String?
        public let text: String
        public let toolCall: AgentToolCall?
    }

    /// Fold the raw assistant buffer into the three fields the UI cares about.
    /// - parameter includeOpenThinking: when `true`, an unclosed
    ///   `<|channel>thought` (still streaming) is surfaced via `thinking`
    ///   instead of being held back until the closer arrives.
    public static func parse(
        _ buffer: String,
        includeOpenThinking: Bool = true
    ) -> ParsedTurn {
        var thoughts: [String] = []
        var toolCall: AgentToolCall? = nil
        var textParts: [String] = []

        for seg in tokenize(buffer) {
            switch seg {
            case .thought(let body, let closed):
                guard closed || includeOpenThinking else { continue }
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { thoughts.append(trimmed) }
            case .toolCall(let name, let args):
                if toolCall == nil {
                    toolCall = AgentToolCall(name: name, arguments: args)
                }
            case .text(let s):
                textParts.append(s)
            case .toolResponse:
                continue   // not expected in fresh model output
            }
        }
        let text = textParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let thinking = thoughts.isEmpty ? nil : thoughts.joined(separator: "\n\n")
        return ParsedTurn(thinking: thinking, text: text, toolCall: toolCall)
    }

    // MARK: - Serialize (round-trip into the next prompt)

    public static func serialize(_ call: AgentToolCall) -> String {
        let body = call.arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\(formatValue($0.value))" }
            .joined(separator: ",")
        return "<|tool_call>call:\(call.name){\(body)}<tool_call|>"
    }

    public static func serializeResponse(toolName: String, output: String) -> String {
        let value = formatValue(.string(output))
        return "<|tool_response>response:\(toolName){value:\(value)}<tool_response|>"
    }

    private static func formatValue(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): "\(escapeMarker)\(s)\(escapeMarker)"
        case .bool(let b):   b ? "true" : "false"
        case .int(let n):    String(n)
        case .double(let d): String(d)
        case .null:          "null"
        case .array(let a):
            "[" + a.map(formatValue).joined(separator: ",") + "]"
        case .object(let o):
            "{" + o.sorted { $0.key < $1.key }
                .map { "\($0.key):\(formatValue($0.value))" }
                .joined(separator: ",") + "}"
        }
    }

    // MARK: - Tokenizer

    enum Segment: Equatable {
        case text(String)
        case thought(String, closed: Bool)
        case toolCall(name: String, args: [String: JSONValue])
        case toolResponse(name: String, output: String)
    }

    private struct Wrapper {
        let open: String
        let close: String
        /// `closed` is `false` when end-of-buffer arrives before the closer.
        /// Returning `nil` tells the tokenizer to drop the body silently
        /// (used for partial tool calls during streaming).
        let makeSegment: (_ body: String, _ closed: Bool) -> Segment?
    }

    /// Order matters: the longest / most specific opener for a shared prefix
    /// must come first so `<|channel>thought` wins over a bare `<|channel>`.
    private static let wrappers: [Wrapper] = [
        Wrapper(open: "<|channel>thought", close: "<channel|>") { body, closed in
            // Strip the single `\n` the chat template emits between marker
            // and content, if present.
            var b = body
            if b.hasPrefix("\n") { b.removeFirst() }
            return .thought(b, closed: closed)
        },
        Wrapper(open: "<|tool_call>", close: "<tool_call|>") { body, closed in
            guard closed, let parsed = parseCallBody(body) else { return nil }
            return .toolCall(name: parsed.name, args: parsed.args)
        },
        Wrapper(open: "<|tool_response>", close: "<tool_response|>") { body, closed in
            guard closed, let parsed = parseResponseBody(body) else { return nil }
            return .toolResponse(name: parsed.name, output: parsed.output)
        },
    ]

    /// Standalone control tokens we silently drop from the text stream.
    private static let strays: [String] = [
        "<|turn>", "<turn|>",
        "<|think|>",
        "<|channel>", "<channel|>",        // bare channel markers (non-thought)
        "<|tool_call>",                    // leaked opener without closer
        "<|tool_response>", "<tool_response|>",
        "<|tool>", "<tool|>",
    ]

    static func tokenize(_ input: String) -> [Segment] {
        var out: [Segment] = []
        var textBuf = ""
        var i = input.startIndex

        func flushText() {
            if !textBuf.isEmpty {
                out.append(.text(textBuf))
                textBuf = ""
            }
        }

        scan: while i < input.endIndex {
            let here = input[i...]

            // 1. Wrapper opener?
            for w in wrappers where here.hasPrefix(w.open) {
                let bodyStart = input.index(i, offsetBy: w.open.count)
                let (body, after, closed): (String, String.Index, Bool)
                if let closeRange = input.range(of: w.close, range: bodyStart..<input.endIndex) {
                    body = String(input[bodyStart..<closeRange.lowerBound])
                    after = closeRange.upperBound
                    closed = true
                } else {
                    body = String(input[bodyStart...])
                    after = input.endIndex
                    closed = false
                }
                flushText()
                if let seg = w.makeSegment(body, closed) {
                    out.append(seg)
                }
                i = after
                continue scan
            }

            // 2. Leaked-closer recovery: `<tool_call|>` with no matching
            //    opener. Walk back over the recently accumulated text for
            //    `NAME{ARGS}` and re-emit it as a synthesized tool call.
            if here.hasPrefix("<tool_call|>") {
                if let call = recoverLeakedCall(fromTailOf: &textBuf) {
                    flushText()
                    out.append(.toolCall(name: call.name, args: call.args))
                } else {
                    // Nothing recoverable — just drop the stray closer.
                }
                i = input.index(i, offsetBy: "<tool_call|>".count)
                continue scan
            }

            // 3. Standalone stray markers we silently drop.
            for s in strays where here.hasPrefix(s) {
                i = input.index(i, offsetBy: s.count)
                continue scan
            }

            // 4. Plain character.
            textBuf.append(input[i])
            i = input.index(after: i)
        }
        flushText()
        return out
    }

    // MARK: - Body parsers

    private static func parseCallBody(_ body: String) -> (name: String, args: [String: JSONValue])? {
        var s = Substring(body)
        if s.hasPrefix("call:") { s = s.dropFirst("call:".count) }
        guard let braceStart = s.firstIndex(of: "{"),
              let braceEnd = s.lastIndex(of: "}"),
              braceStart < braceEnd
        else { return nil }
        let name = String(s[..<braceStart]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let argsStr = String(s[s.index(after: braceStart)..<braceEnd])
        return (name, parseArgs(argsStr))
    }

    private static func parseResponseBody(_ body: String) -> (name: String, output: String)? {
        var s = Substring(body)
        if s.hasPrefix("response:") { s = s.dropFirst("response:".count) }
        guard let braceStart = s.firstIndex(of: "{"),
              let braceEnd = s.lastIndex(of: "}"),
              braceStart < braceEnd
        else { return nil }
        let name = String(s[..<braceStart])
        let inner = String(s[s.index(after: braceStart)..<braceEnd])
        if case .string(let out) = parseArgs(inner)["value"] {
            return (name, out)
        }
        return nil
    }

    /// Walk back over the END of `textBuf` for a `[call:]NAME{matched braces}`
    /// pattern. If found, the matched chars (plus an optional `call:` prefix)
    /// are sliced out of `textBuf` and returned as a parsed call.
    private static func recoverLeakedCall(
        fromTailOf textBuf: inout String
    ) -> (name: String, args: [String: JSONValue])? {
        // Allow trailing whitespace between the `}` and the closer the model
        // emitted, but no other text — that would mean the `}` is part of
        // natural-language content, not a tool call.
        var tailEnd = textBuf.endIndex
        while tailEnd > textBuf.startIndex,
              textBuf[textBuf.index(before: tailEnd)].isWhitespace {
            tailEnd = textBuf.index(before: tailEnd)
        }
        guard tailEnd > textBuf.startIndex,
              textBuf[textBuf.index(before: tailEnd)] == "}"
        else { return nil }
        let braceEnd = textBuf.index(before: tailEnd)

        // Match braces backward.
        var depth = 1
        var idx = braceEnd
        while idx > textBuf.startIndex {
            idx = textBuf.index(before: idx)
            let c = textBuf[idx]
            if c == "}" { depth += 1 }
            else if c == "{" {
                depth -= 1
                if depth == 0 { break }
            }
        }
        guard depth == 0, textBuf[idx] == "{" else { return nil }
        let braceStart = idx

        // Function name: identifier chars immediately before `{`.
        var nameStart = braceStart
        while nameStart > textBuf.startIndex {
            let prev = textBuf.index(before: nameStart)
            let c = textBuf[prev]
            if c.isLetter || c.isNumber || c == "_" { nameStart = prev }
            else { break }
        }
        guard nameStart < braceStart else { return nil }
        let name = String(textBuf[nameStart..<braceStart])
        let argsStr = String(textBuf[textBuf.index(after: braceStart)..<braceEnd])
        let args = parseArgs(argsStr)

        // Lift the matched region (plus an optional `call:` prefix) out.
        var sliceStart = nameStart
        if textBuf[..<sliceStart].hasSuffix("call:") {
            sliceStart = textBuf.index(sliceStart, offsetBy: -"call:".count)
        }
        textBuf.removeSubrange(sliceStart..<textBuf.endIndex)
        return (name, args)
    }

    // MARK: - Args scanner

    static let escapeMarker = "<|\"|>"

    static func parseArgs(_ input: String) -> [String: JSONValue] {
        // Wrap in `{…}` and reuse the object case of `scanValue` so args
        // and nested object values follow exactly the same grammar.
        let wrapped = Substring("{" + input + "}")
        guard let (value, _) = scanValue(wrapped),
              case .object(let dict) = value
        else { return [:] }
        return dict
    }

    private static func trimLeadingWhitespace(_ s: Substring) -> Substring {
        var r = s
        while let f = r.first, f.isWhitespace { r = r.dropFirst() }
        return r
    }

    /// Single recursive scanner for every value the wire format allows.
    /// Recognises escaped strings, balanced arrays, balanced objects with
    /// bare or escaped keys, scalar literals, numbers, and bare-word
    /// fallback. Stops at the next structural character (`,`, `]`, `}`)
    /// for bare tokens so it composes correctly inside containers.
    private static func scanValue(_ s: Substring) -> (JSONValue, Substring)? {
        guard let first = s.first else { return nil }

        // Escaped string: <|"|>…<|"|>
        if s.hasPrefix(escapeMarker) {
            let body = s.dropFirst(escapeMarker.count)
            guard let endRange = body.range(of: escapeMarker) else {
                return (.string(String(body)), Substring())
            }
            return (.string(String(body[..<endRange.lowerBound])),
                    body[endRange.upperBound...])
        }

        // Array: [ value (, value)* ]
        if first == "[" {
            var s2 = trimLeadingWhitespace(s.dropFirst())
            var items: [JSONValue] = []
            if s2.first == "]" { return (.array(items), s2.dropFirst()) }
            while true {
                guard let (v, rest) = scanValue(s2) else { break }
                items.append(v)
                s2 = trimLeadingWhitespace(rest)
                if s2.first == "," { s2 = trimLeadingWhitespace(s2.dropFirst()); continue }
                if s2.first == "]" { return (.array(items), s2.dropFirst()) }
                break
            }
            return (.array(items), s2)
        }

        // Object: { key:value (, key:value)* } where key is bare or `<|"|>…<|"|>`.
        if first == "{" {
            var s2 = trimLeadingWhitespace(s.dropFirst())
            var dict: [String: JSONValue] = [:]
            if s2.first == "}" { return (.object(dict), s2.dropFirst()) }
            while true {
                let key: String
                if s2.hasPrefix(escapeMarker) {
                    let body = s2.dropFirst(escapeMarker.count)
                    guard let endRange = body.range(of: escapeMarker) else { break }
                    key = String(body[..<endRange.lowerBound])
                    s2 = trimLeadingWhitespace(body[endRange.upperBound...])
                } else {
                    guard let colonIdx = s2.firstIndex(of: ":") else { break }
                    key = String(s2[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                    s2 = s2[s2.index(after: colonIdx)...]
                }
                if s2.first == ":" { s2 = s2.dropFirst() }
                s2 = trimLeadingWhitespace(s2)
                guard let (v, rest) = scanValue(s2) else { break }
                if !key.isEmpty { dict[key] = v }
                s2 = trimLeadingWhitespace(rest)
                if s2.first == "," { s2 = trimLeadingWhitespace(s2.dropFirst()); continue }
                if s2.first == "}" { return (.object(dict), s2.dropFirst()) }
                break
            }
            return (.object(dict), s2)
        }

        // Bare token, stopping at any structural char so it composes inside
        // containers.
        let stoppers: Set<Character> = [",", "]", "}"]
        var idx = s.startIndex
        while idx < s.endIndex, !stoppers.contains(s[idx]) {
            idx = s.index(after: idx)
        }
        let tok = String(s[..<idx]).trimmingCharacters(in: .whitespaces)
        let value: JSONValue
        switch tok {
        case "true":  value = .bool(true)
        case "false": value = .bool(false)
        case "null":  value = .null
        default:
            if let n = Int(tok)         { value = .int(n) }
            else if let n = Double(tok) { value = .double(n) }
            else                        { value = .string(tok) }
        }
        return (value, s[idx...])
    }
}
