import AgentCore
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            messagesScroll
            Divider()
            InputBar()
            Divider()
            StatusBar()
        }
    }

    private var messagesScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let loop = app.loop {
                    ForEach(loop.messages.filter { !$0.isHiddenInUI }) { msg in
                        MessageBubble(message: msg).id(msg.id)
                    }
                }
            }
            .padding()
            // Push the stack to the bottom so the first message starts there
            // rather than the top, before any anchor work.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        // Pin the scroll position to the bottom: initial view shows the latest
        // message and the view auto-follows as content grows (e.g., during
        // streaming or when a new bubble is appended).
        .defaultScrollAnchor(.bottom)
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

    private var contextFraction: Double {
        let cw = app.engine.contextWindow
        guard cw > 0 else { return 0 }
        return min(1, max(0, Double(app.engine.tokenCount) / Double(cw)))
    }

    @ViewBuilder
    private var statusContent: some View {
        switch app.engine.state {
        case .ready:
            HStack(spacing: 6) {
                Text("Ready")
                Text("·").foregroundStyle(.tertiary)
                Text(app.engine.modelName)
                Text("·").foregroundStyle(.tertiary)
                ProgressView(value: contextFraction)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                Text("\(formatTokens(app.engine.tokenCount))/\(formatTokens(app.engine.contextWindow))")
                    .font(.system(.callout, design: .monospaced))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        default:
            Text(statusString)
                .font(.callout)
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
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
            statusContent
                .help(statusString)
                .contextMenu {
                    Button("Copy") { copy(statusString) }
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
            EmptyView()
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
