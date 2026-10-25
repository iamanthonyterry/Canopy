import Foundation

/// One-time carry-over of the separate Canopy app's settings (workflows, devices, schedules, alerts, AI choices…)
/// into this app, which took over Transcriber's bundle id. Settings are stored per bundle id, so without this the
/// merged app would start empty.
///
/// It copies and never deletes, so the old app still works if someone goes back to it. It runs before anything reads
/// those settings, and only once (its own marker; the kit's `LegacyMigration` marker is per app, not per source, and
/// is already taken by the Transcriber carry-over).
///
/// Keychain items need nothing here: this app keeps Canopy's Keychain service name, so the saved website sign-in is
/// found as before. macOS asks once to let this app use items the old app created ("Always Allow").
nonisolated enum CanopyMigration {
    static let oldBundleID = "com.rosesashumans.churchlandingpage.canopy"
    static let markerKey = "canopyMigration.v1"
    /// Set when settings really were carried over, so the first-launch steps can tell an upgrade from a fresh install.
    static let carriedOverKey = "canopyMigration.carriedOver"

    /// Keys never copied: Sparkle's bookkeeping and the system's, and settings of screens that no longer exist
    /// (inventory, feature switches, Show Mode, wireless monitoring, the export queue, starred clips, the file browser).
    private static let skippedPrefixes = ["SU", "NS", "AK", "com.apple.", "churchkit.", "inventory.", "feature.", "showMode.", "wireless."]
    private static let removedKeys: Set<String> = ["showScreens", "exportPresets", "clipMetadata", "dashboardFilesViewMode", "galleryGroupByDay"]

    struct Result: Equatable {
        var copied: [String] = []
        /// Keys this app already had, which win.
        var keptExisting: [String] = []
    }

    static func shouldCopy(_ key: String) -> Bool {
        !removedKeys.contains(key) && !skippedPrefixes.contains { key.hasPrefix($0) }
    }

    /// A value an earlier launch may have saved as an empty list or object before anything was carried over.
    private static func isEmptyPlaceholder(_ value: Any?) -> Bool {
        guard let data = value as? Data, data.count <= 2 else { return false }
        return ["[]", "{}"].contains(String(decoding: data, as: UTF8.self))
    }

    /// Copies `old` into `defaults`. A key `defaults` already holds is kept, unless it is only an empty list or object.
    @discardableResult
    static func copySettings(from old: [String: Any], into defaults: UserDefaults) -> Result {
        var result = Result()
        for (key, value) in old.sorted(by: { $0.key < $1.key }) where shouldCopy(key) {
            let existing = defaults.object(forKey: key)
            if existing != nil, !isEmptyPlaceholder(existing) { result.keptExisting.append(key); continue }
            defaults.set(value, forKey: key)
            result.copied.append(key)
        }
        return result
    }

    /// The usual call at launch. Does nothing the second time, or when the old app was never installed.
    @discardableResult
    static func runIfNeeded(defaults: UserDefaults = .standard,
                            oldDomain: () -> [String: Any]? = { UserDefaults.standard.persistentDomain(forName: oldBundleID) }) -> Result? {
        guard defaults.string(forKey: markerKey) == nil else { return nil }
        guard let old = oldDomain(), !old.isEmpty else {
            defaults.set("none", forKey: markerKey)
            return nil
        }
        let result = copySettings(from: old, into: defaults)
        defaults.set(oldBundleID, forKey: markerKey)
        defaults.set(!result.copied.isEmpty, forKey: carriedOverKey)
        return result
    }
}
