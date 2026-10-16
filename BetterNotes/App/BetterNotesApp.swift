import SwiftUI
import SwiftData

@main
struct BetterNotesApp: App {
    let modelContainer: ModelContainer?
    let startupError: String?
    let recoveryURL: URL?
    @StateObject private var aiSettings: AISettingsStore
    @StateObject private var aiService: AIService
    @StateObject private var corpusStore: NoteCorpusStore
    @StateObject private var assistantCoordinator: AssistantCoordinator
    @StateObject private var writingSuggestionCoordinator: WritingSuggestionCoordinator
    @StateObject private var ocrSettings: OCRSettingsStore
    @StateObject private var ocrService: OCRService

    init() {
        MemoryDiagnostics.shared.start()
        let arguments = CommandLine.arguments
        let isUITesting = arguments.contains("-ui-testing")
        if isUITesting {
            let defaults = UserDefaults.standard
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
            defaults.set(false, forKey: AppPreferenceKey.automaticWritingSuggestions)
            // Pin finger drawing on. Every other preference the tests depend
            // on is pinned here, but this one was left to whatever the host
            // had stored -- so a drawing test passed in a fresh simulator
            // (which defaults to true) and failed on a real iPad belonging to
            // someone who draws with a Pencil and had switched it off. The
            // synthesised touches XCUITest delivers are `.direct`, and
            // PaperCanvas only observes those when this is true.
            defaults.set(true, forKey: AppPreferenceKey.allowsFingerDrawing)
        }
        let settings = AISettingsStore()
        let recognitionSettings = OCRSettingsStore()
        _ocrSettings = StateObject(wrappedValue: recognitionSettings)
        _ocrService = StateObject(wrappedValue: OCRService(settings: recognitionSettings))
        let client = AIClient()
        let corpus = NoteCorpusStore()
        _aiSettings = StateObject(wrappedValue: settings)
        _aiService = StateObject(wrappedValue: AIService(settingsStore: settings, client: client))
        _corpusStore = StateObject(wrappedValue: corpus)
        _assistantCoordinator = StateObject(wrappedValue: AssistantCoordinator(
            settings: settings,
            client: client,
            indexer: corpus.indexer
        ))
        _writingSuggestionCoordinator = StateObject(wrappedValue: WritingSuggestionCoordinator(
            settings: settings,
            client: client
        ))
        let schema = Schema([
            Notebook.self,
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
        } else {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        }
        let startupSnapshot = isUITesting ? nil : StoreRecovery.createSnapshotIfPresent(for: config.url)
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
            startupError = nil
            recoveryURL = startupSnapshot
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
            if let modelContainer {
                LibraryView()
                    .modelContainer(modelContainer)
            } else {
                StoreRecoveryView(errorMessage: startupError ?? "The notes database could not be opened.", recoveryURL: recoveryURL)
            }
        }
        .environmentObject(aiSettings)
        .environmentObject(aiService)
        .environmentObject(corpusStore)
        .environmentObject(assistantCoordinator)
        .environmentObject(writingSuggestionCoordinator)
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
