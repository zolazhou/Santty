import AppKit
import SwiftUI

@MainActor
struct AppearanceSettingsPane: View {
    @Binding var accentColor: Color
    @Binding var activeTabBackgroundKind: ActiveTabBackgroundKind
    @Binding var activeTabSolidColor: Color
    @Binding var activeTabGradientStartColor: Color
    @Binding var activeTabGradientEndColor: Color
    @Binding var activePaneBorderWidth: Double
    @Binding var paneCornerRadius: Double
    @Binding var workspaceEdgePadding: Double
    @Binding var workspaceDividerThickness: Double
    @Binding var isWindowHidden: Bool

    var body: some View {
        Form {
            Section(header: Text("Colors")) {
                LabeledContent("Accent Color") {
                    HStack {
                        ColorPicker(
                            "Accent Color",
                            selection: Binding(
                                get: { accentColor },
                                set: { newValue in
                                    accentColor = newValue
                                    AppAppearanceSettings.accentColor = NSColor(newValue)
                                }
                            ),
                            supportsOpacity: true
                        )
                        .labelsHidden()

                        Button("Reset") {
                            AppAppearanceSettings.resetAccentColor()
                            accentColor = Color(nsColor: AppAppearanceSettings.accentColor)
                        }
                    }
                }

                LabeledContent("Active Tab Background") {
                    HStack {
                        Picker(
                            "Active Tab Background",
                            selection: Binding(
                                get: { activeTabBackgroundKind },
                                set: { newValue in
                                    activeTabBackgroundKind = newValue
                                    persistActiveTabBackground()
                                }
                            )
                        ) {
                            ForEach(ActiveTabBackgroundKind.allCases) { kind in
                                Text(kind.label).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 160)

                        Button("Reset") {
                            AppAppearanceSettings.resetActiveTabBackground()
                            syncActiveTabBackgroundState()
                        }
                    }
                }

                activeTabColorRows
            }

            Section(header: Text("Pane")) {
                LabeledContent("Active Border Width") {
                    pixelSlider(
                        value: $activePaneBorderWidth,
                        range: activePaneBorderWidthRange,
                        persist: { AppAppearanceSettings.activePaneBorderWidth = $0 },
                        reset: {
                            AppAppearanceSettings.resetActivePaneBorderWidth()
                            return AppAppearanceSettings.activePaneBorderWidth
                        }
                    )
                }

                LabeledContent("Corner Radius") {
                    pixelSlider(
                        value: $paneCornerRadius,
                        range: paneCornerRadiusRange,
                        persist: { AppAppearanceSettings.paneCornerRadius = $0 },
                        reset: {
                            AppAppearanceSettings.resetPaneCornerRadius()
                            return AppAppearanceSettings.paneCornerRadius
                        }
                    )
                }

                LabeledContent("Workspace Edge Padding") {
                    pixelSlider(
                        value: $workspaceEdgePadding,
                        range: workspaceEdgePaddingRange,
                        persist: { AppAppearanceSettings.workspaceEdgePadding = $0 },
                        reset: {
                            AppAppearanceSettings.resetWorkspaceEdgePadding()
                            return AppAppearanceSettings.workspaceEdgePadding
                        }
                    )
                }

                LabeledContent("Divider Thickness") {
                    pixelSlider(
                        value: $workspaceDividerThickness,
                        range: workspaceDividerThicknessRange,
                        persist: { AppAppearanceSettings.workspaceDividerThickness = $0 },
                        reset: {
                            AppAppearanceSettings.resetWorkspaceDividerThickness()
                            return AppAppearanceSettings.workspaceDividerThickness
                        }
                    )
                }
            }

            Section(header: Text("Window")) {
                Toggle(
                    "Hide Window",
                    isOn: Binding(
                        get: { isWindowHidden },
                        set: { newValue in
                            isWindowHidden = newValue
                            AppAppearanceSettings.isWindowHidden = newValue
                        }
                    )
                )

                Text(
                    "Makes the terminal window transparent and hides the standard titlebar controls."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var activeTabColorRows: some View {
        switch activeTabBackgroundKind {
        case .solid:
            LabeledContent("Tab Color") {
                ColorPicker(
                    "Tab Color",
                    selection: Binding(
                        get: { activeTabSolidColor },
                        set: { newValue in
                            activeTabSolidColor = newValue
                            persistActiveTabBackground()
                        }
                    ),
                    supportsOpacity: true
                )
                .labelsHidden()
            }
        case .gradient:
            LabeledContent("Gradient") {
                ColorPicker(
                    "Start",
                    selection: Binding(
                        get: { activeTabGradientStartColor },
                        set: { newValue in
                            activeTabGradientStartColor = newValue
                            persistActiveTabBackground()
                        }
                    ),
                    supportsOpacity: true
                )

                ColorPicker(
                    "End",
                    selection: Binding(
                        get: { activeTabGradientEndColor },
                        set: { newValue in
                            activeTabGradientEndColor = newValue
                            persistActiveTabBackground()
                        }
                    ),
                    supportsOpacity: true
                )
            }
        }
    }

    private var activePaneBorderWidthRange: ClosedRange<Double> {
        let range = AppAppearanceSettings.activePaneBorderWidthRange
        return Double(range.lowerBound)...Double(range.upperBound)
    }

    private var paneCornerRadiusRange: ClosedRange<Double> {
        let range = AppAppearanceSettings.paneCornerRadiusRange
        return Double(range.lowerBound)...Double(range.upperBound)
    }

    private var workspaceEdgePaddingRange: ClosedRange<Double> {
        let range = AppAppearanceSettings.workspaceEdgePaddingRange
        return Double(range.lowerBound)...Double(range.upperBound)
    }

    private var workspaceDividerThicknessRange: ClosedRange<Double> {
        let range = AppAppearanceSettings.workspaceDividerThicknessRange
        return Double(range.lowerBound)...Double(range.upperBound)
    }

    private func pixelSlider(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        persist: @escaping (CGFloat) -> Void,
        reset: @escaping () -> CGFloat
    ) -> some View {
        HStack {
            Slider(
                value: Binding(
                    get: { value.wrappedValue },
                    set: { newValue in
                        value.wrappedValue = newValue.rounded()
                        persist(CGFloat(value.wrappedValue))
                    }
                ),
                in: range,
                step: 1
            )

            Text("\(Int(value.wrappedValue)) px")
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)

            Button("Reset") {
                value.wrappedValue = Double(reset())
            }
        }
    }

    private func persistActiveTabBackground() {
        switch activeTabBackgroundKind {
        case .solid:
            AppAppearanceSettings.activeTabBackground = .solid(NSColor(activeTabSolidColor))
        case .gradient:
            AppAppearanceSettings.activeTabBackground = .gradient(
                NSColor(activeTabGradientStartColor),
                NSColor(activeTabGradientEndColor)
            )
        }
    }

    private func syncActiveTabBackgroundState() {
        switch AppAppearanceSettings.activeTabBackground {
        case .solid(let color):
            activeTabBackgroundKind = .solid
            activeTabSolidColor = Color(nsColor: color)
        case .gradient(let startColor, let endColor):
            activeTabBackgroundKind = .gradient
            activeTabGradientStartColor = Color(nsColor: startColor)
            activeTabGradientEndColor = Color(nsColor: endColor)
        }
    }
}

#Preview("Appearance Settings") {
    AppearanceSettingsPanePreview()
        .padding(24)
        .frame(width: 620)
        .background(Color(nsColor: .windowBackgroundColor))
}

@MainActor
private struct AppearanceSettingsPanePreview: View {
    @State private var accentColor = Color(nsColor: AppAppearanceSettings.accentColor)
    @State private var activeTabBackgroundKind = ActiveTabBackgroundKind.solid
    @State private var activeTabSolidColor = Color(nsColor: NSColor.systemBlue)
    @State private var activeTabGradientStartColor = Color(nsColor: NSColor.systemBlue)
    @State private var activeTabGradientEndColor = Color(nsColor: NSColor.systemPurple)
    @State private var activePaneBorderWidth =
        Double(AppAppearanceSettings.defaultActivePaneBorderWidth)
    @State private var paneCornerRadius =
        Double(AppAppearanceSettings.defaultPaneCornerRadius)
    @State private var workspaceEdgePadding =
        Double(AppAppearanceSettings.defaultWorkspaceEdgePadding)
    @State private var workspaceDividerThickness =
        Double(AppAppearanceSettings.defaultWorkspaceDividerThickness)
    @State private var isWindowHidden = false

    var body: some View {
        AppearanceSettingsPane(
            accentColor: $accentColor,
            activeTabBackgroundKind: $activeTabBackgroundKind,
            activeTabSolidColor: $activeTabSolidColor,
            activeTabGradientStartColor: $activeTabGradientStartColor,
            activeTabGradientEndColor: $activeTabGradientEndColor,
            activePaneBorderWidth: $activePaneBorderWidth,
            paneCornerRadius: $paneCornerRadius,
            workspaceEdgePadding: $workspaceEdgePadding,
            workspaceDividerThickness: $workspaceDividerThickness,
            isWindowHidden: $isWindowHidden
        )
    }
}
