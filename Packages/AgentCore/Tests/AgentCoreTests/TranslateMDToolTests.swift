import XCTest
import MLXLMCommon
@testable import AgentCore

final class TranslateMDToolTests: XCTestCase {

    // MARK: - Block splitting

    func testBlocksSplitOnBlankLines() {
        let md = "para one\nstill one\n\npara two\n\npara three"
        let blocks = TranslateMDTool.splitBlocks(md)
        XCTAssertEqual(blocks, ["para one\nstill one", "para two", "para three"])
    }

    func testCodeFenceIsAtomic() {
        let md = """
        prose before

        ```swift
        func foo() {

            print("blank line above is inside the fence")
        }
        ```

        prose after
        """
        let blocks = TranslateMDTool.splitBlocks(md)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0], "prose before")
        XCTAssertTrue(blocks[1].hasPrefix("```swift"))
        XCTAssertTrue(blocks[1].hasSuffix("```"))
        XCTAssertTrue(blocks[1].contains("blank line above"))
        XCTAssertEqual(blocks[2], "prose after")
    }

    // MARK: - Chunking

    func testShortDocFitsOneChunk() {
        let md = "para one\n\npara two"
        let chunks = TranslateMDTool.chunk(markdown: md, targetChars: 1000)
        XCTAssertEqual(chunks, ["para one\n\npara two"])
    }

    func testParagraphsPackedUpToTarget() {
        // Each para is ~30 chars. With target 80, expect roughly 2 per chunk.
        let paras = (1...6).map { "paragraph number \($0) lorem ipsum" }
        let md = paras.joined(separator: "\n\n")
        let chunks = TranslateMDTool.chunk(markdown: md, targetChars: 80)
        XCTAssertGreaterThan(chunks.count, 1)
        // No chunk should significantly exceed target.
        for c in chunks { XCTAssertLessThanOrEqual(c.count, 120) }
        // Concatenation round-trips back to all paragraphs.
        let recombined = chunks.joined(separator: "\n\n")
        for p in paras { XCTAssertTrue(recombined.contains(p), "missing \(p)") }
    }

    func testPageHeaderStartsNewChunk() {
        let md = """
        ## Page 1

        first page text

        ## Page 2

        second page text
        """
        // Target so large the whole doc could fit, but page boundary should still split.
        let chunks = TranslateMDTool.chunk(markdown: md, targetChars: 10_000)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks[0].hasPrefix("## Page 1"))
        XCTAssertTrue(chunks[1].hasPrefix("## Page 2"))
    }

    func testOversizeParagraphEmittedAlone() {
        let huge = String(repeating: "x", count: 500)
        let md = "tiny\n\n\(huge)\n\nalso tiny"
        let chunks = TranslateMDTool.chunk(markdown: md, targetChars: 100)
        // Expect: ["tiny", huge, "also tiny"] (huge gets its own chunk).
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[1], huge)
    }

    // MARK: - Validation

    func testValidateImagePlaceholders() {
        let input = "see ![](images/p1-fig1.png) and ![alt](images/p2-fig1.png)"
        let goodOutput = "看 ![](images/p1-fig1.png) 和 ![alt](images/p2-fig1.png)"
        XCTAssertEqual(TranslateMDTool.validate(input: input, output: goodOutput), [])

        let missing = "看 ![](images/p1-fig1.png) 和 缺失"
        let warnings = TranslateMDTool.validate(input: input, output: missing)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("missing image placeholders"))
        XCTAssertTrue(warnings[0].contains("p2-fig1.png"))
    }

    func testValidatePageHeaders() {
        let input = "## Page 1\n\ntext\n\n## Page 2\n\nmore"
        let missing = "## 第1页\n\nwhatever"  // translator translated headers
        let warnings = TranslateMDTool.validate(input: input, output: missing)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("missing page headers"))
    }

    // MARK: - Sanitization

    func testSanitizeStripsReferencePrefix() {
        let reference = "上一段翻译过的内容"
        let raw = """
        上一段翻译过的内容

        这是新的翻译。
        """
        let cleaned = TranslateMDTool.sanitize(raw, reference: reference)
        XCTAssertEqual(cleaned, "这是新的翻译。")
    }

    func testSanitizeStripsLabels() {
        let raw = """
        [REFERENCE]: 旧内容
        [TRANSLATE]:
        这是翻译。
        """
        let cleaned = TranslateMDTool.sanitize(raw, reference: nil)
        XCTAssertEqual(cleaned, "这是翻译。")
    }

    func testSanitizePassthroughWhenClean() {
        let raw = "## 标题\n\n这是干净的翻译。"
        XCTAssertEqual(TranslateMDTool.sanitize(raw, reference: nil), raw)
    }

    func testSanitizeStripsNewLabelFormat() {
        // The current prompt's output cue is `[<lang> translation]:`. If the
        // model echoes it, strip the line + leading whitespace.
        let raw = """
        [Chinese (Simplified) translation]:
        这是翻译内容。
        """
        XCTAssertEqual(TranslateMDTool.sanitize(raw, reference: nil),
                       "这是翻译内容。")
    }

    func testSanitizePreservesMarkdownLinkStartingWithBracket() {
        // A real markdown link line begins with `[`. Don't mistake it for a label.
        let raw = "[See here](https://example.com) is a useful resource."
        XCTAssertEqual(TranslateMDTool.sanitize(raw, reference: nil), raw)
    }

    // MARK: - Repetition truncation

    func testTruncateAtRepetitionFindsExactRepeat() {
        let p = "这是一个相当长的段落，包含足够的字符以超过30字符的阈值，所以它会被检测为可能重复。"
        let text = "\(p)\n\n中间段落。\n\n\(p)"
        let (cleaned, truncated) = TranslateMDTool.truncateAtRepetition(text)
        XCTAssertTrue(truncated)
        XCTAssertFalse(cleaned.contains("\(p)\n\n中间段落。\n\n\(p)"))
        // The first occurrence and the middle paragraph survive.
        XCTAssertTrue(cleaned.contains(p))
        XCTAssertTrue(cleaned.contains("中间段落。"))
    }

    func testTruncatePassesShortRepeats() {
        // Short repeats like "---" or page numbers should NOT trigger truncation.
        let text = "段落一\n\n---\n\n段落二\n\n---\n\n段落三"
        let (cleaned, truncated) = TranslateMDTool.truncateAtRepetition(text)
        XCTAssertFalse(truncated)
        XCTAssertEqual(cleaned, text)
    }

    func testTruncatePassesUniqueParagraphs() {
        let text = "段落一是足够长的第一段内容，超过了30字符的阈值。\n\n段落二是另一段独立的内容，也足够长以触发去重检查。"
        let (cleaned, truncated) = TranslateMDTool.truncateAtRepetition(text)
        XCTAssertFalse(truncated)
        XCTAssertEqual(cleaned, text)
    }

    // MARK: - lastParagraph

    func testLastParagraphSkipsNonProse() {
        let md = """
        body text

        ![](images/foo.png)

        ## heading

        ---
        """
        XCTAssertEqual(TranslateMDTool.lastParagraph(of: md), "body text")
    }

    func testLastParagraphReturnsProse() {
        let md = "first\n\nsecond\n\nthird"
        XCTAssertEqual(TranslateMDTool.lastParagraph(of: md), "third")
    }

    // MARK: - Language code map

    func testLangCodeMapping() {
        XCTAssertEqual(TranslateMDTool.langCode(for: "Chinese (Simplified)"), "zh-CN")
        XCTAssertEqual(TranslateMDTool.langCode(for: "Chinese (Traditional)"), "zh-TW")
        XCTAssertEqual(TranslateMDTool.langCode(for: "Chinese"), "zh")
        XCTAssertEqual(TranslateMDTool.langCode(for: "Japanese"), "ja")
        XCTAssertEqual(TranslateMDTool.langCode(for: "Spanish"), "es")
        // Unknown -> sluggified (Klingon and Esperanto contain none of the
        // mapped substrings).
        XCTAssertEqual(TranslateMDTool.langCode(for: "Klingon"), "klingon")
        XCTAssertEqual(TranslateMDTool.langCode(for: "Esperanto"), "esperanto")
        // Compound names containing a mapped substring fall through to that
        // code rather than the slug — acceptable trade-off for the simple
        // substring map.
        XCTAssertEqual(TranslateMDTool.langCode(for: "Swiss German"), "de")
    }

    // MARK: - End-to-end via an OpenAI-compatible API (env-gated)

    /// Drives the real translate_md pipeline against any OpenAI-compatible
    /// endpoint (e.g. DeepSeek). Skipped unless all of these are set:
    ///   LOCALCODE_API_BASE, LOCALCODE_API_MODEL, LOCALCODE_API_KEY,
    ///   LOCALCODE_MD_FIXTURE   (a markdown file to translate)
    /// optional: LOCALCODE_MD_LANG (default "Chinese (Simplified)"),
    ///           LOCALCODE_MD_CHARS, LOCALCODE_MD_KEEP=1
    @MainActor
    func testTranslateMDViaAPI() async throws {
        let e = ProcessInfo.processInfo.environment
        guard let base = e["LOCALCODE_API_BASE"], let model = e["LOCALCODE_API_MODEL"],
              let key = e["LOCALCODE_API_KEY"], let mdPath = e["LOCALCODE_MD_FIXTURE"] else {
            throw XCTSkip("Set LOCALCODE_API_BASE/MODEL/KEY + LOCALCODE_MD_FIXTURE to run.")
        }
        let lang = e["LOCALCODE_MD_LANG"] ?? "Chinese (Simplified)"
        let engine = InferenceEngine()
        engine.apiConfig = APIConfig(baseURL: base, model: model, apiKey: key)
        engine.backend = .api
        guard case .ready = engine.state else { return XCTFail("API config incomplete: \(engine.state)") }

        let keep = e["LOCALCODE_MD_KEEP"] == "1"
        let cwd = keep
            ? FileManager.default.temporaryDirectory.appendingPathComponent("translate_md_test_keep")
            : FileManager.default.temporaryDirectory.appendingPathComponent("translate_md_test_\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: cwd)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { if !keep { try? FileManager.default.removeItem(at: cwd) } }
        if keep { print("=== keeping output at: \(cwd.path) ===") }

        try FileManager.default.copyItem(at: URL(fileURLWithPath: mdPath),
                                         to: cwd.appendingPathComponent("document.md"))
        let result = await DebugEntries.translateMD(
            cwd: cwd, engine: engine, path: "document.md",
            targetLanguage: lang, chunkChars: e["LOCALCODE_MD_CHARS"].flatMap(Int.init)
        )
        print("=== translate_md result ===\n\(result)\n=== end ===")
        XCTAssertFalse(result.hasPrefix("Error:"), "tool returned an error: \(result)")
    }
}
