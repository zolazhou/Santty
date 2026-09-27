import XCTest

@testable import Santty

final class AgentSkillInstallerTests: XCTestCase {
    func testBundledSkill() throws {
        let text = try String(
            contentsOf: AgentSkillInstaller().source.appendingPathComponent("SKILL.md"),
            encoding: .utf8)
        XCTAssertTrue(text.contains("name: santty"))
        XCTAssertTrue(text.contains("--start-line"))
    }

    func testLinkLifecycleAndConflicts() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let installer = AgentSkillInstaller(
            appURL: root.appendingPathComponent("current/Santty.app"))
        try manager.createDirectory(at: installer.source, withIntermediateDirectories: true)
        let document = installer.source.appendingPathComponent("SKILL.md")
        try Data("skill".utf8).write(to: document)
        let directory = root.appendingPathComponent("skills")
        let link = directory.appendingPathComponent("santty")
        XCTAssertEqual(installer.status(in: directory), .missing)
        try installer.install(in: directory)
        try installer.install(in: directory)
        XCTAssertEqual(installer.status(in: directory), .installed)
        XCTAssertEqual(
            try String(contentsOf: link.appendingPathComponent("SKILL.md"), encoding: .utf8),
            "skill")
        try installer.remove(from: directory)
        XCTAssertTrue(manager.fileExists(atPath: document.path))

        // Relative symlinks resolve against the skills directory, including URLs without a trailing slash.
        try manager.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "../current/Santty.app/Contents/Resources/Skills/santty")
        XCTAssertEqual(installer.status(in: directory), .installed)
        try installer.remove(from: directory)

        let old = root.appendingPathComponent("old/Santty.app/Contents/Resources/Skills/santty")
        try manager.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent("SKILL.md"))
        try manager.createSymbolicLink(at: link, withDestinationURL: old)
        XCTAssertEqual(installer.status(in: directory), .otherApp(path: old.path, broken: false))
        XCTAssertThrowsError(try installer.install(in: directory))
        try installer.install(in: directory, replacingOtherApp: true)
        XCTAssertEqual(installer.status(in: directory), .installed)
        XCTAssertTrue(manager.fileExists(atPath: old.appendingPathComponent("SKILL.md").path))
        try installer.remove(from: directory)
        try manager.removeItem(at: old)
        try manager.createSymbolicLink(at: link, withDestinationURL: old)
        XCTAssertEqual(installer.status(in: directory), .otherApp(path: old.path, broken: true))
        try installer.install(in: directory, replacingOtherApp: true)
        XCTAssertEqual(installer.status(in: directory), .installed)
        try installer.remove(from: directory)

        for kind in 0..<3 {
            if kind == 0 { try Data("keep".utf8).write(to: link) }
            if kind == 1 {
                try manager.createDirectory(at: link, withIntermediateDirectories: false)
            }
            if kind == 2 {
                try manager.createSymbolicLink(atPath: link.path, withDestinationPath: "unrelated")
            }
            XCTAssertEqual(installer.status(in: directory), .conflict)
            XCTAssertThrowsError(try installer.install(in: directory, replacingOtherApp: true))
            XCTAssertThrowsError(try installer.remove(from: directory))
            if kind == 0 { XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "keep") }
            if kind == 1 { XCTAssertEqual(try manager.contentsOfDirectory(atPath: link.path), []) }
            if kind == 2 {
                XCTAssertEqual(
                    try manager.destinationOfSymbolicLink(atPath: link.path), "unrelated")
            }
            try manager.removeItem(at: link)
        }
        try manager.removeItem(at: document)
        XCTAssertThrowsError(try installer.install(in: directory))
        XCTAssertEqual(installer.status(in: directory), .missing)
    }
}
