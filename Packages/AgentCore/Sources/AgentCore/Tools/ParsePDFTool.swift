import Foundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import MLXLMCommon

/// Native-PDFKit PDF → Markdown + figure PNGs converter. v1 scope:
/// 1- and 2-column text layouts (paper-style), gap-detected figure regions,
/// no OCR fallback, no LaTeX recovery. Outputs files under cwd so long PDFs
/// don't blow the model context — the agent reads chunks via `read_file`.
struct ParsePDFTool: Tool {
    let cwd: URL
    let name = "parse_pdf"

    var toolSpec: ToolSpec {
        ToolSpecBuilder.make(
            name: name,
            description:
                "Parse a PDF into Markdown + extracted figure images using PDFKit. Handles 1- and 2-column layouts (e.g. academic papers). Writes <output_dir>/document.md and <output_dir>/images/p{N}-fig{K}.png under the working directory and returns a short summary plus a text preview. After calling this, use read_file to read the produced markdown. Known v1 limits: math typeset with custom math fonts may appear garbled or missing inline; scanned/image-only PDFs return mostly empty text (no OCR fallback yet).",
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

            var parts: [String] = []
            var totalFigures = 0
            for i in pageIndices {
                guard let page = doc.page(at: i) else { continue }
                let (md, figs) = Self.parsePage(page, pageIndex1: i + 1, imagesDir: imagesDir)
                parts.append(md)
                totalFigures += figs
            }

            let markdown = parts.joined(separator: "\n\n---\n\n")
            let mdURL = outputDir.appendingPathComponent("document.md")
            try markdown.write(to: mdURL, atomically: true, encoding: .utf8)

            let cwdPrefix = cwd.path.hasSuffix("/") ? cwd.path : cwd.path + "/"
            let relMD = mdURL.path.hasPrefix(cwdPrefix) ? String(mdURL.path.dropFirst(cwdPrefix.count)) : mdURL.path
            let relImg = imagesDir.path.hasPrefix(cwdPrefix) ? String(imagesDir.path.dropFirst(cwdPrefix.count)) : imagesDir.path

            let previewLimit = 800
            let preview: String
            if markdown.count > previewLimit {
                preview = String(markdown.prefix(previewLimit)) + "\n... (\(markdown.count - previewLimit) more chars; read_file the markdown for the rest)"
            } else {
                preview = markdown.isEmpty ? "(empty — PDF may be image-only)" : markdown
            }

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

    // MARK: - Per-page parsing

    private struct Line {
        let text: String
        let bounds: CGRect
    }

    /// Pulls text + figures off a page and returns the markdown block plus the
    /// number of figures rendered to disk.
    private static func parsePage(_ page: PDFPage, pageIndex1 i: Int, imagesDir: URL) -> (markdown: String, figureCount: Int) {
        let pageBounds = page.bounds(for: .cropBox)
        let lines = extractLines(page, pageBounds: pageBounds)
        let columns = detectColumns(lines, pageBounds: pageBounds)

        let lineHeights = lines.map(\.bounds.height).sorted()
        let typicalLineHeight: CGFloat = lineHeights.isEmpty ? 12 : lineHeights[lineHeights.count / 2]
        let minFigureHeight = max(typicalLineHeight * 3, 30)
        let paragraphGap = typicalLineHeight * 1.4

        var output = "## Page \(i)\n\n"
        var figureCount = 0

        for column in columns {
            guard !column.isEmpty else { continue }
            let colMinX = column.map(\.bounds.minX).min()!
            let colMaxX = column.map(\.bounds.maxX).max()!
            var paragraph = ""

            for j in column.indices {
                let line = column[j]
                if paragraph.isEmpty {
                    paragraph = line.text
                } else if paragraph.hasSuffix("-") {
                    // Probable hyphenated line wrap: join without space.
                    paragraph = String(paragraph.dropLast()) + line.text
                } else {
                    paragraph += " " + line.text
                }

                guard j + 1 < column.count else { continue }
                let next = column[j + 1]
                let gapHeight = line.bounds.minY - next.bounds.maxY
                if gapHeight >= minFigureHeight {
                    if !paragraph.isEmpty {
                        output += paragraph + "\n\n"
                        paragraph = ""
                    }
                    figureCount += 1
                    let rect = CGRect(
                        x: colMinX,
                        y: next.bounds.maxY,
                        width: colMaxX - colMinX,
                        height: gapHeight
                    )
                    let filename = "p\(i)-fig\(figureCount).png"
                    let outURL = imagesDir.appendingPathComponent(filename)
                    if renderRegion(rect, of: page, to: outURL) {
                        output += "![](images/\(filename))\n\n"
                    } else {
                        figureCount -= 1
                    }
                } else if gapHeight >= paragraphGap {
                    if !paragraph.isEmpty {
                        output += paragraph + "\n\n"
                        paragraph = ""
                    }
                }
            }
            if !paragraph.isEmpty {
                output += paragraph + "\n\n"
            }
        }
        return (output, figureCount)
    }

    private static func extractLines(_ page: PDFPage, pageBounds: CGRect) -> [Line] {
        guard let allSelection = page.selection(for: pageBounds) else { return [] }
        var lines: [Line] = []
        for sel in allSelection.selectionsByLine() {
            let raw = sel.string ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let b = sel.bounds(for: page)
            guard b.width > 0, b.height > 0 else { continue }
            lines.append(Line(text: trimmed, bounds: b))
        }
        return lines
    }

    /// Cluster line midpoints to decide 1- vs 2-column. Always returns at least
    /// one (possibly empty) group, sorted top-down per column.
    private static func detectColumns(_ lines: [Line], pageBounds: CGRect) -> [[Line]] {
        let sortedTopDown: ([Line]) -> [Line] = { $0.sorted { $0.bounds.maxY > $1.bounds.maxY } }
        guard lines.count >= 6 else { return [sortedTopDown(lines)] }

        let midXs = lines.map(\.bounds.midX)
        let minMid = midXs.min()!
        let maxMid = midXs.max()!
        if maxMid - minMid < pageBounds.width * 0.15 {
            return [sortedTopDown(lines)]
        }

        let splitX = (minMid + maxMid) / 2
        let left = lines.filter { $0.bounds.midX < splitX }
        let right = lines.filter { $0.bounds.midX >= splitX }
        guard left.count >= 5, right.count >= 5 else { return [sortedTopDown(lines)] }

        let leftMaxX = left.map(\.bounds.maxX).max()!
        let rightMinX = right.map(\.bounds.minX).min()!
        guard rightMinX - leftMaxX >= pageBounds.width * 0.02 else { return [sortedTopDown(lines)] }
        return [sortedTopDown(left), sortedTopDown(right)]
    }

    /// Renders `rect` (in page user space) to a PNG at `url`. Uses CoreGraphics
    /// directly — no AppKit needed. Returns true on success.
    private static func renderRegion(_ rect: CGRect, of page: PDFPage, to url: URL) -> Bool {
        let scale: CGFloat = 2.0
        let pixelW = Int((rect.width * scale).rounded())
        let pixelH = Int((rect.height * scale).rounded())
        guard pixelW > 0, pixelH > 0 else { return false }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let cg = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return false }

        cg.setFillColor(CGColor(gray: 1, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: -rect.minX, y: -rect.minY)
        page.draw(with: .cropBox, to: cg)

        guard let img = cg.makeImage() else { return false }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }

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
