import Foundation

/// Holds the AI provider configuration used across the app.
///
/// Remote completions go through `AssistantCoordinator`, which owns its own
/// request lifecycle; this type only supplies configuration.
/// Provider credentials are user supplied and kept in Keychain, never bundled.
@MainActor
final class AIService: ObservableObject {
    let settingsStore: AISettingsStore
    let client: AIClient

    init(settingsStore: AISettingsStore? = nil, client: AIClient = AIClient()) {
        self.settingsStore = settingsStore ?? AISettingsStore()
        self.client = client
    }

    var configuredBaseURL: String { settingsStore.baseURL }
    var configuredModel: String { settingsStore.model }
    var isRemoteConfigured: Bool { settingsStore.isRemoteConfigured }
    var sendsPageImages: Bool { settingsStore.sendsPageImages }

    func updateConfiguration(apiKey: String?, baseURL: String, model: String) throws {
        try settingsStore.update(apiKey: apiKey, baseURL: baseURL, model: model)
        objectWillChange.send()
    }

    func setSendsPageImages(_ value: Bool) {
        settingsStore.setSendsPageImages(value)
        objectWillChange.send()
    }

    func clearConfiguration() {
        settingsStore.clear()
        objectWillChange.send()
    }
}
