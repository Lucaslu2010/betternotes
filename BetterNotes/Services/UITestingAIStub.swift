import Foundation

/// A canned provider, for UI tests only.
///
/// The unit tests stub the network with `MockAIURLProtocol`, but that lives in
/// the test bundle and a UI test drives the app from outside its process --
/// so there is no way to inject a fake session from the test side. Without
/// this, covering "ask in ink and watch the answer land" would mean either a
/// real API key on the CI machine or no coverage at all.
///
/// Only ever installed behind `-ui-testing-ai-stub`, which the app itself
/// checks; nothing here is reachable in a shipping build's normal launch.
enum UITestingAIStub {
    static let launchArgument = "-ui-testing-ai-stub"
    static let answer = "Because it kept the French stress on the second syllable."

    static func isEnabled(_ arguments: [String]) -> Bool {
        arguments.contains(launchArgument)
    }

    /// A session whose every request is answered by `StubURLProtocol`.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// A store pointed at the stub, for this launch only.
    ///
    /// `ephemeralKey` rather than `update(apiKey:…)` on purpose: the targeted
    /// UI tests run on a real iPad, and writing a fake key through the normal
    /// path would put it in that device's Keychain and leave the app
    /// configured for a provider that does not exist once the test ends.
    @MainActor static func makeSettings(defaults: UserDefaults) -> AISettingsStore {
        defaults.set("https://ui-testing.invalid/v1", forKey: "ai.baseURL")
        defaults.set("ui-testing-stub", forKey: "ai.model")
        return AISettingsStore(defaults: defaults, ephemeralKey: "ui-testing-stub-key")
    }

    final class StubURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            // Streamed the way a real provider streams, so the app exercises
            // the same SSE path it will use in production.
            let body = """
            data: {"choices":[{"delta":{"content":"\(UITestingAIStub.answer)"}}]}

            data: [DONE]

            """
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://ui-testing.invalid/v1")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
