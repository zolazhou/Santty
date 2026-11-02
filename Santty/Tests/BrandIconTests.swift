import AppKit
import XCTest
@testable import Santty

@MainActor
final class BrandIconTests: XCTestCase {
    func testKnownAgentAliasesAndUnknownTypesPreserveReportedIdentity() throws {
        let groups: [(BrandIcon, String, [String])] = [
            (.codex, "Codex", ["codex", "CODEX"]),
            (.claudeCode, "Claude Code", ["claude", "claude-code", "claude_code", "claude code"]),
            (.pi, "pi", ["pi", "pi-coding-agent"]),
            (.opencode, "OpenCode", ["opencode", "open-code"]),
            (.copilot, "GitHub Copilot", ["copilot", "github-copilot", "github_copilot", "github copilot", "copilot-cli"]),
        ]
        for (icon, title, aliases) in groups {
            for alias in aliases {
                let kind = AgentKind(rawValue: alias)
                XCTAssertEqual(kind.brandIcon, icon)
                XCTAssertEqual(kind.displayName, title)
                XCTAssertEqual(kind.rawValue, alias.lowercased())
                XCTAssertEqual(try JSONDecoder().decode(AgentKind.self, from: JSONEncoder().encode(kind)), kind)
            }
        }
        for raw in ["custom-agent", "future-tool"] {
            let kind = AgentKind(rawValue: raw)
            XCTAssertNil(kind.brandIcon)
            XCTAssertEqual(kind.displayName, raw)
        }
        XCTAssertEqual(AgentKind(rawValue: "").displayName, "Agent")
    }

    func testEveryBundledIconRendersAndSizingDoesNotMutateSharedImages() throws {
        for icon in BrandIcon.allCases {
            let image = try XCTUnwrap(icon.image(), icon.rawValue)
            XCTAssertNotNil(image.tiffRepresentation, icon.rawValue)
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
            XCTAssertEqual(image.isTemplate, icon == .copilot)
            XCTAssertEqual(icon.image(size: 16)?.size, NSSize(width: 16, height: 16))
            XCTAssertEqual(icon.image()?.size, NSSize(width: 18, height: 18))
        }
    }

    func testWorkspaceAndPaletteIconsKeepRemoteContext() throws {
        let local = WorkspaceEntry(reference: UUID(), name: "Local")
        let remote = WorkspaceEntry(reference: UUID(), name: "Server", kind: .herdr,
                                    remote: .init(id: "core-server", name: "Production"))
        XCTAssertNil(local.brandIcon)
        XCTAssertEqual(remote.brandIcon, .herdr)
        XCTAssertEqual(remote.symbol, "network")
        let toolbar = WorkspaceToolbarView()
        toolbar.updateWorkspaceEntries([local, remote], selectedID: remote.id)
        XCTAssertEqual(toolbar.workspaceSwitcher.selectedItem?.image?.tiffRepresentation, BrandIcon.herdr.image(size: 16)?.tiffRepresentation)
        XCTAssertTrue(toolbar.workspaceSwitcher.toolTip?.contains("Production") == true)

        let workspace = WorkspaceViewController()
        workspace.debugLoadForTesting()
        workspace.createRemoteHerdrWorkspace(.init(id: "core-server", name: "Production"))
        let item = try XCTUnwrap(workspace.paletteNavigationItems.first { $0.kind == .workspace && $0.isCurrent })
        XCTAssertEqual(item.brandIcon, .herdr)
        XCTAssertEqual(item.paletteSnapshot.brandIcon, .herdr)
        XCTAssertTrue(item.subtitle?.contains("Production") == true)
    }
}
