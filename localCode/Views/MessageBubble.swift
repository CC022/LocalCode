import AgentCore
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
        let pre = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pre.isEmpty {
            Text(pre).textSelection(.enabled)
        }
        if let call = message.toolCall {
            DisclosureGroup {
                ScrollView {
                    Text(message.toolResult ?? "(no output)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
            } label: {
                Text(call.summary)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        if pre.isEmpty && message.toolCall == nil {
            Text("…").foregroundStyle(.secondary)
        }
    }

    private var background: AnyShapeStyle {
        switch message.role {
        case .user:                AnyShapeStyle(Color.accentColor.opacity(0.18))
        case .assistant:           AnyShapeStyle(Color.gray.opacity(0.12))
        case .system, .tool:       AnyShapeStyle(Color.clear)
        }
    }
}
