import Sparkle

/// Thin wrapper around Sparkle so the rest of the app just needs one shared
/// instance and a single action for the "Check for Updates…" menu item.
@MainActor
final class UpdateService {
    static let shared = UpdateService()

    private let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
