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
                    HStack {
                        Slider(
                            value: Binding(
                                get: { activePaneBorderWidth },
                                set: { newValue in
                                    activePaneBorderWidth = newValue.rounded()
                                    AppAppearanceSettings.activePaneBorderWidth =
                                        CGFloat(activePaneBorderWidth)
                                }
                            ),
                            in: activePaneBorderWidthRange,
                            step: 1
                        )

                        Text("\(Int(activePaneBorderWidth)) px")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)

                        Button("Reset") {
                            AppAppearanceSettings.resetActivePaneBorderWidth()
                            activePaneBorderWidth =
                                Double(AppAppearanceSettings.activePaneBorderWidth)
                        }
                    }
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
    @State private var isWindowHidden = false

    var body: some View {
        AppearanceSettingsPane(
            accentColor: $accentColor,
            activeTabBackgroundKind: $activeTabBackgroundKind,
            activeTabSolidColor: $activeTabSolidColor,
            activeTabGradientStartColor: $activeTabGradientStartColor,
            activeTabGradientEndColor: $activeTabGradientEndColor,
            activePaneBorderWidth: $activePaneBorderWidth,
            isWindowHidden: $isWindowHidden
        )
    }
}
