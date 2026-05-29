import AgentCore
import SwiftUI

struct ChatView: View {
    @Environment(AppState.self) private var app

    /// True while the viewport is parked at (or within `bottomEpsilon` of) the
    /// bottom of the chat. Streaming tokens only scroll the view when this is
    /// true — so once the user scrolls up, decoding tokens stop yanking them
    /// back. Flips true again automatically when they scroll back to bottom.
    @State private var followBottom = true

    /// True only while a *user* gesture is driving the scroll (drag / momentum),
    /// as opposed to streaming relayout or a programmatic scroll. We update
    /// `followBottom` from geometry only when this is set.
    @State private var userScrolling = false

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
    /// grows during streaming. Used as the trigger for tracking-scroll.
    private var streamingTick: Int {
        guard let msgs = app.loop?.messages else { return 0 }
        let last = msgs.last(where: { !$0.isHiddenInUI })
        return msgs.count * 1_000_000 + (last?.text.count ?? 0)
    }

    /// Identity of the most recent user-role message. Changes on send, which
    /// we treat as an explicit intent to follow the new turn.
    private var lastUserID: UUID? {
        app.loop?.messages.last(where: { $0.role == .user })?.id
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
            // Only the user's own gesture may detach / re-attach bottom-follow.
            // Streaming relayout and programmatic scrolls report `.idle` /
            // `.animating`; if those drove `followBottom`, the bottom anchor
            // sliding down as tokens stream in would read "not at bottom" and
            // detach us mid-generation.
            .onScrollPhaseChange { _, phase in
                userScrolling = phase == .tracking
                             || phase == .interacting
                             || phase == .decelerating
            }
            // Within `bottomEpsilon` counts as parked — re-attaches the moment
            // the user scrolls back down.
            .onScrollGeometryChange(for: Bool.self) { geo in
                let distance = geo.contentSize.height
                             - geo.contentOffset.y
                             - geo.containerSize.height
                return distance < Self.bottomEpsilon
            } action: { _, atBottom in
                if userScrolling { followBottom = atBottom }
            }
            // Streaming tokens: track only if the user wants to be tracked.
            // No animation — animated programmatic scrolls would feed the
            // geometry callback intermediate offsets and risk detaching.
            .onChange(of: streamingTick) {
                guard followBottom else { return }
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            // New user turn: explicit intent — re-attach and snap, even if
            // the user had previously scrolled up.
            .onChange(of: lastUserID) {
                followBottom = true
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
    /// Slack between viewport bottom and content bottom that still counts as
    /// "parked". Roughly one line of body text.
    private static let bottomEpsilon: CGFloat = 24
}
