import Foundation
import XCTest
@testable import Santty

final class HerdrClientShellStateTests: XCTestCase {
    private func snapshot(_ revision: UInt64 = 251, boot: String = "boot") throws -> HerdrShellSnapshot {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/herdr-clientshell-snapshot-v1.json")
        let source = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "w1:p1", with: "w5:pA")
            .replacingOccurrences(of: "w1:t1", with: "w5:t4").replacingOccurrences(of: "w1", with: "w5")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any])
        json["revision"] = revision; json["boot_id"] = boot
        return try JSONDecoder().decode(HerdrShellSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func surface(_ revision: UInt64 = 251, serial: UInt64 = 65536, boot: String = "boot", images: Bool = false) throws -> HerdrShellSurface {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/herdr-clientshell-wire-v1.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let hex = try XCTUnwrap((json["payloads"] as? [String: String])?["surface_image"])
        var bytes = Data(), index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2); bytes.append(try XCTUnwrap(UInt8(hex[index..<end], radix: 16))); index = end
        }
        guard case let .surface(s) = try HerdrShellWire.decode(bytes) else { throw CLIError("Missing golden surface") }
        return .init(boot_id: boot, projection_revision: revision, surface_revision: serial, frame: s.frame,
                     panes: s.panes, splits: s.splits, popup: s.popup,
                     graphics: images ? s.graphics : .init(assets: [], placements: [], retained_assets: []))
    }

    func testFrozenSnapshotAcceptsUnknownAgentStatusAndAdditionalFields() throws {
        let value = try snapshot()
        try value.validate()
        XCTAssertEqual(value.agents?.first?.agent_status, "blocked")
        XCTAssertEqual(value.workspaces.first?.label, "repo")
        XCTAssertEqual(value.focused_pane_id, "w5:pA")
    }

    func testPopupInputTargetCannotFallThroughToUnderlyingPane() throws {
        let base = try surface()
        XCTAssertTrue(base.containsInputTarget("w5:pA", popup: false))
        XCTAssertFalse(base.containsInputTarget("popup", popup: true))
        let popup = HerdrShellPopup(terminal_id: "w5:pA", title: "Popup", width: nil, height: nil,
            widthIsPercent: false, heightIsPercent: false, frame: base.frame,
            mouse_reporting: true, sgr_pixel_mouse: false, pixel_width: 16, pixel_height: 16)
        let modal = HerdrShellSurface(boot_id: base.boot_id, projection_revision: base.projection_revision,
            surface_revision: base.surface_revision, frame: base.frame, panes: base.panes,
            splits: base.splits, popup: popup, graphics: base.graphics)
        XCTAssertFalse(modal.containsInputTarget("w5:pA", popup: false), "Identical string IDs cannot confuse pane and popup routing")
        XCTAssertTrue(modal.containsInputTarget("w5:pA", popup: true))
        XCTAssertFalse(modal.containsInputTarget("another-popup", popup: true))
        XCTAssertEqual(try HerdrShellClientMessage.input(target: popup.terminal_id, popup: true, events: [.paste("text")]).encoded().dropFirst(4).first, 14)
    }

    func testOnlyExportedTopologyMustMatchTheCoherentClientShellProjection() throws {
        let shell = try snapshot(), frame = try surface()
        let layout = HerdrLayout(workspace_id: "w5", tab_id: "w5:t4", zoomed: false,
                                focused_pane_id: "w5:pA", root: .pane("w5:pA"))
        let layouts = ["w5:t4": layout]
        XCTAssertTrue(HerdrLayout.matchesShellProjection(layouts: layouts, shell: shell, surface: frame))
        XCTAssertFalse(HerdrLayout.matchesShellProjection(layouts: [:], shell: shell, surface: frame))
        let ahead = HerdrLayout(workspace_id: "w5", tab_id: "w5:t4", zoomed: false,
                               focused_pane_id: "w5:future", root: .pane("w5:future"))
        XCTAssertFalse(HerdrLayout.matchesShellProjection(layouts: ["w5:t4": ahead], shell: shell, surface: frame))
        let foreign = HerdrLayout(workspace_id: "other", tab_id: "w5:t4", zoomed: false,
                                 focused_pane_id: "w5:pA", root: .pane("w5:pA"))
        XCTAssertFalse(HerdrLayout.matchesShellProjection(layouts: ["w5:t4": foreign], shell: shell, surface: frame))
        XCTAssertFalse(HerdrLayout.matchesShellProjection(layouts: layouts, shell: shell, surface: try surface(252)))
        XCTAssertFalse(HerdrLayout.matchesShellProjection(layouts: layouts, shell: shell, surface: try surface(boot: "restarted")))
        let duplicate = HerdrLayout(workspace_id: "w5", tab_id: "w5:t4", zoomed: false,
            focused_pane_id: "w5:pA", root: .split(.horizontal, 0.5, .pane("w5:pA"), .pane("w5:pA")))
        XCTAssertFalse(HerdrLayout.matchesShellProjection(layouts: ["w5:t4": duplicate], shell: shell, surface: frame))
    }

    func testFutureSurfaceWaitsForExactSnapshotAndOldFramesCannotReplaceIt() throws {
        var state = HerdrShellProjection()
        XCTAssertFalse(try state.receive(snapshot()))
        XCTAssertTrue(try state.receive(surface()))
        XCTAssertFalse(try state.receive(surface(252, serial: 65537)))
        XCTAssertEqual(state.coherentSurface?.projection_revision, 251)
        XCTAssertEqual(state.pendingSurface?.projection_revision, 252)
        XCTAssertFalse(try state.receive(surface(251, serial: 65538)))
        XCTAssertTrue(try state.receive(snapshot(252)))
        XCTAssertEqual(state.coherentSurface?.projection_revision, 252)
        XCTAssertNil(state.pendingSurface)
        XCTAssertFalse(try state.receive(snapshot(251)))
        XCTAssertEqual(state.snapshot?.revision, 252)
    }

    func testRestartClearsPreviousSurfaceAssetsAndRejectsOldBoot() throws {
        var state = HerdrShellProjection()
        _ = try state.receive(snapshot())
        _ = try state.receive(surface(images: true))
        XCTAssertEqual(state.assets.count, 1)
        XCTAssertFalse(try state.receive(snapshot(1, boot: "new-boot")))
        XCTAssertNil(state.coherentSurface)
        XCTAssertTrue(state.assets.isEmpty)
        XCTAssertFalse(try state.receive(surface()))
        XCTAssertTrue(try state.receive(surface(1, serial: 1, boot: "new-boot")))
    }

    func testPatchValidationIsAtomicAndRequiresItsNextBaseline() throws {
        var state = HerdrShellProjection()
        _ = try state.receive(snapshot()); _ = try state.receive(surface())
        let original = try XCTUnwrap(state.surface)
        let cell = HerdrShellCell(symbol: "x", fg: 0, bg: 0, modifier: 0, skip: false, hyperlink: nil)
        let good = HerdrShellPatch.Row(x: 0, y: 0, cells: [cell])
        let bad = HerdrShellPatch.Row(x: 2, y: 0, cells: [cell])
        func patch(_ rows: [HerdrShellPatch.Row], base: UInt64 = 65536) -> HerdrShellPatch {
            .init(boot_id: "boot", projection_revision: 251, base_surface_revision: base, surface_revision: base + 1,
                  rows: rows, panes: original.panes, cursor: original.frame.cursor)
        }
        XCTAssertThrowsError(try state.receive(patch([good, bad])))
        XCTAssertEqual(state.surface, original)
        XCTAssertThrowsError(try state.receive(patch([good], base: 1)))
        XCTAssertEqual(state.surface, original)
        XCTAssertTrue(try state.receive(patch([good])))
        XCTAssertEqual(state.surface?.frame.cells[0].symbol, "x")
        XCTAssertEqual(state.surface?.surface_revision, 65537)
        XCTAssertThrowsError(try state.receive(patch([good])))
    }

    func testPatchAcceptsStableContentRevisionAfterUnstableRenderWithoutRelaxingGeometry() throws {
        var state = HerdrShellProjection()
        _ = try state.receive(snapshot())
        let base = try surface()
        func pane(_ revision: UInt64, rect: HerdrShellRect? = nil) -> HerdrShellPane {
            let original = base.panes[0]
            return .init(pane_id: original.pane_id, content_revision: revision,
                         rect: rect ?? original.rect, inner_rect: original.inner_rect,
                         scrollbar_rect: original.scrollbar_rect, scroll: original.scroll,
                         focused: original.focused, mouse_reporting: original.mouse_reporting,
                         sgr_pixel_mouse: original.sgr_pixel_mouse, alternate_screen_active: original.alternate_screen_active,
                         pixel_width: original.pixel_width, pixel_height: original.pixel_height)
        }
        let unstable = HerdrShellSurface(boot_id: base.boot_id, projection_revision: base.projection_revision,
            surface_revision: base.surface_revision, frame: base.frame, panes: [pane(9)],
            splits: base.splits, popup: base.popup, graphics: base.graphics)
        _ = try state.receive(unstable)
        let stable = HerdrShellPatch(boot_id: base.boot_id, projection_revision: base.projection_revision,
            base_surface_revision: base.surface_revision, surface_revision: base.surface_revision + 1,
            rows: [], panes: [pane(8)], cursor: base.frame.cursor)
        XCTAssertTrue(try state.receive(stable))
        XCTAssertEqual(state.surface?.panes[0].content_revision, 8)
        let committed = state.surface
        let changedRect = HerdrShellRect(x: 1, y: 0, width: 1, height: 1)
        let invalid = HerdrShellPatch(boot_id: base.boot_id, projection_revision: base.projection_revision,
            base_surface_revision: stable.surface_revision, surface_revision: stable.surface_revision + 1,
            rows: [], panes: [pane(10, rect: changedRect)], cursor: base.frame.cursor)
        XCTAssertThrowsError(try state.receive(invalid))
        XCTAssertEqual(state.surface, committed)
    }

    func testMismatchedSnapshotDoesNotCommitPendingSurface() throws {
        var state = HerdrShellProjection()
        _ = try state.receive(snapshot()); _ = try state.receive(surface())
        _ = try state.receive(surface(252, serial: 65537))
        let old = state.snapshot
        let wrong = HerdrShellSnapshot(boot_id: "boot", revision: 252, focused_workspace_id: "w5", focused_tab_id: "w5:t4",
            focused_pane_id: "w5:pB", workspaces: old!.workspaces, tabs: old!.tabs,
            panes: [.init(pane_id: "w5:pB", workspace_id: "w5", tab_id: "w5:t4", label: nil, cwd: nil,
                          foreground_cwd: nil, focused: true, right_click_passthrough: false)], agents: nil, config_diagnostic: nil)
        XCTAssertThrowsError(try state.receive(wrong))
        XCTAssertEqual(state.snapshot, old)
        XCTAssertEqual(state.coherentSurface?.projection_revision, 251)
        XCTAssertEqual(state.pendingSurface?.projection_revision, 252)
    }

    func testAssetReferenceDoesNotRequireRepeatedPixels() throws {
        var state = HerdrShellProjection()
        _ = try state.receive(snapshot())
        let first = try surface(images: true)
        _ = try state.receive(first)
        let scene = HerdrShellGraphics(assets: [], placements: first.graphics.placements, retained_assets: first.graphics.retained_assets)
        let second = HerdrShellSurface(boot_id: "boot", projection_revision: 251, surface_revision: 65537,
            frame: first.frame, panes: first.panes, splits: first.splits, popup: nil, graphics: scene)
        XCTAssertTrue(try state.receive(second))
        XCTAssertEqual(state.assets[first.graphics.assets[0].key], Data([255, 0, 0, 255]))
    }

    func testCompressedImagesAreBudgetedByDecodedPixelsBeforeCommit() throws {
        var state = HerdrShellProjection()
        _ = try state.receive(snapshot())
        let first = try surface(images: true)
        let large = HerdrShellAssetKey(source: .pane("w5:pA", 8), image_width: 8192, image_height: 8192,
            format: 2, data_len: 1, data_fingerprint: 2)
        let graphics = HerdrShellGraphics(assets: first.graphics.assets + [.init(key: large, data: Data([0]))],
            placements: first.graphics.placements, retained_assets: [large])
        let oversized = HerdrShellSurface(boot_id: "boot", projection_revision: 251, surface_revision: 65536,
            frame: first.frame, panes: first.panes, splits: first.splits, popup: nil, graphics: graphics)
        XCTAssertThrowsError(try state.receive(oversized))
        XCTAssertNil(state.surface)
        XCTAssertTrue(state.assets.isEmpty)
    }
}
