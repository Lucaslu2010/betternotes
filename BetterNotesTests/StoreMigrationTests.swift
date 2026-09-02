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
}
