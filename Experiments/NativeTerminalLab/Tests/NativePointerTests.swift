// Mouse vectors adapted from herdr-app terminal.rs (Apache-2.0),
// a547b16ccb5e8811b2dd8b3b901d31df8f05e55a; see Licenses/Herdr-app.txt.
import Foundation
import GhosttyVt
import XCTest
@testable import SanttyTerminalLab

final class NativePointerTests: XCTestCase {
    private func input(_ driver: GhosttyVTDriver, action: GhosttyMouseAction = GHOSTTY_MOUSE_ACTION_PRESS,
                       button: GhosttyMouseButton? = GHOSTTY_MOUSE_BUTTON_LEFT,
                       x: CGFloat = 15, y: CGFloat = 25, mods: GhosttyMods = 0, any: Bool = true,
                       scale: CGFloat = 1) throws -> NativeMouseInput {
        .init(action: action, button: button, modifiers: mods, position: CGPoint(x: x, y: y),
              cell: CGSize(width: 10, height: 20), scale: scale, anyButton: any, modes: try driver.pointerModes)
    }

    func testIndependentMouseProtocolAndModifierVectors() throws {
        for mode in [0, 1005, 1006, 1015, 1016] {
            for (mods, bits): (GhosttyMods, Int) in [(0, 0), (GhosttyMods(GHOSTTY_MODS_SHIFT), 4),
                (GhosttyMods(GHOSTTY_MODS_ALT), 8), (GhosttyMods(GHOSTTY_MODS_CTRL), 16),
                (GhosttyMods(GHOSTTY_MODS_SHIFT | GHOSTTY_MODS_ALT | GHOSTTY_MODS_CTRL), 28)] {
                let driver = try GhosttyVTDriver(columns: 80, rows: 24)
                driver.feed("\u{1b}[?1002h")
                if mode != 0 { driver.feed("\u{1b}[?\(mode)h") }
                func expected(_ button: Int, release: Bool = false, x: Int = 15) -> Data {
                    switch mode {
                    case 1006: return Data("\u{1b}[<\(button + bits);\(x / 10 + 1);2\(release ? "m" : "M")".utf8)
                    case 1016: return Data("\u{1b}[<\(button + bits);\(x);25\(release ? "m" : "M")".utf8)
                    case 1015: return Data("\u{1b}[\((release ? 3 : button) + bits + 32);\(x / 10 + 1);2M".utf8)
                    default: return Data([27, 91, 77, UInt8((release ? 3 : button) + bits + 32), UInt8(x / 10 + 33), 34])
                    }
                }
                XCTAssertEqual(try driver.encodeMouse(input(driver, mods: mods)), expected(0), "format \(mode)")
                XCTAssertEqual(try driver.encodeMouse(input(driver, action: GHOSTTY_MOUSE_ACTION_MOTION, x: 25, mods: mods)), expected(32, x: 25))
                XCTAssertEqual(try driver.encodeMouse(input(driver, action: GHOSTTY_MOUSE_ACTION_RELEASE, x: 25, mods: mods)), expected(0, release: true, x: 25))
                let wheel = NativeProgramScroll(route: .mouse, x: 1, y: 1, mouse: try input(driver, mods: mods, any: false))
                XCTAssertEqual(try driver.encodeWheel(wheel), expected(64) + expected(66))
            }
        }
    }

    func testUTF8MouseCoordinatesUseMultibyteCharactersUnlikeLegacy() throws {
        let driver = try GhosttyVTDriver(columns: 200, rows: 24)
        driver.feed("\u{1b}[?1000h")
        XCTAssertEqual(try driver.encodeMouse(input(driver, x: 1005)), Data([27, 91, 77, 32, 133, 34]))
        driver.feed("\u{1b}[?1005h")
        XCTAssertEqual(try driver.encodeMouse(input(driver, x: 1005)), Data([27, 91, 77, 32, 194, 133, 34]))
    }

