import AgentCore
import Foundation

// Disable stdout buffering so progress streams to logs/pipes line-by-line.
// Without this, `print` writes are held in an 8KB buffer when stdout is a
// pipe, which makes the CLI look frozen during debug runs.
setbuf(stdout, nil)

/// Tiny reference box for sharing a Bool across the polling printer and the
/// `Task { … }` that runs `loop.send`. Both run on the main actor, so plain
/// reference semantics are enough.
@MainActor
final class MutableBox<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

func stderr(_ s: String) {
    FileHandle.standardError.write(Data(s.utf8))
}

/// Synchronous stdin approval prompt. y = allow once, a = allow for session,
/// anything else = deny. Defaulting to deny is the safer behavior for the CLI.
func askApproval(_ request: ApprovalRequest) async -> ApprovalChoice {
    stderr("\n⚠  \(request.reason)\n   \(request.call.summary)\n   Allow? [y / a (session) / N]: ")
    let line = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    return switch line {
    case "y", "yes": .once
    case "a", "always": .session
    default: .deny
    }
}

/// Coarse "which fields exist" sketch of an assistant message. We reprint
/// when this changes — i.e. when a brand-new field appears — not on every
/// chunk-level text growth, which would spam the log.
struct FieldSketch: Equatable {
    var hasText: Bool
    var hasThinking: Bool
    var hasToolCall: Bool
    var hasToolResult: Bool
}

@MainActor
func sketch(_ m: Message) -> FieldSketch {
    FieldSketch(
        hasText: !m.text.isEmpty,
        hasThinking: m.thinking?.isEmpty == false,
        hasToolCall: m.toolCall != nil,
        hasToolResult: m.toolResult?.isEmpty == false
    )
}

@MainActor
func render(_ m: Message) -> String {
    switch m.role {
    case .user:
        return "[USER] \(m.text)"
    case .assistant:
        var parts: [String] = []
        if let t = m.thinking, !t.isEmpty { parts.append("[THINKING] \(t)") }
        if !m.text.isEmpty { parts.append("[ASSISTANT] \(m.text)") }
        if let call = m.toolCall {
            parts.append("[TOOL CALL] \(call.summary)")
            if let r = m.toolResult {
                parts.append("[TOOL RESULT]\n\(r.clipped(to: 1000, withCount: false))")
            }
        }
        return parts.isEmpty ? "[ASSISTANT] (empty)" : parts.joined(separator: "\n")
    case .tool, .system:
        return ""
    }
}

/// Print any newly appended messages, plus reprint any assistant message
/// when its `FieldSketch` changes — i.e. when a *new field* appears
/// (thinking → text → toolCall → toolResult). Text growth within an
/// already-printed field is not re-emitted; the final flush after the send
/// task settles will catch the complete content.
@MainActor
func flushPrints(
    loop: AgentLoop,
    printedThrough: inout Int,
    sketches: inout [Int: FieldSketch],
    final: Bool = false
) {
    let total = loop.messages.count

    while printedThrough < total {
        let idx = printedThrough
        let msg = loop.messages[idx]
        // Skip rendering a completely empty assistant placeholder — wait for
        // the first real field to appear.
        if msg.role == .assistant && sketch(msg) == .init(
            hasText: false, hasThinking: false, hasToolCall: false, hasToolResult: false
        ) {
            break
        }
        let r = render(msg)
        if !r.isEmpty { print(r); print("") }
        sketches[idx] = sketch(msg)
        printedThrough += 1
    }

    for idx in 0..<printedThrough {
        let msg = loop.messages[idx]
        guard msg.role == .assistant else { continue }
        let current = sketch(msg)
        let last = sketches[idx]
        if last != current || (final && last != nil) {
            sketches[idx] = current
            let r = render(msg)
            if !r.isEmpty {
                print("--- #\(idx) update ---")
                print(r)
                print("")
            }
        }
    }
}

