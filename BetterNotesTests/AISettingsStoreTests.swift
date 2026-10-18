import XCTest
@testable import BetterNotes

/// This is where the user's own API key lives. The store had no tests, and its
/// two jobs are both security-shaped: keep the key in the Keychain rather than
/// anywhere readable, and refuse to send it to a provider URL that isn't
/// HTTPS.
@MainActor
final class AISettingsStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AISettingsStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        AISettingsStore(defaults: defaults, keychainService: suiteName).clear()
    }

    override func tearDown() {
        AISettingsStore(defaults: defaults, keychainService: suiteName).clear()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> AISettingsStore { AISettingsStore(defaults: defaults, keychainService: suiteName) }

    // MARK: - Which provider URLs are allowed

    func testOnlyHTTPSOrLocalhostIsAccepted() {
        for allowed in ["https://api.deepseek.com/v1",
                        "https://api.openai.com/v1",
                        "http://localhost:11434/v1",
                        "http://127.0.0.1:1234/v1"] {
            XCTAssertTrue(AISettingsStore.isAllowedProviderURL(allowed), "rejected \(allowed)")
        }
        for refused in ["http://api.deepseek.com/v1",   // the key would cross the wire in clear
                       "http://192.168.1.10/v1",
                       "ftp://example.com",
                       "javascript:alert(1)",
                       "not a url at all",
                       "https://",
                       ""] {
            XCTAssertFalse(AISettingsStore.isAllowedProviderURL(refused), "accepted \(refused)")
        }
    }

    func testAHostThatMerelyStartsWithLocalhostIsNotLocalhost() {
        XCTAssertFalse(AISettingsStore.isAllowedProviderURL("http://localhost.evil.example.com/v1"))
    }

    // MARK: - Storing the key

    func testNothingIsConfiguredUntilAKeyIsSet() {
        let store = makeStore()
        XCTAssertFalse(store.isRemoteConfigured)
        XCTAssertNil(store.configuration, "a configuration was offered with no API key")
    }

    func testSavingAKeyMakesItAvailableToTheClient() throws {
        let store = makeStore()
        try store.update(apiKey: "sk-test-123", baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat")
        XCTAssertTrue(store.isRemoteConfigured)
        let configuration = try XCTUnwrap(store.configuration)
        XCTAssertEqual(configuration.apiKey, "sk-test-123")
        XCTAssertEqual(configuration.baseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(configuration.model, "deepseek-chat")
    }

    func testTheKeySurvivesRelaunchButNeverTouchesUserDefaults() throws {
        try makeStore().update(apiKey: "sk-persisted", baseURL: "https://api.deepseek.com/v1", model: "m")

        // A fresh store is what a relaunch looks like.
        XCTAssertEqual(makeStore().configuration?.apiKey, "sk-persisted")

        // And the key must not be sitting in a plist anyone can read.
        let dumped = defaults.dictionaryRepresentation().values.compactMap { $0 as? String }
        XCTAssertFalse(dumped.contains { $0.contains("sk-persisted") },
                       "the API key was written into UserDefaults")
    }

    func testEditingTheURLWithoutRetypingTheKeyKeepsTheKey() throws {
        let store = makeStore()
        try store.update(apiKey: "sk-keep", baseURL: "https://api.deepseek.com/v1", model: "m")
        try store.update(apiKey: nil, baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini")
        XCTAssertEqual(store.configuration?.apiKey, "sk-keep")
        XCTAssertEqual(store.configuration?.baseURL, "https://api.openai.com/v1")
    }

    func testAnEmptyKeyClearsTheStoredOne() throws {
        let store = makeStore()
        try store.update(apiKey: "sk-temp", baseURL: "https://api.deepseek.com/v1", model: "m")
        try store.update(apiKey: "   ", baseURL: "https://api.deepseek.com/v1", model: "m")
        XCTAssertFalse(store.isRemoteConfigured)
        XCTAssertNil(store.configuration)
        XCTAssertNil(makeStore().configuration, "the cleared key came back after a relaunch")
    }

    func testClearingRemovesTheKeyForGood() throws {
        let store = makeStore()
        try store.update(apiKey: "sk-gone", baseURL: "https://api.deepseek.com/v1", model: "m")
        store.clear()
        XCTAssertFalse(store.isRemoteConfigured)
        XCTAssertNil(makeStore().configuration, "the key outlived clear() and came back on relaunch")
    }

    // MARK: - Normalisation and rejection

    func testConnectionDraftDoesNotReplaceSavedConfigurationOrKey() throws {
        let store = makeStore()
        try store.update(apiKey: "saved-key", baseURL: "https://saved.example/v1", model: "saved-model")
        let draft = try store.testConfiguration(apiKey: " draft-key ", baseURL: " https://draft.example/v1/ ", model: "draft-model")
        XCTAssertEqual(draft, AIProviderConfiguration(apiKey: "draft-key", baseURL: "https://draft.example/v1", model: "draft-model", sendsPageImages: false))
        XCTAssertEqual(makeStore().configuration, AIProviderConfiguration(apiKey: "saved-key", baseURL: "https://saved.example/v1", model: "saved-model", sendsPageImages: false))
        XCTAssertEqual(try store.testConfiguration(apiKey: nil, baseURL: store.baseURL, model: "").apiKey, "saved-key")
    }

    func testConnectionRequiresKeyAndRejectsInsecureURLWithoutSaving() {
        let store = makeStore()
        XCTAssertThrowsError(try store.testConfiguration(apiKey: nil, baseURL: "https://draft.example/v1", model: "m"))
        XCTAssertThrowsError(try store.testConfiguration(apiKey: "draft-key", baseURL: "http://remote.example/v1", model: "m"))
        XCTAssertNil(makeStore().configuration)
    }

    func testATrailingSlashAndBlankModelAreNormalised() throws {
        let store = makeStore()
        try store.update(apiKey: "sk-1", baseURL: "  https://api.deepseek.com/v1/  ", model: "   ")
        XCTAssertEqual(store.baseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(store.model, "deepseek-chat")
    }

    func testARejectedURLChangesNothing() throws {
        let store = makeStore()
        try store.update(apiKey: "sk-1", baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat")
        XCTAssertThrowsError(try store.update(apiKey: "sk-2", baseURL: "http://evil.example.com", model: "x"))
        // The whole update must be refused, not half-applied.
        XCTAssertEqual(store.baseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(store.model, "deepseek-chat")
        XCTAssertEqual(store.configuration?.apiKey, "sk-1", "the key was replaced by a refused update")
    }

    func testAStoredURLIsRevalidatedOnLoad() throws {
        // UserDefaults is not a trust boundary the way the Keychain is: a
        // plain-HTTP URL that got in there — an older build, a synced plist, a
        // jailbroken device — would otherwise be used unchecked, and the key
        // would cross the wire in clear.
        try makeStore().update(apiKey: "sk-1", baseURL: "https://api.deepseek.com/v1", model: "m")
        defaults.set("http://evil.example.com/v1", forKey: "ai.baseURL")
        let reloaded = makeStore()
        XCTAssertNotEqual(reloaded.baseURL, "http://evil.example.com/v1",
                          "a plain-HTTP provider URL was loaded from UserDefaults unchecked")
        XCTAssertTrue(AISettingsStore.isAllowedProviderURL(reloaded.baseURL),
                      "the fallback URL is itself not an allowed one")
    }
}
