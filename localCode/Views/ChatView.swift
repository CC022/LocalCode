import SwiftUI

struct ChatView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            StatusBar()
            Divider()
            messagesScroll
            Divider()
            InputBar()
        }
    }

    private var messagesScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let loop = app.loop {
                        ForEach(loop.messages.filter { !$0.isHiddenInUI }) { msg in
                            MessageBubble(message: msg).id(msg.id)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: app.loop?.messages.count ?? 0) {
                if let last = app.loop?.messages.last(where: { !$0.isHiddenInUI }) {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}

private struct StatusBar: View {
    @Environment(AppState.self) private var app

    private var statusString: String {
        switch app.engine.state {
        case .idle:           "Idle"
        case .loading:        "Loading model…"
        case .ready:          "Ready"
        case .failed(let m):  m
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
            Text(statusString)
                .font(.callout)
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(statusString)
                .contextMenu {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(statusString, forType: .string)
                    }
                }
            Spacer()
            if let cwd = app.cwd {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(cwd.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder private var statusIcon: some View {
        switch app.engine.state {
        case .ready:
            Image(systemName: "circle.fill").foregroundStyle(.green).font(.caption2)
        case .loading:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .idle:
            Image(systemName: "circle").foregroundStyle(.secondary).font(.caption2)
        }
    }

    private var textColor: Color {
        switch app.engine.state {
        case .failed: .red
        case .idle:   .secondary
        default:      .primary
        }
    }
}
