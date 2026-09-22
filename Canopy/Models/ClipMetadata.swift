import Foundation

// MARK: - Clip Metadata
// A star and/or note attached to a single clip, keyed by `FileNode.id` (see
// DeviceFilesBrowser.swift) — already a stable, globally-unique identity in
// this codebase: FTP ids embed the owning deck's UUID + relative path, and
// local/Cloud Store ids are the clip's absolute filesystem path.
//
// Carries a denormalized snapshot of the clip (name, device, size, paths)
// captured at the moment it's starred or noted, so the cross-device Starred
// view and reopening the clip from there don't require re-browsing the
// device's file tree. If a Cloud Store's SMB volume is ever remounted under
// a different name than before, a stored `localURL` can go stale until the
// clip is re-starred — an accepted limitation rather than something this
// resolves live.
struct ClipMetadata: Codable, Equatable {
    var starred: Bool = false
    var note: String = ""

    var clipName: String
    var deviceID: String
    var deviceLabel: String
    var ftpPath: String?
    var localURL: URL?
    var isVideo: Bool
    var isImage: Bool
    var size: Int64
    var modified: Date
    var updatedAt: Date

    var isEmpty: Bool { !starred && note.isEmpty }
}