    func testExtendedButtonsAndPixelMotionWithinOneCell() throws {
        let driver = try GhosttyVTDriver()
        driver.feed("\u{1b}[?1003h\u{1b}[?1006h")
        XCTAssertEqual(try driver.encodeMouse(input(driver, button: GHOSTTY_MOUSE_BUTTON_EIGHT)), Data("\u{1b}[<128;2;2M".utf8))
        driver.feed("\u{1b}[?1016h")
        let first = try driver.encodeMouse(input(driver, action: GHOSTTY_MOUSE_ACTION_MOTION, button: nil, any: false))
        let second = try driver.encodeMouse(input(driver, action: GHOSTTY_MOUSE_ACTION_MOTION, button: nil, x: 16, any: false))
        XCTAssertFalse(first.isEmpty)
        XCTAssertFalse(second.isEmpty, "SGR-pixel motion must not be deduplicated by the containing cell")
        XCTAssertNotEqual(first, second)
    }

    func testMouseTrackingFiltersMotionAndDeduplicatesCells() throws {
        let driver = try GhosttyVTDriver()
        XCTAssertTrue(try driver.encodeMouse(input(driver)).isEmpty)
        driver.feed("\u{1b}[?1000h\u{1b}[?1006h")
        XCTAssertTrue(try driver.encodeMouse(input(driver, action: GHOSTTY_MOUSE_ACTION_MOTION)).isEmpty)
        driver.feed("\u{1b}[?1003h")
        XCTAssertFalse(try driver.encodeMouse(input(driver, action: GHOSTTY_MOUSE_ACTION_MOTION, button: nil, any: false)).isEmpty)
        XCTAssertTrue(try driver.encodeMouse(input(driver, action: GHOSTTY_MOUSE_ACTION_MOTION, button: nil, any: false)).isEmpty)
    }

    func testMouseReleaseDrainsDuringSynchronizedOutputHold() throws {
        let driver = try GhosttyVTDriver()
        driver.feed("\u{1b}[?1000h\u{1b}[?1006h")
        _ = try driver.encodeMouse(input(driver))
        driver.feed("\u{1b}[?2026h")
        XCTAssertTrue(try driver.encodeMouse(input(driver)).isEmpty)
        XCTAssertEqual(try driver.encodeMouse(input(driver, action: GHOSTTY_MOUSE_ACTION_RELEASE, any: false)), Data("\u{1b}[<0;2;2m".utf8))
    }

    func testStaleModesAndGeometryNeverReplayMouseEvents() throws {
        let driver = try GhosttyVTDriver()
        driver.feed("\u{1b}[?1000h\u{1b}[?1006h")
        let before = try input(driver)
        driver.feed("\u{1b}[?1016h")
        XCTAssertTrue(try driver.encodeMouse(before).isEmpty)
        let sized = try input(driver)
        try driver.resize(columns: 100, rows: 30)
        XCTAssertTrue(try driver.encodeMouse(sized).isEmpty)
        let connected = try input(driver)
        driver.reset()
        XCTAssertTrue(try driver.encodeMouse(connected).isEmpty)
    }

    func testFractionalCellsAndRetinaPixelCoordinates() throws {
        let driver = try GhosttyVTDriver(columns: 80, rows: 24)
        driver.feed("\u{1b}[?1000h\u{1b}[?1006h")
        var modes = try driver.pointerModes
        let fractional = NativeMouseInput(action: GHOSTTY_MOUSE_ACTION_PRESS, button: GHOSTTY_MOUSE_BUTTON_LEFT,
            modifiers: 0, position: CGPoint(x: 9.75 * 39 + 9.7, y: 21.5 * 2 + 1),
            cell: CGSize(width: 9.75, height: 21.5), scale: 2, anyButton: true, modes: modes)
        XCTAssertEqual(try driver.encodeMouse(fractional), Data("\u{1b}[<0;40;3M".utf8))
        driver.feed("\u{1b}[?1016h"); modes = try driver.pointerModes
        XCTAssertEqual(try driver.encodeMouse(input(driver, x: 15, y: 25, scale: 2)), Data("\u{1b}[<0;30;50M".utf8))
    }

