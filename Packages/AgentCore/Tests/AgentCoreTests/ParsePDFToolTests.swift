import XCTest
import MLXLMCommon
@testable import AgentCore

final class ParsePDFToolTests: XCTestCase {

    // MARK: - Page range parsing

    func testAllPagesWhenSpecEmpty() throws {
        XCTAssertEqual(try ParsePDFTool.parsePageRange(nil, total: 5), [0, 1, 2, 3, 4])
        XCTAssertEqual(try ParsePDFTool.parsePageRange("", total: 5), [0, 1, 2, 3, 4])
        XCTAssertEqual(try ParsePDFTool.parsePageRange("  ", total: 5), [0, 1, 2, 3, 4])
    }

    func testSinglePage() throws {
        XCTAssertEqual(try ParsePDFTool.parsePageRange("3", total: 10), [2])
    }

    func testRangeAndUnionWithDedupe() throws {
        XCTAssertEqual(try ParsePDFTool.parsePageRange("1-3,5,7-9,2", total: 10),
                       [0, 1, 2, 4, 6, 7, 8])
    }

    func testRangeClampedToTotal() throws {
        XCTAssertEqual(try ParsePDFTool.parsePageRange("8-100", total: 10), [7, 8, 9])
    }

    func testOutOfRangeSkippedOrErrors() throws {
        // Range entirely past the end is silently skipped.
        XCTAssertEqual(try ParsePDFTool.parsePageRange("20-30", total: 10), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
        // Bare integer past the end errors.
        XCTAssertThrowsError(try ParsePDFTool.parsePageRange("99", total: 10))
        // Malformed range errors.
        XCTAssertThrowsError(try ParsePDFTool.parsePageRange("5-2", total: 10))
        XCTAssertThrowsError(try ParsePDFTool.parsePageRange("abc", total: 10))
    }

    // MARK: - End-to-end smoke (env-gated)

    /// Run with: `LOCALCODE_PDF_FIXTURE=/path/to/file.pdf swift test --filter testEndToEndAgainstRealPDF`
    /// Skipped otherwise so the regular test suite has no external dependency.
    func testEndToEndAgainstRealPDF() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOCALCODE_PDF_FIXTURE"] else {
            throw XCTSkip("Set LOCALCODE_PDF_FIXTURE to a PDF path to run this test.")
        }
        let pdfURL = URL(fileURLWithPath: path)
        let keep = ProcessInfo.processInfo.environment["LOCALCODE_PDF_KEEP"] == "1"
        let cwd = keep
            ? FileManager.default.temporaryDirectory.appendingPathComponent("parse_pdf_test_keep")
            : FileManager.default.temporaryDirectory.appendingPathComponent("parse_pdf_test_\(UUID().uuidString)")
        if keep, FileManager.default.fileExists(atPath: cwd.path) {
            try FileManager.default.removeItem(at: cwd)
        }
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { if !keep { try? FileManager.default.removeItem(at: cwd) } }
        if keep { print("=== keeping output at: \(cwd.path) ===") }

        // SafePath resolves symlinks before checking containment, so we copy
        // the fixture into cwd rather than symlinking.
        let copied = cwd.appendingPathComponent(pdfURL.lastPathComponent)
        try FileManager.default.copyItem(at: pdfURL, to: copied)

        let tool = ParsePDFTool(cwd: cwd)
        let result = await tool.run([
            "path": .string(pdfURL.lastPathComponent)
        ])
        print("=== parse_pdf result ===\n\(result)\n=== end ===")
        XCTAssertFalse(result.hasPrefix("Error:"), "tool returned an error: \(result)")
        XCTAssertTrue(result.contains("Markdown:"), "missing Markdown: line")

        let parsedDir = cwd.appendingPathComponent("\(pdfURL.deletingPathExtension().lastPathComponent).parsed")
        let mdPath = parsedDir.appendingPathComponent("document.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mdPath.path),
                      "document.md missing at \(mdPath.path)")
        let md = try String(contentsOf: mdPath, encoding: .utf8)
        XCTAssertTrue(md.contains("## Page 1"), "page 1 header missing")
    }
}
