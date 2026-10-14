import AppKit
import Foundation
import Darwin
import GhosttyTerminal
import XCTest
@testable import Santty

final class HerdrClientShellRendererTests: XCTestCase {
    private func patchScene(columns: Int = 600, rows: Int = 60, paneCount: Int = 2) throws -> HerdrShellProjection {
        let panes = (["left", "right"] + (2..<max(2, paneCount)).map { "pane-\($0)" }).prefix(paneCount).enumerated().map { index, id in
            let rect = HerdrShellRect(x: UInt16(index * columns / paneCount), y: 0, width: UInt16(columns / paneCount), height: UInt16(rows))
            return HerdrShellPane(pane_id: id, content_revision: 1, rect: rect, inner_rect: rect,
                scrollbar_rect: nil, scroll: nil, focused: index == 0, mouse_reporting: false,
                sgr_pixel_mouse: false, alternate_screen_active: false, pixel_width: 2400, pixel_height: 960)
        }
        let snapshot = HerdrShellSnapshot(boot_id: "boot", revision: 1, focused_workspace_id: "w",
            focused_tab_id: "t", focused_pane_id: "left",
            workspaces: [.init(workspace_id: "w", active_tab_id: "t", number: 1, label: "w", focused: true)],
            tabs: [.init(tab_id: "t", workspace_id: "w", number: 1, label: "t", zoomed: false, focused: true)],
            panes: panes.map { .init(pane_id: $0.pane_id, workspace_id: "w", tab_id: "t", label: nil,
                cwd: nil, foreground_cwd: nil, focused: $0.focused, right_click_passthrough: false) },
            agents: nil, config_diagnostic: nil)
        var projection = HerdrShellProjection()
        try projection.receive(snapshot)
        try projection.receive(HerdrShellSurface(boot_id: "boot", projection_revision: 1, surface_revision: 1,
            frame: .init(cells: Array(repeating: cell("A"), count: columns * rows), width: UInt16(columns), height: UInt16(rows),
                cursor: nil, hyperlinks: [], graphics: Data()), panes: panes, splits: [], popup: nil,
            graphics: .init(assets: [], placements: [], retained_assets: [])))
        return projection
    }

    func testPaneExtractionSharesTheSurfaceCellBuffer() throws {
        let surface = try XCTUnwrap(patchScene().coherentSurface)
        let viewport = try HerdrShellViewportFrame.extract(.pane("right"), from: surface)
        surface.frame.cells(in: 0).withUnsafeBufferPointer { source in
            viewport.frame.cells(in: 0).withUnsafeBufferPointer { extracted in
                XCTAssertEqual(source.baseAddress, extracted.baseAddress, "Pane extraction must share immutable cells")
            }
        }
    }

    func testPatchPreparationBenchmark() async throws {
        var projection = try patchScene()
        var left = HerdrClientShellRenderer(), right = HerdrClientShellRenderer()
        let initial = try XCTUnwrap(projection.coherentSurface)
        left = try await left.prepare(.pane("left"), from: initial, assets: [:]).renderer
        right = try await right.prepare(.pane("right"), from: initial, assets: [:]).renderer
        var samples = HerdrShellLatencySamples()
        for index in 0..<90 {
            let current = try XCTUnwrap(projection.coherentSurface)
            let start = ProcessInfo.processInfo.systemUptime
            try projection.receive(HerdrShellPatch(boot_id: "boot", projection_revision: 1,
                base_surface_revision: current.surface_revision, surface_revision: current.surface_revision + 1,
                rows: [.init(x: 0, y: 0, cells: [cell(index % 2 == 0 ? "X" : "Y")])],
                panes: [current.panes[0]], cursor: nil))
            let next = try XCTUnwrap(projection.coherentSurface)
            left = try await left.prepare(.pane("left"), from: next, assets: [:]).renderer
            right = try await right.prepare(.pane("right"), from: next, assets: [:]).renderer
            if index >= 10 { samples.record(seconds: ProcessInfo.processInfo.systemUptime - start) }
        }
        print("HERDR_PATCH_BENCHMARK " + String(decoding: try JSONEncoder().encode(samples.summary), as: UTF8.self))
    }

