import AppKit
import ChurchKitAuth
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
    @Published private(set) var isChoosingCampus = false
    @Published private(set) var duplicates: [URL] = []

    private static let campusKey = "transcriberHelper.campusName"
    private var flow: ConnectFlow?

    /// The campus the helper was last known to send to, remembered because the helper's own status is only
    /// readable while it runs. Empty means it has never been connected, so Canopy's sign-in asks for a key too.
    var knownCampus: String { UserDefaults.standard.string(forKey: Self.campusKey) ?? "" }

    /// True when signing in to Canopy should also ask the website for the helper's campus key.
    var wantsKey: Bool { isBundled && knownCampus.isEmpty }

    private var service: SMAppService { .loginItem(identifier: Self.bundleID) }

    var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/Transcriber.app")
    }

    /// False in dev builds, which don't embed the helper.
    var isBundled: Bool { FileManager.default.fileExists(atPath: helperURL.path) }

    var startsAtLogin: Bool { registration == .enabled }

    /// Other copies of the helper outside Canopy.app. The old standalone Transcriber, updated in place by its own
    /// Sparkle feed, has the same bundle id as the built-in one, so two would fight over the audio input and
    /// the login item. Only the usual Applications folders are checked, so a developer's build folder isn't flagged.
    var standaloneCopies: [URL] {
        let found = (LSCopyApplicationURLsForBundleIdentifier(Self.bundleID as CFString, nil)?.takeRetainedValue() as? [URL]) ?? []
        let roots = ["/Applications/", NSHomeDirectory() + "/Applications/"]
        return found.filter { url in
            !url.path.hasPrefix(Bundle.main.bundleURL.path) && roots.contains { url.path.hasPrefix($0) }
        }
    }

    /// Quits and trashes a standalone copy. The Trash keeps it recoverable.
    func removeStandalone(_ url: URL) {
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleURL == url }
            .forEach { $0.terminate() }
        NSWorkspace.shared.recycle([url]) { [weak self] _, error in
            Task { @MainActor in
                if let error { self?.lastError = "Couldn't move it to the Trash: \(error.localizedDescription)" }
                self?.refresh()
            }
        }
    }

    /// Set when macOS wants the person to approve the login item in System Settings.
    var needsApproval: Bool { registration == .requiresApproval }

    private init() { refresh() }

    func refresh() {
        guard isBundled else { return }
        registration = service.status
        duplicates = standaloneCopies
        isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        // A status file that has stopped being refreshed is from a helper that has quit.
        if let s = HelperStatus.read(), !s.isStale(), isRunning { status = s } else { status = nil }
        if let name = status?.connectedTo, !name.isEmpty { UserDefaults.standard.set(name, forKey: Self.campusKey) }
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

    /// Gives the helper the campus key the website returned. The helper picks it up when it next looks (at
    /// once if running), and Canopy starts it if it isn't.
    func offer(_ campus: ConnectResult.CampusKey) {
        guard isBundled else { return }
        do {
            try HelperHandoff.offer(key: campus.key, campusID: campus.campusID, campusName: campus.campusName,
                                    keychainService: Self.bundleID, helperApp: helperURL)
            UserDefaults.standard.set(campus.campusName.isEmpty ? campus.campusID : campus.campusName, forKey: Self.campusKey)
            lastError = nil
            start()
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Signs in through the website just to pick the campus (the browser is usually still signed in, so it's one click).
    func chooseCampus(site: URL) {
        guard isBundled, !isChoosingCampus else { return }
        isChoosingCampus = true
        lastError = nil
        let flow = ConnectFlow()
        self.flow = flow
        Task {
            defer { isChoosingCampus = false; self.flow = nil }
            do {
                let result = try await flow.run(ConnectRequest(app: .transcriber, want: .key, site: site))
                if let campus = result.campus { offer(campus) }
            } catch is CancellationError {
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func cancelChoosingCampus() { flow?.cancel() }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}
