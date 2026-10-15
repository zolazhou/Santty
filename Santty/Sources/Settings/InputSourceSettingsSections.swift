import Carbon.HIToolbox
import SwiftUI

@MainActor
struct InputSourceSettingsSections: View {
    @State private var settings = InputSourceSettings.configuration
    @State private var sources = SystemInputSources.available
    @ObservedObject private var coordinator = PaneInputSourceCoordinator.shared

    var body: some View {
        Group {
            Section {
                sourcePicker("English Input Source", selection: $settings.englishInputSourceID)
                if !sourceIsAvailable(settings.englishInputSourceID) {
                    Text("Choose an enabled English input source. Unavailable sources cannot be selected.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("Automatically Switch to English", isOn: $settings.commandPaletteEnglish)
                    .accessibilityLabel("Command Palette Input: Automatically Switch to English")
            } header: {
                Text("Command Palette Input")
            } footer: {
                Text("Use the selected English input source when opening the command palette. Closing it applies the current pane's rule, or restores the previous input source.")
            }

            Section {
                Toggle("Switch Input Source by Foreground Program", isOn: $settings.paneRulesEnabled)
                    .accessibilityLabel("Switch Input Source by Foreground Program")
                ForEach($settings.rules) { $rule in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Program (e.g. nvim)", text: $rule.program)
                                .accessibilityLabel("Program name")
                            sourcePicker("Input Source", selection: $rule.inputSourceID, includeEnglish: true)
                                .labelsHidden()
                                .accessibilityLabel("Input source for \(rule.program)")
                            Button {
                                settings.rules.removeAll { $0.id == rule.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove Rule")
                            .accessibilityLabel("Remove rule for \(rule.program)")
                        }
                        if let message = ruleWarning(rule) {
                            Text(message).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                Button("Add Program Rule") {
                    settings.rules.append(.init(program: "", inputSourceID: InputSourceSettings.english))
                }
                if let error = coordinator.lastError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Pane Input")
            } footer: {
                Text("Rules apply when entering a terminal pane or its foreground program changes. Program names match exactly; unknown programs keep the current input source. Manual changes last until the next context change. SSH and tmux programs require foreground process information from Herdr.")
            }
        }
        .onChange(of: settings) { _, value in InputSourceSettings.configuration = value }
        .onAppear { sources = SystemInputSources.available }
        .onReceive(DistributedNotificationCenter.default.publisher(
            for: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String))) { _ in
                sources = SystemInputSources.available
            }
    }

    @ViewBuilder
    private func sourcePicker(_ title: String, selection: Binding<String>, includeEnglish: Bool = false) -> some View {
        Picker(title, selection: selection) {
            Text("Choose Input Source…").tag("")
            if includeEnglish { Text("English Input Source").tag(InputSourceSettings.english) }
            ForEach(sources) { source in Text(source.name).tag(source.id) }
            if !selection.wrappedValue.isEmpty,
               !(includeEnglish && selection.wrappedValue == InputSourceSettings.english),
               !sources.contains(where: { $0.id == selection.wrappedValue }) {
                Text("Unavailable Input Source").tag(selection.wrappedValue)
            }
        }
        .accessibilityLabel(title)
    }

    private func ruleWarning(_ rule: InputSourceSettings.Rule) -> String? {
        let program = InputSourceForeground.Process.normalized(rule.program)
        if program.isEmpty || program.contains(where: \.isWhitespace) {
            return "Enter an executable name without arguments."
        }
        if settings.rules.first(where: { InputSourceForeground.Process.normalized($0.program) == program })?.id != rule.id {
            return "The first rule for this program takes precedence."
        }
        if settings.sourceID(for: rule).isEmpty { return "Choose an input source for this rule." }
        if !sourceIsAvailable(settings.sourceID(for: rule)) {
            return "Enable this input source in System Settings, or choose another."
        }
        return nil
    }

    private func sourceIsAvailable(_ id: String) -> Bool {
        sources.contains { $0.id == id }
    }
}
