import XCTest
import MLXLMCommon
@testable import AgentCore

final class TranslatePDFToolTests: XCTestCase {

    // MARK: - shouldTranslate

    func testProsePasses() {
        XCTAssertTrue(TranslatePDFTool.shouldTranslate("We propose a technique for fusing a bracketed exposure sequence."))
        XCTAssertTrue(TranslatePDFTool.shouldTranslate("Abstract"))
        XCTAssertTrue(TranslatePDFTool.shouldTranslate("3. Exposure Fusion"))
        // CJK source prose (e.g. translating zh → en).
        XCTAssertTrue(TranslatePDFTool.shouldTranslate("这是一个测试段落，包含足够的文字。"))
    }

    func testMathAndNoiseSkipped() {
        // Linearized display math: symbol-heavy, no ≥3-letter word.
        XCTAssertFalse(TranslatePDFTool.shouldTranslate("w = (i, j) · C λ + (1 − λ) S"))
        XCTAssertFalse(TranslatePDFTool.shouldTranslate("12.3 45 × 0.7"))
        XCTAssertFalse(TranslatePDFTool.shouldTranslate("= + − ÷"))
        XCTAssertFalse(TranslatePDFTool.shouldTranslate("x"))
    }

    // MARK: - Math line detection (PDFBlocks)

    func testMathLinesDetected() {
        // Real lines from exposure_fusion.pdf page 3/4 equations.
        XCTAssertTrue(PDFBlocks.isMathLine("Rij="))
        XCTAssertTrue(PDFBlocks.isMathLine("Wij,k="))
        XCTAssertTrue(PDFBlocks.isMathLine("L{R}l ij = argmax"))
        XCTAssertTrue(PDFBlocks.isMathLine("ˆ"))
        XCTAssertTrue(PDFBlocks.isMathLine("k =1"))
        // Subscript fragments like "−1Wij,k" carry a ≥3-letter token, so the
        // textual rule passes on them — they reach math blocks via the dropped
        // minor tier + band propagation instead.
        XCTAssertFalse(PDFBlocks.isMathLine("−1Wij,k"))
    }

    func testProseLinesNotMath() {
        XCTAssertFalse(PDFBlocks.isMathLine("at each pixel (i, j):"))
        XCTAssertFalse(PDFBlocks.isMathLine("a power function:"))
        XCTAssertFalse(PDFBlocks.isMathLine("curve: exp− 2σ , where σ equals 0.2 in our implementation."))
        XCTAssertFalse(PDFBlocks.isMathLine("with C, S and E, being contrast, saturation, and well-"))
        XCTAssertFalse(PDFBlocks.isMathLine("weight maps."))
        // Prose containing '=' but with several real words stays prose.
        XCTAssertFalse(PDFBlocks.isMathLine("quality measures (ωC = ωS = ωE = 1) in most examples,"))
        // Reference tails: parens/brackets alone are not math.
        XCTAssertFalse(PDFBlocks.isMathLine("23(3):294–302, 2004."))
        XCTAssertFalse(PDFBlocks.isMathLine("al. [2]."))
    }

    func testAccentArtifactIsSymbolNoise() {
        XCTAssertTrue(PDFBlocks.isSymbolNoise("ˆ"))
        XCTAssertTrue(PDFBlocks.isSymbolNoise("˜"))
        XCTAssertFalse(PDFBlocks.isSymbolNoise("ab"))
        XCTAssertFalse(PDFBlocks.isSymbolNoise("我"))
    }

    // MARK: - splitForFragments

    func testSingleFragmentPassthrough() {
        XCTAssertEqual(TranslatePDFTool.splitForFragments("hello world", areas: [100]), ["hello world"])
    }

