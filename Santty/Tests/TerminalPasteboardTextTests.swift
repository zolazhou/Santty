import AppKit
import XCTest
@testable import Santty

final class TerminalPasteboardTextTests: XCTestCase {
    func testEscapedForTerminalPrefixesShellSensitiveCharacters() {
        XCTAssertEqual(
            TerminalPasteboardText.escapedForTerminal(#"/tmp/a b's & c;.txt"#),
            #"/tmp/a\ b\'s\ \&\ c\;.txt"#
        )
    }

    func testEscapedForTerminalEscapesTabsAndBrackets() {
        XCTAssertEqual(
            TerminalPasteboardText.escapedForTerminal("/tmp/[a]\t{b}"),
            "/tmp/\\[a\\]\\\t\\{b\\}"
        )
    }

    func testDropInsertionTextEscapesURLStringBeforeFileURLs() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        pasteboard.setString("https://example.com/a b?q=1&x=2", forType: .URL)

        XCTAssertEqual(
            TerminalPasteboardText.dropInsertionText(from: pasteboard),
            "https://example.com/a\\ b\\?q=1\\&x=2"
        )
    }

    func testDropInsertionTextLeavesPlainStringUnescaped() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        pasteboard.setString("echo hello && pwd", forType: .string)

        XCTAssertEqual(
            TerminalPasteboardText.dropInsertionText(from: pasteboard),
            "echo hello && pwd"
        )
    }

    func testURLInsertionTextEscapesFilePathsAndJoinsWithSpaces() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        pasteboard.writeObjects([
            URL(fileURLWithPath: "/tmp/a b.txt") as NSURL,
            URL(fileURLWithPath: "/tmp/c&d.txt") as NSURL,
        ])

        XCTAssertEqual(
            TerminalPasteboardText.urlInsertionText(from: pasteboard),
            "/tmp/a\\ b.txt /tmp/c\\&d.txt"
        )
    }
}
