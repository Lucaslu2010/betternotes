import XCTest
import SwiftData
@testable import BetterNotes

/// Bring Forward and Send Backward work by reordering `page.elements`, but a
/// SwiftData to-many relationship has no guaranteed order — so before zIndex
/// existed, the layering a user set was lost the moment the relationship was
/// re-materialised from the store. These tests pin the persisted order.
@MainActor
final class ElementLayerOrderTests: XCTestCase {

    private func makeStore() throws -> (ModelContainer, URL) {
        let schema = Schema([Notebook.self, Page.self, PageElement.self])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Layering-\(UUID().uuidString).store")
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return (try ModelContainer(for: schema, configurations: [configuration]), url)
    }

    func testLayeringSurvivesReopeningTheStore() throws {
        let (container, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let schema = Schema([Notebook.self, Page.self, PageElement.self])
        let notebookID: UUID

        do {
            let context = ModelContext(container)
            let notebook = Notebook(title: "Layers")
            notebookID = notebook.stableID
            let page = Page(index: 0)
            page.notebook = notebook
            for name in ["bottom", "middle", "top"] {
                let element = PageElement(type: .textBox, x: 0, y: 0)
                element.text = name
                page.appendElement(element)
            }
            notebook.pages = [page]
            context.insert(notebook)
            // The user sends "top" to the back — a pure array reorder, exactly
            // as moveSelectedElement does.
            page.elements.swapAt(2, 0)
            page.stampElementOrder()
            try context.save()
        }

        let reopened = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)]
        )
        let context = ModelContext(reopened)
        let notebook = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Notebook>()).first { $0.stableID == notebookID }
        )
        let page = try XCTUnwrap(notebook.pages.first)
        page.restoreElementOrder()
        XCTAssertEqual(page.elements.compactMap(\.text), ["top", "middle", "bottom"],
                       "the layering the user set did not survive a relaunch")
    }

    func testANewElementLandsOnTop() throws {
        let schema = Schema([Notebook.self, Page.self, PageElement.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let page = Page(index: 0)
        context.insert(page)
        for name in ["a", "b"] {
            let element = PageElement(type: .textBox, x: 0, y: 0)
            element.text = name
            page.appendElement(element)
        }
        page.elements.swapAt(0, 1)
        page.stampElementOrder()

        let fresh = PageElement(type: .textBox, x: 0, y: 0)
        fresh.text = "new"
        page.appendElement(fresh)
        XCTAssertEqual(page.orderedElements.compactMap(\.text).last, "new",
                       "a newly added element did not land on top of the stack")
    }

    func testAPageWrittenBeforeZIndexKeepsTheOrderItWasDrawnIn() {
        // Every element in an existing store has zIndex 0; createdAt breaks
        // the tie so those pages open in the order they were drawn rather
        // than in an arbitrary one.
        let page = Page(index: 0)
        let older = PageElement(type: .textBox, x: 0, y: 0)
        older.text = "older"
        older.createdAt = Date(timeIntervalSince1970: 1_000)
        let newer = PageElement(type: .textBox, x: 0, y: 0)
        newer.text = "newer"
        newer.createdAt = Date(timeIntervalSince1970: 2_000)
        page.elements = [newer, older]
        XCTAssertEqual(page.orderedElements.compactMap(\.text), ["older", "newer"])
    }
}
