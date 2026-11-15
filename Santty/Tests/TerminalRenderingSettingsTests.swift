import AppKit
import XCTest
@testable import Santty

private final class RenderingChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@MainActor
final class TerminalRenderingSettingsTests: XCTestCase {
    private enum SimulatedFailure: Error { case unavailable }

    private func preferences() throws -> (String, UserDefaults) {
        let name = "santty-rendering-test.\(UUID())"
        return (name, try XCTUnwrap(UserDefaults(suiteName: name)))
    }

    private func pane(
        id: UUID = UUID(),
        engine: @escaping @MainActor () -> TerminalSettings.RenderingEngine,
        configure: @escaping @MainActor (NativeTerminalScrollView, TerminalSettings.RenderingEngine) throws -> Void = {
            try $0.setMetal($1 == .metal)
        }
    ) throws -> TerminalPaneController {
        // This owner is never started: no process, user shell/profile or files.
        let launch = try NativeLocalPTYLaunch(paneID: id, executable: "/bin/sh", arguments: [],
            environment: ["HOME": "/unused-santty-rendering-test"], workingDirectory: "/unused-santty-rendering-test")
        let owner = NativeTerminalPaneSession.local(launch: launch, driver: try GhosttyVTDriver())
        return TerminalPaneController(id: id, session: owner,
            renderingEngineProvider: engine, configureRenderer: configure)
    }