    @MainActor
    func testScenePreparationBenchmark() async throws {
        @MainActor final class Heartbeat {
            var recording = false
            var samples: [Double] = []
        }
        for count in [1, 2, 8] {
            for mode in ["serial", "scene"] {
                var projection = try patchScene(columns: 1200, rows: 60, paneCount: count)
                var encoders = Array(repeating: HerdrClientShellRenderer(), count: count)
                let initial = try XCTUnwrap(projection.coherentSurface)
                for (i, pane) in initial.panes.enumerated() {
                    encoders[i] = try await encoders[i].prepare(.pane(pane.pane_id), from: initial, assets: [:]).renderer
                }
                var samples: [Double] = []
                var queue = HerdrShellLatencySamples(), resume = HerdrShellLatencySamples()
                let ticks = Heartbeat()
                let heartbeat = Task { @MainActor in
                    var previous = ProcessInfo.processInfo.systemUptime
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(1)) } catch { break }
                        let now = ProcessInfo.processInfo.systemUptime
                        if ticks.recording { ticks.samples.append((now - previous) * 1000) }
                        previous = now
                    }
                }
                defer { heartbeat.cancel() }
                for index in 0..<1100 {
                    let base = try XCTUnwrap(projection.coherentSurface)
                    let changed = base.panes.map {
                        HerdrShellPatch.Row(x: $0.inner_rect.x, y: UInt16(index % 60), cells: [cell((index / 60) % 2 == 0 ? "X" : "Y")])
                    }
                    try projection.receive(HerdrShellPatch(boot_id: "boot", projection_revision: 1,
                        base_surface_revision: base.surface_revision, surface_revision: base.surface_revision + 1,
                        rows: changed, panes: base.panes, cursor: nil))
                    let scene = try XCTUnwrap(projection.coherentSurface)
                    ticks.recording = index >= 100
                    let start = ProcessInfo.processInfo.systemUptime
                    if mode == "serial" {
                        for (i, pane) in scene.panes.enumerated() {
                            let result = try await encoders[i].prepare(.pane(pane.pane_id), from: scene, assets: [:])
                            encoders[i] = result.renderer
                            if ticks.recording, let timing = result.timing { queue.record(seconds: timing.queue); resume.record(seconds: timing.resume) }
                        }
                    } else {
                        let inputs = scene.panes.enumerated().map {
                            HerdrClientShellRenderer.Input(renderer: encoders[$0.offset], target: .pane($0.element.pane_id))
                        }
                        let result = try await HerdrClientShellRenderer.prepareScene(inputs, from: scene, assets: [:])
                        encoders = result.outputs.map(\.renderer)
                        if ticks.recording, let timing = result.timing { queue.record(seconds: timing.queue); resume.record(seconds: timing.resume) }
                    }
                    if ticks.recording { samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000) }
                }
                heartbeat.cancel(); await heartbeat.value
                samples.sort()
                let heartbeats = ticks.samples.sorted()
                print("HERDR_SCENE_BENCHMARK mode=\(mode) panes=\(count) p50=\(samples[499]) p95=\(samples[949]) p99=\(samples[989])")
                print("HERDR_SCENE_SCHEDULE mode=\(mode) panes=\(count) queue=" + String(decoding: try JSONEncoder().encode(queue.summary), as: UTF8.self)
                    + " resume=" + String(decoding: try JSONEncoder().encode(resume.summary), as: UTF8.self))
                XCTAssertFalse(heartbeats.isEmpty, "The main actor must run while scene encoding is pending")
                if !heartbeats.isEmpty {
                    print("HERDR_SCENE_HEARTBEAT mode=\(mode) panes=\(count) count=\(heartbeats.count) p95=\(heartbeats[Int(ceil(Double(heartbeats.count) * 0.95)) - 1]) p99=\(heartbeats[Int(ceil(Double(heartbeats.count) * 0.99)) - 1])")
                }
            }
        }
    }

    func testSceneEncodingMatchesIndependentPanesAndDoesNotCommitFailedOrCancelledCandidates() async throws {
        var projection = try patchScene()
        let initial = try XCTUnwrap(projection.coherentSurface)
        let inputs = initial.panes.map { HerdrClientShellRenderer.Input(renderer: .init(), target: .pane($0.pane_id)) }
        let first = try await HerdrClientShellRenderer.prepareScene(inputs, from: initial, assets: [:])
        XCTAssertNotNil(first.timing)
        let committed = zip(first.outputs, inputs).map { HerdrClientShellRenderer.Input(renderer: $0.0.renderer, target: $0.1.target) }
        let unchanged = try await HerdrClientShellRenderer.prepareScene(committed, from: initial, assets: [:])
        XCTAssertNil(unchanged.timing, "An unchanged scene must not enqueue an encoding worker")
        XCTAssertTrue(unchanged.outputs.allSatisfy { $0.bytes.isEmpty })
        try projection.receive(.init(boot_id: "boot", projection_revision: 1, base_surface_revision: 1, surface_revision: 2,
            rows: [.init(x: 1, y: 0, cells: [cell("界"), cell(" ")]), .init(x: 300, y: 59, cells: [cell("Z")])],
            panes: initial.panes, cursor: nil))
        let changed = try XCTUnwrap(projection.coherentSurface)
        let candidate = try await HerdrClientShellRenderer.prepareScene(committed, from: changed, assets: [:])
        for (input, output) in zip(committed, candidate.outputs) {
            var reference = input.renderer
            XCTAssertEqual(output.bytes, try reference.render(.extract(input.target, from: changed), assets: [:]))
        }
        let image = HerdrShellAssetKey(source: .pane("right", 7), image_width: 1, image_height: 1,
                                      format: 1, data_len: 4, data_fingerprint: 1)
        var invalid = HerdrShellSurface(boot_id: "boot", projection_revision: 1, surface_revision: 2,
            frame: changed.frame, panes: changed.panes, splits: [], popup: nil,
            graphics: .init(assets: [], placements: [placement(image, x: 301)], retained_assets: []))
        invalid.damage = changed.damage
        do {
            _ = try await HerdrClientShellRenderer.prepareScene(committed, from: invalid, assets: [image: Data()])
            XCTFail("A later pane's invalid image must fail the whole batch")
        } catch { }
        let retried = try await HerdrClientShellRenderer.prepareScene(committed, from: changed, assets: [:])
        XCTAssertEqual(retried.outputs.map(\.bytes), candidate.outputs.map(\.bytes), "Rejected preparation cannot advance any encoder")
        let cancelled = Task { try await HerdrClientShellRenderer.prepareScene(committed, from: changed, assets: [:]) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled scene was prepared") } catch is CancellationError { }
        let cancelledReuse = Task { try await HerdrClientShellRenderer.prepareScene(committed, from: initial, assets: [:]) }
        cancelledReuse.cancel()
        do { _ = try await cancelledReuse.value; XCTFail("Even unchanged scenes must honor cancellation") } catch is CancellationError { }
    }

    @MainActor
    func testSceneRequestRejectsOutputAfterItsDisplayIdentityChanges() async throws {
        @MainActor final class Display {
            var current = true
            var commits = 0
        }
        let surface = try XCTUnwrap(patchScene().coherentSurface)
        let display = Display()
        let request = HerdrShellRenderRequest(input: .init(renderer: .init(), target: .pane("left")),
            isCurrent: { display.current }, commit: { _, _ in display.commits += 1; return nil })
        let scene = try await HerdrClientShellRenderer.prepareScene([request.input], from: surface, assets: [:])
        let output = request.output(scene.outputs[0])
        XCTAssertGreaterThan(output.byteCount, 0)
        XCTAssertTrue(output.isCurrent())
        display.current = false
        XCTAssertFalse(output.isCurrent())
        XCTAssertNil(output.commit())
        XCTAssertEqual(display.commits, 0, "Encoding completion cannot authorize output into a retired display")
    }

    func testSceneBatchKeepsPopupAndPaneImageNamespacesIndependent() async throws {
        var scene = try XCTUnwrap(patchScene().coherentSurface)
        let paneImage = HerdrShellAssetKey(source: .pane("left", 7), image_width: 1, image_height: 1,
                                          format: 1, data_len: 4, data_fingerprint: 1)
        let popupImage = HerdrShellAssetKey(source: .popup("popup", 7), image_width: 1, image_height: 1,
                                           format: 1, data_len: 4, data_fingerprint: 2)
        scene.popup = .init(terminal_id: "popup", title: "popup", width: nil, height: nil,
            widthIsPercent: false, heightIsPercent: false,
            frame: .init(cells: [cell("P"), cell("Q")], width: 2, height: 1, cursor: nil, hyperlinks: [], graphics: Data()),
            mouse_reporting: false, sgr_pixel_mouse: false, pixel_width: 16, pixel_height: 16)
        scene = .init(boot_id: scene.boot_id, projection_revision: scene.projection_revision, surface_revision: scene.surface_revision,
            frame: scene.frame, panes: scene.panes, splits: [], popup: scene.popup,
            graphics: .init(assets: [], placements: [placement(paneImage), placement(popupImage, x: 0, y: 0)], retained_assets: []))
        let inputs: [HerdrClientShellRenderer.Input] = ["left", "right"].map { .init(renderer: .init(), target: .pane($0)) }
            + [.init(renderer: .init(), target: .popup("popup"))]
        let assets = [paneImage: Data([255, 0, 0, 255]), popupImage: Data([0, 0, 255, 255])]
        let batch = try await HerdrClientShellRenderer.prepareScene(inputs, from: scene, assets: assets)
        XCTAssertEqual(batch.outputs.count, inputs.count)
        for (input, output) in zip(inputs, batch.outputs) {
            var reference = input.renderer
            XCTAssertEqual(output.bytes, try reference.render(.extract(input.target, from: scene), assets: assets))
        }
        XCTAssertTrue(batch.outputs[0].renderer.ownsImage(1))
        XCTAssertFalse(batch.outputs[1].renderer.ownsImage(1))
        XCTAssertTrue(batch.outputs[2].renderer.ownsImage(1))
    }

    func testProjectionPatchBenchmark() throws {
        func heapBytes() -> Int {
            var statistics = malloc_statistics_t()
            malloc_zone_statistics(nil, &statistics)
            return Int(statistics.size_in_use)
        }
        for (columns, rows) in [(600, 60), (1200, 120)] {
            var projection = try patchScene(columns: columns, rows: rows)
            var milliseconds: [Double] = [], liveHeapBytes: [Int] = []
            for index in 0..<1100 {
                let current = try XCTUnwrap(projection.coherentSurface)
                let patch = HerdrShellPatch(boot_id: "boot", projection_revision: 1,
                    base_surface_revision: current.surface_revision, surface_revision: current.surface_revision + 1,
                    rows: [.init(x: 0, y: UInt16(index % rows), cells: [cell(index % 2 == 0 ? "X" : "Y")])],
                    panes: [current.panes[0]], cursor: nil)
                let before = heapBytes()
                let start = ProcessInfo.processInfo.systemUptime
                try projection.receive(patch)
                let duration = (ProcessInfo.processInfo.systemUptime - start) * 1000
                withExtendedLifetime(current) {
                    if index >= 100 {
                        milliseconds.append(duration)
                        liveHeapBytes.append(heapBytes() - before)
                    }
                }
            }
            let report = try JSONSerialization.data(withJSONObject: ["columns": columns, "rows": rows,
                "milliseconds": milliseconds, "netLiveHeapBytes": liveHeapBytes], options: [.sortedKeys])
            print("HERDR_PROJECTION_BENCHMARK " + String(decoding: report, as: UTF8.self))
        }
    }

    func testPatchSharesUnchangedRowsWithoutMutatingRetainedFrames() throws {
        var projection = try patchScene()
        let previous = try XCTUnwrap(projection.coherentSurface)
        try projection.receive(HerdrShellPatch(boot_id: "boot", projection_revision: 1,
            base_surface_revision: previous.surface_revision, surface_revision: previous.surface_revision + 1,
            rows: [.init(x: 7, y: 3, cells: [cell("X")]), .init(x: 8, y: 3, cells: [cell("Y")])],
            panes: [previous.panes[0]], cursor: nil))
        let next = try XCTUnwrap(projection.coherentSurface)
        previous.frame.cells(in: 4).withUnsafeBufferPointer { old in
            next.frame.cells(in: 4).withUnsafeBufferPointer { new in
                XCTAssertEqual(old.baseAddress, new.baseAddress, "A single-cell patch must not copy an unchanged row")
            }
        }
        XCTAssertEqual(previous.frame.cells(in: 3).map(\.symbol), Array(repeating: "A", count: 600))
        let changed = next.frame.cells(in: 3)
        XCTAssertEqual(changed[changed.startIndex + 7].symbol, "X")
        XCTAssertEqual(changed[changed.startIndex + 8].symbol, "Y")
    }

    func testCoalescedPatchesKeepUncommittedRowsAndSkipOnlyUnchangedPanes() async throws {
        var projection = try patchScene()
        let initial = try XCTUnwrap(projection.coherentSurface)
        let left = try await HerdrClientShellRenderer().prepare(.pane("left"), from: initial, assets: [:]).renderer
        let right = try await HerdrClientShellRenderer().prepare(.pane("right"), from: initial, assets: [:]).renderer
        func patch(_ rows: [HerdrShellPatch.Row], cursor: HerdrShellCursor? = nil) throws {
            let base = try XCTUnwrap(projection.coherentSurface)
            try projection.receive(HerdrShellPatch(boot_id: "boot", projection_revision: 1,
                base_surface_revision: base.surface_revision, surface_revision: base.surface_revision + 1,
                rows: rows, panes: base.panes, cursor: cursor))
        }
        try patch([.init(x: 0, y: 0, cells: [cell("X")])])
        let first = try XCTUnwrap(projection.coherentSurface)
        _ = try await left.prepare(.pane("left"), from: first, assets: [:]) // Deliberately discard the candidate.
        try patch([.init(x: 1, y: 59, cells: [cell("界"), cell(" ")])])
        let merged = try XCTUnwrap(projection.coherentSurface)
        let committed = try await left.prepare(.pane("left"), from: merged, assets: [:])
        var fullScan = merged; fullScan.damage = nil
        let expected = try await left.prepare(.pane("left"), from: fullScan, assets: [:])
        XCTAssertEqual(committed.bytes, expected.bytes, "Discarding a prepared frame cannot consume its dirty rows")
        XCTAssertTrue(String(decoding: committed.bytes, as: UTF8.self).contains("X"))
        XCTAssertTrue(String(decoding: committed.bytes, as: UTF8.self).contains("界"))
        XCTAssertEqual(initial.frame.cells[0].symbol, "A", "Retained frame cells must remain immutable")
        let skipped = try await right.prepare(.pane("right"), from: merged, assets: [:])
        XCTAssertTrue(skipped.bytes.isEmpty, "A sibling patch must not emit even cursor or synchronization escapes")

        try patch([], cursor: .init(x: 2, y: 0, visible: true, shape: 2))
        let cursor = try XCTUnwrap(projection.coherentSurface)
        XCTAssertFalse(try committed.renderer.canReuse(.pane("left"), from: cursor, assets: [:]))
        let cursorOnly = try await committed.renderer.prepare(.pane("left"), from: cursor, assets: [:])
        XCTAssertTrue(String(decoding: cursorOnly.bytes, as: UTF8.self).contains("\u{1b}[1;3H"))
        XCTAssertFalse(String(decoding: cursorOnly.bytes, as: UTF8.self).contains("界"))
        XCTAssertTrue(try right.canReuse(.pane("right"), from: cursor, assets: [:]))

        try patch([.init(x: 300, y: 20, cells: [cell("Z")])], cursor: cursor.frame.cursor)
        let sibling = try XCTUnwrap(projection.coherentSurface)
        XCTAssertFalse(try right.canReuse(.pane("right"), from: sibling, assets: [:]))
        XCTAssertTrue(try cursorOnly.renderer.canReuse(.pane("left"), from: sibling, assets: [:]))
        let rightOutput = try await right.prepare(.pane("right"), from: sibling, assets: [:])
        XCTAssertTrue(String(decoding: rightOutput.bytes, as: UTF8.self).contains("Z"))

        var replacement = sibling
        replacement.surface_revision += 1
        replacement.frame.cells[2] = cell("N")
        try projection.receive(replacement)
        let full = try XCTUnwrap(projection.coherentSurface)
        XCTAssertFalse(try cursorOnly.renderer.canReuse(.pane("left"), from: full, assets: [:]),
            "A full surface must replace any inherited patch damage")
        let replaced = try await cursorOnly.renderer.prepare(.pane("left"), from: full, assets: [:])
        XCTAssertTrue(String(decoding: replaced.bytes, as: UTF8.self).contains("N"))
        var reset = replaced.renderer; reset.reset()
        XCTAssertFalse(try reset.canReuse(.pane("left"), from: full, assets: [:]))
        let cancelled = Task { try await rightOutput.renderer.prepare(.pane("right"), from: sibling, assets: [:]) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Even an unchanged pane must honor cancellation") }
        catch is CancellationError { }
    }

    func testDenseTabEncodingStaysWithinOutputBudget() throws {
        let width = 314, height = 41
        let cells = (0..<(width * height)).map { index in
            HerdrShellCell(symbol: String(UnicodeScalar(65 + index % 26)!),
                fg: index % width / 32 % 2 == 0 ? 0x02112233 : 0x02445566,
                bg: 0, modifier: 0, skip: false, hyperlink: nil)
        }
        let viewport = HerdrShellViewportFrame(frame: .init(cells: cells, width: UInt16(width), height: UInt16(height),
            cursor: nil, hyperlinks: [], graphics: Data()), originX: 0, originY: 0, placements: [], retained: [])
        var renderer = HerdrClientShellRenderer()
        let byteCount = try renderer.render(viewport, assets: [:]).count
        XCTAssertLessThan(byteCount, 40_000, "Contiguous ASCII must not need a cursor command for each cell")
    }

    func testASCIIEncodingKeepsExplicitPositionsAcrossSkippedAndWideCells() throws {
        let cells: [HerdrShellCell] = [cell("A"), cell("B", modifier: 1),
            .init(symbol: " ", fg: 0, bg: 0, modifier: 0, skip: true, hyperlink: nil),
            cell("C", link: 0), cell("界"), cell(" "), cell("D"), cell("E")]
        let viewport = HerdrShellViewportFrame(frame: .init(cells: cells, width: 8, height: 1,
            cursor: nil, hyperlinks: ["https://example.com"], graphics: Data()),
            originX: 0, originY: 0, placements: [], retained: [])
        var renderer = HerdrClientShellRenderer()
        let output = String(decoding: try renderer.render(viewport, assets: [:]), as: UTF8.self)
        XCTAssertTrue(output.contains("\u{1b}[1;4H"), "Skipped cells must break the contiguous run")
        XCTAssertTrue(output.contains("\u{1b}[1;5H"), "Unicode keeps explicit placement")
        XCTAssertFalse(output.contains("\u{1b}[1;6H"), "Wide glyph continuation cannot be overwritten")
        XCTAssertTrue(output.contains("\u{1b}[1;7H"), "Position after Unicode remains explicit")
        XCTAssertTrue(output.contains("\u{1b}]8;;https://example.com\u{1b}\\C"))
    }

    func testSingleCellEditDoesNotRewriteTheWholeRow() throws {
        var frame = HerdrShellFrame(cells: Array(repeating: cell("A"), count: 300 * 60), width: 300, height: 60,
            cursor: .init(x: 42, y: 0, visible: true, shape: 2), hyperlinks: [], graphics: Data())
        var renderer = HerdrClientShellRenderer()
        func viewport() -> HerdrShellViewportFrame {
            .init(frame: frame, originX: 0, originY: 0, placements: [], retained: [])
        }
        _ = try renderer.render(viewport(), assets: [:])
        frame.cells[42] = cell("X")
        let output = try renderer.render(viewport(), assets: [:])
        print("HERDR_TYPING_BENCHMARK single_cell_bytes=\(output.count)")
        XCTAssertLessThan(output.count, 100, "A single typed character must not rewrite a 300-column row")
        XCTAssertFalse(String(decoding: output, as: UTF8.self).contains("AAAA"))
    }

    func testOutputReceiptRejectsAnUnattachedInMemorySurface() {
        let memory = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        XCTAssertFalse(memory.receiveIfAttached(Data("unattached output".utf8)))
        memory.waitForPendingOutput()
        XCTAssertNil(memory.readViewportText())
    }

    @MainActor
    func testAsyncEncodingUsesACandidateAndHonorsCancellation() async throws {
        let frame = HerdrShellFrame(cells: [.init(symbol: "X", fg: 0, bg: 0, modifier: 0, skip: false, hyperlink: nil)],
            width: 1, height: 1, cursor: nil, hyperlinks: [], graphics: Data())
        let viewport = HerdrShellViewportFrame(frame: frame, originX: 0, originY: 0, placements: [], retained: [])
        let rect = HerdrShellRect(x: 0, y: 0, width: 1, height: 1)
        let pane = HerdrShellPane(pane_id: "p", content_revision: 1, rect: rect, inner_rect: rect,
            scrollbar_rect: nil, scroll: nil, focused: true, mouse_reporting: false, sgr_pixel_mouse: false,
            alternate_screen_active: false, pixel_width: 8, pixel_height: 16)
        let surface = HerdrShellSurface(boot_id: "boot", projection_revision: 1, surface_revision: 1,
            frame: frame, panes: [pane], splits: [], popup: nil,
            graphics: .init(assets: [], placements: [], retained_assets: []))
        let initial = HerdrClientShellRenderer()
        let prepared = try await initial.prepare(.pane("p"), from: surface, assets: [:])
        var untouched = initial
        XCTAssertEqual(try untouched.render(viewport, assets: [:]), prepared.bytes,
            "Background preparation cannot consume the installed baseline")
        var committed = prepared.renderer
        XCTAssertLessThan(try committed.render(viewport, assets: [:]).count, prepared.bytes.count)
        let cancelled = Task { try await initial.prepare(.pane("p"), from: surface, assets: [:]) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled preparation produced a commit candidate") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected cancellation error: \(error)") }
    }

    func testClipboardOutputIsBoundedBase64AndCannotInjectTerminalControls() throws {
        let text = "中文\u{1b}]0;fake title\u{7}\n"
        let output = String(decoding: try HerdrClientShellRenderer.clipboardOutput(text), as: UTF8.self)
        XCTAssertEqual(output, "\u{1b}]52;c;" + Data(text.utf8).base64EncodedString() + "\u{1b}\\")
        XCTAssertFalse(output.contains("fake title"))
        XCTAssertThrowsError(try HerdrClientShellRenderer.clipboardOutput(String(repeating: "x", count: 2 * 1024 * 1024 + 1)))
    }
    @MainActor
    private final class RejectClipboardWrites: TerminalSurfaceClipboardWriteDelegate {
        var calls = 0
        var allCallsOnMainThread = true
        func terminalShouldWriteClipboard(afterConfirmation: Bool) -> Bool {
            calls += 1
            allCallsOnMainThread = allCallsOnMainThread && Thread.isMainThread
            return false
        }
    }

    @MainActor
    func testClipboardHostPolicyRunsOnMainBeforeAnyConfirmationOrPasteboardWrite() async throws {
        let memory = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        let policy = RejectClipboardWrites()
        terminal.delegate = policy
        terminal.configuration = .init(backend: .inMemory(memory))
        let configuration = TerminalConfiguration(startingFrom: TerminalDefaults.configuration) { builder in
            builder.withCustom("clipboard-write", "ask")
        }
        terminal.controller = TerminalController(configuration: configuration, theme: TerminalDefaults.theme)
        let window = NSWindow(contentRect: terminal.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = terminal; window.orderBack(nil); terminal.fitToSize()
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<100 where memory.readViewportText() == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(memory.readViewportText())
        memory.receive(try HerdrClientShellRenderer.clipboardOutput("clipboard policy fixture"))
        for _ in 0..<100 where policy.calls == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(policy.calls, 1, "Host rejection must happen before opening an ask dialog")
        XCTAssertTrue(policy.allCallsOnMainThread)
        XCTAssertTrue(terminal.requestClipboardWrite("native host event"))
        for _ in 0..<100 where policy.calls == 1 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(policy.calls, 2, "Host events reuse the same confirmation policy without OSC parsing")
        XCTAssertTrue(terminal.requestClipboardWrite("invalidated before callback"))
        XCTAssertFalse(terminal.requestClipboardWrite("nested ask"), "Only one host confirmation may be pending")
        terminal.invalidateClipboardWrites()
        await Task.yield()
        XCTAssertEqual(policy.calls, 2, "A queued host event retains its submission generation")
        XCTAssertFalse(terminal.requestClipboardWrite(String(repeating: "x", count: 2 * 1024 * 1024 + 1)))
        let denied = TerminalConfiguration(startingFrom: TerminalDefaults.configuration) { builder in
            builder.withCustom("clipboard-write", "deny")
        }
        XCTAssertTrue(try XCTUnwrap(terminal.controller).setTerminalConfiguration(denied))
        XCTAssertTrue(terminal.requestClipboardWrite("configured deny"), "Deny is a handled policy decision")
        await Task.yield()
        XCTAssertEqual(policy.calls, 2, "Resolved deny must not ask the host or open a confirmation")
        let allowed = TerminalConfiguration(startingFrom: TerminalDefaults.configuration) { builder in
            builder.withCustom("clipboard-write", "allow")
        }
        XCTAssertTrue(try XCTUnwrap(terminal.controller).setTerminalConfiguration(allowed))
        let maximumText = String(repeating: "x", count: 2 * 1024 * 1024)
        XCTAssertTrue(terminal.requestClipboardWrite(maximumText))
        XCTAssertTrue(terminal.requestClipboardWrite(maximumText))
        XCTAssertFalse(terminal.requestClipboardWrite("over aggregate budget"))
        terminal.invalidateClipboardWrites()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(policy.calls, 2)
        for _ in 0..<128 { XCTAssertTrue(terminal.requestClipboardWrite("")) }
        XCTAssertFalse(terminal.requestClipboardWrite(""), "Empty requests also consume queue slots")
        terminal.invalidateClipboardWrites()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(terminal.requestClipboardWrite("credits returned"))
        for _ in 0..<100 where policy.calls == 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(policy.calls, 3, "Invalidated tasks return their queue credit")
    }

    private func hostColorReplies(includeBackground: Bool = true) -> Data {
        var text = "\u{1b}[0n\u{1b}]10;rgb:1111/2222/3333\u{1b}\\"
        if includeBackground { text += "\u{1b}]11;#abcdef\u{7}" }
        for index in 0...255 { text += "\u{1b}]4;\(index);rgb:ffff/0000/8080\u{1b}\\" }
        text += "\u{1b}[0n"
        return Data(text.utf8)
    }

    func testHostColorQueryRequiresItsFencesAndComplete256ColorPalette() throws {
        let feedback = HerdrShellDisplayFeedback()
        feedback.receive(Data("\u{1b}]10;rgb:ffff/ffff/ffff\u{1b}\\".utf8))
        let query = try XCTUnwrap(feedback.beginHostColorQuery())
        let output = String(decoding: query.output, as: UTF8.self)
        XCTAssertTrue(output.hasPrefix("\u{1b}[5n")); XCTAssertTrue(output.hasSuffix("\u{1b}[5n"))
        XCTAssertTrue(output.contains("\u{1b}]4;255;?\u{1b}\\"))
        XCTAssertNil(feedback.beginHostColorQuery(), "Queries must not overlap")
        XCTAssertFalse(feedback.hostColorQueryResult(query.id).finished)
        for byte in hostColorReplies() { feedback.receive(Data([byte])) }
        let result = feedback.hostColorQueryResult(query.id)
        XCTAssertTrue(result.finished)
        let colors = try XCTUnwrap(result.colors)
        XCTAssertEqual(colors.foreground, .init(r: 17, g: 34, b: 51))
        XCTAssertEqual(colors.background, .init(r: 171, g: 205, b: 239))
        XCTAssertEqual(colors.palette.count, 256)
        XCTAssertEqual(colors.palette[255], .init(r: 255, g: 0, b: 128))
        let incomplete = try XCTUnwrap(feedback.beginHostColorQuery())
        feedback.receive(hostColorReplies(includeBackground: false))
        XCTAssertTrue(feedback.hostColorQueryResult(incomplete.id).finished)
        XCTAssertNil(feedback.hostColorQueryResult(incomplete.id).colors, "Never publish a partially populated theme")
        XCTAssertNil(feedback.hostColorQueryResult(query.id).colors, "Old query IDs cannot read a new result")
    }

    func testCancelledColorQueryDrainsAndMalformedRepliesRemainBounded() throws {
        let feedback = HerdrShellDisplayFeedback(), failures = Failures()
        feedback.setHandler { failures.append($0) }
        let old = try XCTUnwrap(feedback.beginHostColorQuery())
        feedback.cancelHostColorQuery(old.id)
        XCTAssertNil(feedback.beginHostColorQuery(), "Cancellation must retain the old reply boundaries")
        feedback.receive(hostColorReplies())
        XCTAssertNil(feedback.hostColorQueryResult(old.id).colors)
        let next = try XCTUnwrap(feedback.beginHostColorQuery())
        feedback.receive(Data("\u{1b}]10;rgb:".utf8) + Data(repeating: 120, count: 20_000))
        feedback.receive(Data("\u{1b}\\\u{1b}_Gi=9;ENOENT\u{1b}\\\u{1b}[1n".utf8))
        XCTAssertFalse(feedback.hostColorQueryResult(next.id).finished)
        feedback.receive(Data("\u{1b}[0n\u{1b}]10;rgb:+fff/ffff/ffff\u{7}\u{1b}]11;rgb:00000/0/0\u{7}\u{1b}]4;256;rgb:ff/ff/ff\u{7}\u{1b}[0n".utf8))
        XCTAssertNil(feedback.hostColorQueryResult(next.id).colors)
        XCTAssertEqual(failures.snapshot(), [.init(imageID: 9, message: "ENOENT")])
        feedback.resetHostColorQueries()
        XCTAssertNotNil(feedback.beginHostColorQuery())
    }

    private final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [HerdrShellDisplayFeedback.Failure] = []
        func append(_ value: HerdrShellDisplayFeedback.Failure) { lock.lock(); values.append(value); lock.unlock() }
        func snapshot() -> [HerdrShellDisplayFeedback.Failure] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func testDisplayFeedbackHandlesFragmentsLimitsAndIgnoresOtherReplies() {
        let feedback = HerdrShellDisplayFeedback(), failures = Failures()
        feedback.setHandler { failures.append($0) }
        let reply = Data("\u{1b}[0n\u{1b}_Gi=7,p=2;EINVAL: bad image\u{1b}\\\u{1b}_Gi=8;OK\u{1b}\\".utf8)
        for byte in reply { feedback.receive(Data([byte])) }
        XCTAssertEqual(failures.snapshot(), [.init(imageID: 7, message: "EINVAL: bad image")])
        feedback.receive(Data("\u{1b}_Gi=0;bad\u{1b}\\\u{1b}_Gi=2,i=3;bad\u{1b}\\\u{1b}_Gx=1;bad\u{1b}\\".utf8))
        XCTAssertEqual(failures.snapshot().count, 1)
        feedback.receive(Data("\u{1b}_Gi=9;".utf8) + Data(repeating: 120, count: 20_000))
        feedback.receive(Data("\u{1b}\\\u{1b}_Gi=10;ENOENT\nimage\u{1b}\\".utf8))
        XCTAssertEqual(failures.snapshot().last, .init(imageID: 10, message: "ENOENTimage"))
        feedback.receive(Data("\u{1b}_Gi=11;partial".utf8))
        feedback.setHandler(nil)
        feedback.receive(Data("\u{1b}\\\u{1b}_Gi=12;bad\u{1b}\\".utf8))
        XCTAssertEqual(failures.snapshot().count, 2, "Retired display callbacks and partial replies are cleared")
    }

    func testSurfaceLayoutProjectionWithAndWithoutSplitHandles() throws {
        func pane(_ id: String, _ rect: HerdrShellRect) -> HerdrShellPane {
            .init(pane_id: id, content_revision: 1, rect: rect, inner_rect: rect, scrollbar_rect: nil,
                  scroll: nil, focused: id == "a", mouse_reporting: false, sgr_pixel_mouse: false,
                  alternate_screen_active: false, pixel_width: 0, pixel_height: 0)
        }
        let area = HerdrShellRect(x: 0, y: 0, width: 10, height: 6)
        let right = HerdrShellRect(x: 4, y: 0, width: 6, height: 6)
        let panes = [pane("a", .init(x: 0, y: 0, width: 4, height: 6)),
                     pane("b", .init(x: 4, y: 0, width: 6, height: 2)),
                     pane("c", .init(x: 4, y: 2, width: 6, height: 4))]
        func surface(_ panes: [HerdrShellPane], _ splits: [HerdrShellSplit] = []) -> HerdrShellSurface {
            .init(boot_id: "boot", projection_revision: 1, surface_revision: 1,
                  frame: .init(cells: Array(repeating: cell(" "), count: 60), width: 10, height: 6,
                               cursor: nil, hyperlinks: [], graphics: Data()), panes: panes, splits: splits,
                  popup: nil, graphics: .init(assets: [], placements: [], retained_assets: []))
        }
        let tree = HerdrLayout.Node.split(.horizontal, 0.9, .pane("a"),
            .split(.vertical, 0.9, .pane("b"), .pane("c")))
        let ids = ["a": UUID(), "b": UUID(), "c": UUID()]
        let expected = LayoutNode.split(axis: .horizontal, children: [.panel(ids["a"]!),
            .split(axis: .vertical, children: [.panel(ids["b"]!), .panel(ids["c"]!)], fractions: [1.0 / 3, 1 - 1.0 / 3])], fractions: [0.4, 0.6])
        XCTAssertEqual(try tree.projected(on: surface(panes)).nativeLayout(panes: ids), expected)
        let root = HerdrShellSplit(horizontal: true, pos: 4, area: area,
                                  hit_rect: .init(x: 4, y: 0, width: 1, height: 6), path: [])
        let child = HerdrShellSplit(horizontal: false, pos: 2, area: right,
                                   hit_rect: .init(x: 4, y: 2, width: 6, height: 1), path: [true])
        let withHandles = try tree.projected(on: surface(panes, [child, root])).nativeLayout(panes: ids)
        XCTAssertEqual(withHandles, expected, "Handle order does not define tree order")
        let projected = try tree.projected(on: surface(panes))
        let calibrated = try projected.nativeShellLayout(panes: ids, surface: surface(panes),
            cellSize: .init(width: 8, height: 16), padding: 8, divider: 6).layout
        guard case .split(.horizontal, let children, let fractions) = calibrated,
              case .split(.vertical, _, let nested) = children[1] else { return XCTFail("Native chrome lost the backend tree") }
        XCTAssertEqual(fractions[0], 48.0 / 112, accuracy: 0.0001)
        XCTAssertEqual(nested[0], 48.0 / 128, accuracy: 0.0001,
                       "Each child needs its own padding in addition to backend cell dimensions")
        let gapped = [pane("a", .init(x: 0, y: 0, width: 3, height: 6)),
                      pane("b", .init(x: 5, y: 0, width: 5, height: 2)),
                      pane("c", .init(x: 5, y: 2, width: 5, height: 4))]
        XCTAssertEqual(try tree.projected(on: surface(gapped, [root])).nativeLayout(panes: ids), expected)
        XCTAssertThrowsError(try tree.projected(on: surface(panes, [root, root])))
        let wrong = HerdrShellSplit(horizontal: false, pos: 4, area: area, hit_rect: root.hit_rect, path: [])
        XCTAssertThrowsError(try tree.projected(on: surface(panes, [wrong])))
        XCTAssertThrowsError(try tree.projected(on: surface([panes[0], panes[1]])))
        let swapped = HerdrLayout.Node.split(.horizontal, 0.5, .pane("b"), .split(.vertical, 0.5, .pane("a"), .pane("c")))
        XCTAssertThrowsError(try swapped.projected(on: surface(panes)))
        XCTAssertEqual(try tree.projected(on: surface([pane("b", area)])).paneIDs, ["b"], "Zoom shows only the authoritative visible pane")
        XCTAssertThrowsError(try tree.projected(on: surface([pane("unknown", area)])))
    }

    func testNativeViewportReclaimsBackendBordersAndGaps() throws {
        func pane(_ id: String, _ rect: HerdrShellRect, inset: UInt16) -> HerdrShellPane {
            .init(pane_id: id, content_revision: 1, rect: rect,
                inner_rect: .init(x: rect.x + inset, y: rect.y + inset,
                    width: rect.width - inset * 2, height: rect.height - inset * 2),
                scrollbar_rect: nil, scroll: nil, focused: id == "a", mouse_reporting: false,
                sgr_pixel_mouse: false, alternate_screen_active: false, pixel_width: 0, pixel_height: 0)
        }
        func surface(_ panes: [HerdrShellPane], width: UInt16 = 80, height: UInt16 = 24) -> HerdrShellSurface {
            .init(boot_id: "boot", projection_revision: 1, surface_revision: 1,
                frame: .init(cells: Array(repeating: cell(" "), count: Int(width) * Int(height)),
                    width: width, height: height, cursor: nil, hyperlinks: [], graphics: Data()),
                panes: panes, splits: [], popup: nil,
                graphics: .init(assets: [], placements: [], retained_assets: []))
        }
        let ids = ["a": UUID(), "b": UUID(), "c": UUID()]
        let cellSize = CGSize(width: 8, height: 16)
        func viewport(_ tree: HerdrLayout.Node, _ surface: HerdrShellSurface, _ available: CGSize) throws -> HerdrShellSize? {
            let geometry = try tree.nativeShellLayout(panes: ids, surface: surface,
                cellSize: cellSize, padding: 8, divider: 6)
            return HerdrLayout.nativeShellViewportSize(surface: surface, nativeSize: geometry.size,
                availableSize: available, cellSize: cellSize)
        }
        let horizontal = HerdrLayout.Node.split(.horizontal, 0.5, .pane("a"), .pane("b"))
        let bordered = surface([pane("a", .init(x: 0, y: 0, width: 40, height: 24), inset: 1),
                                pane("b", .init(x: 40, y: 0, width: 40, height: 24), inset: 1)])
        let available = CGSize(width: 678, height: 400)
        XCTAssertEqual(try viewport(horizontal, bordered, available), .init(cols: 84, rows: 26))
        let resized = surface([pane("a", .init(x: 0, y: 0, width: 42, height: 26), inset: 1),
                               pane("b", .init(x: 42, y: 0, width: 42, height: 26), inset: 1)], width: 84, height: 26)
        XCTAssertEqual(try viewport(horizontal, resized, available), .init(cols: 84, rows: 26),
                       "Repeated scenes must not accumulate compensation")
        let borderless = surface([pane("a", .init(x: 0, y: 0, width: 40, height: 24), inset: 0),
                                  pane("b", .init(x: 40, y: 0, width: 40, height: 24), inset: 0)])
        XCTAssertEqual(try viewport(horizontal, borderless, available), .init(cols: 80, rows: 24))
        let gapped = surface([pane("a", .init(x: 0, y: 0, width: 39, height: 24), inset: 0),
                              pane("b", .init(x: 40, y: 0, width: 40, height: 24), inset: 0)])
        XCTAssertEqual(try viewport(horizontal, gapped, available), .init(cols: 81, rows: 24))
        let vertical = HerdrLayout.Node.split(.vertical, 0.5, .pane("a"), .pane("b"))
        let stacked = surface([pane("a", .init(x: 0, y: 0, width: 80, height: 12), inset: 1),
                               pane("b", .init(x: 0, y: 12, width: 80, height: 12), inset: 1)])
        XCTAssertEqual(try viewport(vertical, stacked, .init(width: 656, height: 422)), .init(cols: 82, rows: 28))
        let mixed = HerdrLayout.Node.split(.horizontal, 0.5, .pane("a"),
            .split(.vertical, 0.5, .pane("b"), .pane("c")))
        let nested = surface([bordered.panes[0],
            pane("b", .init(x: 40, y: 0, width: 40, height: 12), inset: 1),
            pane("c", .init(x: 40, y: 12, width: 40, height: 12), inset: 1)])
        XCTAssertEqual(try viewport(mixed, nested, available), .init(cols: 84, rows: 26),
                       "Mixed splits must use the reconstructed native size, not the deepest padding count")
        let single = surface([pane("a", .init(x: 0, y: 0, width: 80, height: 24), inset: 0)])
        XCTAssertEqual(try viewport(.pane("a"), single, .init(width: 659, height: 407)), .init(cols: 80, rows: 24),
                       "Sub-cell remainder stays as normal padding")
        XCTAssertNil(try viewport(.pane("a"), single, .zero))
    }

    private func cell(_ text: String, fg: UInt32 = 0, modifier: UInt16 = 0, link: UInt32? = nil) -> HerdrShellCell {
        .init(symbol: text, fg: fg, bg: 0, modifier: modifier, skip: false, hyperlink: link)
    }
    private func key(_ fingerprint: UInt64 = 1, size: UInt32 = 1, format: UInt32 = 1, length: UInt64? = nil) -> HerdrShellAssetKey {
        .init(source: .pane("p1", 7), image_width: size, image_height: size, format: format,
              data_len: length ?? UInt64(size) * UInt64(size) * 4, data_fingerprint: fingerprint)
    }
    private func placement(_ key: HerdrShellAssetKey, x: UInt16 = 1, y: UInt16 = 1) -> HerdrShellPlacement {
        .init(asset: key, logical_placement_id: 3, x: x, y: y, cols: 1, rows: 1,
              source_x: 0, source_y: 0, source_width: key.image_width, source_height: key.image_height,
              x_offset: 0, y_offset: 0, z: 1, scrollback_offset: 0)
    }
    private func scene(placements: [HerdrShellPlacement] = [], retained: Set<HerdrShellAssetKey> = []) throws -> HerdrShellViewportFrame {
        var cells = Array(repeating: cell("#"), count: 18)
        cells.replaceSubrange(7..<11, with: [cell("A", fg: 0x02112233, modifier: 0x3008, link: 0), cell("界"), cell(" "), cell("B")])
        let frame = HerdrShellFrame(cells: cells, width: 6, height: 3,
            cursor: .init(x: 4, y: 1, visible: true, shape: 2), hyperlinks: ["https://example.com"], graphics: Data())
        let pane = HerdrShellPane(pane_id: "p1", content_revision: 1, rect: .init(x: 0, y: 0, width: 6, height: 3),
            inner_rect: .init(x: 1, y: 1, width: 4, height: 1), scrollbar_rect: nil, scroll: nil, focused: true,
            mouse_reporting: false, sgr_pixel_mouse: false, alternate_screen_active: false, pixel_width: 32, pixel_height: 16)
        let surface = HerdrShellSurface(boot_id: "boot", projection_revision: 1, surface_revision: 1, frame: frame,
            panes: [pane], splits: [], popup: nil, graphics: .init(assets: [], placements: placements, retained_assets: Array(retained)))
        return try .extract(.pane("p1"), from: surface)
    }

    func testPaneExtractionAndStyleCursorWideGlyphs() throws {
        let viewport = try scene()
        XCTAssertEqual(viewport.cells(in: 0).map(\.symbol), ["A", "界", " ", "B"])
        XCTAssertEqual(viewport.cursor?.x, 3)
        XCTAssertEqual(viewport.cursor?.y, 0)
        var renderer = HerdrClientShellRenderer()
        let text = String(decoding: try renderer.render(viewport, assets: [:]), as: UTF8.self)
        XCTAssertFalse(text.contains("#"))
        XCTAssertTrue(text.hasPrefix("\u{1b}[?1049h"), "Projected scenes must not create local terminal history")
        XCTAssertTrue(text.contains("38;2;17;34;51"))
        XCTAssertTrue(text.contains("4:3"))
        XCTAssertTrue(text.contains("\u{1b}]8;;https://example.com\u{1b}\\"))
        XCTAssertTrue(text.contains("\u{1b}[1;4H"))
        XCTAssertFalse(text.contains("\u{1b}[1;3H"), "Do not overwrite the trailing cell of a wide glyph")
        let repeatFrame = String(decoding: try renderer.render(viewport, assets: [:]), as: UTF8.self)
        XCTAssertFalse(repeatFrame.contains("界"))
        XCTAssertFalse(repeatFrame.contains("[2J"))
        XCTAssertFalse(repeatFrame.contains("[?1049h"), "Steady frames retain their display and image state")
    }

    func testImagesUploadOnceReplaceDeleteAndRebuild() throws {
        var renderer = HerdrClientShellRenderer()
        let red = Data([255, 0, 0, 255]), blue = Data([0, 0, 255, 255])
        let first = try scene(placements: [placement(key())])
        let initial = String(decoding: try renderer.render(first, assets: [key(): red]), as: UTF8.self)
        XCTAssertTrue(initial.contains("a=t,t=d,f=32,s=1,v=1,i=1"))
        XCTAssertTrue(initial.contains("a=p,i=1,p=1"))
        XCTAssertTrue(initial.contains("\u{1b}[1;1H\u{1b}_Ga=p"), "Placement must use pane-relative coordinates")
        XCTAssertFalse(String(decoding: try renderer.render(first, assets: [:]), as: UTF8.self).contains("a=t"))
        let replacement = try scene(placements: [placement(key(2))])
        let waiting = String(decoding: try renderer.render(replacement, assets: [:]), as: UTF8.self)
        XCTAssertFalse(waiting.contains("a=d"), "Deferred pixels must not erase the previously displayed image")
        let replaced = String(decoding: try renderer.render(replacement, assets: [key(2): blue]), as: UTF8.self)
        XCTAssertTrue(replaced.contains("a=t,t=d,f=32,s=1,v=1,i=2"))
        XCTAssertTrue(replaced.contains("a=d,d=I,i=1"))
        let removed = String(decoding: try renderer.render(scene(), assets: [:]), as: UTF8.self)
        XCTAssertTrue(removed.contains("a=d,d=i,i=2"))
        XCTAssertTrue(removed.contains("a=d,d=I,i=2"))
        renderer.reset()
        XCTAssertFalse(renderer.ownsImage(2))
        let rebuilt = String(decoding: try renderer.render(first, assets: [key(): red]), as: UTF8.self)
        XCTAssertTrue(rebuilt.contains("a=t,t=d,f=32,s=1,v=1,i=3"))
        XCTAssertTrue(rebuilt.hasPrefix("\u{1b}[?1049h"))
        XCTAssertTrue(renderer.ownsImage(3), "A late reply for image 1 or 2 cannot refer to the rebuilt scene")
    }

    func testRetainedAssetsHideAndRedisplayWithoutUpload() throws {
        var renderer = HerdrClientShellRenderer()
        let pixels = Data([255, 0, 0, 255]), image = key()
        _ = try renderer.render(scene(placements: [placement(image)]), assets: [image: pixels])
        let hidden = String(decoding: try renderer.render(scene(retained: [image]), assets: [:]), as: UTF8.self)
        XCTAssertTrue(hidden.contains("a=d,d=i"))
        XCTAssertFalse(hidden.contains("a=d,d=I"))
        let shown = String(decoding: try renderer.render(scene(placements: [placement(image)]), assets: [:]), as: UTF8.self)
        XCTAssertTrue(shown.contains("a=p"))
        XCTAssertFalse(shown.contains("a=t"))
    }

    func testChunkedUploadRoundTripsAndRejectedSceneDoesNotAdvanceBaseline() throws {
        var renderer = HerdrClientShellRenderer()
        let image = key(size: 32), pixels = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0) })
        let viewport = try scene(placements: [placement(image)])
        let text = String(decoding: try renderer.render(viewport, assets: [image: pixels]), as: UTF8.self)
        let chunks = text.components(separatedBy: "\u{1b}_G").dropFirst().compactMap { part -> String? in
            guard let semicolon = part.firstIndex(of: ";"), part[..<semicolon].contains("m=") else { return nil }
            return String(part[part.index(after: semicolon)...].components(separatedBy: "\u{1b}\\")[0])
        }
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(Data(base64Encoded: chunks.joined()), pixels)
        XCTAssertTrue(text.contains("m=1;")); XCTAssertTrue(text.contains("m=0;"))
        XCTAssertThrowsError(try renderer.render(scene(placements: [placement(image, x: 6)]), assets: [image: pixels]))
        let unchanged = String(decoding: try renderer.render(viewport, assets: [:]), as: UTF8.self)
        XCTAssertFalse(unchanged.contains("a=t"))
        XCTAssertFalse(unchanged.contains("a=p"))
    }

    func testControlCharactersCannotInjectTerminalCommands() throws {
        let bad = cell("x\u{1b}]52;c;aGk=\u{7}", link: 0)
        let frame = HerdrShellFrame(cells: [bad], width: 1, height: 1, cursor: nil,
            hyperlinks: ["https://example.com\u{1b}]52;c;aGk=\u{7}"], graphics: Data())
        let viewport = HerdrShellViewportFrame(frame: frame, originX: 0, originY: 0, placements: [], retained: [])
        var renderer = HerdrClientShellRenderer()
        let text = String(decoding: try renderer.render(viewport, assets: [:]), as: UTF8.self)
        XCTAssertFalse(text.contains("\u{1b}]52"))
        XCTAssertFalse(text.contains("\u{7}"))
    }

    func testPopupUsesItsOwnFrameAndCoordinateSpace() throws {
        let image = HerdrShellAssetKey(source: .popup("popup-1", 7), image_width: 1, image_height: 1,
                                      format: 1, data_len: 4, data_fingerprint: 1)
        let frame = HerdrShellFrame(cells: [cell("p")], width: 1, height: 1,
                                   cursor: .init(x: 0, y: 0, visible: true, shape: 2), hyperlinks: [], graphics: Data())
        let popup = HerdrShellPopup(terminal_id: "popup-1", title: "popup", width: 1, height: 1,
            widthIsPercent: false, heightIsPercent: false, frame: frame, mouse_reporting: false,
            sgr_pixel_mouse: false, pixel_width: 8, pixel_height: 16)
        var surface = HerdrShellSurface(boot_id: "boot", projection_revision: 1, surface_revision: 1, frame: frame,
            panes: [], splits: [], popup: popup, graphics: .init(assets: [], placements: [placement(image, x: 0, y: 0)], retained_assets: []))
        surface.recordCellDamage([])
        let viewport = try HerdrShellViewportFrame.extract(.popup("popup-1"), from: surface)
        XCTAssertEqual(viewport.frame, frame)
        XCTAssertEqual(viewport.originX, 0)
        var renderer = HerdrClientShellRenderer()
        let text = String(decoding: try renderer.render(viewport, assets: [image: Data([255, 0, 0, 255])]), as: UTF8.self)
        XCTAssertTrue(text.contains("\u{1b}[1;1H\u{1b}_Ga=p"))
        surface.surface_revision += 1
        surface.popup?.frame.replaceCells([cell("q")], x: 0, y: 0)
        let changed = try renderer.render(.extract(.popup("popup-1"), from: surface), assets: [:])
        XCTAssertTrue(String(decoding: changed, as: UTF8.self).contains("q"), "Main-grid damage cannot hide popup edits")
        XCTAssertThrowsError(try HerdrShellViewportFrame.extract(.popup("other"), from: surface))
    }

    private final class Replies: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ bytes: Data) { lock.lock(); data.append(bytes); lock.unlock() }
        func contains(_ text: String) -> Bool { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self).contains(text) }
        func count(_ text: String) -> Int { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self).components(separatedBy: text).count - 1 }
    }

    @MainActor
    func testBackendResizeRepaintsEveryRowAndCursorInRealGhostty() async throws {
        do {
            let replies = Replies()
            let feedback = HerdrShellDisplayFeedback()
            let memory = InMemoryTerminalSession(write: { bytes in
                replies.append(bytes)
                for byte in bytes { feedback.receive(Data([byte])) }
            }, resize: { _ in feedback.invalidateViewport() })
            let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
            terminal.configuration = .init(backend: .inMemory(memory))
            let config = TerminalConfiguration(startingFrom: TerminalDefaults.configuration) { builder in
                builder.withCustom("window-padding-x", "0")
                builder.withCustom("window-padding-y", "0")
                builder.withCustom("window-padding-balance", "false")
            }
            terminal.controller = TerminalController(configuration: config, theme: TerminalDefaults.theme)
            let host = TerminalPaneHostView(paneID: UUID(), terminalView: terminal)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                  styleMask: [], backing: .buffered, defer: false)
            window.contentView = host; window.orderBack(nil); host.layoutSubtreeIfNeeded(); terminal.fitToSize()
            defer { window.orderOut(nil); window.contentView = nil }
            for _ in 0..<100 where terminal.scrollModeGrid == nil { try await Task.sleep(for: .milliseconds(10)) }
            let grid = try XCTUnwrap(terminal.scrollModeGrid)
            let scale = terminal.convertToBacking(NSSize(width: 1, height: 1))
            var renderer = HerdrClientShellRenderer()
            for (cols, rows) in [(80, 24), (40, 12), (100, 30), (25, 8), (80, 24), (80, 24)] {
                host.setFixedTerminalSize(NSSize(width: CGFloat(cols) * CGFloat(grid.cellWidthPixels) / scale.width,
                                                height: CGFloat(rows) * CGFloat(grid.cellHeightPixels) / scale.height))
                terminal.fitToSize()
                XCTAssertEqual(terminal.scrollModeGrid?.columns, UInt16(cols))
                XCTAssertEqual(terminal.scrollModeGrid?.rows, UInt16(rows))
                try await feedback.waitForViewport(.init(cols: UInt16(cols), rows: UInt16(rows)), in: memory)
                let response = "\u{1b}[8;\(rows);\(cols)t"
                let confirmations = replies.count(response)
                try await feedback.waitForViewport(.init(cols: UInt16(cols), rows: UInt16(rows)), in: memory)
                XCTAssertEqual(replies.count(response), confirmations, "Stable geometry must not query Ghostty every frame")
                feedback.invalidateViewport()
                try await feedback.waitForViewport(.init(cols: UInt16(cols), rows: UInt16(rows)), in: memory)
                XCTAssertGreaterThan(replies.count(response), confirmations, "Invalidated geometry must be confirmed again")
                let lines = (0..<rows).map { row in String(repeating: String(UnicodeScalar(65 + row % 26)!), count: cols) }
                let cells = lines.joined().map { cell(String($0)) }
                let frame = HerdrShellFrame(cells: cells, width: UInt16(cols), height: UInt16(rows),
                    cursor: .init(x: UInt16(cols - 1), y: UInt16(rows - 1), visible: true, shape: 2),
                    hyperlinks: [], graphics: Data())
                let viewport = HerdrShellViewportFrame(frame: frame, originX: 0, originY: 0, placements: [], retained: [])
                XCTAssertTrue(memory.receiveIfAttached(try renderer.render(viewport, assets: [:])))
                await Task.detached { memory.waitForPendingOutput() }.value
                XCTAssertEqual(memory.readViewportText(), lines.joined(separator: "\n"), "Backend grid \(cols)x\(rows)")
                let cursorReply = "\u{1b}[\(rows);\(cols)R"
                let previousReplies = replies.count(cursorReply)
                memory.receive("\u{1b}[6n")
                await Task.detached { memory.waitForPendingOutput() }.value
                // Draining the write queue does not drain Ghostty's asynchronous reply callback.
                for _ in 0..<100 where replies.count(cursorReply) == previousReplies {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertGreaterThan(replies.count(cursorReply), previousReplies, "Cursor at \(cols)x\(rows)")
            }
        } catch {
            XCTFail("Ghostty resize synchronization: \(error)")
        }
    }

    @MainActor
    func testRenderedCellsAndStoredKittyImageReachRealGhostty() async throws {
        let replies = Replies()
        let feedback = HerdrShellDisplayFeedback(), failures = Failures()
        feedback.setHandler { failures.append($0) }
        let memory = InMemoryTerminalSession(write: { replies.append($0); feedback.receive($0) }, resize: { _ in })
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        terminal.configuration = .init(backend: .inMemory(memory))
        terminal.controller = TerminalController(configuration: TerminalDefaults.configuration, theme: TerminalDefaults.theme)
        let window = NSWindow(contentRect: terminal.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = terminal; window.orderBack(nil); terminal.fitToSize()
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<100 where memory.readViewportText() == nil { try await Task.sleep(for: .milliseconds(10)) }
        let hostColors = try await feedback.queryHostColors(in: memory)
        XCTAssertEqual(hostColors.palette.count, 256)
        if let theme = TerminalDefaults.themeDefinition {
            XCTAssertEqual(hostColors.foreground, HerdrShellRGB(hex: theme.foreground))
            XCTAssertEqual(hostColors.background, HerdrShellRGB(hex: theme.background))
            for (index, hex) in theme.palette {
                XCTAssertEqual(hostColors.palette[try XCTUnwrap(UInt8(exactly: index))], HerdrShellRGB(hex: hex))
            }
        }
        var renderer = HerdrClientShellRenderer()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 4, bitsPerPixel: 32))
        let pointer = try XCTUnwrap(bitmap.bitmapData)
        for (i, byte) in [UInt8(255), 0, 0, 255].enumerated() { pointer[i] = byte }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        for (format, pixels) in [(UInt32(1), Data([255, 0, 0, 255])), (UInt32(0), Data([255, 0, 0])), (UInt32(2), png)] {
            let image = key(UInt64(format + 1), format: format, length: UInt64(pixels.count))
            memory.receive(try renderer.render(scene(placements: [placement(image)]), assets: [image: pixels]))
            for _ in 0..<100 where memory.readViewportText()?.contains("A界B") != true { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(memory.readViewportText()?.contains("A界B") == true)
            let id = format == 1 ? 1 : format == 0 ? 2 : 3
            // Re-place the generated image ID to prove the upload reached Ghostty storage.
            memory.receive("\u{1b}_Ga=p,i=\(id),p=1234,c=1,r=1,q=0;\u{1b}\\")
            for _ in 0..<100 where !replies.contains("i=\(id),p=1234;OK") { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(replies.contains("i=\(id),p=1234;OK"), "Missing stored image for format \(format)")
        }
        memory.receive("\u{1b}_Ga=p,i=999999,c=1,r=1,q=0;\u{1b}\\")
        for _ in 0..<100 where !failures.snapshot().contains(where: { $0.imageID == 999999 }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(failures.snapshot().contains(where: { $0.imageID == 999999 && $0.message.hasPrefix("ENOENT") }),
                      "Real Ghostty image failures must reach the feedback parser")
        var commits: [String] = [], keys: [UInt16] = []
        terminal.semanticTextCommitHandler = { commits.append($0) }
        terminal.semanticKeyHandler = { event, _, _ in keys.append(event.keyCode) }
        terminal.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(terminal.hasMarkedText())
        XCTAssertEqual(terminal.markedRange().length, 2)
        terminal.insertText(NSAttributedString(string: "中文"), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(terminal.hasMarkedText()); XCTAssertEqual(commits, ["中文"])
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        terminal.keyDown(with: enter)
        XCTAssertEqual(keys, [36], "Hardware Enter is sent semantically once, without the in-memory VT shortcut")
        XCTAssertEqual(commits, ["中文"], "Key and IME commit must not duplicate each other")
    }

    @MainActor
    func testSparseEditsRepairWideGlyphsInRealGhostty() async throws {
        let memory = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        terminal.configuration = .init(backend: .inMemory(memory))
        terminal.controller = TerminalController(configuration: TerminalDefaults.configuration, theme: TerminalDefaults.theme)
        let window = NSWindow(contentRect: terminal.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = terminal; window.orderBack(nil); terminal.fitToSize()
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<100 where memory.readViewportText() == nil { try await Task.sleep(for: .milliseconds(10)) }
        var renderer = HerdrClientShellRenderer()
        for (symbol, expected) in [("界", "界Z....!"), ("A", "A Z....!"), ("😀", "😀Z....!"), ("é", "é Z....!")] {
            let frame = HerdrShellFrame(cells: [cell(symbol), cell(" "), cell("Z"), cell("."), cell("."), cell("."), cell("."), cell("!")],
                width: 8, height: 1, cursor: nil, hyperlinks: [], graphics: Data())
            let output = try renderer.render(.init(frame: frame, originX: 0, originY: 0, placements: [], retained: []), assets: [:])
            XCTAssertTrue(memory.receiveIfAttached(output))
            await Task.detached { memory.waitForPendingOutput() }.value
            XCTAssertEqual(memory.readViewportText()?.components(separatedBy: "\n").first, expected)
        }
    }
}
