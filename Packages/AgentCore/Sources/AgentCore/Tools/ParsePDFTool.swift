import Foundation
import PDFKit
import AppKit
import ImageIO
import UniformTypeIdentifiers
import MLXLMCommon

/// Native-PDFKit PDF → Markdown + figure PNGs converter.
///
/// Design (see the `pdfkit-extraction-findings` project memory): trust
/// `page.string` for reading order (it is already column-correct, even for
/// 2-column papers), and attach geometry + font size to each glyph via the
/// index-aligned trio `page.string` ⇄ `page.attributedString` ⇄
/// `page.characterBounds(at:)`. Structure (headings) comes from doc-wide font
/// size tiers; paragraphs from the justified-text "short last line" signal;
/// figures/tables are anchored on their captions and rendered to PNG with their
/// internal text suppressed. Output files land under the working directory so
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
                "Parse a PDF into clean, structure-preserving Markdown + extracted figure/table images using PDFKit. Detects headings (from font-size tiers), reflows justified paragraphs, de-hyphenates line wraps, keeps correct reading order for 1- and 2-column layouts (e.g. academic papers), and renders figures and tables to PNGs (so tables that would otherwise linearize into garbled text stay readable). Writes <output_dir>/document.md and <output_dir>/images/p{N}-fig{K}.png under the working directory and returns a short summary plus a text preview. After calling this, use read_file to read the produced markdown. Limits: math typeset with custom math fonts may linearize/garble inline; scanned/image-only PDFs return mostly empty text (no OCR fallback yet).",
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
            var pageLines: [[Line]] = []
            for i in pageIndices {
                guard let page = doc.page(at: i) else { pageLines.append([]); continue }
                pageLines.append(Self.extractLines(page, sizeHist: &sizeHist))
            }
            let bodySize = CGFloat(sizeHist.max { $0.value < $1.value }?.key ?? 20) / 2.0
            var hyphenSet = Set<String>()
            for lines in pageLines { for l in lines { Self.collectInlineHyphens(l.text, into: &hyphenSet) } }

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

    // MARK: - Line model

    /// Size tier of a line, relative to the doc-wide body font size.
    private enum Tier { case title, h2, h3, body, minor }

    /// One visual line (a `\n`-delimited run of `page.string`) with the geometry
    /// + font size attached from the index-aligned glyph trio.
    private struct Line {
        var text: String
        var size: CGFloat          // median glyph point size (0 if unknown)
        var hasBox: Bool
        var minX: CGFloat = 0, maxX: CGFloat = 0, minY: CGFloat = 0, maxY: CGFloat = 0
        var tier: Tier = .body
        var isCaption = false
        var dropped = false        // symbol / numeric / minor-label noise
        var suppressed = false     // covered by a figure/table region
    }

    // MARK: - Glyph extraction (pass 1)

    /// Build `Line`s for a page from the index-aligned `page.string` /
    /// `attributedString` / `characterBounds` trio, accumulating the doc-wide
    /// font-size histogram (keyed by `round(pointSize*2)` for ½-pt buckets).
    private static func extractLines(_ page: PDFPage, sizeHist: inout [Int: Int]) -> [Line] {
        guard let attr = page.attributedString else { return [] }
        let n = page.numberOfCharacters
        let ns = (page.string ?? "") as NSString
        let cb = page.bounds(for: .cropBox)
        let upTo = min(n, attr.length)
        guard upTo > 0 else { return [] }

        var sizes = [CGFloat](repeating: 0, count: n)
        var boxes = [CGRect](repeating: .null, count: n)
        for i in 0..<upTo {
            if let f = attr.attribute(.font, at: i, effectiveRange: nil) as? NSFont {
                sizes[i] = f.pointSize
                sizeHist[Int((f.pointSize * 2).rounded()), default: 0] += 1
            }
            boxes[i] = page.characterBounds(at: i)
        }

        // Some glyphs report degenerate / off-page boxes (zero rects, rotated
        // side-stamps outside the crop). Keep them in the text stream but exclude
        // them from geometry so they don't poison line bounds / margins.
        func validBox(_ b: CGRect) -> Bool {
            !b.isNull && b.width > 0 && b.height > 0
                && b.width <= cb.width && b.height <= cb.height * 0.5
                && b.minX.isFinite && b.minY.isFinite
                && b.minX >= cb.minX - 2 && b.maxX <= cb.maxX + 2
                && b.minY >= cb.minY - 2 && b.maxY <= cb.maxY + 2
        }

        var lines: [Line] = []
        var start = 0, idx = 0
        func emit(_ a: Int, _ b: Int) {
            let text = ns.substring(with: NSRange(location: a, length: b - a))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            var ss: [CGFloat] = []
            var ys: [CGFloat] = [], xs0: [CGFloat] = [], xs1: [CGFloat] = []
            for i in a..<b {
                if sizes[i] > 0 { ss.append(sizes[i]) }
                let bx = boxes[i]
                if validBox(bx) { ys.append(bx.minY); xs0.append(bx.minX); xs1.append(bx.maxX) }
            }
            ss.sort()
            var line = Line(text: text, size: ss.isEmpty ? 0 : ss[ss.count / 2], hasBox: !ys.isEmpty)
            if !ys.isEmpty {
                // Use the median baseline, then take x-extents only from glyphs
                // near it, so one off-baseline glyph can't blow up the box.
                let baseY = ys.sorted()[ys.count / 2]
                let med = max(line.size, 1)
                var lo = CGFloat.greatestFiniteMagnitude, hi = -CGFloat.greatestFiniteMagnitude
                var ylo = CGFloat.greatestFiniteMagnitude, yhi = -CGFloat.greatestFiniteMagnitude
                for k in 0..<ys.count where abs(ys[k] - baseY) <= med * 1.2 {
                    lo = min(lo, xs0[k]); hi = max(hi, xs1[k])
                    ylo = min(ylo, ys[k]); yhi = max(yhi, ys[k] + med)
                }
                line.minX = lo; line.maxX = hi; line.minY = ylo; line.maxY = yhi
            }
            lines.append(line)
        }
        while idx <= ns.length {
            if idx == ns.length || ns.character(at: idx) == 10 { emit(start, idx); start = idx + 1 }
            idx += 1
        }
        return lines
    }

    // MARK: - Per-page rendering (pass 2)

    private static func renderPage(
        _ input: [Line], page: PDFPage, pageIndex1 pageNo: Int,
        bodySize: CGFloat, hyphenSet: Set<String>, imagesDir: URL
    ) -> (markdown: String, figureCount: Int) {
        var lines = input
        let cb = page.bounds(for: .cropBox)

        func tier(_ s: CGFloat) -> Tier {
            guard s > 0 else { return .body }
            let r = s / bodySize
            if r >= 1.30 { return .title }
            if r >= 1.15 { return .h2 }
            if r >= 1.045 { return .h3 }
            if r < 0.86 { return .minor }
            return .body
        }

        // Classify lines: tier, caption, and noise to drop.
        for j in lines.indices {
            lines[j].tier = tier(lines[j].size)
            lines[j].isCaption = isCaptionText(lines[j].text)
            if isSymbolNoise(lines[j].text) || isNumericNoise(lines[j].text) { lines[j].dropped = true }
            if lines[j].tier == .minor && lines[j].text.count < 90 { lines[j].dropped = true }
        }

        // Demote runs of ≥3 consecutive same-size heading-tier lines to body — a
        // title/author/affiliation block, not a stack of headings.
        var run: [Int] = []
        func flushRun() {
            if run.count >= 3 { for r in run { lines[r].tier = .body } }
            run.removeAll()
        }
        for j in lines.indices where !lines[j].dropped {
            switch lines[j].tier {
            case .title, .h2, .h3:
                if let last = run.last, abs(lines[last].size - lines[j].size) < 0.1 { run.append(j) }
                else { flushRun(); run = [j] }
            default: flushRun()
            }
        }
        flushRun()
        // Recover common unnumbered headings swept into that demotion (e.g.
        // "Abstract" trailing the author block).
        for j in lines.indices where !lines[j].dropped {
            if headingWords.contains(lines[j].text.lowercased()), lines[j].size >= bodySize * 1.05 {
                lines[j].tier = .h2
            }
        }

        // Column geometry from body lines. `page.string` already orders columns
        // correctly; this is used only for paragraph margins and figure crops.
        let body = lines.filter { $0.tier == .body && $0.hasBox && !$0.dropped }
        let leftX = body.map { $0.minX }.min() ?? cb.minX
        let pageW = cb.width
        let rightCand = body.filter { $0.minX > leftX + 0.25 * pageW }
        var twoCol = false
        var gutter = cb.maxX
        var lcL = leftX, lcR = percentile(body.map { $0.maxX }, 0.92)
        var rcL = leftX, rcR = lcR
        if rightCand.count >= max(3, Int(Double(body.count) * 0.12)) {
            twoCol = true
            // Robust split: stray table cells / caption fragments can sit in the
            // gutter, so use the MEDIAN right-column edge, never the min.
            let g0 = (leftX + percentile(rightCand.map { $0.minX }, 0.5)) / 2
            let leftCol = body.filter { $0.minX < g0 }
            let rightCol = body.filter { $0.minX >= g0 }
            lcL = percentile(leftCol.map { $0.minX }, 0.05)
            lcR = percentile(leftCol.map { $0.maxX }, 0.92)
            rcL = percentile(rightCol.map { $0.minX }, 0.5)
            rcR = percentile(rightCol.map { $0.maxX }, 0.92)
            gutter = (lcR + rcL) / 2
        }
        let lcW = lcR - lcL, rcW = rcR - rcL
        func extent(_ l: Line) -> (x0: CGFloat, x1: CGFloat) {
            guard twoCol else { return (lcL, lcR) }
            if (l.maxX - l.minX) > 1.4 * lcW || (l.minX < gutter && l.maxX > gutter) { return (lcL, rcR) }
            if l.minX >= gutter { return (rcL, rcR) }
            return (lcL, lcR)
        }
        func colRight(_ l: Line) -> CGFloat { (twoCol && l.minX >= gutter) ? rcR : lcR }

        // Typical line leading (median baseline step among adjacent same-column lines).
        var leads: [CGFloat] = []
        var prevB: Line?
        for l in lines where l.hasBox && !l.dropped {
            if let p = prevB, abs(p.minX - l.minX) < 30, p.minY > l.minY {
                let d = p.minY - l.minY
                if d > 2, d < bodySize * 2.5 { leads.append(d) }
            }
            prevB = l
        }
        _ = leads // (kept for clarity; not currently needed after gap-rule removal)

        // Figure / table regions, anchored on captions.
        let pageTop = cb.maxY - cb.height * 0.04
        struct Fig { var rect: CGRect; var captionLineIdx: Int }
        var figs: [Fig] = []
        for j in lines.indices where lines[j].isCaption && lines[j].hasBox && !lines[j].suppressed {
            let cap = lines[j]
            let ext = extent(cap)
            let regionBottom = cap.maxY
            let isTable = cap.text.hasPrefix("Table")
            var ceiling: CGFloat
            if isTable {
                // A table renders as garbled text, so its "image" is the
                // contiguous block of (mis-classified body) lines above the
                // caption. Consume upward while lines stay contiguous.
                let typLead = leads.isEmpty ? bodySize * 1.2 : percentile(leads, 0.5)
                var cur = regionBottom
                let above = lines.indices
                    .filter { let s = lines[$0]; return s.hasBox && !s.dropped && s.minY > regionBottom + 1
                              && s.minX < ext.x1 && s.maxX > ext.x0 }
                    .sorted { lines[$0].minY < lines[$1].minY }
                for m in above {
                    if lines[m].tier == .h2 || lines[m].tier == .h3 || lines[m].tier == .title { break }
                    if lines[m].minY - cur <= typLead * 3 || lines[m].tier != .body { cur = max(cur, lines[m].maxY) }
                    else { break }
                }
                ceiling = cur
            } else {
                // A figure's image sits above its caption, up to the nearest
                // real text row / heading / caption opener within the column.
                // Narrow caption-overflow fragments are ignored; figures suppress
                // only minor lines, so over-extending the crop loses no prose.
                ceiling = pageTop
                for m in lines.indices where m != j {
                    let s = lines[m]
                    guard s.hasBox, !s.dropped, s.tier != .minor,
                          s.maxY - s.minY <= bodySize * 2.5,
                          s.minY > regionBottom + 1, s.minX < ext.x1, s.maxX > ext.x0 else { continue }
                    let isAnchor = s.isCaption || s.tier == .title || s.tier == .h2 || s.tier == .h3
                        || (s.maxX - s.minX) >= 0.45 * lcW
                    guard isAnchor else { continue }
                    ceiling = min(ceiling, s.minY)
                }
            }
            let height = ceiling - regionBottom
            guard height >= max(bodySize * 1.5, 18) else { continue }
            let rect = CGRect(x: ext.x0, y: regionBottom, width: ext.x1 - ext.x0, height: height)
            figs.append(Fig(rect: rect, captionLineIdx: j))
            for m in lines.indices where lines[m].hasBox && m != j {
                let cx = (lines[m].minX + lines[m].maxX) / 2, cy = (lines[m].minY + lines[m].maxY) / 2
                guard cx >= rect.minX, cx <= rect.maxX, cy >= rect.minY, cy <= rect.maxY else { continue }
                if isTable || lines[m].tier == .minor || isSymbolNoise(lines[m].text) { lines[m].suppressed = true }
            }
        }

        // Emit: headings on their own line, body/caption lines reflowed into
        // paragraphs (break on a short justified last line), figures emitted
        // before their caption paragraph.
        var out = "## Page \(pageNo)\n\n"
        var figCount = 0
        var para = "", prev: Line?
        func flushPara() {
            let t = para.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out += t + "\n\n" }
            para = ""; prev = nil
        }
        func emitFig(_ idx: Int) {
            guard let f = figs.first(where: { $0.captionLineIdx == idx }) else { return }
            figCount += 1
            let name = "p\(pageNo)-fig\(figCount).png"
            if renderRegion(f.rect, of: page, to: imagesDir.appendingPathComponent(name)) {
                out += "![](images/\(name))\n\n"
            } else {
                figCount -= 1
            }
        }
        for j in lines.indices {
            let l = lines[j]
            if l.dropped || l.suppressed { continue }
            switch l.tier {
            case .title, .h2, .h3:
                flushPara()
                let hashes = l.tier == .title ? "#" : (l.tier == .h2 ? "##" : "###")
                out += "\(hashes) \(l.text)\n\n"
            default:
                if l.isCaption { flushPara(); emitFig(j) }
                if para.isEmpty {
                    para = l.text
                } else {
                    var brk = false
                    if let p = prev, p.hasBox, l.hasBox {
                        let w = (twoCol && p.minX >= gutter) ? rcW : lcW
                        if p.maxX < colRight(p) - max(bodySize * 1.3, w * 0.06) { brk = true }
                        if p.text.hasSuffix("-") { brk = false }   // hyphen wrap = continuation
                    }
                    if brk {
                        flushPara(); para = l.text
                    } else if para.hasSuffix("-") {
                        let lw = lastWord(beforeTrailingHyphen: para), rw = firstWord(l.text)
                        if rw.isEmpty { para += " " + l.text }
                        else if hyphenSet.contains((lw + "-" + rw).lowercased()) { para += l.text } // keep real hyphen
                        else { para = String(para.dropLast()) + l.text }                            // drop wrap hyphen
                    } else {
                        para += " " + l.text
                    }
                }
                prev = l
            }
        }
        flushPara()
        return (out, figCount)
    }

    // MARK: - Text helpers

    private static let captionRegex = try! NSRegularExpression(pattern: "^(Figure|Table)\\s+\\d+\\s*[:.]")
    private static let inlineHyphenRegex = try! NSRegularExpression(pattern: "\\p{L}+-\\p{L}+")
    private static let headingWords: Set<String> = [
        "abstract", "introduction", "related work", "conclusion", "conclusions",
        "references", "acknowledgements", "acknowledgments", "discussion", "appendix", "background",
    ]

    private static func isCaptionText(_ s: String) -> Bool {
        captionRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func isSymbolNoise(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.count <= 2 && !t.contains(where: { $0.isLetter || $0.isNumber })
    }

    /// Standalone numeric / table-cell remnant like "12.0", "3.2", "6 .2".
    private static func isNumericNoise(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count <= 12, t.contains(where: { $0.isNumber }) else { return false }
        return t.allSatisfy { $0.isNumber || $0 == "." || $0 == "," || $0 == "×" || $0 == " " }
    }

    /// Collect inline (non-wrap) hyphenated compounds — those with a letter on
    /// BOTH sides of the hyphen, so an end-of-line wrap "...car-" never matches.
    /// A wrap's hyphen is "real" iff the compound recurs in this set elsewhere.
    private static func collectInlineHyphens(_ text: String, into set: inout Set<String>) {
        for m in inlineHyphenRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let r = Range(m.range, in: text) { set.insert(text[r].lowercased()) }
        }
    }

    private static func lastWord(beforeTrailingHyphen s: String) -> String {
        var t = s
        if t.hasSuffix("-") { t.removeLast() }
        return String(t.reversed().prefix { $0.isLetter || $0.isNumber }.reversed())
    }
    private static func firstWord(_ s: String) -> String { String(s.prefix { $0.isLetter || $0.isNumber }) }

    private static func percentile(_ xs: [CGFloat], _ p: Double) -> CGFloat {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[min(s.count - 1, max(0, Int(p * Double(s.count - 1))))]
    }

    // MARK: - Region rendering

    /// Renders `rect` (in page user space) to a PNG at `url`. Uses CoreGraphics
    /// directly — no AppKit drawing needed. Returns true on success.
    private static func renderRegion(_ rect: CGRect, of page: PDFPage, to url: URL) -> Bool {
        let scale: CGFloat = 2.0
        let pixelW = Int((rect.width * scale).rounded())
        let pixelH = Int((rect.height * scale).rounded())
        guard pixelW > 0, pixelH > 0 else { return false }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let cg = CGContext(
            data: nil, width: pixelW, height: pixelH,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return false }

        cg.setFillColor(CGColor(gray: 1, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: -rect.minX, y: -rect.minY)
        page.draw(with: .cropBox, to: cg)

        guard let img = cg.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
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
