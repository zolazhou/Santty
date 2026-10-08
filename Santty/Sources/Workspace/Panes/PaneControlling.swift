import AppKit

@MainActor
protocol PaneControlling: AnyObject {
    var id: PaneID { get }
    var hostView: NSView { get }
    var displayTitle: String { get }
    var name: String? { get set }
    var isLive: Bool { get }
    var focusTargetView: NSView { get }

    var onFocusRequest: ((PaneID) -> Void)? { get set }
    var onTitleChange: ((PaneID) -> Void)? { get set }

    func updatePresentation(isFocused: Bool, isFloating: Bool)
    func updateAppearance()
    func setNameVisible(_ visible: Bool)
    func startIfNeeded()
    func fitToSize()
}
