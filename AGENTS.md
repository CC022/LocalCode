# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## What this project is

`LocalCode` is a SwiftUI macOS app that runs a coding agent **entirely on-device** using Apple's MLX framework. It mirrors Codex's UX (pick a working directory → chat with an agent that can run shell + file tools in that directory) but with a local LLM and no network calls during inference.

The Swift app is being built as a **step-by-step port of the Python tutorial in `learn-Codex-main/`** (chapters `s01_agent_loop` … `s20_comprehensive`). Each step lands one tutorial chapter. Current state: through **s05 (todo_write)** with six tools (bash, read_file, write_file, edit_file, glob, todo_write) wired through a registry, plus the s03 permission layer and s04 hook system.

The active model is **`mlx-community/gemma-4-26b-a4b-it-4bit`** (Gemma 4 26B MoE, ~4B active, 4-bit quant, ~15.6 GB on disk, 262144-token context).

## Build & run

```bash
# Build (the -skipMacroValidation flag is required because mlx-swift-lm uses
# a Swift macro plugin that Xcode otherwise asks to "Trust & Enable" on first run)
xcodebuild -project LocalCode.xcodeproj -scheme LocalCode \
  -configuration Debug -destination 'platform=macOS' \
  -skipMacroValidation build

# Filter to just errors / final status (build output is verbose):
xcodebuild ... build 2>&1 | grep -E "error:|FAILED|BUILD SUCCEEDED" | tail -10

# Download the model (one-time, ~15.6 GB into <repo>/models/, gitignored)
pip install -U huggingface_hub
python3 scripts/download_model.py

# Run the app: open the Xcode project and ⌘R, or launch the built binary at
# ~/Library/Developer/Xcode/DerivedData/LocalCode-*/Build/Products/Debug/LocalCode.app
```

There are **no tests** yet — verification is manual through the chat UI.

## Architecture

The code splits into three layers:

- **`Packages/AgentCore/`** — local SPM package holding the model-driven loop, tools, hooks, permission, and inference engine. Pure logic, no SwiftUI. Linked by both the app and the CLI.
- **`LocalCode/ViewModels/AppState.swift`** — single `@Observable @MainActor` glue object exposed via SwiftUI `@Environment`. Owns the `AgentLoop`, holds inspector toggle, and tracks the current `send` Task so the stop button can cancel it.
- **`LocalCode/Views/`** — SwiftUI views that read `AppState`. The chat lives in `ChatView`; the right-side todo panel is `TasksInspector`.
- **`LocalCodeCLI/`** — small command-line target that drives `AgentCore` directly for debugging without SwiftUI.

### The agent loop (the thing that matters)

`AgentLoop.send(_:)` is a `while true` that mirrors `learn-Codex-main/s05_todo_write/code.py`:

```
append user message
loop:
    snapshot messages
    append empty assistant message
    for each StreamEvent from engine.stream(messages: snapshot, tools: registry.toolSpecs):
        .text(delta)     → append to assistant message text
        .toolCall(mlx)   → remember pending call, break the stream
    if no pending call → return     ← model produced a final answer, we're done
    dispatch tool through registry, attach call/result to the assistant msg
    append Message.tool(output) to history
    (continue loop with the now-longer history)
```

**The model is the driver, the harness executes.** There is no agent-side decision logic, no routing, no if-this-then-that. The framework decides when a tool call happens (it emits `Generation.toolCall(_)`); we just dispatch and continue. This is the same invariant the tutorial layers everything else on top of.

### Why MLXVLM, not MLXLLM

Gemma 4 is multimodal — its MoE branches (`experts`, `router`, the extra layernorms) only exist in `MLXVLM/Models/Gemma4.swift`. Using `MLXLLM.LLMModelFactory` produces an `unhandledKeys(...experts, router...)` error at load. Use `MLXVLM.VLMModelFactory.shared.loadContainer(from:using:)`. Text-only generation works because we pass no `images:` to `UserInput`.

### Native tool calling, not string fences

