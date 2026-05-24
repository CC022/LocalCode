import Foundation
import MLXLMCommon

/// A tool the agent can invoke. The model "sees" the OpenAI-style `toolSpec`
/// via the chat template; the framework parses the model's reply into a
/// `MLXLMCommon.ToolCall`, which we then dispatch through `ToolRegistry`.
protocol Tool: Sendable {
    var name: String { get }
    var toolSpec: ToolSpec { get }
    func run(_ arguments: [String: JSONValue]) async -> String
}

extension JSONValue {
    nonisolated var string: String? { if case .string(let v) = self { v } else { nil } }
    nonisolated var int: Int? {
        switch self {
        case .int(let v):    v
        case .double(let v): Int(v)
        default:             nil
        }
    }
    nonisolated var array: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
    nonisolated var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
}

enum ToolSpecBuilder {
    /// Build an OpenAI-style `ToolSpec` from compact inputs.
    static func make(
        name: String,
        description: String,
        properties: [(name: String, type: String, description: String?)],
        required: [String]
    ) -> ToolSpec {
        var props: [String: any Sendable] = [:]
        for p in properties {
            var entry: [String: any Sendable] = ["type": p.type]
            if let d = p.description { entry["description"] = d }
            props[p.name] = entry
        }
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": props,
                    "required": required,
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ]
    }
}

struct ToolRegistry: Sendable {
    private let tools: [String: any Tool]
    let toolSpecs: [ToolSpec]

    init(_ tools: [any Tool]) {
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        self.toolSpecs = tools.map(\.toolSpec)
    }

    func dispatch(name: String, arguments: [String: JSONValue]) async -> String {
        guard let tool = tools[name] else { return "Error: unknown tool '\(name)'" }
        return await tool.run(arguments)
    }
}
