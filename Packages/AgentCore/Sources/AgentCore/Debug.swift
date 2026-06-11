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

    /// Translate `path` (a PDF under `cwd`) to `targetLanguage` via the
    /// layout-preserving HTML pipeline. `fake: true` swaps the model for an
    /// identity translator so geometry/HTML can be iterated without inference.
    @MainActor
    public static func translatePDF(
        cwd: URL,
        engine: InferenceEngine,
        path: String,
        targetLanguage: String,
        pages: String? = nil,
        fake: Bool = false,
        outputDir: String? = nil
    ) async -> String {
        var tool = TranslatePDFTool(cwd: cwd, engine: engine)
        if fake { tool.translator = { text, _ in text } }
        var args: [String: JSONValue] = [
            "path": .string(path),
            "target_language": .string(targetLanguage),
        ]
        if let pages { args["pages"] = .string(pages) }
        if let outputDir { args["output_dir"] = .string(outputDir) }
        return await tool.run(args)
    }
}
