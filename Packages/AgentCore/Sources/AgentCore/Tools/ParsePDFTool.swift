import Foundation
import PDFKit
import MLXLMCommon

/// Native-PDFKit PDF → Markdown + figure PNGs converter, built on the shared
/// `PDFBlocks` extractor. Output files land under the working directory so
/// long PDFs don't blow the model context — the agent reads the markdown in
/// chunks via `read_file`.
///
/// Known limits: inline math / fractions linearize (no LaTeX recovery);
/// scanned/image-only PDFs return little text (no OCR fallback); paragraphs are
/// not joined across page boundaries (a `## Page N` header always starts fresh,
/// which keeps `translate_md` page-aligned).
struct ParsePDFTool: Tool {
    let cwd: URL
    let name = "parse_pdf"

    var toolSpec: ToolSpec {
        ToolSpecBuilder.make(
            name: name,
            description:
                "Parse a PDF into clean, structure-preserving Markdown + extracted figure/table images using PDFKit. Detects headings (from font-size tiers), reflows justified paragraphs, de-hyphenates line wraps, keeps correct reading order for 1- and 2-column layouts (e.g. academic papers), and renders figures and tables to PNGs (so tables that would otherwise linearize into garbled text stay readable). Writes <output_dir>/document.md and <output_dir>/images/p{N}-fig{K}.png under the working directory and returns a short summary plus a text preview. After calling this, use read_file to read the produced markdown. To translate a PDF, use translate_pdf instead (one step, layout-preserving). Limits: math typeset with custom math fonts may linearize/garble inline; scanned/image-only PDFs return mostly empty text (no OCR fallback yet).",
            properties: [
                (name: "path", type: "string", description: "PDF path (relative to working directory or absolute under it)."),
                (name: "output_dir", type: "string", description: "Output directory. Default: <pdf-basename>.parsed next to the PDF."),
                (name: "pages", type: "string", description: "Optional 1-indexed page range like \"1-10\", \"3\", or \"1-3,5\". Default: all pages."),
            ],
            required: ["path"]
        )
    }

