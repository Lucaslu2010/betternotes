import SwiftData
import SwiftUI

@main
struct BetterNotesMacApp: App {
    @Environment(\.scenePhase) private var scenePhase
    let container: ModelContainer
    let startupError: String?
    @StateObject private var aiSettings = AISettingsStore()
    @StateObject private var corpus = NoteCorpusStore()
    @StateObject private var nearbySync = NearbySyncCoordinator()

    init() {
        let storeDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BetterNotesMac", isDirectory: true)
        let storeURL = storeDirectory.appendingPathComponent("BetterNotes.store")
        let schema = Schema([
            Notebook.self, Page.self, PageElement.self,
            AssistantThread.self, AssistantMessage.self,
        ])
        do {
            try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
            let config = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
            container = try ModelContainer(for: schema, configurations: [config])
            startupError = nil
        } catch {
            // Preserve the on-disk library if a store migration fails.
            NSLog("BetterNotes Mac store unavailable: %@", error.localizedDescription)
            startupError = error.localizedDescription
            container = try! ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ])
        }
    }

    var body: some Scene {
        WindowGroup {
            MacLibraryView(startupError: startupError)
                .nearbyDeletionPrompt()
                .environmentObject(aiSettings)
                .environmentObject(corpus)
                .environmentObject(nearbySync)
                .task { if startupError == nil, nearbySync.isPaired { nearbySync.start(context: container.mainContext) } }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active, startupError == nil, nearbySync.isPaired {
                        nearbySync.start(context: container.mainContext)
                    } else if phase == .background {
                        nearbySync.stop()
                    }
                }
        }
        .modelContainer(container)
    }
}
