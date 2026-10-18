import AppKit
import ChurchKitCore
import Combine
import ServiceManagement

/// Controls the Transcriber helper that ships inside Canopy.app (Contents/Library/LoginItems).
/// It is a separate app with its own process, menu-bar icon and settings; Canopy only turns it on
/// at login, starts and stops it, and reads the status file it writes. Dev builds don't include it.
@MainActor
final class TranscriberHelper: ObservableObject {
    static let shared = TranscriberHelper()

    static let bundleID = "com.rosesashumans.churchlandingpage.transcriber"

    @Published private(set) var registration: SMAppService.Status = .notRegistered
    @Published private(set) var isRunning = false
    @Published private(set) var status: HelperStatus?
    @Published private(set) var lastError: String?

    private var service: SMAppService { .loginItem(identifier: Self.bundleID) }

    var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/Transcriber.app")
    }

    /// False in dev builds, which don't embed the helper.
    var isBundled: Bool { FileManager.default.fileExists(atPath: helperURL.path) }

    var startsAtLogin: Bool { registration == .enabled }

    /// Set when macOS wants the person to approve the login item in System Settings.
    var needsApproval: Bool { registration == .requiresApproval }

    private init() { refresh() }

    func refresh() {
        guard isBundled else { return }
        registration = service.status
        isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        // A status file that has stopped being refreshed is from a helper that has quit.
        if let s = HelperStatus.read(), !s.isStale(), isRunning { status = s } else { status = nil }
    }

    /// Turns "start at login" on or off. Turning it on also starts the helper now.
    func setStartsAtLogin(_ on: Bool) {
        lastError = nil
        do {
            if on {
                try service.register()
                start()
            } else {
                try service.unregister()
            }
        } catch {
            lastError = "Couldn't change the login item: \(error.localizedDescription)"
        }
        refresh()
    }

    func start() {
        guard isBundled, !isRunning else { return }
        NSWorkspace.shared.openApplication(at: helperURL, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            Task { @MainActor in
                if let error { self?.lastError = "Couldn't start Transcriber: \(error.localizedDescription)" }
                self?.refresh()
            }
        }
    }

    func stop() {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).forEach { $0.terminate() }
        // The helper removes its status file on a clean quit; give it a moment before reading again.
        Task { try? await Task.sleep(for: .seconds(1)); refresh() }
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}