    nonisolated func run(_ arguments: [String: JSONValue]) async -> String {
        guard let path = arguments["path"]?.string else { return "Error: missing 'path'" }
        do {
            let pdfURL = try SafePath.resolve(path, cwd: cwd)
            guard FileManager.default.fileExists(atPath: pdfURL.path) else {
                return "Error: file not found at \(path)"
            }
            guard let doc = PDFDocument(url: pdfURL) else {
                return "Error: could not open PDF (may be encrypted, corrupted, or not a PDF)"
            }
            guard doc.pageCount > 0 else { return "Error: PDF has no pages" }

            let outputDir: URL
            if let dirArg = arguments["output_dir"]?.string, !dirArg.isEmpty {
                outputDir = try SafePath.resolve(dirArg, cwd: cwd)
            } else {
                let base = pdfURL.deletingPathExtension().lastPathComponent
                outputDir = try SafePath.resolve(
                    pdfURL.deletingLastPathComponent().appendingPathComponent("\(base).parsed").path,
                    cwd: cwd
                )
            }
            let imagesDir = outputDir.appendingPathComponent("images")
            try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

            let pageIndices = try Self.parsePageRange(arguments["pages"]?.string, total: doc.pageCount)

            // Pass 1 (doc-wide): extract lines per page and collect the font-size
            // histogram + the set of "real" inline hyphenated compounds. Body
            // size and de-hyphenation must be decided document-wide, not per-page.
            var sizeHist: [Int: Int] = [:]
            var pageLines: [[PDFBlocks.Line]] = []
            for i in pageIndices {
                guard let page = doc.page(at: i) else { pageLines.append([]); continue }
                pageLines.append(PDFBlocks.extractLines(page, sizeHist: &sizeHist))
            }
            let bodySize = PDFBlocks.bodySize(from: sizeHist)
            var hyphenSet = Set<String>()
            for lines in pageLines { for l in lines { PDFBlocks.collectInlineHyphens(l.text, into: &hyphenSet) } }

            // Pass 2: render each page to markdown using doc-wide context.
            var parts: [String] = []
            var totalFigures = 0
            for (k, i) in pageIndices.enumerated() {
                guard let page = doc.page(at: i) else { continue }
                let (md, figs) = Self.renderPage(
                    pageLines[k], page: page, pageIndex1: i + 1,
                    bodySize: bodySize, hyphenSet: hyphenSet, imagesDir: imagesDir
                )
                parts.append(md)
                totalFigures += figs
            }

            let markdown = parts.joined(separator: "\n\n---\n\n")
            let mdURL = outputDir.appendingPathComponent("document.md")
            try markdown.write(to: mdURL, atomically: true, encoding: .utf8)

            let relMD = SafePath.relativize(mdURL, to: cwd)
            let relImg = SafePath.relativize(imagesDir, to: cwd)

            let preview = markdown.isEmpty
                ? "(empty — PDF may be image-only)"
                : markdown.clipped(to: 800)

            return """
            Parsed "\(pdfURL.lastPathComponent)": \(pageIndices.count) pages, \(totalFigures) figures extracted.
            Markdown: \(relMD)
            Images:   \(relImg)/

            Preview:
            \(preview)
            """
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    /// Markdown for one page: headings, reflowed paragraphs, and figure/table
    /// PNGs emitted just before their caption paragraph.
    private static func renderPage(
        _ input: [PDFBlocks.Line], page: PDFPage, pageIndex1 pageNo: Int,
        bodySize: CGFloat, hyphenSet: Set<String>, imagesDir: URL
    ) -> (markdown: String, figureCount: Int) {
        var lines = input
        let cb = page.bounds(for: .cropBox)
        PDFBlocks.classify(&lines, bodySize: bodySize)
        let geo = PDFBlocks.columnGeometry(lines, cropBox: cb)
        let figs = PDFBlocks.markFigures(&lines, geo: geo, cropBox: cb, bodySize: bodySize)
        let blocks = PDFBlocks.buildBlocks(lines, geo: geo, bodySize: bodySize, hyphenSet: hyphenSet)

        var out = "## Page \(pageNo)\n\n"
        var figCount = 0
        for b in blocks {
            if b.level > 0 {
                out += "\(String(repeating: "#", count: b.level)) \(b.text)\n\n"
            } else {
                if b.isCaption, let f = figs.first(where: { $0.captionLineIdx == b.firstLine }) {
                    let name = "p\(pageNo)-fig\(figCount + 1).png"
                    if PDFBlocks.renderRegion(f.rect, of: page, to: imagesDir.appendingPathComponent(name)) {
                        figCount += 1
                        out += "![](images/\(name))\n\n"
                    }
                }
                out += "\(b.text)\n\n"
            }
        }
        return (out, figCount)
    }

    // MARK: - Page range

    /// Parse a spec like "1-3,5,7-9" (1-indexed). Empty/missing → all pages.
    /// Returns sorted 0-indexed page indices.
    static func parsePageRange(_ spec: String?, total: Int) throws -> [Int] {
        guard let spec, !spec.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Array(0..<total)
        }
        var picked = Set<Int>()
        for part in spec.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if let dash = trimmed.firstIndex(of: "-") {
                let lhs = trimmed[..<dash].trimmingCharacters(in: .whitespaces)
                let rhs = trimmed[trimmed.index(after: dash)...].trimmingCharacters(in: .whitespaces)
                guard let lo = Int(lhs), let hi = Int(rhs), lo >= 1, hi >= lo else {
                    throw ParseError.badRange(String(trimmed))
                }
                let safeHi = min(hi, total)
                guard lo <= total else { continue }
                for n in lo...safeHi { picked.insert(n - 1) }
            } else {
                guard let n = Int(trimmed), n >= 1, n <= total else {
                    throw ParseError.badRange(String(trimmed))
                }
                picked.insert(n - 1)
            }
        }
        return picked.isEmpty ? Array(0..<total) : picked.sorted()
    }

    enum ParseError: LocalizedError {
        case badRange(String)
        var errorDescription: String? {
            switch self {
            case .badRange(let s): "invalid page range: \(s)"
            }
        }
    }
}
