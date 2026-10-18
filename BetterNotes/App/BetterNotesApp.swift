import SwiftUI
import SwiftData

@main
struct BetterNotesApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppPreferenceKey.language) private var language = AppLanguage.english.rawValue
    let modelContainer: ModelContainer?
    let startupError: String?
    let recoveryURL: URL?
    @StateObject private var aiSettings: AISettingsStore
    @StateObject private var aiService: AIService
    @StateObject private var corpusStore: NoteCorpusStore
    @StateObject private var assistantCoordinator: AssistantCoordinator
    @StateObject private var inkAnswerCoordinator: InkAnswerCoordinator
    @StateObject private var nearbySync = NearbySyncCoordinator()
    @StateObject private var ocrSettings: OCRSettingsStore
    @StateObject private var ocrService: OCRService

    init() {
        MemoryDiagnostics.shared.start()
        let arguments = CommandLine.arguments
        let isUITesting = arguments.contains("-ui-testing")
        let isUnitTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let defaults = UserDefaults.standard
        let testPreferencesKey = "uiTesting.originalPreferences"
        if !isUITesting, let original = defaults.dictionary(forKey: testPreferencesKey) {
            for (key, value) in original["values"] as? [String: Any] ?? [:] {
                defaults.set(value, forKey: key)
            }
            for key in original["missing"] as? [String] ?? [] { defaults.removeObject(forKey: key) }
            defaults.removeObject(forKey: testPreferencesKey)
        }
        // Finger drawing shipped defaulting to on; that shipped default is
        // now off. Changing an @AppStorage default only changes what a
        // never-written key reads as -- every device that ever launched the
        // old build already has `true` persisted for this key, so the new
        // default silently does nothing for anyone who'd already used the
        // app. Force it once, the first time this build runs, and never
        // touch it again so a later manual toggle sticks.
        let fingerDrawingMigrationKey = "migration.fingerDrawingDefaultOff.v1"
        if !isUITesting, !defaults.bool(forKey: fingerDrawingMigrationKey) {
            defaults.set(false, forKey: AppPreferenceKey.allowsFingerDrawing)
            defaults.set(true, forKey: fingerDrawingMigrationKey)
        }
        if isUITesting {
            // Device tests use an isolated notes store; restore the preferences
            // they pin too, when the user's normal app is next launched.
            if defaults.dictionary(forKey: testPreferencesKey) == nil {
                let keys = ["ocr.provider", AppPreferenceKey.scrollMode, AppPreferenceKey.toolbarDock,
                            AppPreferenceKey.toolbarHintSeen, AppPreferenceKey.panHintSeen,
                            AppPreferenceKey.fingerHintSeen, AppPreferenceKey.lassoHintSeen,
                            AppPreferenceKey.assistantEnabled, AppPreferenceKey.searchAnswersEnabled,
                            AppPreferenceKey.inkQuestionsEnabled, AppPreferenceKey.language,
                            AppPreferenceKey.allowsFingerDrawing]
                var values: [String: Any] = [:]
                var missing: [String] = []
                for key in keys {
                    if let value = defaults.object(forKey: key) { values[key] = value }
                    else { missing.append(key) }
                }
                defaults.set(["values": values, "missing": missing], forKey: testPreferencesKey)
            }
            defaults.set(OCRProvider.local.rawValue, forKey: "ocr.provider")
            let scrollMode: ScrollMode = arguments.contains("-ui-testing-vertical-scroll") ? .verticalScroll : .singlePage
            defaults.set(scrollMode.rawValue, forKey: AppPreferenceKey.scrollMode)
            let toolbarDock: ToolbarDock = arguments.contains("-ui-testing-bottom-toolbar") ? .bottom : .top
            defaults.set(toolbarDock.rawValue, forKey: AppPreferenceKey.toolbarDock)
            defaults.set(true, forKey: AppPreferenceKey.toolbarHintSeen)
            defaults.set(true, forKey: AppPreferenceKey.panHintSeen)
            defaults.set(true, forKey: AppPreferenceKey.fingerHintSeen)
            defaults.set(true, forKey: AppPreferenceKey.lassoHintSeen)
            defaults.set(true, forKey: AppPreferenceKey.assistantEnabled)
            defaults.set(true, forKey: AppPreferenceKey.searchAnswersEnabled)
            defaults.set(true, forKey: AppPreferenceKey.inkQuestionsEnabled)
            defaults.set(AppLanguage.english.rawValue, forKey: AppPreferenceKey.language)
            // Not pinned on every launch, because a test relaunches the app to
            // prove the choice persists; a test that needs the default asks.
            if arguments.contains("-ui-testing-reset-conflict-policy") {
                defaults.removeObject(forKey: NearbyConflictPolicy.defaultsKey)
            }
            // Pin finger drawing on. Every other preference the tests depend
            // on is pinned here, but this one was left to whatever the host
            // had stored -- so a drawing test passed in a fresh simulator
            // (which defaults to true) and failed on a real iPad belonging to
            // someone who draws with a Pencil and had switched it off. The
            // synthesised touches XCUITest delivers are `.direct`, and
            // PaperCanvas only observes those when this is true.
            defaults.set(true, forKey: AppPreferenceKey.allowsFingerDrawing)
        }
        // A UI test cannot inject a URLSession from outside the process, so
        // the stubbed provider has to be chosen here, behind its own flag.
        let usesStubbedAI = isUITesting && UITestingAIStub.isEnabled(arguments)
        let settings = usesStubbedAI
            ? UITestingAIStub.makeSettings(defaults: .standard)
            : AISettingsStore()
        let client = usesStubbedAI ? AIClient(session: UITestingAIStub.makeSession()) : AIClient()
        let recognitionSettings = OCRSettingsStore()
        _ocrSettings = StateObject(wrappedValue: recognitionSettings)
        _ocrService = StateObject(wrappedValue: OCRService(settings: recognitionSettings))
        let corpus = NoteCorpusStore()
        _aiSettings = StateObject(wrappedValue: settings)
        _aiService = StateObject(wrappedValue: AIService(settingsStore: settings, client: client))
        _corpusStore = StateObject(wrappedValue: corpus)
        _assistantCoordinator = StateObject(wrappedValue: AssistantCoordinator(
            settings: settings,
            client: client,
            indexer: corpus.indexer
        ))
        _inkAnswerCoordinator = StateObject(wrappedValue: InkAnswerCoordinator(
            settings: settings,
            client: client,
            indexer: corpus.indexer
        ))
        let schema = Schema([
            Notebook.self,
            NotebookFolder.self,
            Page.self,
            PageElement.self,
            AssistantThread.self,
            AssistantMessage.self,
        ])
        let config: ModelConfiguration
        if let storeID = Self.argumentValue(after: "-ui-testing-store-id", in: arguments) {
            let storeURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("BetterNotesUITests-\(storeID).store")
            config = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        } else if isUnitTesting {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else {
            // Keep the existing store URL so already downloaded notes remain.
            config = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        }
        let startupSnapshot = (isUITesting || isUnitTesting) ? nil : StoreRecovery.createSnapshotIfPresent(for: config.url)
        do {
            let opened = try ModelContainer(for: schema, configurations: [config])
            modelContainer = opened
            recoveryURL = startupSnapshot
            if !isUITesting && !isUnitTesting {
                do {
                    try RichTextMigration.run(in: opened)
                    try InterruptedAnswerRecovery.run(in: opened)
                    startupError = nil
                } catch {
                    startupError = "Notebook recovery could not be saved: \(error.localizedDescription)"
                }
            } else {
                startupError = nil
            }
        } catch {
            // Recovery has no model dependencies. Do not try to open the broken
            // schema again (or force-unwrap a fallback) just to present it.
            modelContainer = nil
            startupError = error.localizedDescription
            recoveryURL = startupSnapshot ?? StoreRecovery.createSnapshotIfPresent(for: config.url, force: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let startupError {
                    StoreRecoveryView(errorMessage: startupError, recoveryURL: recoveryURL)
                } else if let modelContainer {
                    LibraryView()
                        .modelContainer(modelContainer)
                        .task { if nearbySync.isPaired { nearbySync.start(context: modelContainer.mainContext) } }
                        .onChange(of: scenePhase) { _, phase in
                            if phase == .active, nearbySync.isPaired {
                                nearbySync.start(context: modelContainer.mainContext)
                            } else if phase == .background {
                                nearbySync.stop()
                            }
                        }
                } else {
                    StoreRecoveryView(errorMessage: "The notes database could not be opened.", recoveryURL: recoveryURL)
                }
            }
            .environment(\.locale, Locale(identifier: language))
            .nearbyDeletionPrompt()
        }
        .environmentObject(aiSettings)
        .environmentObject(aiService)
        .environmentObject(corpusStore)
        .environmentObject(assistantCoordinator)
        .environmentObject(inkAnswerCoordinator)
        .environmentObject(nearbySync)
        .environmentObject(ocrSettings)
        .environmentObject(ocrService)
    }

    private static func argumentValue(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

private enum StoreRecovery {
    static func createSnapshotIfPresent(for storeURL: URL, force: Bool = false) -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: storeURL.path) else { return nil }

        let defaults = UserDefaults.standard
        let lastSnapshot = defaults.object(forKey: "store.lastSnapshot") as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(lastSnapshot) > 24 * 60 * 60 else {
            return latestSnapshot()
        }

        do {
            let root = try recoveryRoot()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let destination = root.appendingPathComponent("BetterNotes-\(formatter.string(from: .now)).recovery", isDirectory: true)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

            for source in storeFiles(for: storeURL) where fileManager.fileExists(atPath: source.path) {
                try fileManager.copyItem(at: source, to: destination.appendingPathComponent(source.lastPathComponent))
            }
            defaults.set(Date(), forKey: "store.lastSnapshot")
            pruneSnapshots(in: root, keeping: 5)
            return destination
        } catch {
            return nil
        }
    }

    private static func storeFiles(for storeURL: URL) -> [URL] {
        [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm"),
        ]
    }

    private static func recoveryRoot() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("BetterNotes Recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func latestSnapshot() -> URL? {
        guard let root = try? recoveryRoot() else { return nil }
        return try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ).sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }.first
    }

    private static func pruneSnapshots(in root: URL, keeping limit: Int) {
        guard let snapshots = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) else { return }
        for snapshot in snapshots.dropFirst(limit) {
            try? FileManager.default.removeItem(at: snapshot)
        }
    }
}

private struct StoreRecoveryView: View {
    let errorMessage: String
    let recoveryURL: URL?
    @State private var showingShare = false

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Notes Need Recovery", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text("The notes database could not be opened. BetterNotes preserved it instead of deleting it.\n\n\(errorMessage)")
            } actions: {
                if recoveryURL != nil {
                    Button {
                        showingShare = true
                    } label: {
                        Label("Export Recovery Copy", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("BetterNotes")
        }
        .sheet(isPresented: $showingShare) {
            if let recoveryURL {
                ShareSheet(items: [recoveryURL])
            }
        }
    }
}
