import Foundation
import Sparkle

@MainActor
final class AppUpdater {
    static let shared = AppUpdater()

    /// Whether Sparkle is configured (SUFeedURL/SUPublicEDKey are embedded at
    /// generate time; local unsigned builds ship without them).
    let isAvailable: Bool

    private let updaterController: SPUStandardUpdaterController

    private init() {
        let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        isAvailable = !feedURL.isEmpty
        updaterController = SPUStandardUpdaterController(
            startingUpdater: isAvailable,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        guard isAvailable else { return }
        updaterController.checkForUpdates(nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastUpdateCheckDate: Date? {
        updaterController.updater.lastUpdateCheckDate
    }
}
