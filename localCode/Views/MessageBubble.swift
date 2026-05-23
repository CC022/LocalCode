import SwiftUI

struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(12)
            .background(background, in: RoundedRectangle(cornerRadius: 12))
            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let call = message.toolCall {
            let pre = message.text
                .components(separatedBy: "```tool_use").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !pre.isEmpty {
                Text(pre).textSelection(.enabled)
            }
            DisclosureGroup {
                ScrollView {
                    Text(message.toolResult ?? "(no output)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
            } label: {
                Text("$ \(call.command)")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            Text(message.text.isEmpty ? "…" : message.text)
                .textSelection(.enabled)
        }
    }

    private var background: AnyShapeStyle {
        switch message.role {
        case .user:      AnyShapeStyle(Color.accentColor.opacity(0.18))
        case .assistant: AnyShapeStyle(Color.gray.opacity(0.12))
        case .system:    AnyShapeStyle(Color.clear)
        }
    }
}
