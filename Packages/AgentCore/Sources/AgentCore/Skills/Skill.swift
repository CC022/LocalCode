import Foundation

/// A piece of compiled-in knowledge the agent can pull into its context on
/// demand. The model sees only the catalog (name + one-line description) every
/// turn — the full `body` is returned by `LoadSkillTool` when the model calls
/// `load_skill(name:)`. This trades a small static-tokens cost for the ability
/// to keep deep procedural / stylistic knowledge out of the system prompt
/// until it's actually needed.
///
/// Skills live as `static let` constants on this type, one per file under
/// `Skills/Builtins/`, and are collected in `Skill.registry` below. To add a
/// new skill: write a file, add it to the registry list, ship it. Refining a
/// skill's `body` requires no migration — the next launch picks it up.
public struct Skill: Sendable {
    /// Stable identifier used as the `name` argument to `load_skill`. Should
    /// be a short, lowercase, hyphenated slug.
    public let name: String
    /// One-line summary shown in the system-prompt catalog. The model uses
    /// this to decide whether the skill is relevant — keep it concrete.
    public let description: String
    /// Full markdown content returned by `load_skill`. Multi-paragraph is fine;
    /// formatting is preserved.
    public let body: String

    public init(name: String, description: String, body: String) {
        self.name = name
        self.description = description
        self.body = body
    }
}

extension Skill {
    /// All compiled-in skills. Add a new entry here when you create a new
    /// builtin under `Skills/Builtins/`.
    static let all: [Skill] = [
        .verifyBuild,
        .translatePDF,
    ]

    /// Lookup table built once at module init.
    static let registry: [String: Skill] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.name, $0) }
    )

    /// Catalog block appended to the system prompt — one line per skill so the
    /// model knows what's available without paying for the bodies until it
    /// asks. Returns empty string if no skills are registered, so the system
    /// prompt stays clean.
    static var catalog: String {
        guard !all.isEmpty else { return "" }
        let lines = all.map { "- \($0.name): \($0.description)" }
        return """

        Available skills (call load_skill with the name to read the full body):
        \(lines.joined(separator: "\n"))
        """
    }
}
