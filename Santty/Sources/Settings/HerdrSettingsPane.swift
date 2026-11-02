import AppKit
import SwiftUI

@MainActor
struct HerdrSettingsPane: View {
    @ObservedObject var client: HerdrCoreClient = .shared
    var createWorkspace: ((HerdrRemote) -> Bool)?
    @State private var executablePath = HerdrSettings.shared.executablePath ?? ""
    @State private var historyLines = HerdrSettings.shared.historyLines
    @State private var isBusy = false
    @State private var message: String?
    @State private var copiedDiagnostics = false

    private var normalizedPath: String? {
        let path = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    var body: some View {
        Form {
            Section {
                TextField("hc Path", text: $executablePath, prompt: Text("Automatic detection"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("herdr.executablePath")
                HStack {
                    Button("Choose…", action: chooseExecutable)
                    Button("Automatic") { executablePath = "" }
                    Spacer()
                    Button("Apply and Reconnect") {
                        perform { try await client.applyExecutablePath(normalizedPath) }
                    }
                    .disabled(normalizedPath == client.configuredExecutablePath)
                }
                LabeledContent("Status", value: client.details == nil ? "Disconnected" : "Connected")
                if let details = client.details {
                    LabeledContent("Version", value: details.version ?? "Unknown")
                    DisclosureGroup("Connection Details") {
                        detail("Executable", details.executablePath)
                        detail("Core", details.coreName)
                        detail("Core ID", details.coreID)
                        detail("Session", details.session)
                    }
                }
                HStack {
                    Button("Check Connection") { perform { _ = try await client.configuredMachines() } }
                    Button("Reconnect") { perform { try await client.reconnect() } }
                    if isBusy || client.isReconnecting { ProgressView().controlSize(.small) }
                }
                if let message {
                    Text(message).foregroundStyle(.red).textSelection(.enabled)
                } else if let error = client.lastError {
                    Text("Last connection error: " + error.localizedDescription).foregroundStyle(.red).textSelection(.enabled)
                }
            } header: {
                Text("herdr-core")
            } footer: {
                Text("Leave the path empty to find hc automatically. Applying a path checks compatibility before replacing Santty’s connection. Reconnecting keeps terminal processes and saved bindings.")
            }
            .disabled(isBusy || client.isReconnecting)

            Section {
                Stepper("\(historyLines) lines", value: $historyLines, in: HerdrSettings.historyRange, step: 500)
                    .accessibilityLabel("History Lines to Restore")
                    .onChange(of: historyLines) { _, value in client.settings.historyLines = value }
                Button("Reset to 2000 Lines") { historyLines = HerdrSettings.defaultHistoryLines }
            } header: {
                Text("History to Restore")
            } footer: {
                Text("Applies the next time a terminal is attached. This does not change how much history core retains. Zero restores only the current screen.")
            }

            Section {
                if client.machines.isEmpty {
                    Text(client.details == nil ? "Check the connection to load machines." : "No machines configured. Add one with hc machine add.")
                        .foregroundStyle(.secondary)
                }
                ForEach(client.machines, id: \.id) { machine in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(machine.name, systemImage: "network")
                            Spacer()
                            Button("Create Workspace") {
                                if createWorkspace?(machine.reference) != true {
                                    message = "A workspace could not be created. Close a workspace or finish the current close operation, then retry."
                                }
                            }
                            .disabled(createWorkspace == nil || isBusy || client.details == nil || client.isReconnecting)
                            .accessibilityLabel("Create Workspace on \(machine.name)")
                        }
                        Text(machine.destination + " · hc " + (machine.version ?? "Unknown"))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(machine.status)
                            .font(.caption).foregroundStyle(machine.state == "connected" ? Color.secondary : Color.orange)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
                Button("Refresh Machines") { perform { _ = try await client.configuredMachines() } }
                    .disabled(isBusy || client.isReconnecting)
            } header: {
                Text("Remote Machines")
            } footer: {
                Text("Machines are shared with other herdr-core clients. Configure machines, SSH login and hc updates with hc machine.")
            }

            Section {
                Button(copiedDiagnostics ? "Diagnostics Copied" : "Copy Diagnostics") {
                    NSPasteboard.general.clearContents()
                    copiedDiagnostics = NSPasteboard.general.setString(client.diagnosticText, forType: .string)
                }
                Text("Includes connection identity, versions, machine states and the recent error category. Excludes terminal contents, environment variables, connection commands and raw error text.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Diagnostics")
            }

            Section {
                Text("Quitting Santty keeps Herdr terminals running. Closing a pane, tab or workspace ends its terminals.")
                Text("Remote reconnects rebuild the screen and exit the previous Scroll Mode. Input typed while disconnected is never replayed.")
                Text("Fonts, themes and input sources use Terminal settings.")
            } header: {
                Text("Terminal Behavior")
            }
        }
        .formStyle(.grouped)
        .task {
            executablePath = client.configuredExecutablePath ?? ""
            historyLines = client.settings.historyLines
            perform { _ = try await client.configuredMachines() }
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose hc"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        executablePath = url.path
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy, !client.isReconnecting else { return }
        isBusy = true
        message = nil
        copiedDiagnostics = false
        Task { @MainActor in
            defer { isBusy = false }
            do { try await operation() }
            catch { message = error.localizedDescription }
        }
    }
}
