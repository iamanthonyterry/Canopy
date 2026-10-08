import Foundation
import SwiftUI

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
/// A time-stamped point of interest on a clip, set from the player with `M`.
struct ClipMarker: Codable, Equatable, Identifiable {
    var id = UUID()
    var time: Double
    var label: String
}

/// NLE-style color label for sorting clips into selects/rejects/etc.
enum ClipLabel: String, Codable, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple, gray

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .red:    return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green:  return .green
        case .blue:   return .blue
        case .purple: return .purple
        case .gray:   return .gray
        }
    }
}

struct ClipMetadata: Codable, Equatable {
    var starred: Bool = false
    var note: String = ""
    var markers: [ClipMarker] = []
    var label: ClipLabel? = nil
    var keywords: [String] = []

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

    var isEmpty: Bool { !starred && note.isEmpty && markers.isEmpty && label == nil && keywords.isEmpty }

    init(starred: Bool = false, note: String = "", markers: [ClipMarker] = [],
         label: ClipLabel? = nil, keywords: [String] = [],
         clipName: String, deviceID: String, deviceLabel: String,
         ftpPath: String?, localURL: URL?, isVideo: Bool, isImage: Bool,
         size: Int64, modified: Date, updatedAt: Date) {
        self.starred = starred
        self.note = note
        self.markers = markers
        self.label = label
        self.keywords = keywords
        self.clipName = clipName
        self.deviceID = deviceID
        self.deviceLabel = deviceLabel
        self.ftpPath = ftpPath
        self.localURL = localURL
        self.isVideo = isVideo
        self.isImage = isImage
        self.size = size
        self.modified = modified
        self.updatedAt = updatedAt
    }

    // Hand-written so payloads saved before `markers` existed still decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        markers = try c.decodeIfPresent([ClipMarker].self, forKey: .markers) ?? []
        label = try c.decodeIfPresent(ClipLabel.self, forKey: .label)
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        clipName = try c.decode(String.self, forKey: .clipName)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        deviceLabel = try c.decode(String.self, forKey: .deviceLabel)
        ftpPath = try c.decodeIfPresent(String.self, forKey: .ftpPath)
        localURL = try c.decodeIfPresent(URL.self, forKey: .localURL)
        isVideo = try c.decode(Bool.self, forKey: .isVideo)
        isImage = try c.decode(Bool.self, forKey: .isImage)
        size = try c.decode(Int64.self, forKey: .size)
        modified = try c.decode(Date.self, forKey: .modified)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}
