import SwiftUI

@MainActor
struct GeneralSettingsPane: View {
    @State private var cliEnabled = CLIControlServer.isEnabled
    @State private var cliInstallationMessage: String?
    @State private var automaticallyChecksForUpdates =
        AppUpdater.shared.automaticallyChecksForUpdates

    var body: some View {
        Form {
            Section {
                Toggle("Allow CLI to Read Terminal Panes", isOn: $cliEnabled)
                    .onChange(of: cliEnabled) { _, value in
                        CLIControlServer.isEnabled = value
                    }
                Button("Install Command Line Tool") {
                    do {
                        try CLIInstaller.install()
                        cliEnabled = true
                        CLIControlServer.isEnabled = true
                        cliInstallationMessage = "Installed ~/.local/bin/santty."
                    } catch {
                        cliInstallationMessage = error.localizedDescription
                    }
                }
                if let cliInstallationMessage {
                    Text(cliInstallationMessage).textSelection(.enabled)
                }
                Text("If santty is not found, add this to your shell configuration:")
                    .font(.caption).foregroundStyle(.secondary)
                Text("export PATH=\"$HOME/.local/bin:$PATH\"")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } header: {
                Text("Command Line")
            } footer: {
                Text("Lets local tools running as your user read pane contents. The CLI updates with Santty. Reinstall the link if you move the app.")
            }
            AgentSkillSettingsSection()
            if AppUpdater.shared.isAvailable {
                Section {
                    Toggle(
                        "Automatically Check for Updates",
                        isOn: $automaticallyChecksForUpdates
                    )
                    .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                        AppUpdater.shared.automaticallyChecksForUpdates = newValue
                    }

                    HStack {
                        Button("Check Now") {
                            AppUpdater.shared.checkForUpdates()
                        }

                        Spacer()

                        if let lastCheckDate = AppUpdater.shared.lastUpdateCheckDate {
                            Text("Last checked: \(lastCheckDate.formatted())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text(
                        "Updates are delivered with Sparkle and verified with an EdDSA signature."
                    )
                }
            }
        }
        .formStyle(.grouped)
    }
}

#Preview("General Settings") {
    GeneralSettingsPane()
        .padding(24)
        .frame(width: 620)
        .background(Color(nsColor: .windowBackgroundColor))
}
