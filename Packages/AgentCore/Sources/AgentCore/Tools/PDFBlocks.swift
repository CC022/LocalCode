import Foundation
import PDFKit
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Shared glyph→line→block extraction for `parse_pdf` and `translate_pdf`.
///
/// Design (see the `pdfkit-extraction-findings` project memory): trust
/// `page.string` for reading order (it is already column-correct, even for
/// 2-column papers), and attach geometry + font size to each glyph via the
/// index-aligned trio `page.string` ⇄ `page.attributedString` ⇄
/// `page.characterBounds(at:)`. Structure (headings) comes from doc-wide font
/// size tiers; paragraphs from the justified-text "short last line" signal;
/// figures/tables are anchored on their captions.
enum PDFBlocks {

    /// Size tier of a line, relative to the doc-wide body font size.
    enum Tier { case title, h2, h3, body, minor }

    /// One visual line (a `\n`-delimited run of `page.string`) with the geometry
    /// + font size attached from the index-aligned glyph trio.
    struct Line {
        var text: String
        var size: CGFloat          // median glyph point size (0 if unknown)
        var hasBox: Bool
        var minX: CGFloat = 0, maxX: CGFloat = 0, minY: CGFloat = 0, maxY: CGFloat = 0
        var tier: Tier = .body
        var isCaption = false
        var dropped = false        // symbol / numeric / minor-label noise
        var suppressed = false     // covered by a figure/table region
        /// `selection(for:).bounds(for:)` for the line — a different PDFKit
        /// code path that stays correct where `characterBounds` returns junk
        /// (e.g. bold heading runs in Type1/dvips PDFs). Used for the visual
        /// overlay geometry; `.null` when degenerate.
        var selRect: CGRect = .null

