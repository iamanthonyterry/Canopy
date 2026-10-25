import AppKit
import ServiceManagement

/// What the merged app tidies up the first time it runs on a Mac that had the separate Canopy app: the old helper's
/// login item, the old Canopy.app itself, a second copy of this same app (a Mac that had both old apps ends up with
/// two, since each updates to the same app), and starting at login. Each step asks or happens once.
@MainActor
enum FirstLaunch {
    private static let defaults = UserDefaults.standard
    private static let handledOldCanopy = "firstLaunch.oldCanopyHandled"
    private static let askedLogin = "firstLaunch.askedLaunchAtLogin"
    /// Paths of other copies of this app the person chose to keep, so they are not asked again about the same ones.
    private static let declinedCopies = "firstLaunch.declinedOtherCopies"
    /// Canopy used to carry this app inside it as a login item, under the id this app now has.
    private static let nestedHelperID = "com.rosesashumans.churchlandingpage.transcriber"

    static func run() async {
        guard !FileTest.isSafeMode else { return }
        retireNestedHelper()
        await offerToTrashOldCanopy()
        await offerToTrashOtherCopies()
        offerLaunchAtLogin()
    }

    /// The old Canopy registered its built-in Transcriber to open at login. That helper is gone, so drop the stale entry.
    private static func retireNestedHelper() {
        let helper = SMAppService.loginItem(identifier: nestedHelperID)
        guard helper.status != .notRegistered else { return }
        try? helper.unregister()
    }

    /// Every app with this bundle id in the given folders (the usual two Applications folders), looking one folder deep.
    /// Read from the apps' own Info.plist: Launch Services' list of where an app is installed is often stale or incomplete.
    nonisolated static func installedCopies(bundleID: String, in roots: [URL] = applicationRoots, fileManager: FileManager = .default) -> [URL] {
        func children(_ url: URL) -> [URL] {
            (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        }
        var found: [URL] = []
        for root in roots {
            for item in children(root) {
                if item.pathExtension == "app" {
                    if Bundle(url: item)?.bundleIdentifier == bundleID { found.append(item) }
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    found += children(item).filter { $0.pathExtension == "app" && Bundle(url: $0)?.bundleIdentifier == bundleID }
                }
            }
        }
        return found
    }

    nonisolated static var applicationRoots: [URL] {
        [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: NSHomeDirectory() + "/Applications")]
    }

    /// Copies of the old Canopy still sitting in the usual Applications folders (not this app, wherever it is).
    nonisolated static func oldCanopyCopies(finding urls: [URL], home: String = NSHomeDirectory(), running: URL = Bundle.main.bundleURL) -> [URL] {
        urls.filter { $0.standardizedFileURL != running.standardizedFileURL && ($0.path.hasPrefix("/Applications/") || $0.path.hasPrefix(home + "/Applications/")) }
    }

    private static func offerToTrashOldCanopy() async {
        guard !defaults.bool(forKey: handledOldCanopy) else { return }
        let copies = oldCanopyCopies(finding: installedCopies(bundleID: CanopyMigration.oldBundleID))
        defaults.set(true, forKey: handledOldCanopy)
        guard !copies.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Move the old Canopy to the Trash?"
        alert.informativeText = "This Canopy now includes everything the old one did, and your workflows and devices have been brought across. The old app is still installed at \(copies[0].deletingLastPathComponent().path). Keeping both can start the same workflows twice."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Keep It")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await quitAndTrash(copies)
    }

    /// Copies not already answered with "Keep Both".
    nonisolated static func unanswered(_ urls: [URL], declined: Set<String>) -> [URL] {
        urls.filter { !declined.contains($0.standardizedFileURL.path) }
    }

    /// Another copy of this very app in Applications. A Mac that had the old Canopy and the standalone Transcriber gets one
    /// from each feed, at different paths. Two copies would both listen to the microphone, run the same scheduled
    /// workflows and open at login, so the person is asked to keep just the one that is running.
    private static func offerToTrashOtherCopies() async {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let declined = Set(defaults.stringArray(forKey: declinedCopies) ?? [])
        let copies = unanswered(
            oldCanopyCopies(finding: installedCopies(bundleID: id)),
            declined: declined)
        guard !copies.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = copies.count == 1 ? "Another copy of Canopy is installed" : "Other copies of Canopy are installed"
        alert.informativeText = "This Mac has Canopy at \(Bundle.main.bundleURL.path) (the one running now) and also at \(copies.map(\.path).joined(separator: ", ")). Both would listen to the microphone, run the same workflows and open at login. Quit and move the other to the Trash?"
        alert.addButton(withTitle: "Quit and Move to Trash")
        alert.addButton(withTitle: "Keep Both")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            defaults.set(Array(declined.union(copies.map { $0.standardizedFileURL.path })), forKey: declinedCopies)
            return
        }
        // "Open at login" belongs to the app's bundle id, not a path, so it follows whichever copy is left. Put it back if removing the other one dropped it.
        let atLogin = SMAppService.mainApp.status == .enabled
        await quitAndTrash(copies)
        if atLogin, SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
    }

    /// Quits any of these that are running (waiting a few seconds, then insisting), then moves them to the Trash.
    private static func quitAndTrash(_ urls: [URL]) async {
        for url in urls {
            let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
            running.forEach { $0.terminate() }
            for _ in 0..<20 where running.contains(where: { !$0.isTerminated }) { try? await Task.sleep(for: .milliseconds(250)) }
            running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        }
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { _, _ in continuation.resume() }
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
