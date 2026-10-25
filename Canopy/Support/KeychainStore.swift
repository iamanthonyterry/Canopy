import Foundation
import ChurchKitCore
import Security

/// Minimal Keychain wrapper. Holds the church-site session.
/// In the dev command-line and preview modes (see `FileTest.isSafeMode`) it touches nothing: no reads, writes or deletes.
enum KeychainStore {
    static let service = "com.rosesashumans.churchlandingpage.canopy"
    /// Where items lived before the bundle id changed (see LegacyMigration).
    static let legacyService = "com.rosesashumans.Canopy.gmail"
    /// The service name used between the bundle id change and the rename to `service`.
    private static let gmailNamedService = "com.rosesashumans.churchlandingpage.canopy.gmail"
    private static let renameMarker = "keychainServiceRenamed"

    /// Moves items from the old `.gmail`-named service to `service`, once. Run after
    /// LegacyMigration so items carried over from the original bundle id are included.
    static func migrateRenamedService() {
        guard !FileTest.isSafeMode, !UserDefaults.standard.bool(forKey: renameMarker) else { return }
        LegacyMigration.copyKeychain(fromService: gmailNamedService, toService: service)
        let old: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: gmailNamedService
        ]
        SecItemDelete(old as CFDictionary)
        UserDefaults.standard.set(true, forKey: renameMarker)
    }

    static func set(_ value: String, key: String) {
        guard !FileTest.isSafeMode else { return }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func get(key: String) -> String? {
        guard !FileTest.isSafeMode else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        guard !FileTest.isSafeMode else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
