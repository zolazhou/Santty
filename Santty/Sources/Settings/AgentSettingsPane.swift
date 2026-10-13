import SwiftUI

@MainActor
struct AgentSettingsPane: View {
    @State private var claude = AgentNotificationSettings.isClaudeCodeEnabled
    @State private var codex = AgentNotificationSettings.isCodexEnabled
    @State private var other = AgentNotificationSettings.isOtherAgentsEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Claude Code Notifications", isOn: $claude)
                    .onChange(of: claude) { _, value in AgentNotificationSettings.isClaudeCodeEnabled = value; authorize(value) }
                Toggle("Codex Notifications", isOn: $codex)
                    .onChange(of: codex) { _, value in AgentNotificationSettings.isCodexEnabled = value; authorize(value) }
                Toggle("Other Herdr Agent Notifications", isOn: $other)
                    .onChange(of: other) { _, value in AgentNotificationSettings.isOtherAgentsEnabled = value; authorize(value) }
            } footer: {
                Text("Agent status and messages come from the configured Herdr service, including while Default is selected. These switches control system notifications; messages remain available in Agents. Santty does not install agent hooks.")
            }
        }.formStyle(.grouped)
    }
    private func authorize(_ enabled: Bool) { if enabled { AgentNotifier.shared.requestAuthorization() } }
}
