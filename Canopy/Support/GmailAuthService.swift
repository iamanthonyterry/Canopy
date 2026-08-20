import Foundation
import AppKit
import Observation

/// Manages Gmail OAuth sign-in and access token lifecycle.
@MainActor
@Observable
final class GmailAuthService {
    static let shared = GmailAuthService()

    private(set) var connectedEmail: String?
    private(set) var isConnecting = false
    private(set) var lastError: String?

    private var pendingVerifier: String?
    private var pendingContinuation: CheckedContinuation<Void, Error>?

    private init() {
        connectedEmail = KeychainStore.get(key: "connectedEmail")
    }

    var isConnected: Bool { connectedEmail != nil }

    // MARK: - Start Sign-In

    func signIn() {
        guard !isConnecting else { return }
        isConnecting = true
        lastError = nil

        let verifier = PKCE.generateVerifier()
        let challenge = PKCE.challenge(for: verifier)
        pendingVerifier = verifier

        var components = URLComponents(string: GoogleOAuthConfig.authorizationEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: GoogleOAuthConfig.clientID),
            URLQueryItem(name: "redirect_uri", value: GoogleOAuthConfig.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleOAuthConfig.scope + " https://www.googleapis.com/auth/userinfo.email"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        guard let url = components.url else {
            isConnecting = false
            lastError = "Could not build authorization URL"
            return
        }
        NSWorkspace.shared.open(url)
    }

    func signOut() {
        connectedEmail = nil
        KeychainStore.delete(key: "connectedEmail")
        KeychainStore.delete(key: "refreshToken")
        KeychainStore.delete(key: "accessToken")
        KeychainStore.delete(key: "accessTokenExpiry")
    }

    // MARK: - Handle Redirect (called from onOpenURL)

    func handleRedirect(url: URL) {
        guard url.absoluteString.hasPrefix(GoogleOAuthConfig.redirectURI) else { return }

        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            isConnecting = false
            lastError = "No authorization code returned"
            return
        }

        Task { await exchangeCodeForTokens(code: code) }
    }

    // MARK: - Token Exchange

    private func exchangeCodeForTokens(code: String) async {
        guard let verifier = pendingVerifier else {
            isConnecting = false
            lastError = "Missing PKCE verifier"
            return
        }

        var request = URLRequest(url: URL(string: GoogleOAuthConfig.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "code": code,
            "client_id": GoogleOAuthConfig.clientID,
            "redirect_uri": GoogleOAuthConfig.redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier
        ]
        request.httpBody = formEncode(params)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(TokenResponse.self, from: data)

            // Google's consent screen lets the user uncheck individual
            // permissions ("granular consent"). If they left "Send email on
            // your behalf" unchecked, sign-in still succeeds but the token
            // won't carry gmail.send — every send will then fail with a 403.
            // Catch that here instead of failing silently later.
            if let grantedScope = response.scope, !grantedScope.contains("gmail.send") {
                isConnecting = false
                lastError = "Sign-in succeeded, but \"Send email on your behalf\" wasn't granted. Reconnect and make sure that permission is checked."
                return
            }

            KeychainStore.set(response.access_token, key: "accessToken")
            let expiry = Date().addingTimeInterval(TimeInterval(response.expires_in))
            KeychainStore.set(String(expiry.timeIntervalSince1970), key: "accessTokenExpiry")
            if let refreshToken = response.refresh_token {
                KeychainStore.set(refreshToken, key: "refreshToken")
            }

            let email = try await fetchUserEmail(accessToken: response.access_token)
            connectedEmail = email
            KeychainStore.set(email, key: "connectedEmail")

            isConnecting = false
        } catch {
            isConnecting = false
            lastError = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    private func fetchUserEmail(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let info = try JSONDecoder().decode(UserInfoResponse.self, from: data)
        return info.email
    }

    // MARK: - Access Token (auto-refreshes)

    /// Returns a valid access token, refreshing it first if it's expired.
    func validAccessToken() async -> String? {
        guard isConnected else { return nil }

        if let expiryString = KeychainStore.get(key: "accessTokenExpiry"),
           let expiryInterval = TimeInterval(expiryString),
           Date().timeIntervalSince1970 < expiryInterval - 60,
           let token = KeychainStore.get(key: "accessToken") {
            return token
        }

        return await refreshAccessToken()
    }

    private func refreshAccessToken() async -> String? {
        guard let refreshToken = KeychainStore.get(key: "refreshToken") else { return nil }

        var request = URLRequest(url: URL(string: GoogleOAuthConfig.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "client_id": GoogleOAuthConfig.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        request.httpBody = formEncode(params)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(TokenResponse.self, from: data)
            KeychainStore.set(response.access_token, key: "accessToken")
            let expiry = Date().addingTimeInterval(TimeInterval(response.expires_in))
            KeychainStore.set(String(expiry.timeIntervalSince1970), key: "accessTokenExpiry")
            return response.access_token
        } catch {
            lastError = "Token refresh failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Helpers

    private func formEncode(_ params: [String: String]) -> Data {
        params.map { key, value in
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(key)=\(encodedValue)"
        }
        .joined(separator: "&")
        .data(using: .utf8)!
    }
}

private struct TokenResponse: Decodable {
    let access_token: String
    let expires_in: Int
    let refresh_token: String?
    /// Space-separated list of scopes Google actually granted. Present when
    /// it differs from what was requested — e.g. via granular consent.
    let scope: String?
}

private struct UserInfoResponse: Decodable {
    let email: String
}
