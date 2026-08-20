import Foundation

// Wraps curl-based FTP operations using async/await.
// HyperDecks don't support Swift's URLSession FTP on modern macOS, so we shell out to curl.
struct FTPService {

    // MARK: - FTP Directory Entry

    struct FTPEntry: Hashable {
        let name: String
        let isDirectory: Bool
        let size: Int64
        let modified: Date
    }

    // MARK: - Login / permission probe

    /// Result of attempting to actually log in and list the remote path,
    /// as opposed to just checking that the port is open. curl surfaces
    /// these as two distinct exit codes, so we keep them distinct here too
    /// instead of collapsing both into one generic "login failed" state.
    enum AuthResult: Sendable {
        case authorized
        case unauthorized   // reachable, but username/password was rejected
        case pathNotFound   // login succeeded, but the remote folder doesn't exist
        case inconclusive   // couldn't tell (timeout, network error, etc.)
    }

    /// Exit codes that indicate a transient connectivity hiccup rather than
    /// a definitive answer — worth retrying a couple of times before giving
    /// up. Codes like 67 (bad login) or 9 (path denied) are real answers
    /// and retrying them would just waste time.
    private static let retryableCurlExitCodes: Set<Int32> = [
        -1,  // couldn't even launch curl
        7,   // couldn't connect to host
        28,  // operation timed out (connect or --max-time/--speed-time)
    ]
    private static let maxTransientAttempts = 3
    private static let transientRetryDelay: Duration = .seconds(1)

    /// Confirms the deck's stored username/password can actually log in and
    /// list its configured remote path.
    static func probeAuth(on deck: HyperDeck) async -> AuthResult {
        let encoded = deck.remotePath
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deck.remotePath
        let url = "ftp://\(deck.ipAddress)/\(encoded)/"

        let (_, exitCode) = await runProcessWithExitCode(
            executable: "/usr/bin/curl",
            args: ["--user", "\(deck.username):\(deck.password)",
                   "--connect-timeout", "5", "--max-time", "15",
                   "-s", "--list-only", url],
            retryOn: retryableCurlExitCodes
        )

        switch exitCode {
        case 0:   return .authorized
        case 67:  return .unauthorized   // CURLE_LOGIN_DENIED — bad username/password
        case 9:   return .pathNotFound   // CURLE_REMOTE_ACCESS_DENIED — couldn't cwd into remotePath
        default:  return .inconclusive
        }
    }

    // MARK: - List all files in a remote directory

    static func listAllFiles(on deck: HyperDeck, path: String) async -> [FTPEntry] {
        let encoded = path
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let url = "ftp://\(deck.ipAddress)/\(encoded)/"

        // No --list-only here: that returns bare filenames only. We want the
        // full "ls -l" style listing so we can read real file sizes and tell
        // directories from files without guessing from the name.
        let (output, _) = await runProcessWithExitCode(
            executable: "/usr/bin/curl",
            args: ["--user", "\(deck.username):\(deck.password)",
                   "--connect-timeout", "5", "--max-time", "15", "-s", url],
            retryOn: retryableCurlExitCodes
        )
        return parseFTPListing(from: output, basePath: path, deck: deck)
    }

    // MARK: - List remote .mov files (legacy)
    static func listMovFiles(on deck: HyperDeck) async -> [String] {
        let encoded = deck.remotePath
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deck.remotePath
        let url = "ftp://\(deck.ipAddress)/\(encoded)/"

        let (output, _) = await runProcessWithExitCode(
            executable: "/usr/bin/curl",
            args: ["--user", "\(deck.username):\(deck.password)",
                   "--connect-timeout", "5", "--max-time", "15", "-s", url],
            retryOn: retryableCurlExitCodes
        )
        return parseMovFiles(from: output)
    }

    // MARK: - Download result
    // Carries a human-readable reason on failure so logs and the UI can
    // explain *why* a download failed, not just that it did.
    struct DownloadResult: Sendable {
        let success: Bool
        let failureReason: String?

        nonisolated static let ok = DownloadResult(success: true, failureReason: nil)
        nonisolated static func failed(_ reason: String) -> DownloadResult {
            DownloadResult(success: false, failureReason: reason)
        }
    }

