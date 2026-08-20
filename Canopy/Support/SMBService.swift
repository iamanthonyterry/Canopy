import Foundation
import NetFS

/// Describes why an SMB mount attempt failed, with a message suitable for display to the user.
struct SMBMountError: LocalizedError {
    let ip: String
    let volume: String
    let status: OSStatus?

    var errorDescription: String? {
        switch status {
        case nil where volume.isEmpty:
            return "No Cloud Store volume name is set for \(ip)."
        case 1:
            return "Could not mount \"\(volume)\" on \(ip). Check the username and password."
        case -6585, 64, 60:
            // Common NetFS codes for unreachable host / timeout.
            return "Could not reach \(ip). Make sure the server is on and connected to the network."
        default:
            let suffix = status.map { " (status \($0))" } ?? ""
            return "Could not mount \"\(volume)\" on \(ip)\(suffix)."
        }
    }
}

enum SMBService {

    // MARK: - Primary API

    /// Mount an SMB share and return the actual /Volumes path where it landed.
    /// Uses NetFS (sandbox-safe) instead of osascript.
    /// Throws `SMBMountError` if the mount could not be completed.
    static func mountAndResolve(
        ip: String,
        volume: String,
        username: String,
        password: String
    ) async throws -> String {

        // A blank volume name would make the "already mounted" check below
        // collapse to "/Volumes/" itself, which always exists — that would
        // falsely report success without ever mounting a share.
        guard !volume.isEmpty else {
            throw SMBMountError(ip: ip, volume: volume, status: nil)
        }

        // 1. Already mounted at exact stored name?
        let exactPath = "/Volumes/\(volume)"
        if FileManager.default.fileExists(atPath: exactPath) {
            print("[SMBService] Already mounted at \(exactPath)")
            return exactPath
        }

        // 2. Already mounted under a different name for this IP?
        if let existing = resolveByIP(ip) {
            print("[SMBService] Found existing mount for \(ip): \(existing)")
            return existing
        }

        // 3. Snapshot /Volumes before mounting
        let before = Set(volumeNames())

        // 4. Mount via NetFS
        print("[SMBService] Mounting smb://\(ip)/\(volume) as \(username)…")
        let status = await runMount(ip: ip, volume: volume, username: username, password: password)

        let delay: Duration = status == 0 ? .milliseconds(1500) : .seconds(1)
        try? await Task.sleep(for: delay)

        // 5. New /Volumes entry?
        let after = Set(volumeNames())
        let newEntries = after.subtracting(before)
        print("[SMBService] New /Volumes entries: \(newEntries.sorted())")

        if let newVol = newEntries.first {
            let resolved = "/Volumes/\(newVol)"
            print("[SMBService] Resolved → \(resolved)")
            return resolved
        }

        // 6. Last resort: re-scan by IP
        if let found = resolveByIP(ip) {
            print("[SMBService] Resolved via IP scan → \(found)")
            return found
        }

        print("[SMBService] ✗ Mount failed — /Volumes: \(volumeNames().joined(separator: ", "))")
        throw SMBMountError(ip: ip, volume: volume, status: status)
    }

    /// Convenience wrapper for a CloudStore.
    static func mount(store: CloudStore) async throws -> String {
        try await mountAndResolve(
            ip:       store.ipAddress,
            volume:   store.volumeName,
            username: store.username,
            password: store.password
        )
    }

    // MARK: - Login / permission probe

    /// Result of actually attempting to authenticate against the share list,
    /// as opposed to just checking the SMB port is open.
    enum AuthResult: Sendable {
        case authorized
        case unauthorized   // reachable, but login denied
        case inconclusive   // couldn't tell (timeout, network error, etc.)
    }

