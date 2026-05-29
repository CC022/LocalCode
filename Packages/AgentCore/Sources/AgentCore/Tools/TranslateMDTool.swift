import Foundation
import MLXLMCommon

/// Chunked Markdown translator. Splits the input into paragraph-aware chunks,
/// drives each chunk through the model with `InferenceEngine.stream(...)` (the
/// same off-turn pattern `AgentLoop.compact()` uses), and appends the result
/// to disk incrementally so a crash mid-translation leaves a clean partial.
/// Each chunk after the first is prompted with the last translated paragraph
/// of the previous chunk so terminology stays consistent across boundaries.
struct TranslateMDTool: Tool {
    let cwd: URL
    /// `InferenceEngine` is `@MainActor`-isolated. We hop to MainActor to
    /// kick off each chunk's stream; the returned `AsyncStream<StreamEvent>`
    /// is `Sendable`, so iteration over text deltas runs from the tool's
    /// off-main context.
    let engine: InferenceEngine
    let name = "translate_md"

    var toolSpec: ToolSpec {
        ToolSpecBuilder.make(
            name: name,
            description:
                "Translate a Markdown file into another language using chunked, paragraph-aware passes through the local/API model. Writes incrementally to <output_path>; safe for long documents (papers, books) that exceed the model's context window. Preserves Markdown structure: headers, lists, image placeholders (![](images/..)), code blocks, and LaTeX are passed through verbatim. Returns a summary including chunk count, elapsed seconds, output path, and any structural-validation warnings.",
            properties: [
                (name: "path", type: "string", description: "Path to the Markdown file (relative to working directory or absolute under it)."),
                (name: "target_language", type: "string", description: "Natural-language name of the target, e.g. \"Chinese (Simplified)\", \"Japanese\", \"Spanish\". Passed to the model verbatim."),
                (name: "output_path", type: "string", description: "Output Markdown path. Default: <input-stem>.<lang-code>.md next to the input."),
                (name: "chunk_chars", type: "integer", description: "Target chunk size in characters. Default 6000 (~1.5K tokens for English source)."),
            ],
            required: ["path", "target_language"]
        )
    }

    private static let defaultChunkChars = 3_000
    private static let minChunkChars = 500
    private static let maxChunkChars = 30_000

    /// Sampling parameters tuned for translation: low temperature for
    /// deterministic faithful output, plus a repetition penalty to prevent
    /// the model from degenerating into "translate first page → repeat
    /// previous paragraphs forever" loops we saw at temperature 0.7 with
    /// no penalty.
    private static let translateParams = GenerateParameters(
        maxTokens: 4096,
        temperature: 0.4,
        repetitionPenalty: 1.05,
        repetitionContextSize: 64
    )

    nonisolated func run(_ arguments: [String: JSONValue]) async -> String {
        guard let path = arguments["path"]?.string else { return "Error: missing 'path'" }
        guard let lang = arguments["target_language"]?.string, !lang.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "Error: missing 'target_language'"
        }
        let chunkChars = min(max(arguments["chunk_chars"]?.int ?? Self.defaultChunkChars,
                                 Self.minChunkChars),
                             Self.maxChunkChars)

