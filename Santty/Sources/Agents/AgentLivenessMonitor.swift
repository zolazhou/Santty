import Foundation

@MainActor
final class AgentLivenessMonitor {
    static let shared = AgentLivenessMonitor()

    private let scanInterval: TimeInterval
    private let missingScanThreshold: Int
    private let inspector: AgentForegroundProcessInspector
    private var timer: Timer?

    init(
        scanInterval: TimeInterval = 1,
        missingScanThreshold: Int = 2,
        inspector: AgentForegroundProcessInspector = AgentForegroundProcessInspector()
    ) {
        self.scanInterval = scanInterval
        self.missingScanThreshold = missingScanThreshold
        self.inspector = inspector
    }

    func startIfNeeded() {
        guard timer == nil,
            AgentSessionStore.shared.hasLivenessTrackableSessions,
            AgentNotificationSettings.isClaudeCodeEnabled || AgentNotificationSettings.isCodexEnabled
        else {
            return
        }

        let timer = Timer.scheduledTimer(
            withTimeInterval: scanInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.scanOnce(missingScanThreshold: self.missingScanThreshold)
            }
        }
        self.timer = timer
        scanOnce(missingScanThreshold: missingScanThreshold)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refreshNow(missingScanThreshold: Int = 1) {
        scanOnce(missingScanThreshold: missingScanThreshold)
    }

    private func scanOnce(missingScanThreshold: Int) {
        guard AgentSessionStore.shared.hasLivenessTrackableSessions else {
            stop()
            return
        }

        let observations = inspector.observe(
            paneForegroundProcessIDs: AgentForegroundProcessRegistry.shared.snapshot()
        )
        AgentSessionStore.shared.reconcileForegroundLiveness(
            observations: observations,
            missingScanThreshold: missingScanThreshold
        )
        if !AgentSessionStore.shared.hasLivenessTrackableSessions {
            stop()
        }
    }
}