    /// Confirms the store's stored username/password can actually log in,
    /// without mounting anything. Lighter weight than `mount(store:)`, so
    /// it's safe to call on a recurring health-check timer.
    static func probeAuth(ip: String, username: String, password: String) async -> AuthResult {
        let (output, exitCode) = await runView(ip: ip, username: username, password: password)
        if exitCode == 0 { return .authorized }

        let lower = output.lowercased()
        let authFailureMarkers = [
            "authentication error", "logon failure", "login failed",
            "access denied", "permission denied", "logon_failure"
        ]
        if authFailureMarkers.contains(where: lower.contains) {
            return .unauthorized
        }
        return .inconclusive
    }

    // MARK: - Share Discovery

    /// Lists the disk shares advertised by an SMB server, so the user can pick
    /// a volume name instead of typing it. Shells out to `smbutil view`, the
    /// same way FTPService shells out to curl for HyperDecks.
    static func listShares(ip: String, username: String, password: String) async -> [String] {
        let (output, _) = await runView(ip: ip, username: username, password: password)
        return parseShares(from: output)
    }

    /// Parses `smbutil view` output into a list of browsable disk share names,
    /// skipping admin/system shares like IPC$, print$, and ADMIN$.
    /// Columns are padded with runs of spaces, so share names that contain a
    /// single space (e.g. "My Drive") are still captured correctly.
    private static func parseShares(from output: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"^(.+?)\s{2,}Disk\b"#) else { return [] }
        return output
            .components(separatedBy: "\n")
            .compactMap { line -> String? in
                let range = NSRange(line.startIndex..., in: line)
                guard let match = regex.firstMatch(in: line, range: range),
                      let nameRange = Range(match.range(at: 1), in: line) else { return nil }
                let name = line[nameRange].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !name.hasSuffix("$") else { return nil }
                return name
            }
    }

    // MARK: - Private helpers

    /// Runs `smbutil view` against a server and returns its combined output
    /// and exit code. Used both for share discovery and for auth probing.
    private static func runView(ip: String, username: String, password: String) async -> (output: String, exitCode: Int32) {
        let user = username.isEmpty ? "guest" : username
        let encodedUser = user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? user
        let auth = password.isEmpty
            ? encodedUser
            : "\(encodedUser):\(password.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? password)"

        return await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/smbutil")
            process.arguments = ["view", "-N", "//\(auth)@\(ip)"]
            process.standardOutput = pipe
            process.standardError = pipe

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

    private static func volumeNames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
    }

    /// Mount using NetFS — the sandbox-approved way to mount SMB shares.
    /// Returns the raw NetFS status code (0 == success).
    private static func runMount(
        ip: String, volume: String, username: String, password: String
    ) async -> OSStatus {
        await withCheckedContinuation { continuation in
            // Share names can contain spaces and other characters that aren't
            // valid in a raw URL string, so percent-encode the path component.
            guard let encodedVolume = volume.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "smb://\(ip)/\(encodedVolume)") else {
                continuation.resume(returning: -1)
                return
            }

            let openOptions: NSMutableDictionary = [
                kNetFSUseGuestKey: false,
                kNetFSNoUserPreferencesKey: true   // suppress interactive auth dialogs
            ]
            let mountOptions: NSMutableDictionary = [
                kNetFSAllowLoopbackKey: false,
                kNetFSSoftMountKey: true
            ]

            var mountpoints: Unmanaged<CFArray>?

            let status = NetFSMountURLSync(
                url as CFURL,
                nil,
                username as CFString,
                password as CFString,
                openOptions,
                mountOptions,
                &mountpoints
            )

            if status == 0 {
                print("[SMBService] NetFS mount succeeded")
            } else {
                print("[SMBService] NetFS mount failed, status: \(status)")
            }
            continuation.resume(returning: status)
        }
    }

    /// Return the /Volumes path of any currently-mounted volume whose remount URL
    /// hostname matches `ip`.
    private static func resolveByIP(_ ip: String) -> String? {
        for vol in volumeNames() {
            let url = URL(fileURLWithPath: "/Volumes/\(vol)")
            if let remount = try? url.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting,
               remount.host == ip {
                return "/Volumes/\(vol)"
            }
        }
        return nil
    }
}
