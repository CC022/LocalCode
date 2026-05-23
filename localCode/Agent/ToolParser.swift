import Foundation

enum ToolParser {
    private static let pattern = /```tool_use\s*\n([\s\S]*?)\n```/

    static func extract(_ text: String) -> ToolCall? {
        guard let match = text.firstMatch(of: pattern) else { return nil }
        let json = String(match.1)
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = dict["command"] as? String, !cmd.isEmpty else { return nil }
        return ToolCall(command: cmd)
    }

    static func resultMessage(_ output: String) -> String {
        "```tool_result\n\(output)\n```"
    }
}
