import AppKit

/// An app that was installed as Transcriber.app and updated in place to Canopy keeps its old file name (Sparkle installs
/// over the same path). This moves it to Canopy.app, beside where it was, and opens it again.
///
/// It waits for the app to be idle first, so a live service is never cut off to rename a file, and only touches
/// /Applications and ~/Applications: an app run from anywhere else (a build folder, Downloads) is left alone.
@MainActor
enum SelfRename {
    nonisolated static let oldName = "Transcriber.app"
    nonisolated static let newName = "Canopy.app"

    /// Where this copy would move to, or nil when it should stay put.
    nonisolated static func destination(for bundle: URL, homeDirectory: String = NSHomeDirectory(), fileManager: FileManager = .default) -> URL? {
        guard bundle.lastPathComponent == oldName else { return nil }
        let folder = bundle.deletingLastPathComponent()
        guard folder.path == "/Applications" || folder.path == homeDirectory + "/Applications" else { return nil }
        let target = folder.appendingPathComponent(newName)
        guard !fileManager.fileExists(atPath: target.path), fileManager.isWritableFile(atPath: folder.path) else { return nil }
        return target
    }

    static var pending: URL? { FileTest.isSafeMode ? nil : destination(for: Bundle.main.bundleURL) }

    /// Quits this app, renames it once it has gone, and opens it again. Falls back to opening the original if the move fails.
    static func performAndRelaunch() {
        guard let target = pending else { return }
        let script = #"( while kill -0 "$1" 2>/dev/null; do sleep 0.3; done; if [ ! -e "$3" ] && mv -- "$2" "$3"; then open "$3"; else open "$2"; fi ) >/dev/null 2>&1 &"#
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path, target.path]
        do { try p.run() } catch { return }
        NSApp.terminate(nil)
    }
}
