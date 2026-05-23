import Markdown
import SwiftUI

/// Renders Markdown source as native SwiftUI by walking Apple's swift-markdown AST.
///
/// Block-level: headings, paragraphs, fenced code, ordered/unordered lists, block quotes, dividers.
/// Inline-level (via `AttributedString`): bold, italic, inline code, links, soft/hard line breaks.
struct MarkdownView: View {
    let source: String

    var body: some View {
        let doc = Document(parsing: source)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(doc.blockChildren.enumerated()), id: \.offset) { _, block in
                MarkdownBlock(block: block)
            }
        }
    }
}

// MARK: - Block

private struct MarkdownBlock: View {
    let block: any BlockMarkup

    var body: some View {
        switch block {
        case let h as Heading:
            Text(inlineString(h))
                .font(headingFont(level: h.level))
                .fontWeight(.semibold)
        case let p as Paragraph:
            Text(inlineString(p))
                .fixedSize(horizontal: false, vertical: true)
        case let c as CodeBlock:
            CodeBlockView(code: c.code, language: c.language)
        case let l as UnorderedList:
            MarkdownList(items: Array(l.listItems), ordered: false, start: 1)
        case let l as OrderedList:
            MarkdownList(items: Array(l.listItems), ordered: true, start: Int(l.startIndex))
        case let q as BlockQuote:
            BlockQuoteView(quote: q)
        case is ThematicBreak:
            Divider()
        default:
            Text(inlineString(block))
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1:  .title2
        case 2:  .title3
        case 3:  .headline
        case 4:  .subheadline
        default: .body
        }
    }
}

private struct MarkdownList: View {
    let items: [ListItem]
    let ordered: Bool
    let start: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ordered ? "\(start + idx)." : "•")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(item.blockChildren.enumerated()), id: \.offset) { _, child in
                            MarkdownBlock(block: child)
                        }
                    }
                }
            }
        }
    }
}

private struct BlockQuoteView: View {
    let quote: BlockQuote

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(.tertiary)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(quote.blockChildren.enumerated()), id: \.offset) { _, child in
                    MarkdownBlock(block: child)
                }
            }
            .foregroundStyle(.secondary)
        }
    }
}

private struct CodeBlockView: View {
    let code: String
    let language: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.trimmingCharacters(in: .newlines))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Inline → AttributedString

/// Concatenates inline children of `markup` into a single AttributedString.
private func inlineString(_ markup: any Markup) -> AttributedString {
    markup.children.reduce(into: AttributedString()) { acc, child in
        acc.append(inlineRun(child))
    }
}

private func inlineRun(_ markup: any Markup) -> AttributedString {
    switch markup {
    case let t as Markdown.Text:
        return AttributedString(t.string)
    case let s as Strong:
        var a = inlineString(s)
        a.inlinePresentationIntent = .stronglyEmphasized
        return a
    case let e as Emphasis:
        var a = inlineString(e)
        a.inlinePresentationIntent = .emphasized
        return a
    case let c as InlineCode:
        var a = AttributedString(c.code)
        a.font = .system(.body, design: .monospaced)
        a.backgroundColor = .secondary.opacity(0.18)
        return a
    case let link as Markdown.Link:
        var a = inlineString(link)
        if let dest = link.destination, let url = URL(string: dest) {
            a.link = url
        }
        return a
    case is LineBreak:
        return AttributedString("\n")
    case is SoftBreak:
        return AttributedString(" ")
    default:
        // Unknown inline node — fall back to its plain text content.
        return AttributedString(markup.format())
    }
}
