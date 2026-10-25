import Foundation
import Testing
@testable import Canopy

struct CanopyMigrationTests {
    private func suite() -> (UserDefaults, String) {
        let name = "canopy-migration-test-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private let oldDomain: [String: Any] = [
        "workflows": Data("[{\"name\":\"Offload\"}]".utf8), "hyperDecks": Data("[{\"name\":\"A\"}]".utf8),
        "cloudStores": Data("[]".utf8), "userRole": Data("\"Admin\"".utf8),
        "workflowRuns.deviceID": "abc", "ai.useEnhancedModel": true,
        "SULastCheckTime": Date(), "NSNavPanelExpandedSizeForOpenMode": "{880, 448}", "SUHasLaunchedBefore": true,
        "inventory.scope": "lewis-center", "feature.inventory.enabled": true, "showMode.screen": "x", "wireless.monitor": true,
        "showScreens": Data("[]".utf8), "exportPresets": Data("[]".utf8), "dashboardFilesViewMode": "gallery",
        "churchkit.migratedFromBundleID": "com.ROSESASHUMANS.Canopy",
    ]

    @Test func carriesWorkflowsDevicesAndSettingsButNotRemovedFeaturesOrSystemKeys() {
        let (defaults, name) = suite(); defer { defaults.removePersistentDomain(forName: name) }
        let r = CanopyMigration.copySettings(from: oldDomain, into: defaults)
        #expect(Set(r.copied) == ["workflows", "hyperDecks", "cloudStores", "userRole", "workflowRuns.deviceID", "ai.useEnhancedModel"])
        #expect(defaults.data(forKey: "workflows") == Data("[{\"name\":\"Offload\"}]".utf8))
        for skipped in ["SULastCheckTime", "NSNavPanelExpandedSizeForOpenMode", "SUHasLaunchedBefore", "inventory.scope", "feature.inventory.enabled",
                        "showMode.screen", "wireless.monitor", "showScreens", "exportPresets", "dashboardFilesViewMode", "churchkit.migratedFromBundleID"] {
            #expect(defaults.object(forKey: skipped) == nil, "\(skipped) should not be copied")
        }
    }

    @Test func keepsWhatThisAppAlreadyHasButFillsEmptyPlaceholders() {
        let (defaults, name) = suite(); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("[{\"name\":\"Mine\"}]".utf8), forKey: "workflows")
        defaults.set(Data("[]".utf8), forKey: "hyperDecks")  // saved empty by an earlier launch
        let r = CanopyMigration.copySettings(from: oldDomain, into: defaults)
        #expect(r.keptExisting == ["workflows"])
        #expect(defaults.data(forKey: "workflows") == Data("[{\"name\":\"Mine\"}]".utf8))
        #expect(defaults.data(forKey: "hyperDecks") == Data("[{\"name\":\"A\"}]".utf8))
    }

    @Test func runsOnceAndRemembersWhetherAnythingCameAcross() {
        let (defaults, name) = suite(); defer { defaults.removePersistentDomain(forName: name) }
        let first = CanopyMigration.runIfNeeded(defaults: defaults, oldDomain: { oldDomain })
        #expect(first?.copied.isEmpty == false)
        #expect(defaults.bool(forKey: CanopyMigration.carriedOverKey))
        defaults.set(Data("[]".utf8), forKey: "workflows")
        #expect(CanopyMigration.runIfNeeded(defaults: defaults, oldDomain: { oldDomain }) == nil)
        #expect(defaults.data(forKey: "workflows") == Data("[]".utf8), "a second launch must not copy again")
    }

    @Test func noOldAppMeansNothingToCarryAndNoUpgradePrompts() {
        let (defaults, name) = suite(); defer { defaults.removePersistentDomain(forName: name) }
        #expect(CanopyMigration.runIfNeeded(defaults: defaults, oldDomain: { nil }) == nil)
        #expect(!defaults.bool(forKey: CanopyMigration.carriedOverKey))
        #expect(defaults.string(forKey: CanopyMigration.markerKey) == "none")
    }
}

struct SelfRenameTests {
    private func makeHome() throws -> String {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rename-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Applications"), withIntermediateDirectories: true)
        return home.path
    }

    @Test func movesTranscriberAppToCanopyInUserApplications() throws {
        let home = try makeHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let bundle = URL(fileURLWithPath: home + "/Applications/Transcriber.app")
        #expect(SelfRename.destination(for: bundle, homeDirectory: home)?.path == home + "/Applications/Canopy.app")
    }

