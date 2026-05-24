import Foundation
import MLXLMCommon

/// Returns the body of a compiled-in `Skill` by name. The catalog of available
/// skills is injected into the system prompt by `SystemPrompt.make(...)`, so
/// the model knows which names are valid without us listing them in the tool
/// description.
struct LoadSkillTool: Tool {
    let name = "load_skill"

    var toolSpec: ToolSpec {
        ToolSpecBuilder.make(
            name: name,
            description: "Load the full content of a named skill. The available skill names are listed in the system prompt under 'Available skills'.",
            properties: [
                (name: "name", type: "string",
                 description: "The skill's slug (e.g. 'verify-build'). Must match a name from the system-prompt catalog."),
            ],
            required: ["name"]
        )
    }

    nonisolated func run(_ arguments: [String: JSONValue]) async -> String {
        guard let slug = arguments["name"]?.string else {
            return "Error: missing 'name'"
        }
        guard let skill = Skill.registry[slug] else {
            let available = Skill.all.map(\.name).joined(separator: ", ")
            return "Error: unknown skill '\(slug)'. Available: \(available)"
        }
        return skill.body
    }
}
