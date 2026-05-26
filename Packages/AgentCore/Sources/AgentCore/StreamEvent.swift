import Foundation
import MLXLMCommon

/// Output of `InferenceEngine.stream`. Text chunks update the live assistant
/// bubble; a tool call signals the agent loop to dispatch and continue.
/// `.reasoning` is emitted by API backends that separate chain-of-thought from
/// response content (e.g. DeepSeek's `delta.reasoning_content`) — the local
/// engine parses thinking from the text buffer instead.
enum StreamEvent: Sendable {
    case text(String)
    case reasoning(String)
    case toolCall(MLXLMCommon.ToolCall)
}
