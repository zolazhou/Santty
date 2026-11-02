import AppKit

@MainActor
final class AgentsPaneController: PaneControlling {
    let id: PaneID
    private let container = ListPaneHostView()
    let managerView = AgentManagerView(sessions: [])
    var hostView: NSView { container }
    var focusTargetView: NSView { managerView }
    var displayTitle: String { "Agents" }
    var isLive: Bool { false }
    var name: String? { didSet { container.nameBadge.name = name } }
    var onFocusRequest: ((PaneID) -> Void)?
    var onTitleChange: ((PaneID) -> Void)?

    init(id: PaneID = UUID()) {
        self.id = id
        container.content = managerView
        container.addSubview(managerView, positioned: .below, relativeTo: container.nameBadge)
        container.onFocus = { [weak self] in
            guard let self else { return }
            self.onFocusRequest?(self.id)
        }
        updateAppearance()
    }

    func update(sessions: [AgentSessionSnapshot], messages: [AgentSessionSnapshot]) {
        managerView.updateSessions(sessions, messages: messages)
    }
    func startIfNeeded() {}
    func fitToSize() { container.layoutSubtreeIfNeeded() }
    func setNameVisible(_ visible: Bool) { container.nameBadge.isRevealed = visible }
    func updatePresentation(isFocused: Bool, isFloating: Bool) {
        container.isFocused = isFocused
        container.isFloating = isFloating
        container.nameBadge.isFocused = isFocused
        updateAppearance()
    }
    func updateAppearance() { container.updateAppearance() }
}
