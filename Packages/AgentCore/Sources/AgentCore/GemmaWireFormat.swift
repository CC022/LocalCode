import Foundation
import MLXLMCommon

/// Serialize an `AgentToolCall` into Gemma 4's on-the-wire format so it can be
/// embedded back into the assistant turn's `content`. Mirrors the
/// `format_argument` macro in the model's `chat_template.jinja`.
///
/// Required because `Chat.Message` only carries `role` + `content` — the default
/// `MessageGenerator` doesn't emit a `tool_calls` field, so without this the
/// model can't see its own prior tool calls and loops forever.
enum GemmaWireFormat {
    static func serialize(_ call: AgentToolCall) -> String {
        let body = call.arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\(format($0.value, escapeKeys: false))" }
            .joined(separator: ",")
        return "<|tool_call>call:\(call.name){\(body)}<tool_call|>"
    }

    /// Render a tool result the way the chat template's
    /// `format_tool_response_block` macro would.
    static func serializeResponse(toolName: String, output: String) -> String {
        let value = format(.string(output), escapeKeys: false)
        return "<|tool_response>response:\(toolName){value:\(value)}<tool_response|>"
    }

    private static func format(_ v: JSONValue, escapeKeys: Bool) -> String {
        switch v {
        case .string(let s): "<|\"|>\(s)<|\"|>"
        case .bool(let b):   b ? "true" : "false"
        case .int(let n):    String(n)
        case .double(let d): String(d)
        case .null:          "null"
        case .array(let a):
            "[" + a.map { format($0, escapeKeys: escapeKeys) }.joined(separator: ",") + "]"
        case .object(let o):
            "{" + o.sorted { $0.key < $1.key }.map { k, v in
                let key = escapeKeys ? "<|\"|>\(k)<|\"|>" : k
                return "\(key):\(format(v, escapeKeys: escapeKeys))"
            }.joined(separator: ",") + "}"
        }
    }
}