    func testProportionalSplitPrefersBreakChars() {
        // Two equal areas: split should land near the middle, at the comma.
        let text = "前半部分的内容在这里，后半部分的内容在那里结束。"
        let parts = TranslatePDFTool.splitForFragments(text, areas: [100, 100])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0], "前半部分的内容在这里，")
        XCTAssertEqual(parts[1], "后半部分的内容在那里结束。")
        XCTAssertEqual(parts.joined(), text)
    }

    func testUnevenAreas() {
        let text = String(repeating: "字", count: 30) + "。" + String(repeating: "符", count: 10)
        let parts = TranslatePDFTool.splitForFragments(text, areas: [300, 100])
        XCTAssertEqual(parts.count, 2)
        // ~3/4 of the text in the first fragment, cut at the 。
        XCTAssertTrue(parts[0].hasSuffix("。"))
        XCTAssertEqual(parts[1], String(repeating: "符", count: 10))
    }

    func testNoBreakCharStillSplits() {
        let text = String(repeating: "a", count: 20)
        let parts = TranslatePDFTool.splitForFragments(text, areas: [100, 100])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts.joined().count, 20)
    }

    // MARK: - cleanTranslation

    func testCleanCollapsesWhitespaceAndStripsLabels() {
        let raw = "[Chinese (Simplified) translation]:\n第一行\n第二行  多空格"
        XCTAssertEqual(TranslatePDFTool.cleanTranslation(raw, reference: nil), "第一行 第二行 多空格")
    }

    // MARK: - HTML emission

    func testHtmlEscape() {
        XCTAssertEqual(TranslatePDFTool.htmlEscape("a < b & c > d"), "a &lt; b &amp; c &gt; d")
    }

    func testPageHTMLCoordinateFlip() {
        // Crop box 0,0,600×800; a block at PDF y [700, 760] → CSS top = 800-760 = 40.
        let cb = CGRect(x: 0, y: 0, width: 600, height: 800)
        let o = TranslatePDFTool.Overlay(
            rect: CGRect(x: 50, y: 700, width: 200, height: 60),
            text: "你好 <世界>", size: 10, lines: 5, heading: false
        )
        let html = TranslatePDFTool.pageHTML(pageNo: 3, cropBox: cb, image: "images/page3.jpg", overlays: [o])
        XCTAssertTrue(html.contains("id=\"p3\""))
        XCTAssertTrue(html.contains("width:600.0px;height:800.0px"))
        XCTAssertTrue(html.contains("left:50.0px;top:40.0px"))
        XCTAssertTrue(html.contains("font-size:10.0px"))
        XCTAssertTrue(html.contains("line-height:12.00px"))   // 60pt box / 5 original lines
        XCTAssertTrue(html.contains("你好 &lt;世界&gt;"))
        XCTAssertTrue(html.contains("images/page3.jpg"))
    }

    func testDocumentIsCompleteHTML() {
        let doc = TranslatePDFTool.document(title: "t & t", sections: ["<div class=\"page\"></div>"])
        XCTAssertTrue(doc.hasPrefix("<!doctype html>"))
        XCTAssertTrue(doc.contains("t &amp; t"))
        XCTAssertTrue(doc.contains("</html>"))
        XCTAssertTrue(doc.contains("scrollHeight"))      // shrink-to-fit script present
        XCTAssertTrue(doc.contains("renderMathInElement")) // KaTeX math rendering
        // Math render must precede the fit pass (boxes account for typeset math).
        let render = doc.range(of: "renderMathInElement(document.body")!
        let fit = doc.range(of: "fitAll();")!
        XCTAssertTrue(render.lowerBound < fit.lowerBound)
    }

    // MARK: - End-to-end with fake translator (env-gated)

    /// Run with: `LOCALCODE_PDF_FIXTURE=/path/to/file.pdf swift test --filter testTranslatePDFEndToEndFake`
    /// Uses a marker-wrapping fake translator — no model needed. Set
    /// LOCALCODE_PDF_KEEP=1 to keep output at $TMPDIR/translate_pdf_test_keep.
    func testTranslatePDFEndToEndFake() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOCALCODE_PDF_FIXTURE"] else {
            throw XCTSkip("Set LOCALCODE_PDF_FIXTURE to a PDF path to run this test.")
        }
        let pdfURL = URL(fileURLWithPath: path)
        let keep = ProcessInfo.processInfo.environment["LOCALCODE_PDF_KEEP"] == "1"
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent(
            keep ? "translate_pdf_test_keep" : "translate_pdf_test_\(UUID().uuidString)")
        if FileManager.default.fileExists(atPath: cwd.path) {
            try FileManager.default.removeItem(at: cwd)
        }
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { if !keep { try? FileManager.default.removeItem(at: cwd) } }
        if keep { print("=== keeping output at: \(cwd.path) ===") }

        let copied = cwd.appendingPathComponent(pdfURL.lastPathComponent)
        try FileManager.default.copyItem(at: pdfURL, to: copied)

        var tool = await TranslatePDFTool(cwd: cwd, engine: InferenceEngine())
        tool.translator = { text, _ in text }   // identity: geometry check only
        let result = await tool.run([
            "path": .string(pdfURL.lastPathComponent),
            "target_language": .string("Chinese (Simplified)"),
        ])
        print("=== translate_pdf result ===\n\(result)\n=== end ===")
        XCTAssertFalse(result.hasPrefix("Error:"), "tool returned an error: \(result)")

        let outDir = cwd.appendingPathComponent("\(pdfURL.deletingPathExtension().lastPathComponent).translated")
        let html = try String(contentsOf: outDir.appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertTrue(html.contains("id=\"p1\""), "page 1 missing")
        XCTAssertTrue(html.contains("class=\"t"), "no overlay blocks emitted")
        let images = try FileManager.default.contentsOfDirectory(atPath: outDir.appendingPathComponent("images").path)
        XCTAssertFalse(images.filter { $0.hasSuffix(".jpg") }.isEmpty, "no page background images")
    }
}
