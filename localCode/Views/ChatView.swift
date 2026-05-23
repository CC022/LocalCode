import SwiftUI
import UniformTypeIdentifiers

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
    @State private var changingDir = false
    @State private var justCopied = false

    private var statusString: String {
        switch app.engine.state {
        case .idle:           return "Idle"
        case .loading:        return "Loading model…"
        case .ready:
            let used = formatTokens(app.engine.tokenCount)
            let total = formatTokens(app.engine.contextWindow)
            return "Ready · \(app.engine.modelName) · \(used)/\(total)"
        case .failed(let m):  return m
        }
    }

    private func formatTokens(_ n: Int) -> String {
        switch n {
        case 0..<1_000:           "\(n)"
        case 1_000..<10_000:      String(format: "%.1fk", Double(n) / 1_000)
        case 10_000..<1_000_000:  "\(n / 1_000)k"
        default:                  String(format: "%.1fM", Double(n) / 1_000_000)
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
                        copy(statusString)
                    }
                }
            Spacer()
            copyButton
            if let cwd = app.cwd {
                Button {
                    changingDir = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text(cwd.lastPathComponent).font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Click to change working directory (resets chat)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .fileImporter(
            isPresented: $changingDir,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result { app.pickDirectory(url) }
        }
    }

    private var copyButton: some View {
        Button {
            copy(app.exportTranscript())
            justCopied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                justCopied = false
            }
        } label: {
            Image(systemName: justCopied ? "checkmark" : "doc.on.clipboard")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Copy full transcript to clipboard")
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
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
