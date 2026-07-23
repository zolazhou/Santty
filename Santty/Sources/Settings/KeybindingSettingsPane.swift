import KeyboardShortcuts
import SwiftUI

@MainActor
struct KeybindingSettingsPane: View {
    @State private var recordingAction: KeybindingAction?

    var body: some View {
        Form {
            ForEach(groupedActions, id: \.title) { group in
                Section(header: Text(group.title)) {
                    ForEach(group.actions) { action in
                        KeybindingActionRow(
                            action: action,
                            isRecording: recordingAction == action,
                            onStartRecording: {
                                recordingAction = action
                            },
                            onFinishRecording: {
                                recordingAction = nil
                            }
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var groupedActions: [(title: String, actions: [KeybindingAction])] {
        ["Pane", "Tab"].compactMap { title in
            let actions = KeybindingAction.allCases.filter { $0.groupTitle == title }
            return actions.isEmpty ? nil : (title, actions)
        }
    }
}

@MainActor
private struct KeybindingActionRow: View {
    let action: KeybindingAction
    let isRecording: Bool
    let onStartRecording: () -> Void
    let onFinishRecording: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(action.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            keyCell
        }
    }

    @ViewBuilder
    private var keyCell: some View {
        if isRecording {
            KeyboardShortcuts.Recorder(for: action.shortcutName) { shortcut in
                if shortcut == nil {
                    KeybindingSettings.resetShortcut(for: action)
                } else {
                    KeybindingSettings.notifyChange(for: action)
                }
                onFinishRecording()
            }
            .frame(width: 170, alignment: .trailing)
        } else {
            Text(KeybindingSettings.displayShortcut(for: action) ?? "")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    onStartRecording()
                }
        }
    }
}

#Preview("Keybinding Settings") {
    KeybindingSettingsPane()
        .padding(24)
        .frame(width: 620)
        .background(Color(nsColor: .windowBackgroundColor))
}
