import Foundation

/// Resolves the sync server base URL.
///
/// Resolution order:
///   1. A user override stored in UserDefaults (`sync.baseURL`), editable from
///      Settings → Cloud Sync. This is how you point the app at a dev server.
///   2. The `BNSyncBaseURL` Info.plist value, if the build supplies one.
///   3. `http://localhost:3000` for local development.
///
/// This deliberately does NOT read `Config/secrets.json`. That file is excluded
/// from the app target in `project.yml`, so it never reaches the bundle — any
/// value placed there was silently ignored at runtime.
enum SyncConfig {
    static let defaultBaseURL = "http://localhost:3000"
    private static let overrideKey = "sync.baseURL"

    /// The base URL of the sync server, without a trailing slash.
    static var baseURL: String {
        if let override = UserDefaults.standard.string(forKey: overrideKey),
           !override.isEmpty {
            return normalized(override)
        }
        if let bundled = Bundle.main.object(forInfoDictionaryKey: "BNSyncBaseURL") as? String,
           !bundled.isEmpty {
            return normalized(bundled)
        }
        return defaultBaseURL
    }

    /// True when the user has set an explicit override.
    static var hasOverride: Bool {
        let value = UserDefaults.standard.string(forKey: overrideKey)
        return !(value ?? "").isEmpty
    }

    /// Stores a user override. Pass nil or an empty string to clear it.
    /// - Throws: `SyncConfigError.invalidURL` when the value is not a usable
    ///   http(s) URL with a host.
    static func setBaseURL(_ value: String?) throws {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            UserDefaults.standard.removeObject(forKey: overrideKey)
            return
        }
        guard isValid(trimmed) else { throw SyncConfigError.invalidURL }
        UserDefaults.standard.set(normalized(trimmed), forKey: overrideKey)
    }

    /// Accepts https anywhere, and http only for loopback or private-range
    /// addresses. Plain http to a public host is never allowed.
    static func isValid(_ value: String) -> Bool {
        guard let url = URL(string: normalized(value)),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return isLocalHost(host)
    }

    /// Whether a plain-http host requires an App Transport Security exception
    /// to be reachable from a device. Loopback works without one; private LAN
    /// addresses do not.
    static func requiresATSException(_ value: String) -> Bool {
        guard let url = URL(string: normalized(value)),
              url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased() else { return false }
        return !["localhost", "127.0.0.1", "::1"].contains(host)
    }

    private static func isLocalHost(_ host: String) -> Bool {
        if ["localhost", "127.0.0.1", "::1"].contains(host) { return true }
        if host.hasSuffix(".local") { return true }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
        // 172.16.0.0 – 172.31.255.255
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        return false
    }

    private static func normalized(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

enum SyncConfigError: LocalizedError {
    case invalidURL

    var errorDescription: String? {
        "Enter an https:// address, or an http:// address on localhost or your local network."
    }
}
