import Combine
import Foundation
import Security

enum OCRProvider: String, CaseIterable, Identifiable {
    case local, custom
    var id: String { rawValue }
    var label: String { self == .local ? "On-Device OCR" : "Custom OCR" }
}

enum OCRAPIFormat: String, CaseIterable, Identifiable, Sendable {
    case paddleOCR, visionChat
    var id: String { rawValue }
    var label: String { self == .paddleOCR ? "PaddleOCR API" : "OpenAI-Compatible Vision API" }
}

struct OCRConfiguration: Sendable {
    let endpoint: URL
    let token: String
    let format: OCRAPIFormat
    let model: String
    let identity: String
}

@MainActor
final class OCRSettingsStore: ObservableObject {
    @Published private(set) var provider: OCRProvider
    @Published private(set) var endpoint: String
    @Published private(set) var format: OCRAPIFormat
    @Published private(set) var model: String
    @Published private(set) var hasToken: Bool
    private var token: String
    private var revision: String
    private let defaults: UserDefaults
    private let tokenService: String

    init(defaults: UserDefaults = .standard, tokenService: String = "com.betternotes.app.ocr-provider") {
        self.defaults = defaults
        self.tokenService = tokenService
        provider = OCRProvider(rawValue: defaults.string(forKey: "ocr.provider") ?? "") ?? .local
        endpoint = defaults.string(forKey: "ocr.endpoint") ?? ""
        format = OCRAPIFormat(rawValue: defaults.string(forKey: "ocr.format") ?? "") ?? .paddleOCR
        model = defaults.string(forKey: "ocr.model") ?? ""
        revision = defaults.string(forKey: "ocr.revision") ?? UUID().uuidString
        token = OCRTokenStore.load(service: tokenService) ?? ""
        hasToken = !token.isEmpty
    }

    var identity: String {
        provider == .local ? "apple-vision-v1" : "custom-\(revision)"
    }

    var configuration: OCRConfiguration? {
        guard provider == .custom, hasToken, Self.isAllowedEndpoint(endpoint),
              let url = URL(string: endpoint) else { return nil }
        return OCRConfiguration(endpoint: url, token: token, format: format, model: model, identity: identity)
    }

    func testConfiguration(endpoint: String, token: String?, format: OCRAPIFormat, model: String) throws -> OCRConfiguration {
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? self.token
        guard Self.isAllowedEndpoint(endpoint), let url = URL(string: endpoint) else { throw OCRError.invalidEndpoint }
        guard !key.isEmpty else { throw OCRError.missingToken }
        if format == .visionChat && model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw OCRError.missingModel }
        return OCRConfiguration(endpoint: url, token: key, format: format, model: model, identity: "test")
    }

    func save(provider: OCRProvider, endpoint: String, token: String?, format: OCRAPIFormat, model: String) throws {
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveToken = replacement ?? self.token
        if provider == .custom {
            guard Self.isAllowedEndpoint(endpoint) else { throw OCRError.invalidEndpoint }
            guard !effectiveToken.isEmpty else { throw OCRError.missingToken }
            if format == .visionChat && model.isEmpty { throw OCRError.missingModel }
        }
        if let replacement { try OCRTokenStore.save(replacement, service: tokenService) }
        if endpoint != self.endpoint || format != self.format || model != self.model || effectiveToken != self.token {
            revision = UUID().uuidString
        }
        self.token = effectiveToken
        self.endpoint = endpoint
        self.format = format
        self.model = model
        self.provider = provider
        hasToken = !effectiveToken.isEmpty
        defaults.set(provider.rawValue, forKey: "ocr.provider")
        defaults.set(endpoint, forKey: "ocr.endpoint")
        defaults.set(format.rawValue, forKey: "ocr.format")
        defaults.set(model, forKey: "ocr.model")
        defaults.set(revision, forKey: "ocr.revision")
    }

    func removeToken() throws {
        try OCRTokenStore.save("", service: tokenService)
        token = ""
        hasToken = false
        provider = .local
        defaults.set(OCRProvider.local.rawValue, forKey: "ocr.provider")
    }

    nonisolated static func isAllowedEndpoint(_ value: String) -> Bool {
        guard let url = URL(string: value), let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else { return false }
        return url.scheme?.lowercased() == "https"
            || (url.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
    }
}

enum OCRError: LocalizedError {
    case invalidEndpoint, missingToken, missingModel, invalidResponse, emptyQuestion, unreadableImage
    case imageTooLarge, responseTooLarge
    case provider(Int), secureStorage(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Enter the full HTTPS OCR endpoint from your provider's API example. HTTP is allowed only for localhost."
        case .missingToken: return "Add your OCR access token in OCR Settings."
        case .missingModel: return "Enter the name of your vision OCR model."
        case .invalidResponse: return "The OCR provider returned an unsupported response. Check the endpoint and API format."
        case .emptyQuestion: return "The question could not be read. Write ?? followed by your question on the same line, then try again."
        case .unreadableImage: return "The image could not be prepared for recognition."
        case .imageTooLarge: return "This OCR image is too large. Try recognizing a smaller area."
        case .responseTooLarge: return "The OCR provider returned too much data. Disable image output in your provider and try again."
        case .provider(401), .provider(403): return "The OCR provider rejected the access token. Check that the token matches the endpoint."
        case .provider(429): return "Your OCR provider's quota was reached. Try again later or check your account."
        case .provider(let code): return "The OCR provider returned error \(code). Try again or check your provider's API settings."
        case .secureStorage(let status): return "The OCR token could not be stored securely (Keychain error \(status))."
        }
    }
}

private enum OCRTokenStore {
    private static func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "access-token"]
    }

    static func load(service: String) -> String? {
        var result: AnyObject?
        let request = query(service: service).merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new }
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String, service: String) throws {
        let query = query(service: service)
        if token.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw OCRError.secureStorage(status) }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw OCRError.secureStorage(status) }
        let added = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard added == errSecSuccess else { throw OCRError.secureStorage(added) }
    }
}