@MainActor
func run() async {
    let args = CommandLine.arguments
    let cwd = URL(
        fileURLWithPath: args.count > 1
            ? args[1]
            : FileManager.default.currentDirectoryPath
    )

    let env = ProcessInfo.processInfo.environment
    let engine = InferenceEngine()

    // Optional OpenAI-compatible API backend, configured purely from env so no
    // endpoint/key ever touches the repo. Set all three to use it:
    //   LOCALCODE_API_BASE=https://<host>/v1
    //   LOCALCODE_API_MODEL=<model-name>
    //   LOCALCODE_API_KEY=<key>
    // When set, we skip loading the ~15 GB local model entirely.
    if let base = env["LOCALCODE_API_BASE"], !base.isEmpty,
       let model = env["LOCALCODE_API_MODEL"], !model.isEmpty,
       let key = env["LOCALCODE_API_KEY"], !key.isEmpty {
        engine.apiConfig = APIConfig(baseURL: base, model: model, apiKey: key)
        engine.backend = .api
        guard case .ready = engine.state else {
            stderr("API config incomplete: \(engine.state)\n")
            exit(1)
        }
        stderr("Ready · API · \(model) @ \(base)\n")
    } else {
        stderr("Loading model from disk…\n")
        await engine.load()
        guard case .ready = engine.state else {
            stderr("Failed to load: \(engine.state)\n")
            exit(1)
        }
        stderr("Ready · \(engine.modelName) · context \(engine.contextWindow)\n")
    }
    stderr("cwd: \(cwd.path)\n\n")

    // Debug path: bypass the agent loop and invoke translate_md directly so
    // we can iterate on the tool without a full chat round-trip. Set:
    //   LOCALCODE_TRANSLATE_DEBUG_PATH=...   (markdown under cwd)
    //   LOCALCODE_TRANSLATE_DEBUG_LANG=...   (e.g. "Chinese (Simplified)")
    // optional:
    //   LOCALCODE_TRANSLATE_DEBUG_CHARS=800  (tiny chunks for fast iteration)
    //   LOCALCODE_TRANSLATE_DEBUG_OUTPUT=... (output path)
    if let dbgPath = env["LOCALCODE_TRANSLATE_DEBUG_PATH"],
       let dbgLang = env["LOCALCODE_TRANSLATE_DEBUG_LANG"] {
        let dbgChars = env["LOCALCODE_TRANSLATE_DEBUG_CHARS"].flatMap(Int.init)
        let dbgOut = env["LOCALCODE_TRANSLATE_DEBUG_OUTPUT"]
        stderr("[translate-debug] path=\(dbgPath) lang=\(dbgLang) chunkChars=\(dbgChars.map(String.init) ?? "default")\n")
        let started = Date()
        let result = await DebugEntries.translateMD(
            cwd: cwd, engine: engine,
            path: dbgPath, targetLanguage: dbgLang,
            chunkChars: dbgChars, outputPath: dbgOut
        )
        stderr("[translate-debug] elapsed \(String(format: "%.1fs", Date().timeIntervalSince(started)))\n")
        print(result)
        exit(0)
    }

    let permission = Permission(ask: askApproval)
    let hooks = HookRegistry()
    hooks.register(preTool: BuiltinHooks.permission(permission))
    hooks.register(postTool: BuiltinHooks.truncateLargeOutput())
    hooks.register(stop: { stderr("[done]\n") })
    let loop = AgentLoop(cwd: cwd, engine: engine, hooks: hooks)
    var printedThrough = 0
    var sketches: [Int: FieldSketch] = [:]

    while true {
        stderr("> ")
        guard let line = readLine(strippingNewline: true) else { break }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        if trimmed == "exit" || trimmed == "quit" || trimmed == "q" { break }
        if trimmed == "/clear" {
            loop.clear()
            printedThrough = loop.messages.count
            sketches.removeAll()
            stderr("[cleared]\n\n")
            continue
        }
        if trimmed == "/compact" {
            await loop.compact()
            if let last = loop.messages.last { print("[COMPACTED]\n\(last.text)\n") }
            continue
        }

        // Live-print new messages and reprint any whose state advances
        // (toolCall populated, toolResult populated, thinking emerged, etc.).
        let isDone = MutableBox(false)
        let sendTask = Task {
            await loop.send(trimmed)
            isDone.value = true
        }
        while !isDone.value {
            try? await Task.sleep(for: .milliseconds(150))
            flushPrints(loop: loop, printedThrough: &printedThrough, sketches: &sketches)
        }
        await sendTask.value
        flushPrints(loop: loop, printedThrough: &printedThrough, sketches: &sketches, final: true)
    }
}

await run()