Earlier work attempted a Markdown ` ```tool_use ` fence convention parsed from model output. **Do not bring that back.** Gemma 4 has tool calling baked into its chat template (special tokens `<|tool_call>...<tool_call|>`), and `mlx-swift-lm` ships a `GemmaFunctionParser` that's auto-selected because `config.json` has `model_type: "gemma4"`. The flow is:

1. Build OpenAI-style `ToolSpec` dicts via `ToolSpecBuilder.make(...)` — one per `Tool`.
2. Pass them to `UserInput(chat:, tools:)`. The chat template formats them into Gemma's expected on-the-wire shape.
3. Receive parsed `MLXLMCommon.ToolCall` in the `Generation.toolCall` stream event.
4. Wrap as our local `AgentToolCall` (just for UI summary labels).

`InferenceEngine.stream(...)` yields `StreamEvent.text(_)` and `StreamEvent.toolCall(_)`. It **breaks the iterator on first tool call** — otherwise the model can hallucinate its own tool result after the call markers.

### Message ↔ Chat.Message mapping

Our `Message.Role` has four cases: `.system`, `.user`, `.assistant`, `.tool`. Each maps 1:1 to `MLXLMCommon.Chat.Message.{system,user,assistant,tool}` in `InferenceEngine.stream`. If you add a role, update both the enum and the mapping. `.system` and `.tool` messages are hidden in the UI (rendered inside the preceding assistant bubble's disclosure for tool results).

### Adding a new tool

1. New file under `Packages/AgentCore/Sources/AgentCore/Tools/`, struct conforming to `Tool` protocol (in `Tool.swift`).
2. Implement `name`, `toolSpec` (use `ToolSpecBuilder.make` for the OpenAI dict), and `nonisolated func run(_ arguments: [String: JSONValue]) async -> String`. The `nonisolated` is required because the project has `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and tools execute off the main thread.
3. Add an instance to the `ToolRegistry([...])` literal in `AgentLoop.init`.
4. (Optional) Add a friendly summary case in `AgentToolCall.summary` so the disclosure label reads nicely.
5. Any tool that takes a file path **must** go through `SafePath.resolve(_:cwd:)` — this rejects paths escaping the chosen working directory.
6. If the tool's input schema has nested arrays or objects (e.g. an array-of-object like `todo_write`'s `todos`), build the `ToolSpec` dict inline rather than via `ToolSpecBuilder.make` — the helper only models flat scalar properties. See `TodoWriteTool.swift` as the reference.

### Inference engine state

`InferenceEngine` is `@Observable @MainActor` and publishes:
- `state: LoadState` — `.idle / .loading / .ready / .failed(String)`
- `tokenCount: Int` — updated to `lmInput.text.tokens.size` before each generation (the prompt size the framework is about to send)
- `contextWindow: Int` — read from `config.json`'s `text_config.max_position_embeddings` on load
- `modelName: String` — derived from the model directory's last path component

The status bar in `ChatView` reads all of these.

### Model path resolution

The model directory is resolved at **compile time** via `#filePath` walking up from `Packages/AgentCore/Sources/AgentCore/InferenceEngine.swift` to the repo root and appending `models/gemma-4-26b-a4b-it-4bit`. This works during Xcode development but would need replacement (env var, bundle resource, user picker) for a shipped binary.

### Background warm-up

`AppState.init()` kicks off `Task { await engine.load() }` so the model starts loading the instant the app launches — by the time the user picks a folder, it's usually already `.ready`. `engine.load()` is idempotent on `.ready` / `.loading`.

### Changing working directory

`AppState.pickDirectory(_:)` creates a **fresh** `AgentLoop`. The chat resets because the new loop builds a new system prompt with the new cwd embedded. The cwd badge in the status bar is a button that re-opens the picker.

## Swift Package Management

Dependencies are wired by directly editing **`LocalCode.xcodeproj/project.pbxproj`** (there is no `Package.swift`). Four SPM packages are linked:

| Package | URL | Products linked |
|---|---|---|
| `mlx-swift-lm` 3.31.3+ | `https://github.com/ml-explore/mlx-swift-lm` | `MLXLLM`, `MLXLMCommon`, `MLXHuggingFace`, `MLXVLM` |
| `swift-huggingface` 0.9.0+ | `https://github.com/huggingface/swift-huggingface` | `Hub`, `HuggingFace` |
| `swift-transformers` 1.3.0+ | `https://github.com/huggingface/swift-transformers` | `Tokenizers` |
| `mlx-swift` 0.31.3+ | `https://github.com/ml-explore/mlx-swift` | `MLX` |

When adding a new package, copy the pattern of the existing entries — each needs:
1. A `PBXBuildFile` (one per product)
2. An entry in the target's `PBXFrameworksBuildPhase.files`
3. An entry in the target's `packageProductDependencies`
4. An `XCSwiftPackageProductDependency` (one per product)
5. An `XCRemoteSwiftPackageReference` (one per package)
6. An entry in `PBXProject.packageReferences`

Existing entries use `A100…`, `A200…`, `A300…` UUID prefixes — pick a fresh `…F000N` suffix to keep them distinguishable from Xcode-generated IDs.

## Platform constraints

- macOS 26.5 deployment target. Apple Silicon only (MLX is Metal).
- Hardened runtime on, app sandbox **off**. Entitlements at `LocalCode/LocalCode.entitlements` allow JIT, unsigned executable memory, disable library validation, and dyld env vars — all required for MLX's Metal JIT and for spawning child processes via `BashTool`.
- Project-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Code outside SwiftUI views (especially `Tool.run`, `InferenceEngine.stream`'s internal Task) must be explicitly `nonisolated` to escape main-thread isolation.

## Tutorial reference

The Python source of truth lives in `learn-Codex-main/` (e.g. `s02_tool_use/code.py` is what `AgentLoop.swift` ports). When porting the next chapter, read both the chapter's `code.py` and its `README*.md` — the README explains the *why* behind the mechanism the chapter introduces.
