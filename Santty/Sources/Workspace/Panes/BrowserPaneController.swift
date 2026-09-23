import AppKit
import WebKit

@MainActor
final class BrowserWebView: WKWebView {
    var onMouseDown: (() -> Void)?
    var onBottomStripHover: ((Bool) -> Void)?

    private var bottomStripTrackingArea: NSTrackingArea?

    static var bottomStripHeight: CGFloat {
        BrowserLocationBarView.height + BrowserLocationBarView.bottomMargin + 8
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onMouseDown?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let bottomStripTrackingArea {
            removeTrackingArea(bottomStripTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: NSRect(x: 0, y: 0, width: bounds.width, height: Self.bottomStripHeight),
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self
        )
        addTrackingArea(trackingArea)
        bottomStripTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === bottomStripTrackingArea {
            onBottomStripHover?(true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === bottomStripTrackingArea {
            onBottomStripHover?(false)
        }
    }
}

@MainActor
final class BrowserPaneHostView: NSView {
    let paneID: PaneID
    let webView: BrowserWebView
    let locationBar = BrowserLocationBarView()
    private let vibrancyView = AppAppearanceDefaults.makeVibrancyView(
        tintViewAlpha: AppAppearanceDefaults.vibrancyTintAlpha
    )
    private let errorView = NSVisualEffectView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    var addressField: NSTextField {
        locationBar.textField
    }

    var onFocusRequest: ((PaneID) -> Void)?
    var onLocationBarReveal: (() -> Void)?
    var onLocationBarConceal: (() -> Void)?
    private var isFocused = false
    private var isFloating = false

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    var isAddressFieldVisible: Bool {
        locationBar.isBarVisible
    }

    var isErrorVisible: Bool {
        !errorView.isHidden
    }

    private var isMouseOverLocationBar: Bool {
        guard let window else {
            return false
        }
        let point = locationBar.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return locationBar.bounds.contains(point)
    }

    private var isMouseOverBottomStrip: Bool {
        guard let window else {
            return false
        }
        let point = webView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return point.y >= 0 && point.y <= BrowserWebView.bottomStripHeight
            && webView.bounds.contains(point)
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

        // The location bar floats above the web content; the error view sits
        // between them so the bar keeps its shadow/border on top.
        errorView.material = .popover
        errorView.blendingMode = .withinWindow
        errorView.state = .active
        errorView.appearance = NSAppearance(named: .darkAqua)
        errorView.wantsLayer = true
        errorView.layer?.cornerRadius = 8
        errorView.layer?.masksToBounds = true
        errorView.isHidden = true

        errorLabel.alignment = .center
        errorLabel.font = .systemFont(ofSize: 13)
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.appearance = NSAppearance(named: .darkAqua)
        errorView.addSubview(errorLabel)
        addSubview(errorView)

        addSubview(locationBar)

        webView.onMouseDown = { [weak self] in
            guard let self else {
                return
            }
            if !self.isFloating {
                self.onFocusRequest?(paneID)
            }
            self.onLocationBarConceal?()
        }
        webView.onBottomStripHover = { [weak self] entered in
            guard let self else {
                return
            }
            if entered {
                self.onLocationBarReveal?()
            } else if !self.isMouseOverLocationBar {
                self.onLocationBarConceal?()
            }
        }
        locationBar.onHoverExit = { [weak self] in
            guard let self, !self.isMouseOverBottomStrip else {
                return
            }
            self.onLocationBarConceal?()
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

        let barWidth = max(0, bounds.width - BrowserLocationBarView.sideMargin * 2)
        locationBar.frame = NSRect(
            x: BrowserLocationBarView.sideMargin,
            y: BrowserLocationBarView.bottomMargin,
            width: barWidth,
            height: BrowserLocationBarView.height
        )

        errorLabel.preferredMaxLayoutWidth = min(360, max(0, bounds.width - 64))
        let labelSize = errorLabel.intrinsicContentSize
        let errorSize = NSSize(
            width: labelSize.width + 32,
            height: labelSize.height + 20
        )
        errorView.frame = NSRect(
            x: (bounds.width - errorSize.width) / 2,
            y: (bounds.height - errorSize.height) / 2,
            width: errorSize.width,
            height: errorSize.height
        )
        errorLabel.frame = errorView.bounds.insetBy(dx: 16, dy: 10)
    }

    func focusAddressField() {
        locationBar.focusTextField()
    }

    func showWebView() {
        webView.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func showError(_ message: String?) {
        guard let message, !message.isEmpty else {
            errorView.isHidden = true
            return
        }

        errorLabel.stringValue = message
        errorView.isHidden = false
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
}

@MainActor
final class BrowserPaneController: NSObject, PaneControlling, WKNavigationDelegate {
    private enum LoadState: Equatable {
        case empty
        case loading
        case loaded
        case failed(String)
    }

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

    private var loadState: LoadState = .empty
    private var progressObservation: NSKeyValueObservation?

    var focusTargetView: NSView {
        browserHostView.isAddressFieldVisible
            ? browserHostView.addressField
            : browserHostView.webView
    }

    private var isAddressFieldEditing: Bool {
        browserHostView.addressField.currentEditor() != nil
    }

    init(id: PaneID = UUID()) {
        self.id = id
        browserHostView = BrowserPaneHostView(paneID: id)
        super.init()

        browserHostView.onFocusRequest = onFocusRequest
        browserHostView.locationBar.onSubmitURL = { [weak self] rawURL in
            self?.loadURLString(rawURL)
        }
        browserHostView.locationBar.onCancel = { [weak self] in
            self?.handleLocationBarCancel()
        }
        browserHostView.onLocationBarReveal = { [weak self] in
            self?.revealLocationBar()
        }
        browserHostView.onLocationBarConceal = { [weak self] in
            self?.concealLocationBar()
        }
        browserHostView.webView.navigationDelegate = self
        progressObservation = browserHostView.webView.observe(
            \.estimatedProgress, options: [.new]
        ) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                self?.browserHostView.locationBar.updateProgress(webView.estimatedProgress)
            }
        }
    }

    func startIfNeeded() {
        guard loadState == .empty else {
            return
        }

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

    func focusLocationBar() {
        browserHostView.locationBar.setVisible(true, animated: true)
        browserHostView.focusAddressField()
    }

    private func revealLocationBar() {
        guard loadState == .loaded else {
            return
        }

        browserHostView.locationBar.setVisible(true, animated: true)
    }

    private func concealLocationBar() {
        guard loadState == .loaded,
            browserHostView.locationBar.isBarVisible,
            !isAddressFieldEditing
        else {
            return
        }

        browserHostView.locationBar.setVisible(false, animated: true)
    }

    private func handleLocationBarCancel() {
        if loadState == .loaded {
            browserHostView.locationBar.setVisible(false, animated: true)
        }
        if !browserHostView.webView.isHidden {
            browserHostView.window?.makeFirstResponder(browserHostView.webView)
        }
    }

    private func loadURLString(_ rawURL: String) {
        guard let url = Self.normalizedURL(from: rawURL) else {
            NSSound.beep()
            return
        }

        loadState = .loading
        browserHostView.showWebView()
        browserHostView.showError(nil)
        browserHostView.locationBar.resetProgress()
        browserHostView.locationBar.setVisible(true, animated: true)
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

    nonisolated func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        MainActor.assumeIsolated {
            loadState = .loading
            browserHostView.showWebView()
            browserHostView.showError(nil)
            browserHostView.locationBar.resetProgress()
            browserHostView.locationBar.setVisible(true, animated: true)
            if !isAddressFieldEditing, let url = browserHostView.webView.url {
                browserHostView.addressField.stringValue = url.absoluteString
            }
        }
    }

    nonisolated func webView(_: WKWebView, didFinish _: WKNavigation!) {
        MainActor.assumeIsolated {
            loadState = .loaded
            browserHostView.showError(nil)
            if !isAddressFieldEditing {
                browserHostView.locationBar.setVisible(false, animated: true)
            }
        }
    }

    nonisolated func webView(
        _: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error
    ) {
        MainActor.assumeIsolated {
            handleLoadFailure(error)
        }
    }

    nonisolated func webView(
        _: WKWebView, didFail _: WKNavigation!, withError error: Error
    ) {
        MainActor.assumeIsolated {
            handleLoadFailure(error)
        }
    }

    private func handleLoadFailure(_ error: Error) {
        // Cancellation errors fire when a new load interrupts an in-flight
        // one; they are not real failures.
        if (error as NSError).code == NSURLErrorCancelled {
            return
        }

        loadState = .failed(error.localizedDescription)
        browserHostView.locationBar.resetProgress()
        browserHostView.locationBar.setVisible(true, animated: true)
        browserHostView.showError(error.localizedDescription)
    }
}
