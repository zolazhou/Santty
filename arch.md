That’s the right architecture for a serious macOS workspace UI.

A strong implementation looks like this:

```text
NSWindow
└── WorkspaceViewController
    └── WorkspaceRootView (AppKit)
        ├── SplitContainerView
        │   ├── PanelHostView
        │   │   └── NSHostingView(SwiftUI)
        │   └── SplitContainerView
        └── OverlayLayer
            ├── Divider overlays
            ├── Dock previews
            └── Drag indicators
```

---

# 1. Core Principles

## AppKit Owns Layout

AppKit should manage:

* panel frames
* drag/resize
* focus
* z-order
* docking
* hit testing
* animations

SwiftUI should only render panel content.

This separation is critical.

---

# 2. Layout Tree

Start with a pure data model.

```swift
typealias PanelID = UUID

enum LayoutNode: Codable {
    case panel(PanelNode)
    case split(SplitNode)
}

struct PanelNode: Codable {
    let id: PanelID
}

struct SplitNode: Codable {
    let axis: Axis
    var ratio: CGFloat
    var first: LayoutNode
    var second: LayoutNode
}

enum Axis: Codable {
    case horizontal
    case vertical
}
```

This becomes:

* your source of truth
* persistence format
* undo history
* docking engine input

Never derive layout from views.

Views derive from the tree.

---

# 3. Workspace Rendering Engine

## Root View

```swift
final class WorkspaceRootView: NSView {

    var layoutTree: LayoutNode {
        didSet {
            rebuild()
        }
    }

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }

        let view = makeView(for: layoutTree)
        addSubview(view)

        view.frame = bounds
        view.autoresizingMask = [.width, .height]
    }
}
```

---

# 4. Recursive Rendering

## Split Container

```swift
final class SplitContainerView: NSView {

    let axis: Axis
    let dividerThickness: CGFloat = 6

    var ratio: CGFloat = 0.5

    let firstView: NSView
    let secondView: NSView

    init(
        axis: Axis,
        ratio: CGFloat,
        first: NSView,
        second: NSView
    ) {
        self.axis = axis
        self.ratio = ratio
        self.firstView = first
        self.secondView = second

        super.init(frame: .zero)

        addSubview(first)
        addSubview(second)

        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override func layout() {
        super.layout()

        let rect = bounds

        switch axis {

        case .horizontal:
            let splitX = rect.width * ratio

            firstView.frame = CGRect(
                x: 0,
                y: 0,
                width: splitX - dividerThickness / 2,
                height: rect.height
            )

            secondView.frame = CGRect(
                x: splitX + dividerThickness / 2,
                y: 0,
                width: rect.width - splitX,
                height: rect.height
            )

        case .vertical:
            let splitY = rect.height * ratio

            firstView.frame = CGRect(
                x: 0,
                y: 0,
                width: rect.width,
                height: splitY - dividerThickness / 2
            )

            secondView.frame = CGRect(
                x: 0,
                y: splitY + dividerThickness / 2,
                width: rect.width,
                height: rect.height - splitY
            )
        }
    }
}
```

This is the core.

Everything else builds on top.

---

# 5. Panel Host View

Panels are AppKit shells hosting SwiftUI.

```swift
final class PanelHostView<Content: View>: NSView {

    let panelID: PanelID

    private let hostingView: NSHostingView<Content>

    init(
        panelID: PanelID,
        rootView: Content
    ) {
        self.panelID = panelID
        self.hostingView = NSHostingView(rootView: rootView)

        super.init(frame: .zero)

        wantsLayer = true

        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        addSubview(hostingView)
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override func layout() {
        super.layout()

        hostingView.frame = bounds
    }
}
```

---

# 6. Divider Overlay System

Do NOT make dividers actual layout containers.

Instead:

* render overlays above content
* easier hit testing
* easier animation
* easier hover effects

Use:

```swift
OverlayContainerView
```

with:

* divider layers
* drag indicators
* docking previews

