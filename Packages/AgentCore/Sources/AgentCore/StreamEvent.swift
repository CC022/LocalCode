import Foundation
import MLXLMCommon

/// Output of `InferenceEngine.stream`. Text chunks update the live assistant
/// bubble; a tool call signals the agent loop to dispatch and continue.
enum StreamEvent: Sendable {
    case text(String)
    case toolCall(MLXLMCommon.ToolCall)
}
