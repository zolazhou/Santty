import AppKit
import GhosttyVt
import Metal
@testable import SwiftTerm
import XCTest
@testable import Santty

@MainActor
final class NativeTerminalSettingsTests: XCTestCase {
    private func settings(_ name: String = "Catppuccin Mocha", size: CGFloat = 13, padding: CGFloat = 8, opacity: CGFloat = 1) throws -> NativeTerminalSettings {
        let catalog = try NativeThemeCatalog.bundled()
        return .init(theme: try XCTUnwrap(catalog.theme(named: name)), fontSize: size, padding: padding, backgroundOpacity: opacity)
    }

    func testFrozenCatalogPreservesAllNamesAndIndependentLiteralColors() throws {
        let catalog = try NativeThemeCatalog.bundled()
        XCTAssertEqual(catalog.themes.count, 485)
        XCTAssertEqual(Set(catalog.names).count, 485)
        XCTAssertNotNil(catalog.theme(named: "Black Metal (Bathory)"))
        let mocha = catalog.defaultTheme
        XCTAssertEqual(mocha.background, .init(red: 30, green: 30, blue: 46))
        XCTAssertEqual(mocha.foreground, .init(red: 205, green: 214, blue: 244))
        XCTAssertEqual(mocha.palette[1], .init(red: 243, green: 139, blue: 168))
        XCTAssertEqual(mocha.cursor, .init(red: 245, green: 224, blue: 220))
        XCTAssertEqual(mocha.cursorText, mocha.background)
        XCTAssertEqual(mocha.selectionBackground, .init(red: 88, green: 91, blue: 112))
        let day = try XCTUnwrap(catalog.theme(named: "3024 Day"))
        XCTAssertEqual(day.background, .init(red: 247, green: 247, blue: 247))
        XCTAssertEqual(day.palette[1], .init(red: 219, green: 45, blue: 32))
        XCTAssertEqual(day.selectionForeground, day.foreground)
    }

