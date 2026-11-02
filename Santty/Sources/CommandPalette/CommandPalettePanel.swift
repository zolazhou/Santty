import AppKit

@MainActor
final class CommandPalettePanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    init(contentView: CommandPaletteView) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentView.preferredContentSize),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.contentView = contentView
        contentMinSize = contentView.preferredContentSize
        contentMaxSize = contentView.preferredContentSize
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.transient, .ignoresCycle]
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        toolbarStyle = .unified
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true {
            return
        }

        super.sendEvent(event)
    }
}