    // MARK: - Download a single file with progress callback (0.0–1.0)
    // Retries a couple of times on a transient failure (dropped connection,
    // stalled transfer) before finally reporting it as failed — a single
    // Wi-Fi blip shouldn't fail the whole file. Each retry removes whatever
    // partial file was left behind and starts the download over.
    static func downloadFile(
        named fileName: String,
        from deck: HyperDeck,
        to destinationURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> DownloadResult {
        var last = DownloadResult.failed("Unknown error")
        for attempt in 1...maxTransientAttempts {
            last = await downloadFileOnce(named: fileName, from: deck, to: destinationURL, progress: progress)
            if last.success { return last }
            try? FileManager.default.removeItem(at: destinationURL)
            if attempt < maxTransientAttempts {
                try? await Task.sleep(for: transientRetryDelay)
            }
        }
        return last
    }

    private static func downloadFileOnce(
        named fileName: String,
        from deck: HyperDeck,
        to destinationURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> DownloadResult {
        let encoded = deck.remotePath
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deck.remotePath
        let fileEncoded = fileName
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        let url = "ftp://\(deck.ipAddress)/\(encoded)/\(fileEncoded)"

        return await withCheckedContinuation { continuation in
            let process = Process()
            let stderrPipe = Pipe()
            nonisolated(unsafe) var stderrText = ""

            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = [
                "--user", "\(deck.username):\(deck.password)",
                "--connect-timeout", "10",
                // --connect-timeout only bounds the initial connection — a
                // transfer that starts fine but then stalls mid-download
                // (deck drops off Wi-Fi, cable pulled, etc.) would otherwise
                // hang forever. --speed-limit/--speed-time make curl abort
                // once throughput stays below 1 KB/s for 20 seconds straight.
                "--speed-limit", "1024",
                "--speed-time", "20",
                "--progress-bar",
                "-o", destinationURL.path,
                url
            ]
            process.standardOutput = Pipe()   // discard stdout
            process.standardError  = stderrPipe

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let text = String(data: handle.availableData, encoding: .utf8) ?? ""
                stderrText += text
                if let pct = parseCurlProgress(text) {
                    Task { @MainActor in progress(pct) }
                }
            }

            process.terminationHandler = { p in
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                if p.terminationStatus == 0 {
                    Task { @MainActor in progress(1.0) }
                    continuation.resume(returning: .ok)
                } else {
                    let reason = curlFailureReason(exitCode: p.terminationStatus, stderr: stderrText)
                    continuation.resume(returning: .failed(reason))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: .failed("Couldn't launch curl: \(error.localizedDescription)"))
            }
        }
    }

    /// Turns a curl exit code + raw stderr into a short, readable failure reason.
    /// See `man curl` exit code list for the full mapping.
    private nonisolated static func curlFailureReason(exitCode: Int32, stderr: String) -> String {
        // --progress-bar writes carriage-return-separated "#" progress ticks to
        // stderr alongside real error text, so strip anything that's just
        // progress-bar noise and keep the actual message lines.
        let detailLines = stderr
            .components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty else { return false }
                return line.contains(where: { !"#% \t0123456789.".contains($0) })
            }
        let detail = detailLines.isEmpty ? nil : detailLines.joined(separator: "; ")

        let summary: String
        switch exitCode {
        case 7:  summary = "couldn't connect to deck"
        case 9:  summary = "remote folder not found — check the file location"
        case 28: summary = "connection timed out"
        case 67: summary = "FTP login failed (check username/password)"
        case 78: summary = "remote file not found"
        default: summary = "curl exit \(exitCode)"
        }

        if let detail {
            return "\(summary) — \(detail)"
        }
        return summary
    }

    // MARK: - Generic process runner (non-blocking)
    private static func runProcess(executable: String, args: [String]) async -> String {
        await runProcessWithExitCode(executable: executable, args: args).output
    }

    /// Same as `runProcess`, but also surfaces the exit code so callers can
    /// distinguish "reachable" from "reachable but denied". If `retryOn`
    /// contains the exit code the process comes back with, retries a
    /// couple more times (short pause in between) before returning —
    /// a single dropped packet shouldn't make an otherwise-healthy device
    /// look offline or empty.
    private static func runProcessWithExitCode(
        executable: String, args: [String], retryOn: Set<Int32> = []
    ) async -> (output: String, exitCode: Int32) {
        var last: (output: String, exitCode: Int32) = ("", -1)
        let attempts = retryOn.isEmpty ? 1 : maxTransientAttempts
        for attempt in 1...attempts {
            last = await runProcessOnce(executable: executable, args: args)
            guard retryOn.contains(last.exitCode) else { return last }
            if attempt < attempts {
                try? await Task.sleep(for: transientRetryDelay)
            }
        }
        return last
    }

    private static func runProcessOnce(
        executable: String, args: [String]
    ) async -> (output: String, exitCode: Int32) {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.standardOutput = pipe
            process.standardError  = pipe

            process.terminationHandler = { p in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (String(data: data, encoding: .utf8) ?? "", p.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: ("", -1))
            }
        }
    }

    // MARK: - Helpers

    /// Parses a Unix "ls -l" style FTP directory listing into FTPEntry values,
    /// reading the real file size and directory flag from each line, e.g.:
    ///   drwxrwxrwx 1 user group        0 Jan  1  2024 folder
    ///   -rwxrwxrwx 1 user group   123456 Jan  1  2024 clip0001.mov
    /// Falls back to bare-filename parsing for servers that don't return the
    /// long format (size is unknown in that case).
    private static func parseFTPListing(from output: String, basePath: String, deck: HyperDeck) -> [FTPEntry] {
        output
            .replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n")
            .compactMap { line -> FTPEntry? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }

                let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard fields.count >= 9, let permissions = fields.first else {
                    guard trimmed != ".", trimmed != ".." else { return nil }
                    let isDirectory = !trimmed.contains(".")
                    return FTPEntry(name: trimmed, isDirectory: isDirectory, size: 0, modified: .distantPast)
                }

                let name = fields[8...].joined(separator: " ")
                guard !name.isEmpty, name != ".", name != ".." else { return nil }
                let isDirectory = permissions.hasPrefix("d")
                let size = Int64(fields[4]) ?? 0
                return FTPEntry(name: name, isDirectory: isDirectory, size: size, modified: .distantPast)
            }
    }

    static func parseMovFiles(from output: String) -> [String] {
        output
            .replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n")
            .compactMap { line -> String? in
                let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard clean.lowercased().contains(".mov") else { return nil }
                let last = clean.components(separatedBy: " ").last ?? clean
                return last.lowercased().hasSuffix(".mov") ? last : nil
            }
    }

    private nonisolated static func parseCurlProgress(_ text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*%"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text),
              let value = Double(text[range]) else { return nil }
        return min(value / 100.0, 1.0)
    }
}