    func testMalformedInternalCatalogIsRejectedRatherThanSilentlyReplacingColors() throws {
        let entry: [String: Any] = ["name": "Catppuccin Mocha", "foreground": "ffffff", "background": "000000", "palette": ["0": "000000"]]
        func resource(_ themes: [[String: Any]], version: Int = 1) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["schemaVersion": version, "sourceRevision": NativeThemeCatalog.sourceRevision, "themes": themes])
        }
        XCTAssertNoThrow(try NativeThemeCatalog(data: resource([entry])))
        XCTAssertThrowsError(try NativeThemeCatalog(data: resource([entry], version: 2)))
        XCTAssertThrowsError(try NativeThemeCatalog(data: resource([entry, entry])))
        var bad = entry; bad["foreground"] = "not-a-color"
        XCTAssertThrowsError(try NativeThemeCatalog(data: resource([bad])))
        bad = entry; bad["palette"] = ["256": "ffffff"]
        XCTAssertThrowsError(try NativeThemeCatalog(data: resource([bad])))
        bad = entry; bad["palette"] = ["01": "ffffff"]
        XCTAssertThrowsError(try NativeThemeCatalog(data: resource([bad])))
    }

    func testExistingPreferenceKeysFallbackClampAndNoWrites() throws {
        let name = "santty-theme-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        // Clear only this privately allocated suite; never standard defaults.
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(" Missing Theme ", forKey: "terminal.themeName")
        defaults.set(" ", forKey: "terminal.fontFamily")
        defaults.set(100.0, forKey: "terminal.fontSize")
        defaults.set(-3.0, forKey: "terminal.padding")
        let before = defaults.dictionaryRepresentation()
        let value = NativeTerminalSettings.preferences(defaults, catalog: try NativeThemeCatalog.bundled())
        XCTAssertEqual(value.theme.name, "Catppuccin Mocha")
        XCTAssertEqual(value.fontFamily, "Menlo"); XCTAssertEqual(value.fontSize, 32)
        XCTAssertEqual(value.padding, 0); XCTAssertEqual(value.backgroundOpacity, 0)
        XCTAssertTrue(NSDictionary(dictionary: before).isEqual(to: defaults.dictionaryRepresentation()))
        let invalid = NativeTerminalSettings(theme: value.theme, fontFamily: "\0", fontSize: .nan, padding: .infinity, backgroundOpacity: .nan)
        XCTAssertEqual(invalid.fontSize, 13); XCTAssertEqual(invalid.padding, 8); XCTAssertEqual(invalid.fontFamily, "Menlo")
        XCTAssertEqual(invalid.backgroundOpacity, 0)
    }

    func testVTDefaultThemePreservesOSCOverridesThenResetsToNewDefaults() throws {
        let driver = try GhosttyVTDriver(columns: 20, rows: 3)
        try driver.applySettings(settings())
        driver.feed("kept\u{1b}]10;#00ff00\u{7}\u{1b}]4;1;#00ff00\u{7}\u{1b}]12;#00ff00\u{7}\u{1b}[6 q")
        try driver.applySettings(settings("3024 Day"))
        var frame = try driver.snapshot(topRow: 0)
        XCTAssertEqual(frame.foreground, .init(red: 0, green: 255, blue: 0))
        XCTAssertEqual(frame.palette[1], frame.foreground); XCTAssertEqual(frame.cursorColor, frame.foreground)
        XCTAssertEqual(frame.cursor.shape, .bar); XCTAssertFalse(frame.cursor.blinking)
        XCTAssertTrue(frame.rows.values.contains { $0.cells.compactMap(\.text).joined().contains("kept") })
        driver.feed("\u{1b}]110\u{7}\u{1b}]104;1\u{7}\u{1b}]112\u{7}\u{1b}[0 q")
        frame = try driver.snapshot(topRow: 0)
        let day = try settings("3024 Day")
        XCTAssertEqual(frame.foreground, day.theme.foreground)
        XCTAssertEqual(frame.palette[1], day.theme.palette[1]); XCTAssertEqual(frame.cursorColor, day.theme.cursor)
        XCTAssertEqual(frame.cursor.shape, .block); XCTAssertTrue(frame.cursor.blinking)
        driver.reset()
        XCTAssertEqual(try driver.snapshot(topRow: 0).background, day.theme.background)
    }

    func testSparsePaletteSwitchCannotLeakAnOldThemeIndex() throws {
        let driver = try GhosttyVTDriver()
        let original = try driver.snapshot(topRow: 0).palette[200], base = try settings().theme
        let extended = NativeTerminalTheme(name: "owned sparse", foreground: base.foreground, background: base.background,
            cursor: nil, cursorText: nil, selectionForeground: nil, selectionBackground: nil,
            palette: [200: .init(red: 1, green: 2, blue: 3)])
        try driver.applySettings(.init(theme: extended))
        XCTAssertEqual(try driver.snapshot(topRow: 0).palette[200], extended.palette[200])
        try driver.applySettings(settings())
        XCTAssertEqual(try driver.snapshot(topRow: 0).palette[200], original)
    }

    func testHostAppliesActualFontPaddingGeometryAndFallbackWithoutInputOrFocus() throws {
        let driver = try GhosttyVTDriver(), terminal = NativeTerminalScrollView(driver: driver)
        let host = NativeTerminalAppearanceHost(terminal: terminal)
        host.setFrameSize(.init(width: 640, height: 320))
        let window = NSWindow(contentRect: host.bounds, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        terminal.renderer.inputEnabled = true
        window.makeFirstResponder(terminal.renderer)
        let responder = window.firstResponder
        var resizes = 0
        terminal.onViewportChange = { _ in resizes += 1 }
        try host.apply(settings(size: 16, padding: 12, opacity: 0.25))
        XCTAssertEqual(terminal.frame, host.bounds)
        XCTAssertEqual(terminal.contentView.frame, NSRect(x: 12, y: 12, width: 616, height: 296))
        XCTAssertEqual(terminal.renderer.font.pointSize, 16)
        XCTAssertEqual(terminal.renderer.font.familyName, "Menlo")
        XCTAssertEqual(driver.columns, Int(terminal.contentSize.width / terminal.renderer.cellSize.width))
        XCTAssertEqual(driver.rows, Int(terminal.contentSize.height / terminal.renderer.cellSize.height))
        XCTAssertEqual(resizes, 1, "no intermediate resize for padding plus font")
        XCTAssertTrue(window.firstResponder === responder)
        XCTAssertEqual(terminal.renderer.nativeBackgroundColor.alphaComponent, 0.25)
        XCTAssertEqual(terminal.renderer.caretTextColor, try settings().theme.cursorText?.nsColor)
        XCTAssertEqual(terminal.source.selectionBackground, try settings().theme.selectionBackground)
        XCTAssertTrue(try driver.encodeFocus(true).isEmpty)
        let fallback = NativeTerminalSettings(theme: try settings().theme, fontFamily: "MissingFont-Santty-Owned-Test", fontSize: 15)
        XCTAssertEqual(fallback.font.familyName, "Menlo"); XCTAssertEqual(fallback.font.pointSize, 15)
    }

    func testZeroPaddingHasNoHiddenInset() throws {
        let terminal = NativeTerminalScrollView(driver: try GhosttyVTDriver())
        let host = NativeTerminalAppearanceHost(terminal: terminal)
        host.setFrameSize(.init(width: 640, height: 320))
        try host.apply(settings(padding: 0))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(terminal.frame, host.bounds)
        XCTAssertEqual(terminal.contentView.frame, terminal.bounds)
    }

    func testColorOnlyThemeChangeRespectsPresentationHold() throws {
        let driver = try GhosttyVTDriver(), terminal = NativeTerminalScrollView(driver: driver, frame: .init(x: 0, y: 0, width: 500, height: 240))
        try terminal.applySettings(settings())
        terminal.feed("\u{1b}[?25lold")
        let old = terminal.renderer.nativeBackgroundColor, selection = terminal.source.selectionBackground
        driver.feed("\u{1b}[?2026hnew")
        try terminal.applySettings(settings("3024 Day"))
        XCTAssertEqual(terminal.renderer.nativeBackgroundColor, old)
        XCTAssertEqual(terminal.source.selectionBackground, selection)
        driver.feed("\u{1b}[?2026l"); terminal.refresh()
        XCTAssertEqual(terminal.renderer.nativeBackgroundColor, try settings("3024 Day").theme.background.nsColor)
        XCTAssertEqual(terminal.source.selectionBackground, try settings("3024 Day").theme.selectionBackground)
    }

    func testFontAndThemeChangePreserveTrackedReadingContentAndFraction() throws {
        let driver = try GhosttyVTDriver(), terminal = NativeTerminalScrollView(driver: driver, frame: .init(x: 0, y: 0, width: 640, height: 240))
        try terminal.applySettings(settings(padding: 0))
        terminal.feed((0..<300).map { "row-\($0)\r\n" }.joined())
        let height = terminal.renderer.cellSize.height
        terminal.contentView.scroll(to: .init(x: 0, y: height * 50.25))
        terminal.reflectScrolledClipView(terminal.contentView)
        let before = try XCTUnwrap(terminal.presentedViewport)
        let row = try XCTUnwrap(terminal.presentedFrame?.rows[before.firstRow])
        let text = row.cells.compactMap(\.text).joined()
        try terminal.applySettings(settings("3024 Day", size: 17, padding: 0))
        let after = try XCTUnwrap(terminal.presentedViewport)
        XCTAssertEqual(terminal.presentedFrame?.rows[after.firstRow]?.cells.compactMap(\.text).joined(), text)
        XCTAssertEqual(after.offset / after.rowHeight - floor(after.offset / after.rowHeight), 0.25, accuracy: 0.01)
        XCTAssertFalse(terminal.isAtLiveBottom)
    }

    func testHiddenSettingsUpdateFactsWithoutPaintingOrSendingInput() throws {
        let driver = try GhosttyVTDriver(), terminal = NativeTerminalScrollView(driver: driver, frame: .init(x: 0, y: 0, width: 500, height: 240))
        try terminal.applySettings(settings())
        let old = terminal.presentedFrame
        let output = NativeTerminalOutput(driver: driver) { _ in XCTFail("settings must not fabricate output") }
        terminal.renderer.output = output // connected but unattached/hidden
        var changes = 0
        terminal.onSettingsChange = { changes += 1 }
        try terminal.applySettings(settings("3024 Day"))
        XCTAssertEqual(changes, 1); XCTAssertTrue(terminal.hasPendingOutput)
        XCTAssertEqual(terminal.presentedFrame?.background, old?.background)
        XCTAssertEqual(driver.displayColors["bg"], "#f7f7f7")
        XCTAssertEqual(terminal.renderer.nativeBackgroundColor, try settings().theme.background.nsColor)
    }
}
