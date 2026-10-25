import AppKit
import ServiceManagement

/// What the merged app tidies up the first time it runs on a Mac that had the separate Canopy app: the old helper's
/// login item, the old Canopy.app itself, and starting at login. Each step asks or happens once.
@MainActor
enum FirstLaunch {
    private static let defaults = UserDefaults.standard
    private static let handledOldCanopy = "firstLaunch.oldCanopyHandled"
    private static let askedLogin = "firstLaunch.askedLaunchAtLogin"
    /// Canopy used to carry this app inside it as a login item, under the id this app now has.
    private static let nestedHelperID = "com.rosesashumans.churchlandingpage.transcriber"

    static func run() async {
        guard !FileTest.isSafeMode else { return }
        retireNestedHelper()
        offerToTrashOldCanopy()
        offerLaunchAtLogin()
    }

    /// The old Canopy registered its built-in Transcriber to open at login. That helper is gone, so drop the stale entry.
    private static func retireNestedHelper() {
        let helper = SMAppService.loginItem(identifier: nestedHelperID)
        guard helper.status != .notRegistered else { return }
        try? helper.unregister()
    }

    /// Copies of the old Canopy still sitting in the usual Applications folders (not this app, wherever it is).
    nonisolated static func oldCanopyCopies(finding urls: [URL], home: String = NSHomeDirectory(), running: URL = Bundle.main.bundleURL) -> [URL] {
        urls.filter { $0.standardizedFileURL != running.standardizedFileURL && ($0.path.hasPrefix("/Applications/") || $0.path.hasPrefix(home + "/Applications/")) }
    }

    private static func offerToTrashOldCanopy() {
        guard !defaults.bool(forKey: handledOldCanopy) else { return }
        let copies = oldCanopyCopies(finding: NSWorkspace.shared.urlsForApplications(withBundleIdentifier: CanopyMigration.oldBundleID))
        defaults.set(true, forKey: handledOldCanopy)
        guard !copies.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Move the old Canopy to the Trash?"
        alert.informativeText = "This Canopy now includes everything the old one did, and your workflows and devices have been brought across. The old app is still installed at \(copies[0].deletingLastPathComponent().path). Keeping both can start the same workflows twice."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Keep It")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for url in copies {
            NSWorkspace.shared.runningApplications.filter { $0.bundleURL == url }.forEach { $0.terminate() }
            NSWorkspace.shared.recycle([url]) { _, _ in }
        }
    }

    /// Canopy's workflows and Transcriber's captions only run while the app is open, so a person who used the old
    /// Canopy is asked once whether to open it at login (the old built-in helper did that for them).
    private static func offerLaunchAtLogin() {
        guard !defaults.bool(forKey: askedLogin), defaults.bool(forKey: CanopyMigration.carriedOverKey),
              SMAppService.mainApp.status != .enabled else { return }
        defaults.set(true, forKey: askedLogin)
        let alert = NSAlert()
        alert.messageText = "Open Canopy when you log in?"
        alert.informativeText = "Scheduled workflows and live captions only run while Canopy is open. You can change this later in Settings."
        alert.addButton(withTitle: "Open at Login")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { try? SMAppService.mainApp.register() }
    }
}
