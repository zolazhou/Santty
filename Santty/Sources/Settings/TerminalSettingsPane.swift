import AppKit
import SwiftUI

@MainActor
struct TerminalSettingsPane: View {
    @Binding var terminalThemeName: String
    @Binding var terminalFontFamily: String
    @Binding var terminalFontSize: Double
    @Binding var terminalPadding: Double
    @State private var fontPanelTarget = FontPanelTarget()

    var body: some View {
        Form {
            Section {
                LabeledContent("Theme") {
                    HStack {
                        Picker(
                            "Theme",
                            selection: Binding(
                                get: { terminalThemeName },
                                set: { newValue in
                                    terminalThemeName = newValue
                                    TerminalSettings.themeName = newValue
                                }
                            )
                        ) {
                            ForEach(TerminalDefaults.availableThemeNames, id: \.self) { themeName in
                                Text(themeName).tag(themeName)
                            }
                        }
                        .labelsHidden()

                        Button("Reset") {
                            TerminalSettings.resetThemeName()
                            terminalThemeName = TerminalSettings.themeName
                        }
                    }
                }

                LabeledContent("Font") {
                    HStack {
                        Text("\(terminalFontFamily), \(Int(terminalFontSize)) pt")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button("Choose...") {
                            fontPanelTarget.showFontPanel(
                                family: terminalFontFamily,
                                size: CGFloat(terminalFontSize)
                            ) { selectedFont in
                                terminalFontFamily =
                                    selectedFont.familyName ?? selectedFont.fontName
                                terminalFontSize = selectedFont.pointSize.rounded()
                                TerminalSettings.fontFamily = terminalFontFamily
                                TerminalSettings.fontSize = CGFloat(terminalFontSize)
                            }
                        }

                        Button("Reset") {
                            TerminalSettings.resetFontFamily()
                            TerminalSettings.resetFontSize()
                            terminalFontFamily = TerminalSettings.fontFamily
                            terminalFontSize = Double(TerminalSettings.fontSize)
                        }
                    }
                }

                LabeledContent("Padding") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { terminalPadding },
                                set: { newValue in
                                    terminalPadding = newValue.rounded()
                                    TerminalSettings.padding = CGFloat(terminalPadding)
                                }
                            ),
                            in: Double(
                                TerminalSettings.paddingRange.lowerBound)...Double(
                                    TerminalSettings.paddingRange.upperBound),
                            step: 1
                        )

                        Text("\(Int(terminalPadding)) px")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)

                        Button("Reset") {
                            TerminalSettings.resetPadding()
                            terminalPadding = Double(TerminalSettings.padding)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

#Preview("Terminal Settings") {
    TerminalSettingsPanePreview()
        .padding(24)
        .frame(width: 620)
        .background(Color(nsColor: .windowBackgroundColor))
}

@MainActor
private struct TerminalSettingsPanePreview: View {
    @State private var terminalThemeName = TerminalSettings.themeName
    @State private var terminalFontFamily = TerminalSettings.fontFamily
    @State private var terminalFontSize = Double(TerminalSettings.fontSize)
    @State private var terminalPadding = Double(TerminalSettings.padding)

    var body: some View {
        TerminalSettingsPane(
            terminalThemeName: $terminalThemeName,
            terminalFontFamily: $terminalFontFamily,
            terminalFontSize: $terminalFontSize,
            terminalPadding: $terminalPadding
        )
    }
}