    func testAlternateScrollUsesVTKeyboardModesNotLocalHistory() throws {
        let driver = try GhosttyVTDriver()
        driver.feed("\u{1b}[?1049h\u{1b}[?1007h\u{1b}[?1h")
        let wheel = NativeProgramScroll(route: .arrows, x: 0, y: 2, mouse: try input(driver))
        XCTAssertEqual(try driver.encodeWheel(wheel), Data("\u{1b}OA\u{1b}OA".utf8))
        driver.feed("\u{1b}[?1007l")
        XCTAssertTrue(try driver.encodeWheel(wheel).isEmpty)
    }

    func testWheelFractionBankIsOwnedByOneRouteIncludingMomentum() {
        let mouse = NativePointerModes(tracking: true, alternate: false, alternateScroll: true, pixels: false, signature: 1)
        let history = NativePointerModes(tracking: false, alternate: false, alternateScroll: true, pixels: false, signature: 2)
        var router = NativeWheelRouter()
        func event(_ modes: NativePointerModes, _ y: CGFloat, began: Bool = false, end: Bool = false) -> NativeWheelDecision {
            router.route(modes: modes, bypass: false, precise: true, began: began, ended: false,
                         momentumEnded: end, delta: CGPoint(x: 0, y: y), cell: CGSize(width: 10, height: 20), rows: 24, columns: 80)
        }
        XCTAssertEqual(event(mouse, 10, began: true).y, 0)
        XCTAssertEqual(event(mouse, 11).y, 1)
        XCTAssertEqual(event(history, 200).route, .discard)
        XCTAssertEqual(event(mouse, 200, end: true).route, .discard)
        XCTAssertEqual(event(history, 200, began: true).route, .history)
    }

    func testCancelledMomentumCannotRestartAfterResizeButPhaselessDevicesRecover() {
        let mode = NativePointerModes(tracking: true, alternate: false, alternateScroll: true, pixels: false, signature: 1)
        var router = NativeWheelRouter()
        func next(_ began: Bool, phased: Bool = true) -> NativeWheelDecision {
            router.route(modes: mode, bypass: false, precise: true, began: began, ended: false, momentumEnded: false,
                delta: CGPoint(x: 0, y: 20), cell: CGSize(width: 10, height: 20), rows: 24, columns: 80, hasGesturePhase: phased)
        }
        XCTAssertEqual(next(true).y, 1)
        router.discardRemainingGesture()
        XCTAssertEqual(next(false).route, .discard)
        XCTAssertEqual(next(true).y, 1)
        router.discardRemainingGesture()
        XCTAssertEqual(next(false, phased: false).y, 1)
    }

    func testEndedNativeGestureIsForwardedWithoutBecomingProgramInput() {
        let local = NativePointerModes(tracking: false, alternate: false, alternateScroll: false, pixels: false, signature: 1)
        let remote = NativePointerModes(tracking: true, alternate: false, alternateScroll: false, pixels: false, signature: 2)
        var router = NativeWheelRouter()
        _ = router.route(modes: local, bypass: false, precise: true, began: true, ended: false, momentumEnded: false,
            delta: .zero, cell: CGSize(width: 10, height: 20), rows: 24, columns: 80)
        let end = router.route(modes: remote, bypass: false, precise: true, began: false, ended: true, momentumEnded: false,
            delta: .zero, cell: CGSize(width: 10, height: 20), rows: 24, columns: 80)
        XCTAssertEqual(end.route, .history)
        XCTAssertEqual(end.y, 0)
    }

    func testShiftBypassAndRouteChangesDoNotTransferFractionalDistance() {
        let mode = NativePointerModes(tracking: true, alternate: true, alternateScroll: true, pixels: false, signature: 1)
        var router = NativeWheelRouter()
        for (shift, start, expected) in [(false, true, NativeWheelRoute.mouse), (true, false, .discard), (true, true, .history)] {
            let result = router.route(modes: mode, bypass: shift, precise: true, began: start, ended: false,
                momentumEnded: false, delta: CGPoint(x: 0, y: 5), cell: CGSize(width: 10, height: 20), rows: 24, columns: 80)
            XCTAssertEqual(result.route, expected)
            XCTAssertEqual(result.y, 0)
        }
    }
}
