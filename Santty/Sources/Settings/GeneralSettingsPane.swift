import SwiftUI

@MainActor
enum HerdrSettings {
    static let didChangeNotification = Notification.Name("Santty.HerdrSettings.didChange")

    static var endpoint: HerdrEndpoint {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaults = UserDefaults.standard
        return .init(binary: URL(fileURLWithPath: defaults.string(forKey: "HerdrBinary") ?? HerdrExecutable.suggestedPath(home: home)),
                     session: defaults.string(forKey: "HerdrSession") ?? "default",
                     socketPath: defaults.string(forKey: "HerdrSocket") ?? home.appendingPathComponent(".config/herdr/herdr.sock").path)
    }

    static func save(binary: String, session: String, socket: String) throws {
        guard binary.hasPrefix("/") else { throw CLIError("Choose an absolute Herdr executable path") }
        let endpoint = HerdrEndpoint(binary: URL(fileURLWithPath: binary), session: session, socketPath: socket)
        try endpoint.validate()
        let defaults = UserDefaults.standard
        defaults.set(binary, forKey: "HerdrBinary")
        defaults.set(session, forKey: "HerdrSession")
        defaults.set(socket, forKey: "HerdrSocket")
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

@MainActor
private struct HerdrSettingsSection: View {
    @State private var binary = HerdrSettings.endpoint.binary.path
    @State private var session = HerdrSettings.endpoint.session
    @State private var socket = HerdrSettings.endpoint.socketPath
    @State private var message: String?

    var body: some View {
        Section {
            TextField("Executable", text: $binary)
            TextField("Session", text: $session)
            TextField("API socket", text: $socket)
            Button("Apply and Refresh Workspaces") {
                do {
                    try HerdrSettings.save(binary: binary, session: session, socket: socket)
                    message = "Connection settings saved."
                } catch { message = error.localizedDescription }
            }
            if let message { Text(message).textSelection(.enabled) }
        } header: {
            Text("Herdr Workspaces")
        } footer: {
            Text("Local and saved SSH machines appear in the workspace switcher. Add a remote machine from Pane > Add Remote Herdr Machine. Setup and authentication run in a local terminal using Herdr and OpenSSH. Use absolute local paths.")
        }
    }
}

@MainActor
struct GeneralSettingsPane: View {
    @State private var cliEnabled = CLIControlServer.isEnabled
    @State private var cliInstallationMessage: String?
    @State private var automaticallyChecksForUpdates =
        AppUpdater.shared.automaticallyChecksForUpdates

    var body: some View {
        Form {
            HerdrSettingsSection()
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
