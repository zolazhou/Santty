import AppKit
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
                            onStartRecording: { recordingAction = action },
                            onFinishRecording: { recordingAction = nil }
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

            if isRecording {
                FocusedShortcutRecorder(
                    action: action,
                    onChange: { KeybindingSettings.notifyChange(for: action) },
                    onFinish: onFinishRecording
                )
                .frame(width: 170, alignment: .trailing)
            } else {
                Text(KeybindingSettings.displayShortcut(for: action) ?? "")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: onStartRecording)
            }
        }
    }
}

struct FocusedShortcutRecorder: NSViewRepresentable {
    let action: KeybindingAction
    let onChange: () -> Void
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeNSView(context: Context) -> KeyboardShortcuts.RecorderCocoa {
        let recorder = KeyboardShortcuts.RecorderCocoa(for: action.shortcutName) { _ in
            onChange()
            onFinish()
        }
        let coordinator = context.coordinator
        coordinator.recorder = recorder
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSControl.textDidEndEditingNotification,
            object: recorder,
            queue: .main
        ) { _ in
            // AppKit may end and restart editing while updating the recorder.
            Task { @MainActor in
                guard let recorder = coordinator.recorder else { return }
                if let editor = recorder.currentEditor(), recorder.window?.firstResponder === editor {
                    return
                }
                coordinator.onFinish()
            }
        }
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                guard let window = recorder.window, recorder.canBecomeKeyView else { return }
                window.makeFirstResponder(recorder)
            }
        }
        return recorder
    }

    func updateNSView(_ recorder: KeyboardShortcuts.RecorderCocoa, context: Context) {
        recorder.shortcutName = action.shortcutName
    }

    static func dismantleNSView(_ recorder: KeyboardShortcuts.RecorderCocoa, coordinator: Coordinator) {
        if let observer = coordinator.observer {
            NotificationCenter.default.removeObserver(observer)
        }
        coordinator.observer = nil
        coordinator.recorder = nil
    }

    @MainActor
    final class Coordinator {
        let onFinish: () -> Void
        weak var recorder: KeyboardShortcuts.RecorderCocoa?
        var observer: NSObjectProtocol?

        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    }
}

#Preview("Keybinding Settings") {
    KeybindingSettingsPane()
        .padding(24)
        .frame(width: 620)
        .background(Color(nsColor: .windowBackgroundColor))
}