    @Test func leavesAlreadyRenamedAppsAndOtherFoldersAlone() throws {
        let home = try makeHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(SelfRename.destination(for: URL(fileURLWithPath: home + "/Applications/Canopy.app"), homeDirectory: home) == nil)
        #expect(SelfRename.destination(for: URL(fileURLWithPath: home + "/Downloads/Transcriber.app"), homeDirectory: home) == nil)
        #expect(SelfRename.destination(for: URL(fileURLWithPath: "/tmp/build/Transcriber.app"), homeDirectory: home) == nil)
    }

    @Test func doesNotOverwriteAnotherCanopyAlreadyThere() throws {
        let home = try makeHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/Applications/Canopy.app", withIntermediateDirectories: true)
        #expect(SelfRename.destination(for: URL(fileURLWithPath: home + "/Applications/Transcriber.app"), homeDirectory: home) == nil)
    }
}

struct FirstLaunchTests {
    /// A folder of stand-in apps: each is a directory with a Contents/Info.plist naming its bundle id.
    private func makeApps(_ apps: [(path: String, id: String)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apps-test-\(UUID().uuidString)")
        for app in apps {
            let contents = root.appendingPathComponent(app.path).appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist = ["CFBundleIdentifier": app.id, "CFBundleName": "X", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        }
        return root
    }

    @Test func findsCopiesByTheirOwnBundleIdAtAnyName() throws {
        let root = try makeApps([("Canopy.app", "com.example.new"), ("Transcriber.app", "com.example.new"), ("Old/Canopy.app", "com.example.new"),
                                 ("Other.app", "com.example.other"), ("Deep/Deeper/Canopy.app", "com.example.new")])
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.resolvingSymlinksInPath().path + "/"  // the temp folder is reached through a symlink
        let found = FirstLaunch.installedCopies(bundleID: "com.example.new", in: [root]).map { $0.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: "") }.sorted()
        #expect(found == ["Canopy.app", "Old/Canopy.app", "Transcriber.app"], "one folder deep, any file name, only this bundle id")
    }

    @Test func aMissingFolderOrNoMatchIsJustEmpty() throws {
        #expect(FirstLaunch.installedCopies(bundleID: "x", in: [URL(fileURLWithPath: "/definitely/not/here")]).isEmpty)
        let root = try makeApps([("A.app", "com.example.a")])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FirstLaunch.installedCopies(bundleID: "com.example.b", in: [root]).isEmpty)
    }

    @Test func copiesTheyKeptAreNotAskedAboutAgainButNewOnesAre() {
        let a = URL(fileURLWithPath: "/Applications/Transcriber.app"), b = URL(fileURLWithPath: "/Users/me/Applications/Canopy.app")
        #expect(FirstLaunch.unanswered([a, b], declined: [a.path]).map(\.path) == [b.path])
        #expect(FirstLaunch.unanswered([a, b], declined: []).count == 2)
        #expect(FirstLaunch.unanswered([a], declined: [a.path]).isEmpty)
    }

    @Test func theOtherCopyOfThisAppIsFoundWhicheverPathItIsAtButNeverTheRunningOne() {
        // A Mac that had both old apps: one updated in place to Canopy.app, the other to Transcriber.app.
        let found = [URL(fileURLWithPath: "/Applications/Canopy.app"), URL(fileURLWithPath: "/Applications/Transcriber.app")]
        #expect(FirstLaunch.oldCanopyCopies(finding: found, home: "/Users/me", running: URL(fileURLWithPath: "/Applications/Transcriber.app")).map(\.path) == ["/Applications/Canopy.app"])
        #expect(FirstLaunch.oldCanopyCopies(finding: found, home: "/Users/me", running: URL(fileURLWithPath: "/Applications/Canopy.app")).map(\.path) == ["/Applications/Transcriber.app"])
        #expect(FirstLaunch.oldCanopyCopies(finding: [found[0]], home: "/Users/me", running: found[0]).isEmpty, "a lone copy has no twin")
    }

    @Test func onlyOldCopiesInApplicationsFoldersCount() {
        let running = URL(fileURLWithPath: "/Applications/Canopy.app")
        let found = [URL(fileURLWithPath: "/Applications/Canopy.app"), URL(fileURLWithPath: "/Applications/Old/Canopy.app"),
                     URL(fileURLWithPath: "/Users/me/Applications/Canopy.app"), URL(fileURLWithPath: "/Users/me/Developer/canopy/build/Canopy.app"),
                     URL(fileURLWithPath: "/private/tmp/dd/Build/Products/Debug/Canopy.app")]
        let old = FirstLaunch.oldCanopyCopies(finding: found, home: "/Users/me", running: running)
        #expect(old.map(\.path) == ["/Applications/Old/Canopy.app", "/Users/me/Applications/Canopy.app"])
    }
}
