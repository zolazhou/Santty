import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct AgentSkillSettingsSection: View {
    @AppStorage("customSkillDirectory") private var customDirectory = ""
    @State private var selectingDirectory = false

    var body: some View {
        Section {
            AgentSkillInstallationRow(name: "Codex", directory: home(".agents/skills"))
            AgentSkillInstallationRow(name: "Claude Code", directory: home(".claude/skills"))
            if !customDirectory.isEmpty {
                AgentSkillInstallationRow(
                    name: "Custom", directory: URL(fileURLWithPath: customDirectory)
                )
                .id(customDirectory)
            }
            Button("Choose Custom Skills Directory…") { selectingDirectory = true }
                .fileImporter(isPresented: $selectingDirectory, allowedContentTypes: [.folder]) {
                    result in
                    if case .success(let url) = result { customDirectory = url.path }
                }
        } header: {
            Text("Agent Skills")
        } footer: {
            Text(
                "Teaches agents to find panes, search logs and read context. Links update with Santty. Install the CLI and enable CLI access separately. Start a new agent session if the skill is not discovered."
            )
        }
    }

    private func home(_ path: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path)
    }
}

@MainActor
private struct AgentSkillInstallationRow: View {
    let name: String
    let directory: URL
    @State private var status: AgentSkillInstaller.Status = .missing
    @State private var message: String?
    private let installer = AgentSkillInstaller()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).fontWeight(.medium)
                Spacer()
                switch status {
                case .missing:
                    Button("Install") { perform { try installer.install(in: directory) } }
                case .installed:
                    Text("Installed").foregroundStyle(.secondary)
                    Button("Remove") { perform { try installer.remove(from: directory) } }
                case .otherApp(_, let broken):
                    Button(broken ? "Repair with This Version" : "Use This Version") {
                        perform { try installer.install(in: directory, replacingOtherApp: true) }
                    }
                    Button("Remove Link") { perform { try installer.remove(from: directory) } }
                case .conflict:
                    Text("Name Conflict").foregroundStyle(.secondary)
                }
            }
            Text(directory.appendingPathComponent("santty").path)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if case .otherApp(let path, let broken) = status {
                Text("\(broken ? "Broken link" : "Linked to another app"): \(path)")
                    .font(.caption).textSelection(.enabled)
            }
            if status == .conflict {
                Text("An unrelated item already exists here. Move it to install the skill.")
                    .font(.caption)
            }
            if let message { Text(message).font(.caption).textSelection(.enabled) }
        }
        .onAppear { refresh() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in refresh() }
    }

    private func refresh() { status = installer.status(in: directory) }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            message = nil
        } catch { message = error.localizedDescription }
        refresh()
    }
}
