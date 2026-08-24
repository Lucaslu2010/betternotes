import Foundation
import SwiftUI

/// Observable session manager for the sync feature.
///
/// On init, restores the saved email + token (if any). The login flow POSTs
/// credentials to the smart-edu `/api/auth/token` bridge, mints a bearer
/// token, and stores it in the Keychain. Logout clears everything.
@MainActor
final class SyncAuth: ObservableObject {

    /// Current logged-in email, restored from UserDefaults on launch.
    @Published private(set) var email: String?

    /// Display name returned by the server.
    @Published private(set) var userName: String?

    /// Convenience: true when a bearer token is present.
    var isLoggedIn: Bool {
        guard let email, KeychainTokenStore.loadToken(for: email) != nil else {
            return false
        }
        return true
    }

    /// Resolved per request so a Settings change takes effect without relaunch.
    private var baseURL: String { SyncConfig.baseURL }

    init() {
        if let savedEmail = UserDefaults.standard.string(forKey: "sync.email") {
            // Only surface as logged-in if the keychain still has the token.
            if KeychainTokenStore.loadToken(for: savedEmail) != nil {
                self.email = savedEmail
                self.userName = UserDefaults.standard.string(forKey: "sync.userName")
            } else {
                // Stale UserDefaults without a keychain entry — clean up.
                UserDefaults.standard.removeObject(forKey: "sync.email")
                UserDefaults.standard.removeObject(forKey: "sync.userName")
            }
        }
    }

    /// The bearer token for the current session, or nil if not logged in.
    var bearerToken: String? {
        guard let email else { return nil }
        return KeychainTokenStore.loadToken(for: email)
    }

    // MARK: - Login

    /// Exchange email + password for a sync token. On success the session is
    /// persisted across launches.
    func login(email: String, password: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/auth/token") else {
            throw SyncError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "email": email,
            "password": password,
            "rotate": true,  // always get a fresh plaintext token at login
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.invalidResponse
        }

        if http.statusCode == 401 {
            throw SyncError.invalidCredentials
        }
        guard (200...299).contains(http.statusCode) else {
            let message = decodeError(data) ?? "HTTP \(http.statusCode)"
            throw SyncError.serverError(message)
        }

        struct LoginResponse: Decodable {
            let token: String
            let userId: String
            let name: String?
            let email: String?
        }

        let parsed: LoginResponse
        do {
            parsed = try JSONDecoder().decode(LoginResponse.self, from: data)
        } catch {
            throw SyncError.invalidResponse
        }

        guard !parsed.token.isEmpty else {
            // Server returned 200 but no plaintext token (e.g. tokenHashed: true
            // because we didn't pass rotate:true). Shouldn't happen, but handle.
            throw SyncError.serverError("No token returned. Try again.")
        }

        let normalisedEmail = (parsed.email ?? email).lowercased()
        KeychainTokenStore.saveToken(parsed.token, for: normalisedEmail)
        UserDefaults.standard.set(normalisedEmail, forKey: "sync.email")
        UserDefaults.standard.set(parsed.name, forKey: "sync.userName")

        self.email = normalisedEmail
        self.userName = parsed.name
    }

    // MARK: - Logout

    func logout() {
        if let email {
            KeychainTokenStore.deleteToken(for: email)
        }
        UserDefaults.standard.removeObject(forKey: "sync.email")
        UserDefaults.standard.removeObject(forKey: "sync.userName")
        email = nil
        userName = nil
    }

    // MARK: - Helpers

    private func decodeError(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["error"] as? String
    }
}

/// Holds both sync singletons so a SwiftUI view can create them together
/// (engine needs auth at construction time, and `@StateObject` only inits once).
@MainActor
final class SyncState: ObservableObject {
    let auth: SyncAuth
    let engine: SyncEngine

    init(auth: SyncAuth, engine: SyncEngine) {
        self.auth = auth
        self.engine = engine
    }
}

// MARK: - Errors

enum SyncError: LocalizedError {
    case badURL
    case invalidResponse
    case invalidCredentials
    case serverError(String)
    case conflict(serverRevision: Int)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .badURL:               return "Invalid server URL"
        case .invalidResponse:      return "Unexpected response from server"
        case .invalidCredentials:   return "Wrong email or password"
        case .serverError(let m):   return m
        case .conflict(let rev):    return "The server has a newer version (revision \(rev)). Pull to merge."
        case .decoding(let m):      return "Couldn't parse server data: \(m)"
        }
    }
}
