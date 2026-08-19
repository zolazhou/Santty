import AppKit
import WebKit

@MainActor
final class BrowserWebView: WKWebView {
    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onMouseDown?()
    }
}

@MainActor
final class BrowserPaneHostView: NSView {
    let paneID: PaneID
    let webView: BrowserWebView
    let addressField = NSTextField(string: "")
    private let vibrancyView = AppAppearanceDefaults.makeVibrancyView(
        tintViewAlpha: AppAppearanceDefaults.vibrancyTintAlpha
    )

    var onFocusRequest: ((PaneID) -> Void)?
    var onSubmitURL: ((String) -> Void)?
    private var isFocused = false
    private var isFloating = false

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    var isAddressFieldVisible: Bool {
        !addressField.isHidden
    }

    init(paneID: PaneID) {
        self.paneID = paneID
        let webView = BrowserWebView(
            frame: NSRect(x: 0, y: 0, width: 720, height: 480),
            configuration: WKWebViewConfiguration()
        )
        self.webView = webView
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = true
        appearance = NSAppearance(named: .darkAqua)

        vibrancyView.frame = bounds
        addSubview(vibrancyView)

        webView.autoresizingMask = [.width, .height]
        webView.isHidden = true
        addSubview(webView)

        addressField.placeholderString = "Enter URL"
        addressField.appearance = NSAppearance(named: .darkAqua)
        addressField.target = self
        addressField.action = #selector(submitAddress(_:))
        addSubview(addressField)

        webView.onMouseDown = { [weak self] in
            guard let self, !self.isFloating else {
                return
            }

            self.onFocusRequest?(paneID)
        }
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        vibrancyView.frame = bounds
        webView.frame = bounds

        let fieldSize = NSSize(width: min(520, max(0, bounds.width - 32)), height: 28)
        addressField.frame = NSRect(
            x: (bounds.width - fieldSize.width) / 2,
            y: (bounds.height - fieldSize.height) / 2,
            width: fieldSize.width,
            height: fieldSize.height
        )
    }

    func focusAddressField() {
        window?.makeFirstResponder(addressField)
    }

    func showWebView() {
        addressField.isHidden = true
        webView.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func updatePresentation(isFocused: Bool, isFloating: Bool) {
        self.isFocused = isFocused
        self.isFloating = isFloating
        updateAppearance()
    }

    func updateAppearance() {
        vibrancyView.isHidden = !(AppAppearanceSettings.isWindowHidden || isFloating)
        vibrancyView.blendingMode =
            isFloating
            ? AppAppearanceDefaults.floatingPaneVibrancyBlendingMode
            : AppAppearanceDefaults.vibrancyBlendingMode
        vibrancyView.material =
            isFloating
            ? AppAppearanceDefaults.floatingPaneVibrancyMaterial
            : AppAppearanceDefaults.vibrancyMaterial
        applyVibrancyTintAlpha(
            isFloating
                ? AppAppearanceDefaults.floatingPaneVibrancyTintAlpha
                : AppAppearanceDefaults.vibrancyTintAlpha
        )
        layer?.cornerRadius = AppAppearanceSettings.paneCornerRadius
        layer?.borderWidth =
            isFocused ? AppAppearanceSettings.activePaneBorderWidth : 1
        layer?.borderColor =
            (isFocused
                ? AppAppearanceSettings.accentColor
                : NSColor.separatorColor.withAlphaComponent(0.45)
            ).cgColor
        layer?.backgroundColor = NSColor.black.withAlphaComponent(
            AppAppearanceSettings.isWindowHidden ? 0 : 0.5
        ).cgColor
        needsLayout = true
    }

    private func applyVibrancyTintAlpha(_ alpha: CGFloat) {
        guard
            let tintView = vibrancyView.subviews.first(where: {
                $0.identifier == AppAppearanceDefaults.vibrancyTintIdentifier
            })
        else {
            return
        }

        tintView.layer?.backgroundColor = NSColor.black.withAlphaComponent(alpha).cgColor
    }

    @objc private func submitAddress(_ sender: NSTextField) {
        onSubmitURL?(sender.stringValue)
    }
}

@MainActor
final class BrowserPaneController: NSObject, PaneControlling {
    let id: PaneID
    let browserHostView: BrowserPaneHostView

    var hostView: NSView {
        browserHostView
    }

    var onFocusRequest: ((PaneID) -> Void)? {
        didSet {
            browserHostView.onFocusRequest = onFocusRequest
        }
    }

    var onTitleChange: ((PaneID) -> Void)?

    private(set) var isLive = false
    private(set) var displayTitle = "Browser"

    var focusTargetView: NSView {
        browserHostView.isAddressFieldVisible
            ? browserHostView.addressField
            : browserHostView.webView
    }

    init(id: PaneID = UUID()) {
        self.id = id
        browserHostView = BrowserPaneHostView(paneID: id)
        super.init()

        browserHostView.onSubmitURL = { [weak self] rawURL in
            self?.loadURLString(rawURL)
        }
        browserHostView.onFocusRequest = onFocusRequest
    }

    func startIfNeeded() {
        browserHostView.focusAddressField()
    }

    func fitToSize() {
        browserHostView.needsLayout = true
        browserHostView.layoutSubtreeIfNeeded()
    }

    func updatePresentation(isFocused: Bool, isFloating: Bool) {
        browserHostView.updatePresentation(isFocused: isFocused, isFloating: isFloating)
    }

    func updateAppearance() {
        browserHostView.updateAppearance()
    }

    private func loadURLString(_ rawURL: String) {
        guard let url = Self.normalizedURL(from: rawURL) else {
            NSSound.beep()
            return
        }

        browserHostView.showWebView()
        browserHostView.webView.load(URLRequest(url: url))
        browserHostView.window?.makeFirstResponder(browserHostView.webView)
        displayTitle = url.host ?? url.absoluteString
        onTitleChange?(id)
    }

    private static func normalizedURL(from rawURL: String) -> URL? {
        let value = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }

        let candidate =
            value.contains("://") || value.hasPrefix("localhost")
            ? value
            : "https://\(value)"
        guard let url = URL(string: candidate), url.scheme != nil else {
            return nil
        }

        return url
    }
}