        do {
            let inputURL = try SafePath.resolve(path, cwd: cwd)
            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                return "Error: file not found at \(path)"
            }
            let inputText = try String(contentsOf: inputURL, encoding: .utf8)
            guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Error: input file is empty"
            }

            let outputURL: URL
            if let outArg = arguments["output_path"]?.string, !outArg.isEmpty {
                outputURL = try SafePath.resolve(outArg, cwd: cwd)
            } else {
                let stem = inputURL.deletingPathExtension().lastPathComponent
                let code = Self.langCode(for: lang)
                let dir = inputURL.deletingLastPathComponent()
                outputURL = try SafePath.resolve(
                    dir.appendingPathComponent("\(stem).\(code).md").path,
                    cwd: cwd
                )
            }

            // Ensure parent dir exists, then truncate any prior file.
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: outputURL)
            let fh = try FileHandle(forWritingTo: outputURL)
            defer { try? fh.close() }

            let chunks = Self.chunk(markdown: inputText, targetChars: chunkChars)
            guard !chunks.isEmpty else { return "Error: nothing to translate after chunking" }

            var warnings: [String] = []
            var lastTranslatedParagraph: String? = nil
            let started = Date()

            for (idx, chunk) in chunks.enumerated() {
                let raw = await translateChunk(chunk, targetLanguage: lang, reference: lastTranslatedParagraph)
                let sanitized = Self.sanitize(raw, reference: lastTranslatedParagraph)
                let (cleaned, truncatedAtRepetition) = Self.truncateAtRepetition(sanitized)
                if truncatedAtRepetition {
                    warnings.append("chunk \(idx + 1): output truncated at repetition loop")
                }

                for w in Self.validate(input: chunk, output: cleaned) {
                    warnings.append("chunk \(idx + 1): \(w)")
                }

                let payload = cleaned + (idx == chunks.count - 1 ? "\n" : "\n\n")
                try fh.write(contentsOf: Data(payload.utf8))
                try fh.synchronize()

                if let last = Self.lastParagraph(of: cleaned), !last.isEmpty {
                    lastTranslatedParagraph = last
                }
            }

            // Warnings file
            let warnURL = outputURL.appendingPathExtension("warnings.txt")
            if warnings.isEmpty {
                try? FileManager.default.removeItem(at: warnURL)
            } else {
                try warnings.joined(separator: "\n")
                    .write(to: warnURL, atomically: true, encoding: .utf8)
            }

            let elapsed = Date().timeIntervalSince(started)

            let relIn = SafePath.relativize(inputURL, to: cwd)
            let relOut = SafePath.relativize(outputURL, to: cwd)

            // Short preview from the head of the output (already on disk).
            let preview = (try? String(contentsOf: outputURL, encoding: .utf8))?
                .clipped(to: 600) ?? ""

            let warnLine = warnings.isEmpty
                ? ""
                : "\nWarnings: \(warnings.count) (see \(relOut).warnings.txt)"

            return """
            Translated "\(relIn)" → "\(relOut)" (\(lang)): \(chunks.count) chunks, \(String(format: "%.1f", elapsed))s.\(warnLine)

            Preview:
            \(preview)
            """
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Inference

    private func translateChunk(_ chunk: String, targetLanguage: String, reference: String?) async -> String {
        // Prompt structure: source FIRST, instruction AFTER the source, then a
        // target-language cue header that immediately precedes generation.
        // Putting the English source last makes the model continue with more
        // English (completion mode) instead of switching to the target
        // language. With the cue header at the very end, the next token has
        // to be in the target language by construction.
        let rules = """
        Translate the source Markdown above into \(targetLanguage).
        - Preserve Markdown syntax byte-for-byte: headers, lists, links, code fences, image placeholders, LaTeX math.
        - Keep `## Page N` (where N is a number) verbatim in English. Do not translate it.
        - Do NOT translate: code blocks, inline code, URLs, image placeholders like ![](images/...), LaTeX math.
        - Translate every other piece of prose, including section headers and figure captions.
        - Translate exactly once. Do not repeat content. Output only the translation, no commentary or preface.
        """

        let prompt: String
        if let reference, !reference.isEmpty {
            prompt = """
            [Already-translated context — match its terminology and style]:
            \(reference)

            [Source Markdown to translate]:
            \(chunk)

            \(rules)

            [\(targetLanguage) translation]:
            """
        } else {
            prompt = """
            [Source Markdown to translate]:
            \(chunk)

            \(rules)

            [\(targetLanguage) translation]:
            """
        }

        var result = ""
        let stream = await MainActor.run {
            engine.stream(
                messages: [.user(prompt)],
                tools: [],
                cacheSlot: nil,
                overrideParams: Self.translateParams
            )
        }
        for await event in stream {
            if case .text(let delta) = event {
                result += delta
            }
        }
        return result
    }

    // MARK: - Chunking (pure, testable)

    /// Split a Markdown string into chunks of about `targetChars`, packed
    /// greedily on paragraph boundaries. Code fences are kept atomic; a
    /// `## Page N` header always starts a fresh chunk so page boundaries
    /// don't blur. Single oversize paragraphs are emitted as their own chunk.
    static func chunk(markdown: String, targetChars: Int) -> [String] {
        let blocks = splitBlocks(markdown)
        var chunks: [String] = []
        var buffer: [String] = []
        var bufferLen = 0

        func flush() {
            if !buffer.isEmpty {
                let joined = buffer.joined(separator: "\n\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { chunks.append(joined) }
                buffer.removeAll()
                bufferLen = 0
            }
        }

        for block in blocks {
            let isPageHeader = block.hasPrefix("## Page ")
            if isPageHeader { flush() }

            let addedLen = bufferLen == 0 ? block.count : bufferLen + 2 + block.count
            if bufferLen > 0 && addedLen > targetChars {
                flush()
            }
            buffer.append(block)
            bufferLen = buffer.joined(separator: "\n\n").count
        }
        flush()
        return chunks
    }

    /// Split a Markdown string into "blocks" — paragraphs separated by blank
    /// lines. Triple-backtick code fences are kept as one block regardless of
    /// internal blank lines.
    static func splitBlocks(_ markdown: String) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        var inFence = false

        for line in markdown.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                current.append(line)
                continue
            }
            if inFence {
                current.append(line)
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty {
                    blocks.append(current.joined(separator: "\n"))
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            blocks.append(current.joined(separator: "\n"))
        }
        return blocks
    }

    // MARK: - Output processing (pure, testable)

    /// Strip echoed prompt labels — both the new bracketed forms
    /// (`[<lang> translation]:`, `[Source Markdown to translate]:`,
    /// `[Already-translated context — ...]:`) and the legacy
    /// `[REFERENCE]` / `[TRANSLATE]` forms — plus any verbatim
    /// repetition of the reference paragraph at the start of the output.
    static func sanitize(_ output: String, reference: String?) -> String {
        var s = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Legacy [REFERENCE] / [TRANSLATE] paired stripping FIRST (kept for
        // back-compat with the older prompt format used in tests). This
        // handles the case where content sits between the two labels and
        // both need to be elided together.
        if s.hasPrefix("[REFERENCE") {
            if let r = s.range(of: "[TRANSLATE]") {
                s = String(s[r.upperBound...])
                s = String(s.drop(while: { $0 == ":" || $0.isWhitespace || $0.isNewline }))
            }
        }
        if s.hasPrefix("[TRANSLATE]") {
            s = String(s.dropFirst("[TRANSLATE]".count))
            s = String(s.drop(while: { $0 == ":" || $0.isWhitespace || $0.isNewline }))
        }

        // Generic `[Short Label]:` line stripper for the current prompt
        // format. Iterating handles stacked echoes. The 80-char cap keeps
        // legitimate markdown lines that happen to start with `[` (links,
        // citations) from being matched.
        for _ in 0..<6 {
            guard s.hasPrefix("[") else { break }
            guard let labelEnd = s.range(of: "]:") else { break }
            let labelLen = s.distance(from: s.startIndex, to: labelEnd.upperBound)
            guard labelLen <= 80 else { break }
            s = String(s[labelEnd.upperBound...])
            s = String(s.drop(while: { $0.isWhitespace || $0.isNewline }))
        }

        if let reference, !reference.isEmpty {
            let trimmedRef = reference.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedRef.isEmpty && s.hasPrefix(trimmedRef) {
                s = String(s.dropFirst(trimmedRef.count))
                s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return s
    }

    /// Detect when the model has gone into a paragraph-level repetition loop
    /// and truncate at the first repeat. A paragraph counts as "substantial"
    /// (and thus subject to dedup) if it's ≥30 characters; shorter lines like
    /// `---` or `## Page 1` are exempt so legitimate repetition of those
    /// doesn't trigger the cut. Returns `(cleaned, wasTruncated)`.
    static func truncateAtRepetition(_ text: String) -> (String, Bool) {
        let blocks = text.components(separatedBy: "\n\n")
        var seen: [String: Int] = [:]
        var kept: [String] = []
        for block in blocks {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            // Use first 80 chars as a fuzzy fingerprint so slight reformatting
            // around the loop boundary doesn't hide a repeat.
            let key = String(trimmed.prefix(80))
            if trimmed.count >= 30, seen[key] != nil {
                return (kept.joined(separator: "\n\n"), true)
            }
            seen[key] = kept.count
            kept.append(block)
        }
        return (text, false)
    }

    /// Best-effort structural checks. Returns human-readable warning lines
    /// (empty array on success).
    static func validate(input: String, output: String) -> [String] {
        var out: [String] = []
        let inImgs = Set(imagePlaceholders(in: input))
        let outImgs = Set(imagePlaceholders(in: output))
        let missingImgs = inImgs.subtracting(outImgs).sorted()
        if !missingImgs.isEmpty {
            out.append("missing image placeholders: \(missingImgs.joined(separator: ", "))")
        }
        let inPages = Set(pageHeaders(in: input))
        let outPages = Set(pageHeaders(in: output))
        let missingPages = inPages.subtracting(outPages).sorted()
        if !missingPages.isEmpty {
            out.append("missing page headers: \(missingPages.joined(separator: ", "))")
        }
        return out
    }

    private static let imageRegex = #/!\[[^\]]*\]\([^)]+\)/#
    private static let pageRegex = #/(?m)^## Page \d+/#

    static func imagePlaceholders(in text: String) -> [String] {
        text.matches(of: Self.imageRegex).map { String($0.output) }
    }

    static func pageHeaders(in text: String) -> [String] {
        text.matches(of: Self.pageRegex).map { String($0.output) }
    }

    /// Last "real paragraph" in the text — skips headings, image placeholders,
    /// code fences, and horizontal rules so the carried context is actual
    /// translatable prose.
    static func lastParagraph(of text: String) -> String? {
        let blocks = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for block in blocks.reversed() {
            if block.hasPrefix("#") { continue }
            if block.hasPrefix("![") { continue }
            if block.hasPrefix("```") { continue }
            if !block.isEmpty, block.allSatisfy({ $0 == "-" }) { continue }
            return block
        }
        return blocks.last
    }

    // MARK: - Language code map

    static func langCode(for language: String) -> String {
        let l = language.lowercased()
        if l.contains("chinese") {
            if l.contains("simplified") || l.contains("hans") { return "zh-CN" }
            if l.contains("traditional") || l.contains("hant") { return "zh-TW" }
            return "zh"
        }
        if l.contains("japanese") { return "ja" }
        if l.contains("korean") { return "ko" }
        if l.contains("spanish") { return "es" }
        if l.contains("french") { return "fr" }
        if l.contains("german") { return "de" }
        if l.contains("portuguese") { return "pt" }
        if l.contains("russian") { return "ru" }
        if l.contains("italian") { return "it" }
        if l.contains("arabic") { return "ar" }
        if l.contains("hindi") { return "hi" }
        if l.contains("english") { return "en" }
        return language.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}
