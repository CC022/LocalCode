import Foundation
import MLXLMCommon

/// Connection params for an OpenAI-compatible Chat Completions endpoint.
/// `apiKey` is held in-memory only — persistence (Keychain for the secret,
/// UserDefaults for url + model) is the app layer's job.
public struct APIConfig: Equatable, Sendable {
    public var baseURL: String
    public var model: String
    public var apiKey: String

    public init(
        baseURL: String = "https://api.openai.com/v1",
        model: String = "gpt-4o-mini",
        apiKey: String = ""
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    public var isComplete: Bool {
        !baseURL.isEmpty && !model.isEmpty && !apiKey.isEmpty
    }
}

/// Stream a chat completion from any OpenAI-compatible endpoint. Yields
/// `.text` deltas chunk-by-chunk and `.toolCall` when one is fully assembled
/// from streaming `tool_calls` deltas. Breaks the stream on the first tool
/// call to mirror the local engine's "model is the driver, harness executes"
/// invariant (see AGENTS.md).
///
/// Errors surface as a final `.text("\n[error: …]")` matching the local
/// engine's pattern so the assistant bubble shows the failure inline.
func streamOpenAI(
    messages: [Message],
    tools: [ToolSpec],
    config: APIConfig,
    onUsage: @MainActor @escaping @Sendable (Int) -> Void
) -> AsyncStream<StreamEvent> {
    AsyncStream { continuation in
        let task = Task {
            do {
                guard let url = URL(string: "\(config.baseURL)/chat/completions") else {
                    continuation.yield(.text("\n[error: invalid baseURL]"))
                    continuation.finish()
                    return
                }
                var req = URLRequest(url: url, timeoutInterval: 120)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
                req.httpBody = try JSONSerialization.data(
                    withJSONObject: buildRequestBody(messages: messages, tools: tools, model: config.model)
                )

                let (bytes, response) = try await URLSession.shared.bytes(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    var errBody = ""
                    for try await line in bytes.lines {
                        errBody += line
                        if errBody.count > 1_500 { break }
                    }
                    continuation.yield(.text("\n[error: HTTP \(http.statusCode) — \(errBody)]"))
                    continuation.finish()
                    return
                }

                var partials: [Int: PartialCall] = [:]
                var emittedToolCall = false

                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    guard line.hasPrefix("data: ") else { continue }
                    let payload = line.dropFirst(6)
                    if payload == "[DONE]" { break }
                    guard let data = payload.data(using: .utf8),
                          let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { continue }

                    // Final usage chunk (request includes stream_options.include_usage)
                    if let usage = chunk["usage"] as? [String: Any],
                       let total = usage["total_tokens"] as? Int {
                        await MainActor.run { onUsage(total) }
                    }

                    guard let choices = chunk["choices"] as? [[String: Any]],
                          let choice = choices.first else { continue }

                    if let delta = choice["delta"] as? [String: Any] {
                        if let content = delta["content"] as? String, !content.isEmpty {
                            continuation.yield(.text(content))
                        }
                        // DeepSeek-style reasoning channel. Other providers
                        // (OpenAI, Anthropic-shim, etc.) simply don't send
                        // this field and the branch is a no-op.
                        if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                            continuation.yield(.reasoning(reasoning))
                        }
                        if let calls = delta["tool_calls"] as? [[String: Any]] {
                            for d in calls {
                                let index = d["index"] as? Int ?? 0
                                var current = partials[index] ?? PartialCall()
                                if let fn = d["function"] as? [String: Any] {
                                    if let name = fn["name"] as? String { current.name = name }
                                    if let args = fn["arguments"] as? String { current.arguments += args }
                                }
                                partials[index] = current
                            }
                        }
                    }

                    if let fr = choice["finish_reason"] as? String, fr == "tool_calls" {
                        if let first = partials.keys.sorted().first, let pc = partials[first] {
                            let argsDict = (try? JSONSerialization.jsonObject(with: Data(pc.arguments.utf8)))
                                as? [String: Any] ?? [:]
                            let jsonArgs = argsDict.mapValues { JSONValue.from($0) }
                            continuation.yield(
                                .toolCall(MLXLMCommon.ToolCall(
                                    function: .init(name: pc.name, arguments: jsonArgs)))
                            )
                            emittedToolCall = true
                        }
                        break
                    }
                }
                _ = emittedToolCall
                continuation.finish()
            } catch {
                if !Task.isCancelled {
                    continuation.yield(.text("\n[error: \(error.localizedDescription)]"))
                }
                continuation.finish()
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

private struct PartialCall {
    var name: String = ""
    var arguments: String = ""
}

/// Convert our `[Message]` history into OpenAI Chat Completions message shape.
/// Assistant turns carrying a `toolCall` + `toolResult` split into two outgoing
/// messages (assistant with `tool_calls`, then a paired `tool` message). Plain
/// `.tool` rows in our history are skipped — the result is already bundled
/// onto the assistant turn that called for it.
private func buildRequestBody(
    messages: [Message],
    tools: [ToolSpec],
    model: String
) -> [String: Any] {
    var out: [[String: Any]] = []
    for msg in messages {
        switch msg.role {
        case .system:
            out.append(["role": "system", "content": msg.text])
        case .user:
            out.append(["role": "user", "content": msg.text])
        case .tool:
            continue
        case .assistant:
            if let call = msg.toolCall {
                let callId = "call_\(out.count)_\(call.name)"
                let argsJSON = jsonStringify(call.arguments)
                var assistant: [String: Any] = [
                    "role": "assistant",
                    "tool_calls": [[
                        "id": callId,
                        "type": "function",
                        "function": ["name": call.name, "arguments": argsJSON],
                    ]],
                ]
                if !msg.text.isEmpty { assistant["content"] = msg.text }
                // DeepSeek's thinking mode requires `reasoning_content` to be
                // echoed back on assistant turns that produced tool calls; the
                // server errors out otherwise. Other providers ignore unknown
                // fields, so it's safe to always include when present.
                if let thinking = msg.thinking, !thinking.isEmpty {
                    assistant["reasoning_content"] = thinking
                }
                out.append(assistant)
                if let result = msg.toolResult {
                    out.append([
                        "role": "tool",
                        "tool_call_id": callId,
                        "content": result,
                    ])
                }
            } else if !msg.text.isEmpty {
                out.append(["role": "assistant", "content": msg.text])
            }
        }
    }

    var body: [String: Any] = [
        "model": model,
        "messages": out,
        "stream": true,
        "stream_options": ["include_usage": true],
    ]
    if !tools.isEmpty {
        body["tools"] = tools
    }
    return body
}

private func jsonStringify(_ args: [String: JSONValue]) -> String {
    let anyDict = args.mapValues { $0.anyValue }
    guard let data = try? JSONSerialization.data(withJSONObject: anyDict),
          let str = String(data: data, encoding: .utf8)
    else { return "{}" }
    return str
}
