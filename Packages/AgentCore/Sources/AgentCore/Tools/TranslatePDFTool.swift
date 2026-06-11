import Foundation
import PDFKit
import MLXLMCommon

/// Layout-preserving PDF translator: PDF → HTML that visually mirrors the
/// original pages.
///
/// Each page is rendered to a background image with the translated regions
/// whited out; translations are absolutely-positioned HTML text at the original
/// paragraph boxes (original font size, shrink-to-fit). Everything that is NOT
/// translated — figures, tables, display math, references, page furniture —
/// stays pixel-identical in the background image, so the hard PDF-layout
/// problems never arise. Translation runs one paragraph block at a time (the
/// local model's sweet spot), carrying the previous translation as context,
/// and the HTML is rewritten after every page so a crash leaves a clean
/// partial document.
struct TranslatePDFTool: Tool {
    let cwd: URL
    let engine: InferenceEngine
    /// Test/debug seam: when set, used instead of the model. Args: (source
    /// text, previous translation). Production leaves this nil.
    var translator: (@Sendable (String, String?) async -> String)? = nil
    let name = "translate_pdf"

    var toolSpec: ToolSpec {
        ToolSpecBuilder.make(
            name: name,
            description:
                "Translate a PDF into another language, preserving the original page layout. Produces <output_dir>/index.html where each page looks like the original (same columns, figures, tables, equations, fonts) with the prose replaced by the translation; open it in a browser. Translates paragraph-by-paragraph through the local/API model and rewrites the HTML after every page, so long documents are safe and a partial file is still valid. Figures, tables, display math, and references remain as in the original. Returns a summary with page/paragraph counts and the output path.",
            properties: [
                (name: "path", type: "string", description: "PDF path (relative to working directory or absolute under it)."),
                (name: "target_language", type: "string", description: "Natural-language name of the target, e.g. \"Chinese (Simplified)\", \"Japanese\", \"Spanish\"."),
                (name: "output_dir", type: "string", description: "Output directory. Default: <pdf-basename>.translated next to the PDF."),
                (name: "pages", type: "string", description: "Optional 1-indexed page range like \"1-10\", \"3\", or \"1-3,5\". Default: all pages."),
            ],
            required: ["path", "target_language"]
        )
    }

    /// Low temperature for faithful output + repetition penalty so the local
    /// model can't degenerate into a repeat loop on a paragraph.
    private static let translateParams = GenerateParameters(
        maxTokens: 2048,
        temperature: 0.4,
        repetitionPenalty: 1.05,
        repetitionContextSize: 64
    )

