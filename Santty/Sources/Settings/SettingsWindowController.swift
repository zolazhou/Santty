import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private let settingsViewController = SettingsHostingController()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 640, height: 420)
        window.contentViewController = settingsViewController
        window.isReleasedWhenClosed = true
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    func show(relativeTo parentWindow: NSWindow?) {
        settingsViewController.reload()

        if let parentWindow, window?.isVisible == false {
            window?.center(relativeTo: parentWindow)
        } else if parentWindow == nil, window?.isVisible == false {
            window?.center()
        }

        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

extension NSWindow {
    fileprivate func center(relativeTo parentWindow: NSWindow) {
        let parentFrame = parentWindow.frame
        let origin = NSPoint(
            x: parentFrame.midX - frame.width / 2,
            y: parentFrame.midY - frame.height / 2
        )
        setFrameOrigin(origin)
    }
}

@MainActor
private final class SettingsHostingController: NSHostingController<SettingsView> {
    init() {
        super.init(rootView: SettingsView())
    }

    @available(*, unavailable)
    @MainActor
    dynamic required init?(coder _: NSCoder) {
        nil
    }

    func reload() {
        rootView = SettingsView()
    }
}