        var rect: CGRect { CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) }
        /// Best visual box for rendering decisions.
        var visRect: CGRect { selRect.isNull ? (hasBox ? rect : .null) : selRect }
    }

    /// One visual box of a block plus the per-line boxes it unions — the line
    /// count reproduces the original leading (`rect.height / lines`), and the
    /// line rects let callers white-out exactly the printed lines (sparing
    /// inline-math overshoots that float between them).
    struct Fragment {
        var rect: CGRect
        var lineRects: [CGRect]
        var lines: Int { lineRects.count }
    }

    /// A logical paragraph / heading in reading order. `fragments` are the
    /// visual boxes it occupies — one per column run, so a paragraph that flows
    /// from the bottom of the left column to the top of the right column gets
    /// two boxes. Empty when no line had usable geometry.
    struct Block {
        var level: Int             // 0 = paragraph, 1...3 = heading depth
        var text: String
        var size: CGFloat
        var isCaption: Bool
        var isMath: Bool = false   // linearized formula content — keep as pixels
        var firstLine: Int         // index into the page's lines (figure anchoring)
        var fragments: [Fragment]
    }

    /// Caption-anchored figure/table region (page user space).
    struct Figure {
        var rect: CGRect
        var captionLineIdx: Int
    }

    /// Column layout derived from body-line geometry. `page.string` already
    /// orders columns correctly; this is used only for paragraph margins,
    /// fragment grouping, and figure crops.
    struct ColumnGeometry {
        var twoCol = false
        var gutter: CGFloat
        var lcL: CGFloat, lcR: CGFloat
        var rcL: CGFloat, rcR: CGFloat
        var lcW: CGFloat { lcR - lcL }
        var rcW: CGFloat { rcR - rcL }

        func extent(_ l: Line) -> (x0: CGFloat, x1: CGFloat) {
            guard twoCol else { return (lcL, lcR) }
            if (l.maxX - l.minX) > 1.4 * lcW || (l.minX < gutter && l.maxX > gutter) { return (lcL, rcR) }
            if l.minX >= gutter { return (rcL, rcR) }
            return (lcL, lcR)
        }
        func colRight(_ l: Line) -> CGFloat { (twoCol && l.minX >= gutter) ? rcR : lcR }
        func inRightColumn(_ l: Line) -> Bool { twoCol && l.minX >= gutter }
        // Rect-based variants for selection-bounds geometry (reliable where
        // glyph boxes are junk).
        func inRight(_ r: CGRect) -> Bool { twoCol && r.minX >= gutter }
        func rightEdge(of r: CGRect) -> CGFloat { inRight(r) ? rcR : lcR }
    }

    // MARK: - Glyph extraction (pass 1)

    /// Build `Line`s for a page from the index-aligned `page.string` /
    /// `attributedString` / `characterBounds` trio, accumulating the doc-wide
    /// font-size histogram (keyed by `round(pointSize*2)` for ½-pt buckets).
    static func extractLines(_ page: PDFPage, sizeHist: inout [Int: Int]) -> [Line] {
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
            if let sel = page.selection(for: NSRange(location: a, length: b - a)) {
                let sb = sel.bounds(for: page)
                if !sb.isNull, sb.width > 0, sb.height > 0, sb.minX.isFinite, sb.minY.isFinite,
                   sb.height <= max(line.size * 3, 12), cb.insetBy(dx: -4, dy: -4).contains(sb) {
                    line.selRect = sb
                }
            }
            lines.append(line)
        }
        while idx <= ns.length {
            if idx == ns.length || ns.character(at: idx) == 10 { emit(start, idx); start = idx + 1 }
            idx += 1
        }
        return lines
    }

    /// Doc-wide body size = MODE of all glyph sizes (½-pt buckets).
    static func bodySize(from sizeHist: [Int: Int]) -> CGFloat {
        CGFloat(sizeHist.max { $0.value < $1.value }?.key ?? 20) / 2.0
    }

    // MARK: - Classification (pass 2, per page)

    /// Assign tiers, mark captions, drop noise, demote heading runs, and
    /// recover whitelisted unnumbered headings.
    static func classify(_ lines: inout [Line], bodySize: CGFloat) {
        func tier(_ s: CGFloat) -> Tier {
            guard s > 0 else { return .body }
            let r = s / bodySize
            if r >= 1.30 { return .title }
            if r >= 1.15 { return .h2 }
            if r >= 1.045 { return .h3 }
            if r < 0.86 { return .minor }
            return .body
        }

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
    }

    /// Column geometry from body lines.
    static func columnGeometry(_ lines: [Line], cropBox cb: CGRect) -> ColumnGeometry {
        let body = lines.filter { $0.tier == .body && $0.hasBox && !$0.dropped }
        let leftX = body.map { $0.minX }.min() ?? cb.minX
        let pageW = cb.width
        let rightCand = body.filter { $0.minX > leftX + 0.25 * pageW }
        var geo = ColumnGeometry(
            gutter: cb.maxX,
            lcL: leftX, lcR: percentile(body.map { $0.maxX }, 0.92),
            rcL: leftX, rcR: percentile(body.map { $0.maxX }, 0.92)
        )
        if rightCand.count >= max(3, Int(Double(body.count) * 0.12)) {
            geo.twoCol = true
            // Robust split: stray table cells / caption fragments can sit in the
            // gutter, so use the MEDIAN right-column edge, never the min.
            let g0 = (leftX + percentile(rightCand.map { $0.minX }, 0.5)) / 2
            let leftCol = body.filter { $0.minX < g0 }
            let rightCol = body.filter { $0.minX >= g0 }
            geo.lcL = percentile(leftCol.map { $0.minX }, 0.05)
            geo.lcR = percentile(leftCol.map { $0.maxX }, 0.92)
            geo.rcL = percentile(rightCol.map { $0.minX }, 0.5)
            geo.rcR = percentile(rightCol.map { $0.maxX }, 0.92)
            geo.gutter = (geo.lcR + geo.rcL) / 2
        }
        return geo
    }

    // MARK: - Figure / table regions (caption-anchored)

    /// Find caption-anchored figure/table regions and mark lines covered by
    /// them as suppressed. Tables consume + suppress the contiguous body-tier
    /// block above the caption (table cells are body-tier garble); figures
    /// suppress only minor lines so an over-tall crop never deletes prose.
    static func markFigures(_ lines: inout [Line], geo: ColumnGeometry, cropBox cb: CGRect, bodySize: CGFloat) -> [Figure] {
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

        let pageTop = cb.maxY - cb.height * 0.04
        var figs: [Figure] = []
        for j in lines.indices where lines[j].isCaption && lines[j].hasBox && !lines[j].suppressed {
            let cap = lines[j]
            let ext = geo.extent(cap)
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
                        || (s.maxX - s.minX) >= 0.45 * geo.lcW
                    guard isAnchor else { continue }
                    ceiling = min(ceiling, s.minY)
                }
            }
            let height = ceiling - regionBottom
            guard height >= max(bodySize * 1.5, 18) else { continue }
            let rect = CGRect(x: ext.x0, y: regionBottom, width: ext.x1 - ext.x0, height: height)
            figs.append(Figure(rect: rect, captionLineIdx: j))
            for m in lines.indices where lines[m].hasBox && m != j {
                let cx = (lines[m].minX + lines[m].maxX) / 2, cy = (lines[m].minY + lines[m].maxY) / 2
                guard cx >= rect.minX, cx <= rect.maxX, cy >= rect.minY, cy <= rect.maxY else { continue }
                if isTable || lines[m].tier == .minor || isSymbolNoise(lines[m].text) { lines[m].suppressed = true }
            }
        }
        return figs
    }

    // MARK: - Paragraph grouping

    /// Lines that are (part of) a display formula. Textual math lines seed the
    /// set; word-poor body lines that share a vertical band (same column) with
    /// a seed or with a dropped sub/superscript formula fragment join it —
    /// PDFKit splits one equation into several lines side by side ("Rij=" at
    /// 10pt next to "Wij,k Iij,k (1)" at 7pt).
    static func markMathLines(_ lines: [Line], geo: ColumnGeometry) -> [Bool] {
        var math = [Bool](repeating: false, count: lines.count)
        for j in lines.indices where !lines[j].suppressed {
            if isMathLine(lines[j].text) { math[j] = true }
        }
        // Seeds for band propagation: textual math + dropped formula fragments.
        let seeds = lines.indices.filter { j in
            math[j] || (lines[j].dropped && !lines[j].suppressed
                        && lines[j].text.contains(where: { mathChars.contains($0) }))
        }
        for j in lines.indices where !math[j] && !lines[j].dropped && !lines[j].suppressed {
            let l = lines[j]
            let r = l.visRect
            guard !r.isNull, l.tier == .body || l.tier == .minor else { continue }
            let realWords = l.text.split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 3 }
            guard realWords.count <= 2 else { continue }   // prose lines are immune
            for s in seeds where s != j {
                let sr = lines[s].visRect
                guard !sr.isNull, geo.inRightColumn(l) == geo.inRightColumn(lines[s]) else { continue }
                let overlap = min(r.maxY, sr.maxY) - max(r.minY, sr.minY)
                if overlap >= r.height * 0.5 { math[j] = true; break }
            }
        }
        return math
    }

    /// Group classified lines into reading-order blocks: headings on their own,
    /// body/caption lines reflowed into paragraphs (break on a short justified
    /// last line), line-wrap hyphens resolved against the doc-wide compound set.
    /// Formula lines break paragraphs and come out as `isMath` blocks so they
    /// are never reflowed or translated.
    static func buildBlocks(_ lines: [Line], geo: ColumnGeometry, bodySize: CGFloat, hyphenSet: Set<String>) -> [Block] {
        let math = markMathLines(lines, geo: geo)
        var blocks: [Block] = []
        var para = "", prev: Line?
        var paraSize: CGFloat = 0
        var paraFirst = -1
        var paraCaption = false
        var frags: [Fragment] = []
        var mathRun = "", mathFirst = -1, mathSize: CGFloat = 0

        func flushPara() {
            let t = para.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                blocks.append(Block(level: 0, text: t, size: paraSize, isCaption: paraCaption,
                                    firstLine: paraFirst, fragments: frags))
            }
            para = ""; prev = nil; frags = []; paraFirst = -1; paraCaption = false; paraSize = 0
        }
        func flushMath() {
            let t = mathRun.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                blocks.append(Block(level: 0, text: t, size: mathSize, isCaption: false,
                                    isMath: true, firstLine: mathFirst, fragments: []))
            }
            mathRun = ""; mathFirst = -1; mathSize = 0
        }
        func startPara(_ l: Line, at j: Int) {
            para = l.text; paraFirst = j; paraCaption = l.isCaption; paraSize = l.size
            frags = l.visRect.isNull ? [] : [Fragment(rect: l.visRect, lineRects: [l.visRect])]
        }
        /// PDFKit splits one visual line into several text lines at font/math
        /// boundaries ("curve: exp−" + "2σ , where…"). Same baseline band and
        /// starting at/after the previous piece's end = same printed line. The
        /// x-slack of one character absorbs stacked fractions, whose lower
        /// digit starts slightly left of where the upper one ended ("1⁄2").
        func sameVisualLine(_ pr: CGRect, _ r: CGRect, size: CGFloat) -> Bool {
            abs(r.minY - pr.minY) < max(size, 1) * 0.6 && r.minX > pr.maxX - max(size, 1)
        }
        func extendGeometry(_ l: Line) {
            let r = l.visRect
            guard !r.isNull else { return }
            // New fragment when the line jumps UP (next column / region),
            // switches columns, or leaves a vertical gap (e.g. text resuming
            // below a figure) — unioning across a gap would inflate the
            // fragment's apparent leading. Otherwise grow the current box.
            let pr = prev?.visRect ?? .null
            let jumped = !pr.isNull && !sameVisualLine(pr, r, size: l.size)
                && (r.minY > pr.maxY + 1
                    || geo.inRight(r) != geo.inRight(pr)
                    || pr.minY - r.maxY > max(l.size * 1.2, 6))
            if frags.isEmpty || jumped { frags.append(Fragment(rect: r, lineRects: [r])) }
            else {
                frags[frags.count - 1].rect = frags[frags.count - 1].rect.union(r)
                // An x-adjacent continuation extends the current printed line
                // instead of counting a new one (keeps the leading math honest).
                if !pr.isNull, sameVisualLine(pr, r, size: l.size),
                   let last = frags[frags.count - 1].lineRects.last {
                    frags[frags.count - 1].lineRects[frags[frags.count - 1].lineRects.count - 1] = last.union(r)
                } else {
                    frags[frags.count - 1].lineRects.append(r)
                }
            }
        }

        for j in lines.indices {
            let l = lines[j]
            if l.dropped || l.suppressed { continue }
            if math[j], l.tier != .title, l.tier != .h2, l.tier != .h3 {
                flushPara()
                if mathRun.isEmpty { mathFirst = j; mathSize = l.size }
                mathRun += mathRun.isEmpty ? l.text : " " + l.text
                continue
            }
            flushMath()
            switch l.tier {
            case .title, .h2, .h3:
                flushPara()
                let level = l.tier == .title ? 1 : (l.tier == .h2 ? 2 : 3)
                blocks.append(Block(level: level, text: l.text, size: l.size, isCaption: false,
                                    firstLine: j,
                                    fragments: l.visRect.isNull ? [] : [Fragment(rect: l.visRect, lineRects: [l.visRect])]))
            default:
                if l.isCaption { flushPara() }
                if para.isEmpty {
                    startPara(l, at: j)
                } else {
                    // The justified-text "short last line" break, read from
                    // selection bounds — glyph boxes are junk for some lines
                    // (false breaks like a stranded "weight maps." widow).
                    var brk = false
                    if let p = prev, !p.visRect.isNull, !l.visRect.isNull {
                        let pr = p.visRect
                        let w = geo.inRight(pr) ? geo.rcW : geo.lcW
                        if pr.maxX < geo.rightEdge(of: pr) - max(bodySize * 1.3, w * 0.06) { brk = true }
                        if p.text.hasSuffix("-") { brk = false }   // hyphen wrap = continuation
                        // Same printed line, split by PDFKit at a font/math
                        // boundary — always a continuation.
                        if sameVisualLine(pr, l.visRect, size: l.size) { brk = false }
                        // A vertical gap ≫ leading within the same column (text
                        // resuming below a display equation or figure) is a
                        // paragraph break even when the previous line ran full.
                        if geo.inRight(pr) == geo.inRight(l.visRect),
                           pr.minY - l.visRect.maxY > bodySize * 2.5 {
                            brk = true
                        }
                    } else if let p = prev, p.hasBox, l.hasBox {
                        let w = geo.inRightColumn(p) ? geo.rcW : geo.lcW
                        if p.maxX < geo.colRight(p) - max(bodySize * 1.3, w * 0.06) { brk = true }
                        if p.text.hasSuffix("-") { brk = false }
                    }
                    if brk {
                        flushPara(); startPara(l, at: j)
                    } else {
                        extendGeometry(l)
                        if para.hasSuffix("-") {
                            let lw = lastWord(beforeTrailingHyphen: para), rw = firstWord(l.text)
                            if rw.isEmpty { para += " " + l.text }
                            else if hyphenSet.contains((lw + "-" + rw).lowercased()) { para += l.text } // keep real hyphen
                            else { para = String(para.dropLast()) + l.text }                            // drop wrap hyphen
                        } else {
                            para += " " + l.text
                        }
                    }
                }
                prev = l
            }
        }
        flushPara()
        flushMath()
        return blocks
    }

    // MARK: - Text helpers

    private static let captionRegex = try! NSRegularExpression(pattern: "^(Figure|Table)\\s+\\d+\\s*[:.]")
    private static let inlineHyphenRegex = try! NSRegularExpression(pattern: "\\p{L}+-\\p{L}+")
    private static let headingWords: Set<String> = [
        "abstract", "introduction", "related work", "conclusion", "conclusions",
        "references", "acknowledgements", "acknowledgments", "discussion", "appendix", "background",
    ]

    static func isCaptionText(_ s: String) -> Bool {
        captionRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func isSymbolNoise(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.count <= 2 && !t.contains(where: { ($0.isLetter && !isAccentArtifact($0)) || $0.isNumber })
    }

    /// Stray accent glyphs PDFKit splits off math (hats, tildes, combining
    /// marks). They are Unicode *letters* (category Lm/Mn/…), so plain
    /// `isLetter` checks keep them as prose — but a line made of them is noise.
    private static func isAccentArtifact(_ c: Character) -> Bool {
        guard c.unicodeScalars.count == 1, let s = c.unicodeScalars.first else { return false }
        switch s.properties.generalCategory {
        case .modifierLetter, .modifierSymbol, .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    /// Broad set — used to recognize dropped sub/superscript fragments as
    /// formula *seeds* for band propagation (parens are enough there, e.g.
    /// "Wij,k Iij,k (1)").
    static let mathChars = Set("=+−±×·÷∗/^∑∏∫√≈≠≤≥∈∉∂∇∞{}()[]|ˆ˜⟨⟩")
    /// Strong set — promoting a *kept* line to math needs an unambiguous math
    /// symbol; parens/brackets alone also occur in prose and reference tails
    /// ("23(3):294–302, 2004.", "al. [2].").
    private static let strongMathChars = Set("=+−±×·÷∗^∑∏∫√≈≠≤≥∈∉∂∇∞{}|ˆ˜⟨⟩")

    /// Does this line look like (part of) a linearized formula? True when it
    /// has no real prose word but does carry math symbols, or when it is a
    /// short `lhs = rhs` with at most one word (e.g. "Rij=", "L{R}l ij = argmax").
    static func isMathLine(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        let nonSpace = t.filter { !$0.isWhitespace }
        let realWords = t.split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 3 }
        let symbolCount = nonSpace.filter { strongMathChars.contains($0) }.count
        if realWords.isEmpty, symbolCount > 0 { return true }
        if t.contains("="), realWords.count <= 1, nonSpace.count <= 48 { return true }
        return false
    }

    /// Standalone numeric / table-cell remnant like "12.0", "3.2", "6 .2".
    static func isNumericNoise(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count <= 12, t.contains(where: { $0.isNumber }) else { return false }
        return t.allSatisfy { $0.isNumber || $0 == "." || $0 == "," || $0 == "×" || $0 == " " }
    }

    /// Collect inline (non-wrap) hyphenated compounds — those with a letter on
    /// BOTH sides of the hyphen, so an end-of-line wrap "...car-" never matches.
    /// A wrap's hyphen is "real" iff the compound recurs in this set elsewhere.
    static func collectInlineHyphens(_ text: String, into set: inout Set<String>) {
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

    static func percentile(_ xs: [CGFloat], _ p: Double) -> CGFloat {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[min(s.count - 1, max(0, Int(p * Double(s.count - 1))))]
    }

    // MARK: - Region rendering

    /// Renders `rect` (in page user space) to an image at `url` (PNG or JPEG by
    /// extension). `whiteOut` rects (page space) are filled white after the page
    /// draws — used by translate_pdf to blank the regions it re-typesets.
    static func renderRegion(
        _ rect: CGRect, of page: PDFPage, to url: URL,
        scale: CGFloat = 2.0, whiteOut: [CGRect] = []
    ) -> Bool {
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
        cg.setFillColor(CGColor(gray: 1, alpha: 1))
        for r in whiteOut { cg.fill(r) }

        let isJPEG = url.pathExtension.lowercased() == "jpg" || url.pathExtension.lowercased() == "jpeg"
        let type = isJPEG ? UTType.jpeg : UTType.png
        let props = isJPEG ? [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary : nil
        guard let img = cg.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, img, props)
        return CGImageDestinationFinalize(dest)
    }
}
