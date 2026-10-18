import Foundation

/// Where downloaded speech models live, shared with the Transcriber helper so
/// each model is stored once. Both apps are unsandboxed, so a plain folder in
/// Application Support is enough. This is the piece that moves into
/// ChurchKitCore when the shared package exists (see docs/shared-package-plan.md).
nonisolated enum SharedModelFolder {
    /// `~/Library/Application Support/Church Landing Page/Models`
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Church Landing Page/Models", isDirectory: true)
    }

    /// WhisperKit's download base. It creates `models/<repo>/<variant>` below this.
    static var whisper: URL { root.appendingPathComponent("whisper", isDirectory: true) }

    /// Transcriber's current location, until it moves to the shared folder. Read
    /// only: Canopy reuses a model found here but never writes to it.
    static var legacyTranscriberWhisper: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriber/Models", isDirectory: true)
    }

    /// A model folder is complete when its compiled audio encoder is present.
    static func isModelFolder(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("AudioEncoder.mlmodelc").path)
    }

    /// Looks for an already-downloaded Whisper variant, shared folder first.
    /// `base` is the folder WhisperKit should use as its download base, because
    /// it keeps the tokenizer beside the model and fetches it from the network
    /// if it isn't there. Using the base the model was found under keeps an
    /// offline Mac working.
    static func whisperModel(variant: String, repo: String) -> (folder: URL, base: URL)? {
        for base in [whisper, legacyTranscriberWhisper] {
            let candidates = [
                base.appendingPathComponent("models/\(repo)/\(variant)"),
                base.appendingPathComponent(variant),
            ]
            if let hit = candidates.first(where: isModelFolder) { return (hit, base) }
        }
        return nil
    }

    /// Serializes downloads between this app and the helper, so the same model
    /// is never fetched twice at once. The lock is released when `body` returns.
    static func withDownloadLock<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
        let dir = root.appendingPathComponent(".locks", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent("\(name).lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return try await body() }
        defer { close(fd) }
        // flock blocks, so wait off the main thread rather than freeze the UI.
        await Task.detached { _ = flock(fd, LOCK_EX) }.value
        defer { flock(fd, LOCK_UN) }
        return try await body()
    }
}
