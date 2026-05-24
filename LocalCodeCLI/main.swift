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

@MainActor
func printNewMessages(loop: AgentLoop, from: Int, to: Int) {
    for msg in loop.messages[from..<to] {
        switch msg.role {
        case .user:
            print("[USER] \(msg.text)")
        case .assistant:
            if !msg.text.isEmpty {
                print("[ASSISTANT] \(msg.text)")
            }
            if let call = msg.toolCall {
                print("[TOOL CALL] \(call.summary)")
                if let r = msg.toolResult {
                    let trimmed = r.count > 1000 ? String(r.prefix(1000)) + "\n…(truncated)" : r
                    print("[TOOL RESULT]\n\(trimmed)")
                }
            }
        case .tool, .system: break
        }
    }
    print("")
}

@MainActor
func run() async {
    let args = CommandLine.arguments
    let cwd = URL(
        fileURLWithPath: args.count > 1
            ? args[1]
            : FileManager.default.currentDirectoryPath
    )

    stderr("Loading model from disk…\n")
    let engine = InferenceEngine()
    await engine.load()
    guard case .ready = engine.state else {
        stderr("Failed to load: \(engine.state)\n")
        exit(1)
    }
    stderr("Ready · \(engine.modelName) · context \(engine.contextWindow)\n")
    stderr("cwd: \(cwd.path)\n\n")

    let permission = Permission(ask: askApproval)
    let hooks = HookRegistry()
    hooks.register(preTool: BuiltinHooks.permission(permission))
    hooks.register(postTool: BuiltinHooks.truncateLargeOutput())
    hooks.register(stop: { stderr("[done]\n") })
    let loop = AgentLoop(cwd: cwd, engine: engine, hooks: hooks)

    while true {
        stderr("> ")
        guard let line = readLine(strippingNewline: true) else { break }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        if trimmed == "exit" || trimmed == "quit" || trimmed == "q" { break }

        let before = loop.messages.count
        // Live-print new messages as the agent runs. Without this the CLI
        // looks frozen during multi-turn tool sessions.
        let isDone = MutableBox(false)
        let sendTask = Task {
            await loop.send(trimmed)
            isDone.value = true
        }
        var printed = before
        while !isDone.value {
            try? await Task.sleep(for: .milliseconds(100))
            let count = loop.messages.count
            if count > printed {
                printNewMessages(loop: loop, from: printed, to: count)
                printed = count
            }
        }
        await sendTask.value
        let final = loop.messages.count
        if final > printed {
            printNewMessages(loop: loop, from: printed, to: final)
        }
    }
}

await run()
