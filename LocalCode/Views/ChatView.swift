import AgentCore
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            if app.developerMode, let loop = app.loop {
                RawTranscriptView(messages: loop.messages)
            } else {
                messagesScroll
            }
            Divider()
            InputBar()
            Divider()
            StatusBar()
        }
        // Empty toolbar + hidden background suppress the 1px separator macOS
        // draws between the window's title bar and the content area. Without
        // this, the line is visible across the top of the message window.
        .toolbar { }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .inspector(isPresented: $app.showTasks) {
            TasksInspector()
        }
    }

    /// Changes when a new message is appended OR when the last message's text
    /// grows during streaming. Used as a single trigger for auto-scroll.
    private var scrollSignal: Int {
        guard let msgs = app.loop?.messages else { return 0 }
        let last = msgs.last(where: { !$0.isHiddenInUI })
        return msgs.count * 1_000_000 + (last?.text.count ?? 0)
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
                    // Invisible anchor — `defaultScrollAnchor` alone misses
                    // updates inside a LazyVStack, so we scrollTo this id.
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding()
                // Push the stack to the bottom so the first message starts at
                // the bottom rather than the top.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: scrollSignal) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            // Coding-agent aesthetic: monospaced everywhere in the chat.
            // Cascades to MessageBubble / MarkdownView so headings, lists,
            // and inline runs all inherit unless they set an explicit design.
            .fontDesign(.monospaced)
        }
    }

    private static let bottomID = "chat-bottom"
}

private struct StatusBar: View {
    @Environment(AppState.self) private var app
    @State private var changingDir = false
    @State private var justCopied = false

    private var statusString: String {
        switch app.engine.state {
        case .idle:           return "Idle"
        case .missing:        return "Model not downloaded"
        case .downloading:    return "Downloading model \(Int(app.engine.downloadProgress * 100))%"
        case .loading:        return "Loading model…"
        case .ready:
            let used = formatTokens(app.engine.tokenCount)
            let total = formatTokens(app.engine.contextWindow)
            let phase = app.engine.inferencePhase == .idle
                ? ""
                : " · \(app.engine.inferencePhase.rawValue)"
            return "Ready · \(app.engine.modelName)\(phase) · \(used)/\(total)"
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
                if app.engine.inferencePhase != .idle {
                    Text("·").foregroundStyle(.tertiary)
                    Text(app.engine.inferencePhase.rawValue)
                        .font(.system(.callout, design: .monospaced))
                }
                Text("·").foregroundStyle(.tertiary)
                Text("\(formatTokens(app.engine.tokenCount))/\(formatTokens(app.engine.contextWindow))")
                    .font(.system(.callout, design: .monospaced))
                ProgressView(value: contextFraction)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        case .downloading:
            HStack(spacing: 6) {
                Text("Downloading model")
                ProgressView(value: app.engine.downloadProgress)
                    .frame(width: 120)
                Text("\(Int(app.engine.downloadProgress * 100))%")
                    .font(.system(.callout, design: .monospaced))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        case .missing:
            Button("Download Model") { app.downloadModel() }
                .buttonStyle(.link)
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
            developerToggle
            tasksToggle
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

    private var developerToggle: some View {
        Button {
            app.developerMode.toggle()
        } label: {
            Image(systemName: "curlybraces")
                .foregroundStyle(app.developerMode ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .help(app.developerMode
              ? "Hide raw model I/O (developer mode)"
              : "Show raw model I/O (developer mode)")
    }

    private var tasksToggle: some View {
        Button {
            app.showTasks.toggle()
        } label: {
            Image(systemName: app.showTasks ? "sidebar.right" : "sidebar.squares.right")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(app.showTasks ? "Hide tasks" : "Show tasks")
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
        case .loading, .downloading:
            ProgressView().controlSize(.small)
        case .missing:
            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .idle:
            Image(systemName: "circle").foregroundStyle(.secondary).font(.caption2)
        }
    }

    private var textColor: Color {
        switch app.engine.state {
        case .failed: .red
        case .missing: .secondary
        case .idle:   .secondary
        default:      .primary
        }
    }
}