    func testPreferenceDefaultInvalidValuePersistenceAndReset() throws {
        let (name, defaults) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(TerminalSettings.readRenderingEngine(from: defaults), .coreGraphics)
        XCTAssertNil(defaults.object(forKey: "terminal.renderingEngine"), "Reading must not write defaults")
        defaults.set("unknown-renderer", forKey: "terminal.renderingEngine")
        XCTAssertEqual(TerminalSettings.readRenderingEngine(from: defaults), .coreGraphics)
        XCTAssertEqual(defaults.string(forKey: "terminal.renderingEngine"), "unknown-renderer")
        TerminalSettings.setRenderingEngine(.metal, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "terminal.renderingEngine"), "metal")
        XCTAssertEqual(TerminalSettings.readRenderingEngine(from: try XCTUnwrap(UserDefaults(suiteName: name))), .metal)
        TerminalSettings.resetRenderingEngine(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "terminal.renderingEngine"))
        XCTAssertEqual(TerminalSettings.readRenderingEngine(from: defaults), .coreGraphics)
    }

    func testPreferenceChangesUseExistingNotification() throws {
        let (name, defaults) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let count = RenderingChangeCounter()
        let token = NotificationCenter.default.addObserver(forName: TerminalSettings.didChangeNotification,
            object: nil, queue: nil) { _ in count.increment() }
        defer { NotificationCenter.default.removeObserver(token) }
        _ = TerminalSettings.readRenderingEngine(from: defaults)
        XCTAssertEqual(count.value, 0)
        TerminalSettings.setRenderingEngine(.metal, defaults: defaults)
        TerminalSettings.setRenderingEngine(.coreGraphics, defaults: defaults)
        TerminalSettings.resetRenderingEngine(defaults: defaults)
        XCTAssertEqual(count.value, 3)
    }

    func testNewPaneUsesPersistedMetalPreferenceWithoutStartingSession() throws {
        let (name, defaults) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        TerminalSettings.setRenderingEngine(.metal, defaults: defaults)
        let pane = try pane(engine: { TerminalSettings.readRenderingEngine(from: defaults) })
        XCTAssertEqual(pane.renderingEngine, .metal)
        XCTAssertNil(pane.renderingWarning)
        XCTAssertTrue(pane.isLive)
        XCTAssertFalse(pane.hasStarted)
        XCTAssertEqual(pane.session?.localSession?.state, .idle)
    }

    func testSwitchPreservesDriverHistoryZoomSelectionAndResponder() throws {
        var choice = TerminalSettings.RenderingEngine.coreGraphics
        let pane = try pane(engine: { choice })
        let owner = try XCTUnwrap(pane.session), view = try XCTUnwrap(pane.terminalView)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 720, height: 480),
            styleMask: [], backing: .buffered, defer: false)
        window.contentView = pane.hostView
        defer { window.contentView = nil }
        pane.hostView.layoutSubtreeIfNeeded()
        let old = try XCTUnwrap(view.settings)
        let zoom = NativeTerminalSettings(theme: old.theme, fontFamily: old.fontFamily,
            fontSize: old.fontSize + 3, padding: old.padding, backgroundOpacity: old.backgroundOpacity,
            cursorShape: old.cursorShape, cursorBlink: old.cursorBlink)
        try view.applySettings(zoom)
        _ = try view.synchronizeViewport()
        owner.output.receive(Data(("\u{1b}]2;renderer sentinel\u{7}" +
            (1...100).map { "history-\($0) 中文🙂\r\n" }.joined()).utf8))
        XCTAssertTrue(window.makeFirstResponder(view.renderer))
        XCTAssertTrue(view.scrollModeController.enter())
        view.scrollModeController.move(.top)
        view.scrollModeController.toggleSelection(linewise: true)
        let selection = try XCTUnwrap(owner.driver.readScrollModeSelection())
        let text = try owner.driver.readScreenText(), epoch = owner.driver.metadata.resetEpoch
        let lease = owner.output.userInputLease, responder = window.firstResponder
        let columns = owner.driver.columns, rows = owner.driver.rows
        for engine in [TerminalSettings.RenderingEngine.metal, .coreGraphics] {
            choice = engine; pane.applyTerminalSettings()
            XCTAssertEqual(pane.renderingEngine, engine)
            XCTAssertNil(pane.renderingWarning)
            XCTAssertTrue(pane.session === owner); XCTAssertTrue(view.driver === owner.driver)
            XCTAssertEqual(try owner.driver.readScreenText(), text)
            XCTAssertEqual(owner.driver.metadata.resetEpoch, epoch)
            XCTAssertEqual(owner.driver.metadata.title, "renderer sentinel")
            XCTAssertEqual(owner.output.userInputLease, lease)
            XCTAssertEqual(owner.driver.columns, columns); XCTAssertEqual(owner.driver.rows, rows)
            XCTAssertEqual(view.settings, zoom, "Renderer-only changes must not reset per-pane font zoom")
            XCTAssertTrue(view.scrollModeController.isActive)
            XCTAssertEqual(try owner.driver.readScrollModeSelection(), selection)
            XCTAssertTrue(window.firstResponder === responder)
            XCTAssertFalse(owner.hasStarted)
        }
        view.scrollModeController.exit()
    }

    func testFailureKeepsSessionLiveAndCurrentRendererWithoutRetryLoop() throws {
        var choice = TerminalSettings.RenderingEngine.coreGraphics, attempts = 0
        let pane = try pane(engine: { choice }, configure: { _, _ in
            attempts += 1; throw SimulatedFailure.unavailable
        })
        var exits = 0; pane.onExit = { _ in exits += 1 }
        let driver = try XCTUnwrap(pane.session?.driver)
        driver.feed("still readable")
        choice = .metal; pane.applyTerminalSettings()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(pane.renderingEngine, .coreGraphics)
        XCTAssertEqual(pane.renderingWarning, "Unable to switch to Metal. Using Core Graphics.")
        XCTAssertTrue(pane.isLive); XCTAssertEqual(exits, 0)
        XCTAssertTrue(try driver.readScreenText().contains("still readable"))
        for _ in 0..<3 { pane.applyTerminalSettings() }
        XCTAssertEqual(attempts, 1)
        choice = .coreGraphics; pane.applyTerminalSettings()
        XCTAssertNil(pane.renderingWarning)
        choice = .metal; pane.applyTerminalSettings()
        XCTAssertEqual(attempts, 2, "An explicit selection change may retry, not layout/metadata polling")
        XCTAssertTrue(pane.isLive); XCTAssertEqual(exits, 0)
    }

    func testNotificationUpdatesExistingForegroundAndBackgroundTabs() throws {
        var choice = TerminalSettings.RenderingEngine.coreGraphics
        let workspace = WorkspaceViewController(); workspace.debugLoadForTesting()
        let first = try XCTUnwrap(workspace.debugFocusedPaneID)
        workspace.debugNewTab()
        let second = try XCTUnwrap(workspace.debugFocusedPaneID)
        let a = try pane(id: first, engine: { choice }), b = try pane(id: second, engine: { choice })
        workspace.debugInstallPaneForCloseTesting(a); workspace.debugInstallPaneForCloseTesting(b)
        let selected = workspace.debugSelectedTabID
        choice = .metal
        NotificationCenter.default.post(name: TerminalSettings.didChangeNotification, object: nil)
        XCTAssertEqual(a.renderingEngine, .metal); XCTAssertEqual(b.renderingEngine, .metal)
        XCTAssertNil(a.renderingWarning); XCTAssertNil(b.renderingWarning)
        XCTAssertEqual(workspace.debugSelectedTabID, selected)
        XCTAssertFalse(a.hasStarted); XCTAssertFalse(b.hasStarted)
        choice = .coreGraphics
        NotificationCenter.default.post(name: TerminalSettings.didChangeNotification, object: nil)
        XCTAssertEqual(a.renderingEngine, .coreGraphics); XCTAssertEqual(b.renderingEngine, .coreGraphics)
        XCTAssertEqual(workspace.debugSelectedTabID, selected)
    }

    func testStaleControllerCannotApplyRenderingPreference() throws {
        var choice = TerminalSettings.RenderingEngine.coreGraphics
        let pane = try pane(engine: { choice })
        pane.isCurrent = { false }; choice = .metal
        pane.applyTerminalSettings()
        XCTAssertEqual(pane.renderingEngine, .coreGraphics)
        XCTAssertNil(pane.renderingWarning)
    }
}
