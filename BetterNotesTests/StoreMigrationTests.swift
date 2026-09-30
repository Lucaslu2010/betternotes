import XCTest
import SwiftData
@testable import BetterNotes

/// `zIndex` was added to PageElement after the app had already shipped stores
/// without it. SwiftData handles that as a lightweight migration — there is no
/// SchemaMigrationPlan in this project — but "should work" is not evidence
/// when the failure mode is a user opening the app to find their notes gone.
///
/// `Fixtures/legacy-v1.store` is a real store written by the build at b4b93aa,
/// the commit before zIndex existed. This opens it with the current schema.
@MainActor
final class StoreMigrationTests: XCTestCase {

    /// Copies the fixture somewhere writable — migration mutates the store,
    /// and the one inside the test bundle is read-only.
    private func openLegacyStore() throws -> ModelContext {
        let bundled = try XCTUnwrap(
            Bundle(for: type(of: self)).url(forResource: "legacy-v1", withExtension: "store"),
            "the legacy store fixture is missing from the test bundle"
        )
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-\(UUID().uuidString).store")
        try FileManager.default.copyItem(at: bundled, to: copy)
        addTeardownBlock {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(
                    at: copy.deletingPathExtension()
                        .appendingPathExtension("store\(suffix)"))
            }
        }

        let schema = Schema([Notebook.self, Page.self, PageElement.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: copy, cloudKitDatabase: .none)]
        )
        return ModelContext(container)
    }

    func testAStoreWrittenBeforeZIndexStillOpens() throws {
        // The whole point: this must not throw. A failed migration is what
        // sends the app into StoreRecovery instead of into the user's notes.
        _ = try openLegacyStore()
    }

    func testNothingIsLostMigratingAPreZIndexStore() throws {
        let context = try openLegacyStore()
        let notebooks = try context.fetch(FetchDescriptor<Notebook>())
        XCTAssertEqual(notebooks.count, 1)

        let notebook = try XCTUnwrap(notebooks.first)
        XCTAssertEqual(notebook.title, "Legacy Notebook")
        XCTAssertEqual(notebook.folderName, "Year 12")
        XCTAssertTrue(notebook.isFavorite)

        let page = try XCTUnwrap(notebook.pages.first)
        XCTAssertEqual(page.title, "Legacy Page")
        XCTAssertEqual(page.ocrText, "written before zIndex existed")
        XCTAssertEqual(page.inkData, Data([0xAB, 0xCD]), "the handwriting did not survive migration")
        XCTAssertEqual(page.elements.count, 3)
        XCTAssertEqual(Set(page.elements.compactMap(\.text)), ["bottom", "middle", "top"])
    }

    func testMigratedElementsGetTheDefaultZIndexAndOpenInDrawnOrder() throws {
        let context = try openLegacyStore()
        let page = try XCTUnwrap(
            try XCTUnwrap(try context.fetch(FetchDescriptor<Notebook>()).first).pages.first
        )
        XCTAssertTrue(page.elements.allSatisfy { $0.zIndex == 0 },
                      "the new attribute did not take its default value")
        // Every zIndex being 0 is exactly why orderedElements falls back to
        // createdAt: without that, a migrated page would stack arbitrarily.
        XCTAssertEqual(page.orderedElements.compactMap(\.text), ["bottom", "middle", "top"])
    }

    func testLayeringCanBeSetAndPersistedOnceMigrated() throws {
        let context = try openLegacyStore()
        let page = try XCTUnwrap(
            try XCTUnwrap(try context.fetch(FetchDescriptor<Notebook>()).first).pages.first
        )
        page.restoreElementOrder()
        page.elements.swapAt(0, 2)
        page.stampElementOrder()
        try context.save()
        XCTAssertEqual(page.orderedElements.compactMap(\.text), ["top", "middle", "bottom"])
    }

    // MARK: - Assistant conversations

    /// `messages` became `storedMessages` (optional, `originalName: "messages"`)
    /// when the CloudKit-era model was reshaped. Nothing else proved that a
    /// conversation written before the rename still opens, or that its messages
    /// are still attached to it -- losing chat history on update is silent.
    ///
    /// `Fixtures/legacy-assistant.store` was written by the pre-rename model
    /// (`AssistantModels.swift` from 2f1cc65, compiled verbatim into a standalone
    /// tool) holding one thread "Old chat" with two messages.
    private func openLegacyAssistantStore() throws -> ModelContext {
        let bundled = try XCTUnwrap(
            Bundle(for: type(of: self)).url(forResource: "legacy-assistant", withExtension: "store"),
            "the legacy assistant store fixture is missing from the test bundle"
        )
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-assistant-\(UUID().uuidString).store")
        try FileManager.default.copyItem(at: bundled, to: copy)
        addTeardownBlock {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(atPath: copy.path + suffix)
            }
        }
        let schema = Schema([
            Notebook.self, Page.self, PageElement.self, AssistantThread.self, AssistantMessage.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: copy, cloudKitDatabase: .none)]
        )
        return ModelContext(container)
    }

    func testAConversationWrittenBeforeTheMessagesRenameStillOpensWithItsMessages() throws {
        let context = try openLegacyAssistantStore()
        let threads = try context.fetch(FetchDescriptor<AssistantThread>())
        XCTAssertEqual(threads.count, 1)

        let thread = try XCTUnwrap(threads.first)
        XCTAssertEqual(thread.title, "Old chat")
        XCTAssertEqual(thread.orderedMessages.map(\.content), ["What is ATP?", "ATP stores energy."],
                       "the messages were orphaned from their thread by the rename")
        XCTAssertTrue(thread.orderedMessages.allSatisfy { $0.thread?.stableID == thread.stableID })
    }

    func testAMigratedConversationAcceptsNewMessagesAndStillCascadesOnDelete() throws {
        let context = try openLegacyAssistantStore()
        let thread = try XCTUnwrap(try context.fetch(FetchDescriptor<AssistantThread>()).first)

        let reply = AssistantMessage(role: .user, content: "And ADP?")
        reply.thread = thread
        thread.messages.append(reply)
        try context.save()
        XCTAssertEqual(thread.orderedMessages.count, 3)

        try AssistantThread.deleteAll(in: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AssistantThread>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AssistantMessage>()), 0,
                       "messages from the old store outlived their deleted thread")
    }
}
