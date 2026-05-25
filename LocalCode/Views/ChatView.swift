import AgentCore
import SwiftUI

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
        }
        // Empty toolbar + hidden background suppress the 1px separator macOS
        // draws between the window's title bar and the content area. The
        // inspector's built-in toolbar toggle button is injected automatically
        // by `.inspector` so we don't need to add it ourselves.
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
