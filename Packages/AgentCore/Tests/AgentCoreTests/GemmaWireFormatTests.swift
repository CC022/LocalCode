import XCTest
import MLXLMCommon
@testable import AgentCore

/// Grammar fixtures for `GemmaWireFormat.parse`. These pin the on-the-wire
/// behavior we rely on for both the well-formed case and the MLX
/// detokenizer bug where `<|tool_call>` is silently swallowed and only the
/// closing `<tool_call|>` arrives in the chunk stream.
final class GemmaWireFormatTests: XCTestCase {

    // MARK: - Thought channel

    func testClosedThoughtOnly() {
        let r = GemmaWireFormat.parse(
            "<|channel>thought\nReasoning about the task.<channel|>"
        )
        XCTAssertEqual(r.thinking, "Reasoning about the task.")
        XCTAssertEqual(r.text, "")
        XCTAssertNil(r.toolCall)
    }

    func testPartialThoughtSurfacesDuringStreaming() {
        let r = GemmaWireFormat.parse(
            "<|channel>thought\nStill thinking…",
            includeOpenThinking: true
        )
        XCTAssertEqual(r.thinking, "Still thinking…")
        XCTAssertEqual(r.text, "")
    }

    func testPartialThoughtHiddenWhenIncludeOpenIsFalse() {
        let r = GemmaWireFormat.parse(
            "<|channel>thought\nStill thinking…",
            includeOpenThinking: false
        )
        XCTAssertNil(r.thinking)
        XCTAssertEqual(r.text, "")
    }

    // MARK: - Tool call: opener present (the well-formed case)

    func testOpenerPresentToolCall() {
        let r = GemmaWireFormat.parse(
            #"<|tool_call>call:bash{command:<|"|>ls -F<|"|>}<tool_call|>"#
        )
        XCTAssertEqual(r.toolCall?.name, "bash")
        XCTAssertEqual(r.toolCall?.arguments["command"], .string("ls -F"))
        XCTAssertEqual(r.text, "")
    }

    // MARK: - Tool call: opener absent (the MLX detokenizer bug)

    /// The exact failure mode we hit in practice — `<|tool_call>` never
    /// reaches the chunk stream, only the closer does, with the body sitting
    /// in plain text right before it.
    func testOpenerAbsentToolCallRecovered() {
        let r = GemmaWireFormat.parse(
            "<|channel>thought\nList files.<channel|>todo_write{todos:[]}<tool_call|>"
        )
        XCTAssertEqual(r.thinking, "List files.")
        XCTAssertEqual(r.toolCall?.name, "todo_write")
        XCTAssertEqual(r.toolCall?.arguments["todos"], .array([]))
        XCTAssertEqual(r.text, "")
    }

    /// Recovery must keep text that precedes the recovered call.
    func testOpenerAbsentRecoveryPreservesLeadingText() {
        let r = GemmaWireFormat.parse(
            "I'll list files now. bash{command:<|\"|>ls<|\"|>}<tool_call|>"
        )
        XCTAssertEqual(r.text, "I'll list files now.")
        XCTAssertEqual(r.toolCall?.name, "bash")
        XCTAssertEqual(r.toolCall?.arguments["command"], .string("ls"))
    }

    /// A `}` that isn't part of a call shouldn't accidentally get lifted.
    func testStrayClosingBraceNotRecovered() {
        // `<tool_call|>` with nothing call-shaped before it: just drop the
        // marker, keep the text.
        let r = GemmaWireFormat.parse(
            "Here is the syntax: `if x { ... }`<tool_call|>"
        )
        XCTAssertNil(r.toolCall)
        XCTAssertEqual(r.text, "Here is the syntax: `if x { ... }`")
    }

    // MARK: - Mixed turn

    func testMixedThoughtCallAndTrailingText() {
        let r = GemmaWireFormat.parse("""
            <|channel>thought
            Plan the work.<channel|>\
            <|tool_call>call:read_file{path:<|"|>README.md<|"|>}<tool_call|>\
            Trailing assistant text.
            """)
        XCTAssertEqual(r.thinking, "Plan the work.")
        XCTAssertEqual(r.toolCall?.name, "read_file")
        XCTAssertEqual(r.toolCall?.arguments["path"], .string("README.md"))
        XCTAssertEqual(r.text, "Trailing assistant text.")
    }

    // MARK: - Arg value types

    func testEscapedStringArgWithEmbeddedBrace() {
        let r = GemmaWireFormat.parse(
            #"<|tool_call>call:bash{command:<|"|>echo "}"<|"|>}<tool_call|>"#
        )
        // Argument value should be the literal `echo "}"` — the `}` inside
        // the escape markers must NOT terminate the call body.
        XCTAssertEqual(r.toolCall?.arguments["command"], .string(#"echo "}""#))
    }

    func testArrayArg() {
        let r = GemmaWireFormat.parse(
            #"<|tool_call>call:todo_write{todos:[1,2,3]}<tool_call|>"#
        )
        XCTAssertEqual(
            r.toolCall?.arguments["todos"],
            .array([.int(1), .int(2), .int(3)])
        )
    }

    func testNestedObjectArg() {
        let r = GemmaWireFormat.parse(
            #"<|tool_call>call:set{config:{depth:3,wide:true}}<tool_call|>"#
        )
        XCTAssertEqual(
            r.toolCall?.arguments["config"],
            .object(["depth": .int(3), "wide": .bool(true)])
        )
    }

    func testScalarLiteralArgs() {
        let r = GemmaWireFormat.parse(
            #"<|tool_call>call:t{a:true,b:false,c:null,d:7,e:1.5}<tool_call|>"#
        )
        let args = r.toolCall?.arguments
        XCTAssertEqual(args?["a"], .bool(true))
        XCTAssertEqual(args?["b"], .bool(false))
        XCTAssertEqual(args?["c"], .null)
        XCTAssertEqual(args?["d"], .int(7))
        XCTAssertEqual(args?["e"], .double(1.5))
    }

    // MARK: - Multiple tool calls

    func testFirstToolCallWins() {
        // Agent loop breaks on first tool call; parser must mirror that.
        let r = GemmaWireFormat.parse("""
            <|tool_call>call:a{x:1}<tool_call|><|tool_call>call:b{y:2}<tool_call|>
            """)
        XCTAssertEqual(r.toolCall?.name, "a")
        XCTAssertEqual(r.toolCall?.arguments["x"], .int(1))
    }

    // MARK: - Stray scaffolding gets dropped

    /// The model normally stops on `<turn|>` as a stop token, but if it
    /// reaches the chunk stream defensively we should still drop it.
    /// `<|think|>` is the system-turn flag that should never appear in
    /// assistant output but we drop it just in case.
    func testStrayTokensStrippedFromText() {
        let r = GemmaWireFormat.parse("Hello<turn|>")
        XCTAssertEqual(r.text, "Hello")
        XCTAssertNil(r.toolCall)

        let r2 = GemmaWireFormat.parse("<|think|>Pondering")
        XCTAssertEqual(r2.text, "Pondering")
        XCTAssertNil(r2.thinking)
    }

    // MARK: - Serialize round-trip

    func testSerializeThenParseRoundTrip() {
        let original = AgentToolCall(
            name: "edit_file",
            arguments: [
                "path": .string("Sources/main.swift"),
                "old_string": .string("foo"),
                "new_string": .string("bar"),
            ]
        )
        let wire = GemmaWireFormat.serialize(original)
        let r = GemmaWireFormat.parse(wire)
        XCTAssertEqual(r.toolCall, original)
    }
}
