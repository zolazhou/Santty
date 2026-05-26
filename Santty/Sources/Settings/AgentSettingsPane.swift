import SwiftUI

@MainActor
struct AgentSettingsPane: View {
    @State private var isClaudeCodeEnabled = AgentNotificationSettings.isClaudeCodeEnabled
    @State private var isCodexEnabled = AgentNotificationSettings.isCodexEnabled
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Claude Code Notifications",
                    isOn: $isClaudeCodeEnabled
                )
                .onChange(of: isClaudeCodeEnabled) { _, newValue in
                    applyClaudeCodeEnabled(newValue)
                }

                Toggle(
                    "Codex Notifications",
                    isOn: $isCodexEnabled
                )
                .onChange(of: isCodexEnabled) { _, newValue in
                    applyCodexEnabled(newValue)
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(
                    "Santty installs local helper scripts to deliver agent notifications."
                )
            }
        }
        .formStyle(.grouped)
    }

    private func applyClaudeCodeEnabled(_ isEnabled: Bool) {
        guard isEnabled else {
            do {
                try AgentIntegrationInstaller().uninstallClaudeCodeIntegration(
                    removeScripts: !isCodexEnabled
                )
                AgentNotificationSettings.isClaudeCodeEnabled = false
                statusMessage = "Claude Code notifications disabled."
            } catch {
                isClaudeCodeEnabled = true
                statusMessage = "Could not disable Claude Code: \(error.localizedDescription)"
            }
            return
        }

        do {
            AgentNotifier.shared.requestAuthorization()
            try AgentIntegrationInstaller().installClaudeCodeIntegration()
            AgentNotificationSettings.isClaudeCodeEnabled = true
            statusMessage = "Claude Code notifications enabled."
        } catch {
            isClaudeCodeEnabled = false
            AgentNotificationSettings.isClaudeCodeEnabled = false
            statusMessage = "Could not enable Claude Code: \(error.localizedDescription)"
        }
    }

    private func applyCodexEnabled(_ isEnabled: Bool) {
        guard isEnabled else {
            do {
                try AgentIntegrationInstaller().uninstallCodexIntegration(
                    removeScripts: !isClaudeCodeEnabled
                )
                AgentNotificationSettings.isCodexEnabled = false
                statusMessage = "Codex notifications disabled."
            } catch {
                isCodexEnabled = true
                statusMessage = "Could not disable Codex: \(error.localizedDescription)"
            }
            return
        }

        do {
            AgentNotifier.shared.requestAuthorization()
            try AgentIntegrationInstaller().installCodexIntegration()
            AgentNotificationSettings.isCodexEnabled = true
            statusMessage = "Codex notifications enabled."
        } catch {
            isCodexEnabled = false
            AgentNotificationSettings.isCodexEnabled = false
            statusMessage = "Could not enable Codex: \(error.localizedDescription)"
        }
    }
}

#Preview("Agent Settings") {
    AgentSettingsPane()
        .padding(24)
        .frame(width: 620)
        .background(Color(nsColor: .windowBackgroundColor))
}