    nonisolated func run(_ arguments: [String: JSONValue]) async -> String {
        guard let path = arguments["path"]?.string else { return "Error: missing 'path'" }
        guard let lang = arguments["target_language"]?.string,
              !lang.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "Error: missing 'target_language'"
        }
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
                    pdfURL.deletingLastPathComponent().appendingPathComponent("\(base).translated").path,
                    cwd: cwd
                )
            }
            let imagesDir = outputDir.appendingPathComponent("images")
            try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

            let pageIndices = try ParsePDFTool.parsePageRange(arguments["pages"]?.string, total: doc.pageCount)

            // Pass 1 (doc-wide): lines + font-size histogram + hyphen compounds.
            var sizeHist: [Int: Int] = [:]
            var pageLines: [[PDFBlocks.Line]] = []
            for i in pageIndices {
                guard let page = doc.page(at: i) else { pageLines.append([]); continue }
                pageLines.append(PDFBlocks.extractLines(page, sizeHist: &sizeHist))
            }
            let bodySize = PDFBlocks.bodySize(from: sizeHist)
            var hyphenSet = Set<String>()
            for lines in pageLines { for l in lines { PDFBlocks.collectInlineHyphens(l.text, into: &hyphenSet) } }

            // Pass 2: translate page by page, rewriting the HTML each time.
            let title = pdfURL.deletingPathExtension().lastPathComponent
            let indexURL = outputDir.appendingPathComponent("index.html")
            var sections: [String] = []
            var reference: String? = nil
            var inReferences = false
            var translated = 0, skipped = 0
            let started = Date()

            for (k, i) in pageIndices.enumerated() {
                guard let page = doc.page(at: i) else { continue }
                var lines = pageLines[k]
                let cb = page.bounds(for: .cropBox)
                PDFBlocks.classify(&lines, bodySize: bodySize)
                let geo = PDFBlocks.columnGeometry(lines, cropBox: cb)
                _ = PDFBlocks.markFigures(&lines, geo: geo, cropBox: cb, bodySize: bodySize)
                let blocks = PDFBlocks.buildBlocks(lines, geo: geo, bodySize: bodySize, hyphenSet: hyphenSet)

                // Front matter (authors/affiliations between the title and the
                // first section heading) keeps its original multi-column pixels —
                // reflowing it never looks right and it doesn't need translation.
                // Only on the document's true first page.
                var inFrontMatter = i == 0 && blocks.contains { $0.level >= 2 }

                var overlays: [Overlay] = []
                var whiteOut: [CGRect] = []
                for b in blocks {
                    if b.level > 0 {
                        let lower = b.text.lowercased()
                        inReferences = lower.contains("reference") || lower.contains("bibliograph")
                        if b.level >= 2 { inFrontMatter = false }
                    }
                    // Headings and figure captions translate even inside the
                    // references section / front matter (figures can follow the
                    // bibliography in papers). Math blocks stay as pixels.
                    guard !b.isMath,
                          (!inReferences && !inFrontMatter) || b.level > 0 || b.isCaption,
                          !b.fragments.isEmpty,
                          Self.shouldTranslate(b.text) else { skipped += 1; continue }

                    let raw = await translate(b.text, reference: reference, language: lang)
                    let cleaned = Self.cleanTranslation(raw, reference: reference)
                    guard !cleaned.isEmpty else { skipped += 1; continue }
                    reference = cleaned
                    translated += 1

                    // Capacity of a fragment ≈ width × line count (same font size
                    // throughout a block, so this is its share of the text).
                    let parts = Self.splitForFragments(cleaned, areas: b.fragments.map { $0.rect.width * CGFloat($0.lines) })
                    for (frag, text) in zip(b.fragments, parts) where !text.isEmpty {
                        overlays.append(Overlay(rect: frag.rect, text: text, size: b.size,
                                                lines: frag.lines, heading: b.level > 0))
                        // White out the printed lines, not the box union — inline
                        // math that overshoots the line band (stacked fractions)
                        // survives in the gaps between lines.
                        whiteOut += frag.lineRects.map { $0.insetBy(dx: -1.5, dy: -1.5).intersection(cb) }
                    }
                }

                // Stacked inline math splits into dropped fragment lines that
                // overlap a translated line's band (e.g. a fraction numerator
                // poking above the prose). White those too — otherwise half a
                // fraction floats over the translation. Display equations are
                // never whited, so their fragments don't intersect anything.
                for l in lines where l.dropped && !l.suppressed {
                    let r = l.visRect
                    if !r.isNull, whiteOut.contains(where: { $0.intersects(r.insetBy(dx: 0, dy: -2)) }) {
                        whiteOut.append(r.insetBy(dx: -1.5, dy: -1.5).intersection(cb))
                    }
                }

                let pageNo = i + 1
                let imgName = "page\(pageNo).jpg"
                _ = PDFBlocks.renderRegion(cb, of: page, to: imagesDir.appendingPathComponent(imgName),
                                           whiteOut: whiteOut)
                sections.append(Self.pageHTML(pageNo: pageNo, cropBox: cb, image: "images/\(imgName)",
                                              overlays: overlays))
                try Self.document(title: "\(title) · \(lang)", sections: sections)
                    .write(to: indexURL, atomically: true, encoding: .utf8)
            }

            let elapsed = Date().timeIntervalSince(started)
            let relOut = SafePath.relativize(indexURL, to: cwd)
            return """
            Translated "\(pdfURL.lastPathComponent)" → \(lang): \(pageIndices.count) pages, \
            \(translated) paragraphs translated, \(skipped) left as-is (math/tables/references/short), \
            \(String(format: "%.1f", elapsed))s.
            Output: \(relOut) — open in a browser; pages mirror the original layout.
            """
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Inference

    private func translate(_ text: String, reference: String?, language: String) async -> String {
        if let translator { return await translator(text, reference) }

        // Source first, instruction after, target-language cue header right
        // before generation — same construction the chunked MD translator
        // validated (forces the first generated token into the target language).
        let context = (reference?.isEmpty == false)
            ? "[Previous paragraph's translation, for terminology consistency]:\n\(reference!.suffix(400))\n\n"
            : ""
        let prompt = context + """
        [Source text]:
        \(text)

        Translate the source text above into \(language).
        - Output ONLY the translation — no commentary, no quotes, no source repetition.
        - Keep numbers, citation markers like [12], URLs, and code unchanged.
        - Inline math: either copy its symbols verbatim, or typeset it as LaTeX wrapped in $...$. Never use \\(...\\) or code blocks.
        - Translate exactly once, as a single paragraph (or a short heading if the source is a heading).

        [\(language) translation]:
        """

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

    // MARK: - Pure helpers (testable)

    /// Should this block's text go through the model? Filters out linearized
    /// display math, table remnants, and other non-prose: requires ≥50%
    /// letters among non-space characters plus at least one ≥3-letter word.
    static func shouldTranslate(_ text: String) -> Bool {
        guard text.count >= 2 else { return false }
        let nonSpace = text.filter { !$0.isWhitespace }
        guard !nonSpace.isEmpty else { return false }
        let letters = nonSpace.filter(\.isLetter)
        guard Double(letters.count) / Double(nonSpace.count) >= 0.5 else { return false }
        return text.split(whereSeparator: { !$0.isLetter }).contains { $0.count >= 3 }
    }

    /// Sanitize model output (label echoes, reference repeats, repeat loops)
    /// and collapse it to a single flowing paragraph.
    static func cleanTranslation(_ raw: String, reference: String?) -> String {
        let s = TranslateMDTool.sanitize(raw, reference: reference)
        let (t, _) = TranslateMDTool.truncateAtRepetition(s)
        return t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Distribute translated text across a block's column fragments,
    /// proportionally to fragment area, cutting at the nearest break character
    /// (space / punctuation) so a paragraph that flowed across columns in the
    /// original flows across the same boxes in the translation.
    static func splitForFragments(_ text: String, areas: [CGFloat]) -> [String] {
        guard areas.count > 1, text.count > 1 else { return [text] }
        let chars = Array(text)
        let total = max(areas.reduce(0, +), 1)
        let breakChars = Set(" 。，；、！？．,.;)）]」』")
        var result: [String] = []
        var start = 0
        var consumed: CGFloat = 0
        for a in areas.dropLast() {
            consumed += a
            let target = min(max(Int(CGFloat(chars.count) * consumed / total), start), chars.count)
            var best = target
            search: for d in 0...max(4, chars.count / 8) {
                for cand in [target + d, target - d] where cand > start && cand <= chars.count {
                    if cand == chars.count || breakChars.contains(chars[cand - 1]) {
                        best = cand; break search
                    }
                }
            }
            result.append(String(chars[start..<best]).trimmingCharacters(in: .whitespaces))
            start = best
        }
        result.append(String(chars[start...]).trimmingCharacters(in: .whitespaces))
        return result
    }

    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - HTML emission

    struct Overlay {
        var rect: CGRect
        var text: String
        var size: CGFloat
        var lines: Int
        var heading: Bool
    }

    /// One page section: a fixed-size div with the whited-out page render as
    /// background and translated text absolutely positioned over it.
    static func pageHTML(pageNo: Int, cropBox cb: CGRect, image: String, overlays: [Overlay]) -> String {
        var html = String(format: "<div class=\"page\" id=\"p%d\" style=\"width:%.1fpx;height:%.1fpx\">\n",
                          pageNo, cb.width, cb.height)
        html += "<img src=\"\(image)\" alt=\"page \(pageNo)\">\n"
        for o in overlays {
            // PDF user space is bottom-up; CSS is top-down. line-height is the
            // fragment's own leading (height / original line count) so the
            // translation reproduces the original vertical rhythm; the small
            // height slack absorbs the last line's descenders.
            let left = o.rect.minX - cb.minX
            let top = cb.maxY - o.rect.maxY
            let leading = o.rect.height / CGFloat(max(o.lines, 1))
            let height = o.rect.height + o.size * 0.3
            html += String(
                format: "<div class=\"t%@\" style=\"left:%.1fpx;top:%.1fpx;width:%.1fpx;height:%.1fpx;font-size:%.1fpx;line-height:%.2fpx\">%@</div>\n",
                o.heading ? " h" : "", left, top, o.rect.width + 3, height, o.size,
                max(leading, o.size), htmlEscape(o.text)
            )
        }
        html += "</div>"
        return html
    }

    /// Full document wrapper. Rewritten after every page so partial output is
    /// always a valid HTML file. KaTeX (CDN, degrades to raw `$...$` text when
    /// offline) typesets the inline LaTeX the model is allowed to emit; the
    /// shrink-to-fit pass runs after it so boxes account for rendered math.
    static func document(title: String, sections: [String]) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(htmlEscape(title))</title>
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.21/dist/katex.min.css">
        <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.21/dist/katex.min.js"></script>
        <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.21/dist/contrib/auto-render.min.js"></script>
        <style>
        body{margin:0;padding:14px;background:#53575e;display:flex;flex-direction:column;align-items:center;gap:14px}
        .page{position:relative;flex:none;background:#fff;box-shadow:0 2px 10px rgba(0,0,0,.45)}
        .page>img{position:absolute;left:0;top:0;width:100%;height:100%;user-select:none;pointer-events:none}
        .t{position:absolute;overflow:hidden;box-sizing:border-box;color:#111;line-height:1.18;
           font-family:-apple-system,"PingFang SC","Hiragino Sans GB","Noto Sans CJK SC",sans-serif;
           text-align:justify;text-justify:inter-ideograph}
        .t.h{font-weight:600;text-align:left}
        </style></head><body>
        \(sections.joined(separator: "\n"))
        <script>
        function fitAll() {
          for (const b of document.querySelectorAll('.t')) {
            const s0 = parseFloat(b.style.fontSize), lh0 = parseFloat(b.style.lineHeight);
            let s = s0;
            while (b.scrollHeight > b.clientHeight + 2 && s > 6) {
              s -= 0.5;
              b.style.fontSize = s + 'px';
              b.style.lineHeight = (lh0 * s / s0) + 'px';
            }
          }
        }
        window.addEventListener('load', () => {
          if (window.renderMathInElement) {
            renderMathInElement(document.body, {
              delimiters: [{left: '$$', right: '$$', display: false}, {left: '$', right: '$', display: false}],
              throwOnError: false
            });
          }
          fitAll();
        });
        </script>
        </body></html>
        """
    }
}
