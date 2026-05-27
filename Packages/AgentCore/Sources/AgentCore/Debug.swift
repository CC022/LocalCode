import Foundation
import MLXLMCommon

/// Debug entry points for the CLI's `--translate-debug` mode. These bypass the
/// agent loop and call tools directly, so iteration on a single chunk is one
/// model-inference round-trip rather than a full chat turn.
public enum DebugEntries {
    /// Translate `path` (a Markdown file under `cwd`) to `targetLanguage`.
    /// Optional `chunkChars` overrides the tool's default chunk budget; pass
    /// a small value (e.g. 800) for sub-page iteration. Returns the tool's
    /// summary string.
    @MainActor
    public static func translateMD(
        cwd: URL,
        engine: InferenceEngine,
        path: String,
        targetLanguage: String,
        chunkChars: Int? = nil,
        outputPath: String? = nil
    ) async -> String {
        let tool = TranslateMDTool(cwd: cwd, engine: engine)
        var args: [String: JSONValue] = [
            "path": .string(path),
            "target_language": .string(targetLanguage),
        ]
        if let chunkChars { args["chunk_chars"] = .int(chunkChars) }
        if let outputPath { args["output_path"] = .string(outputPath) }
        return await tool.run(args)
    }
}
