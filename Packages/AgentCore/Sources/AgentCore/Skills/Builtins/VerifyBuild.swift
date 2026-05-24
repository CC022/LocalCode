import Foundation

extension Skill {
    /// Demo skill: teaches the agent how to build and verify this project.
    /// Loaded when the user asks to "build", "verify", "make sure it compiles",
    /// etc. — the model picks it up from the catalog and pulls in the exact
    /// commands. Refine the body over time as build conventions evolve.
    static let verifyBuild = Skill(
        name: "verify-build",
        description: "How to build the LocalCode app and CLI and read the output for errors.",
        body: """
        # verify-build

        Use these exact commands to build the project. They take a while
        (Swift macro plugin warmup + MLX linkage), so prefer running them
        once at the end of a change rather than after every edit.

        ## App target (LocalCode)

        ```
        xcodebuild -project LocalCode.xcodeproj -scheme LocalCode \\
          -configuration Debug -destination 'platform=macOS' \\
          -skipMacroValidation build 2>&1 \\
          | grep -E "error:|FAILED|BUILD SUCCEEDED" | tail -10
        ```

        ## CLI target (LocalCodeCLI)

        Same flags, swap the scheme:

        ```
        xcodebuild -project LocalCode.xcodeproj -scheme LocalCodeCLI \\
          -configuration Debug -destination 'platform=macOS' \\
          -skipMacroValidation build 2>&1 \\
          | grep -E "error:|FAILED|BUILD SUCCEEDED" | tail -10
        ```

        ## Reading the output

        - `** BUILD SUCCEEDED **` on the last line means clean.
        - Any `error:` line is a real failure; report the message verbatim.
        - A single `warning: Metadata extraction skipped. No AppIntents.framework` is benign and pre-existing; ignore it.
        - The `-skipMacroValidation` flag is required because mlx-swift-lm uses a Swift macro that Xcode otherwise prompts the user to "Trust & Enable".

        ## Don't

        - Don't run plain `xcodebuild` without a scheme — it builds every target and floods the log.
        - Don't `cd` into subdirs first; xcodebuild expects to see `LocalCode.xcodeproj` in the cwd.
        - Don't run the build in the background unless you also tail the log with a `grep` filter — full output is several MB.
        """
    )
}
