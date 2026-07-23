import SwiftUI

@MainActor
struct GeneralSettingsPane: View {
    @State private var automaticallyChecksForUpdates =
        AppUpdater.shared.automaticallyChecksForUpdates

    var body: some View {
        Form {
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
