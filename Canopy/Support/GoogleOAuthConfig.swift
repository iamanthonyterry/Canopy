import Foundation

/// Google OAuth configuration for Gmail sending.
/// Client ID is read from Info.plist key "GIDClientID".
enum GoogleOAuthConfig {
    /// Read from Info.plist (e.g. "123456789-abcdefg.apps.googleusercontent.com")
    static let clientID: String = {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              !id.isEmpty else {
            assertionFailure("Missing GIDClientID in Info.plist")
            return ""
        }
        return id
    }()

    /// Reversed client ID, used as the custom URL scheme (must match Info → URL Types).
    /// e.g. "com.googleusercontent.apps.123456789-abcdefg"
    static var redirectScheme: String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    static var redirectURI: String { "\(redirectScheme):/oauth2redirect" }

    static let scope = "https://www.googleapis.com/auth/gmail.send"
    static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"
}
