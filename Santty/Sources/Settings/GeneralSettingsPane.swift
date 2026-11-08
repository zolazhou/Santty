import SwiftUI

@MainActor
struct GeneralSettingsPane: View {
    @State private var cliEnabled = CLIControlServer.isEnabled
    @State private var cliControlEnabled = CLICommandRouter.controlEnabled
    @State private var cliInputEnabled = CLICommandRouter.inputEnabled
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
                Toggle("Allow CLI to Manage Panes and Layout", isOn: $cliControlEnabled)
                    .disabled(!cliEnabled)
                    .onChange(of: cliControlEnabled) { _, value in
                        CLICommandRouter.controlEnabled = value
                    }
                Toggle("Allow CLI to Send Terminal Input", isOn: $cliInputEnabled)
                    .disabled(!cliEnabled)
                    .onChange(of: cliInputEnabled) { _, value in
                        CLICommandRouter.inputEnabled = value
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
                Text("Read access lets local tools running as your user read pane contents. Pane control can create and close sessions; terminal input can execute commands in local and remote terminals. These permissions are separate and off by default. The CLI updates with Santty; reinstall the link if you move the app.")
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