This is how pro apps do it.

---

# 7. Resizing

When dragging divider:

```text
mouseDragged
→ update ratio
→ invalidate layout
→ animate if needed
```

Never mutate frames directly permanently.

Always mutate:

* tree model
* split ratio

Then re-layout.

---

# 8. Focus System

You need window-manager-style focus.

## Workspace State

```swift
final class WorkspaceState: ObservableObject {

    @Published
    var focusedPanelID: PanelID?
}
```

---

## Focus Flow

```text
mouseDown panel
→ update focused panel
→ redraw chrome
```

---

# 9. SwiftUI Integration

Keep SwiftUI sandboxed.

Good:

```swift
PanelHostView
└── NSHostingView
```

Bad:

* SwiftUI controlling docking
* SwiftUI owning layout tree
* SwiftUI geometry-driven splits

---

# 10. Docking System

When dragging a panel:

```text
Begin drag
→ compute target node
→ show preview overlay
→ drop
→ mutate tree
→ animate transition
```

Typical insertion:

```swift
split(
    axis: .horizontal,
    ratio: 0.5,
    first: draggedPanel,
    second: targetPanel
)
```

---

# 11. Animation

Use AppKit animations.

```swift
NSAnimationContext.runAnimationGroup {
    context.duration = 0.15

    view.animator().frame = targetFrame
}
```

Avoid SwiftUI animation for workspace chrome.

---

# 12. Performance

Critical.

## Use Layer Backing

```swift
wantsLayer = true
```

everywhere appropriate.

---

## Avoid Excessive Auto Layout

Manual layout is much faster here.

Use:

* `layout()`
* explicit frames

---

## Keep Tree Pure

Never store:

* NSView references
* SwiftUI state
* rendering state

inside layout nodes.

---

# 13. Persistence

Your tree is already serializable.

Save:

```json
{
  "split": {
    "axis": "horizontal",
    "ratio": 0.62
  }
}
```

This becomes:

* workspace restore
* saved layouts
* undo/redo
* multi-window workspaces

---

# 14. Future Extensions

This architecture scales to:

## Floating Panels

```swift
case floating(FloatingNode)
```

## Tabs

```swift
case tabs([PanelNode])
```

## Multiple Workspaces

```swift
WorkspaceSession
```

## Minimap / Overview

easy because tree is pure data.

---

# 15. Recommended Folder Structure

```text
Workspace/
├── Model/
│   ├── LayoutNode.swift
│   ├── PanelNode.swift
│   └── WorkspaceState.swift
│
├── Views/
│   ├── WorkspaceRootView.swift
│   ├── SplitContainerView.swift
│   ├── PanelHostView.swift
│   └── OverlayView.swift
│
├── Controllers/
│   ├── WorkspaceController.swift
│   ├── DockingController.swift
│   └── FocusController.swift
│
├── Rendering/
│   ├── LayoutEngine.swift
│   └── HitTesting.swift
│
└── SwiftUI/
    └── Panels/
```

---

# Important Advice

## Treat This Like a Tiny Window Manager

Not like a collection of views.

That mental model changes everything:

* focus system
* input routing
* z-order
* layout tree
* overlays
* docking
* persistence

All become cleaner.

---

# Biggest Mistakes To Avoid

## 1. Letting SwiftUI Control Layout

This becomes painful fast.

---

## 2. Using Auto Layout for Everything

Manual frames are far superior here.

---

## 3. Coupling Tree ↔ Views

Keep:

* model pure
* rendering disposable

---

## 4. Using Many NSWindows

Will become impossible to manage well.

---

# Final Recommended Stack

## Shell

* AppKit
* manual layout
* CALayer-backed

## Content

* SwiftUI
* `NSHostingView`

## Layout

* recursive split tree

## Interaction

* AppKit gestures + hit testing

## Animation

* `NSAnimationContext`

## Rendering

* overlay-based dividers/docking

This is effectively how professional macOS workspace apps are built today.

