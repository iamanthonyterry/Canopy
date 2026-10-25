import Foundation
import Sparkle

/// Sparkle auto-update, from the appcast attached to the latest GitHub release.
/// Updates download in the background; installing relaunches the app, so that waits until the
/// transcriber is stopped (or the user picks "Restart to Update") — a live service is never interrupted.
@MainActor
final class UpdateManager: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    weak var model: AppModel?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: !FileTest.isSafeMode, updaterDelegate: self, userDriverDelegate: nil)
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        // Sparkle calls this block once, from the main thread; it isn't marked Sendable.
        nonisolated(unsafe) let install = immediateInstallationBlock
        Task { @MainActor in
            guard let model = self.model else { return install() }
            if model.running {
                model.pendingUpdate = install
            } else {
                install()
            }
        }
        return true
    }
}
