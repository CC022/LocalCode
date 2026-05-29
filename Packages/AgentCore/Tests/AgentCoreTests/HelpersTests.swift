import XCTest
@testable import AgentCore

final class HelpersTests: XCTestCase {

    func testRelativize() {
        let cwd = URL(fileURLWithPath: "/tmp/work")
        XCTAssertEqual(SafePath.relativize(URL(fileURLWithPath: "/tmp/work/sub/doc.md"), to: cwd), "sub/doc.md")
        // Outside the workspace stays absolute.
        XCTAssertEqual(SafePath.relativize(URL(fileURLWithPath: "/tmp/other/doc.md"), to: cwd), "/tmp/other/doc.md")
        // A sibling sharing a name prefix must not be treated as inside.
        XCTAssertEqual(SafePath.relativize(URL(fileURLWithPath: "/tmp/work2/doc.md"), to: cwd), "/tmp/work2/doc.md")
    }

    func testClipped() {
        XCTAssertEqual("hello".clipped(to: 10), "hello")   // fits, unchanged
        XCTAssertEqual(String(repeating: "x", count: 12).clipped(to: 10),
                       String(repeating: "x", count: 10) + "\n... (2 more chars)")
        XCTAssertEqual(String(repeating: "x", count: 12).clipped(to: 10, withCount: false),
                       String(repeating: "x", count: 10) + "\n…(truncated)")
    }
}
