import AgentCore
import SwiftUI

struct MessageBubble: View {
    @Environment(AppState.self) private var app
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

    /// A pending approval is one whose call matches this bubble's toolCall
    /// and hasn't been answered yet (no toolResult on the bubble).
    private var pendingApproval: ApprovalRequest? {
        guard let req = app.pendingApproval,
              let call = message.toolCall,
              req.call == call,
              message.toolResult == nil
        else { return nil }
        return req
    }

    @ViewBuilder
    private var content: some View {
        let pre = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pre.isEmpty {
            MarkdownView(source: pre).textSelection(.enabled)
        }
        if let call = message.toolCall {
            if let req = pendingApproval {
                ApprovalView(request: req) { app.resolveApproval($0) }
            } else {
                toolDisclosure(call)
            }
        }
        if pre.isEmpty && message.toolCall == nil {
            Text("…").foregroundStyle(.secondary)
        }
    }

    private func toolDisclosure(_ call: AgentToolCall) -> some View {
        DisclosureGroup {
            ScrollView {
                Text(message.toolResult ?? "(running…)")
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

    private var background: AnyShapeStyle {
        switch message.role {
        case .user:                AnyShapeStyle(Color.accentColor.opacity(0.18))
        case .assistant:           AnyShapeStyle(Color.gray.opacity(0.12))
        case .system, .tool:       AnyShapeStyle(Color.clear)
        }
    }
}
