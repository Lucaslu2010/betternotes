import XCTest
import SwiftData
@testable import BetterNotes

/// `.betternotes` archives are the only backup the app has left — cloud sync
/// was removed in 002477c. If a field does not survive export and re-import,
/// a user who restores from their own backup silently loses it. These tests
/// walk a fully-populated notebook out to an archive and back, and compare.
@MainActor
final class ArchiveRoundTripTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Notebook.self, Page.self, PageElement.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
    }

    /// A notebook with every field the archive claims to carry set to a value
    /// that is not its default — so a dropped field shows up as a failure
    /// rather than coincidentally matching.
    private func populatedNotebook(in context: ModelContext) -> Notebook {
        let notebook = Notebook(title: "Organic Chemistry")
        notebook.subtitle = "Michaelmas"
        notebook.folderName = "Year 12"
        notebook.tagsText = "chem,revision"
        notebook.isFavorite = true
        notebook.isArchived = true
        notebook.coverColorHex = "3366CC"
        notebook.coverColor2Hex = "88AAFF"
        notebook.coverStyle = "gradient"
        notebook.coverEmoji = "🧪"
        notebook.defaultLineStyle = PageLineStyle.grid.rawValue
        notebook.defaultBackgroundHex = "FFFDF5"
        notebook.defaultOrientation = PageOrientation.landscape.rawValue

        let page = Page(index: 0)
        page.title = "Alkenes"
        page.isBookmarked = true
        page.backgroundHex = "FFF0E0"
        page.lineStyle = PageLineStyle.ruled.rawValue
        page.orientation = PageOrientation.landscape.rawValue
        page.ocrText = "electrophilic addition"
        page.inkData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        page.notebook = notebook

        let text = PageElement(type: .textBox, x: 12, y: 34, width: 210, height: 90, rotation: 0.25)
        text.text = "Markovnikov"
        text.richTextData = Data([1, 2, 3])
        text.fontName = "Georgia"
        text.fontSize = 22
        text.isBold = true
        text.isItalic = true
        text.isUnderline = true
        text.textAlignment = "center"
        text.colorHex = "112233"
        text.isLocked = true
        text.page = page

        let media = PageElement(type: .audioRecording, x: 300, y: 400)
        media.imageData = Data([9, 8, 7])
        media.audioData = Data([5, 5, 5, 5])
        media.audioDuration = 42.5
        media.transcript = "recap of the mechanism"
        media.shapeKind = "circle"
        media.isRevealed = true
        media.page = page

        page.appendElement(text)
        page.appendElement(media)
        notebook.pages = [page]

        let trashed = Page(index: 1)
        trashed.title = "Deleted draft"
        trashed.trashedAt = .now
        trashed.notebook = notebook
        notebook.pages.append(trashed)

        context.insert(notebook)
        return notebook
    }

    /// Export to a file and import it back into a *fresh* store.
    private func roundTrip(_ notebook: Notebook) throws -> Notebook {
        let url = try CloudTranslator.writeArchive(for: notebook)
        defer { try? FileManager.default.removeItem(at: url) }
        return try CloudTranslator.importArchive(from: url, into: try makeContext())
    }

    func testNotebookMetadataSurvives() throws {
        let original = populatedNotebook(in: try makeContext())
        let restored = try roundTrip(original)

        XCTAssertEqual(restored.title, "Organic Chemistry")
        XCTAssertEqual(restored.stableID, original.stableID)
        XCTAssertEqual(restored.coverColorHex, "3366CC")
        XCTAssertEqual(restored.coverColor2Hex, "88AAFF")
        XCTAssertEqual(restored.coverStyle, "gradient")
        XCTAssertEqual(restored.coverEmoji, "🧪")
        XCTAssertEqual(restored.folderName, "Year 12")
        XCTAssertEqual(restored.tagsText, "chem,revision")
        XCTAssertTrue(restored.isFavorite)
        XCTAssertTrue(restored.isArchived)
        XCTAssertEqual(restored.defaultLineStyle, PageLineStyle.grid.rawValue)
        XCTAssertEqual(restored.defaultBackgroundHex, "FFFDF5")
        XCTAssertEqual(restored.defaultOrientation, PageOrientation.landscape.rawValue)
        XCTAssertNil(restored.cloudID, "an imported notebook must not claim the original's cloud identity")
    }

    func testPagesAndInkSurvive() throws {
        let original = populatedNotebook(in: try makeContext())
        let restored = try roundTrip(original)

        XCTAssertEqual(restored.pages.count, 1, "trashed pages must not come back")
        let page = try XCTUnwrap(restored.pages.first)
        XCTAssertEqual(page.stableID, original.pages[0].stableID)
        XCTAssertEqual(page.title, "Alkenes")
        XCTAssertTrue(page.isBookmarked)
        XCTAssertEqual(page.backgroundHex, "FFF0E0")
        XCTAssertEqual(page.lineStyle, PageLineStyle.ruled.rawValue)
        XCTAssertEqual(page.orientation, PageOrientation.landscape.rawValue)
        XCTAssertEqual(page.ocrText, "electrophilic addition")
        XCTAssertEqual(page.inkData, Data([0xDE, 0xAD, 0xBE, 0xEF]), "the handwriting was lost")
    }

    func testEveryElementFieldSurvives() throws {
        let original = populatedNotebook(in: try makeContext())
        let restored = try roundTrip(original)
        let elements = try XCTUnwrap(restored.pages.first).orderedElements
        XCTAssertEqual(elements.count, 2)

        let text = elements[0]
        XCTAssertEqual(text.elementType, ElementType.textBox.rawValue)
        XCTAssertEqual(text.posX, 12, accuracy: 0.001)
        XCTAssertEqual(text.posY, 34, accuracy: 0.001)
        XCTAssertEqual(text.width, 210, accuracy: 0.001)
        XCTAssertEqual(text.height, 90, accuracy: 0.001)
        XCTAssertEqual(text.rotation, 0.25, accuracy: 0.001)
        XCTAssertEqual(text.text, "Markovnikov")
        XCTAssertEqual(text.richTextData, Data([1, 2, 3]))
        XCTAssertEqual(text.fontName, "Georgia")
        XCTAssertEqual(text.fontSize, 22, accuracy: 0.001)
        XCTAssertTrue(text.isBold)
        XCTAssertTrue(text.isItalic)
        XCTAssertTrue(text.isUnderline)
        XCTAssertEqual(text.textAlignment, "center")
        XCTAssertEqual(text.colorHex, "112233")
        XCTAssertTrue(text.isLocked)

        let media = elements[1]
        XCTAssertEqual(media.elementType, ElementType.audioRecording.rawValue)
        XCTAssertEqual(media.imageData, Data([9, 8, 7]))
        XCTAssertEqual(media.audioData, Data([5, 5, 5, 5]))
        XCTAssertEqual(media.audioDuration ?? 0, 42.5, accuracy: 0.001)
        XCTAssertEqual(media.transcript, "recap of the mechanism")
        XCTAssertEqual(media.shapeKind, "circle")
        XCTAssertTrue(media.isRevealed)
    }

    func testStackingOrderSurvives() throws {
        // The editor draws page.elements in array order, so the array *is* the
        // z-order. An archive that reorders them re-stacks the user's canvas.
        let original = populatedNotebook(in: try makeContext())
        let restored = try roundTrip(original)
        XCTAssertEqual(try XCTUnwrap(restored.pages.first).orderedElements.map(\.elementType),
                       try XCTUnwrap(original.pages.first).orderedElements.map(\.elementType))
    }

    func testCreationDatesSurvive() throws {
        // NoteCorpusIndexer orders elements by createdAt to assign the stable
        // ordinals the assistant cites, so these are load-bearing, not just
        // metadata.
        let context = try makeContext()
        let original = populatedNotebook(in: context)
        let restored = try roundTrip(original)
        let before = try XCTUnwrap(original.pages.first).orderedElements.map(\.createdAt)
        let after = try XCTUnwrap(restored.pages.first).orderedElements.map(\.createdAt)
        for (index, pair) in zip(before, after).enumerated() {
            XCTAssertEqual(pair.1.timeIntervalSince1970, pair.0.timeIntervalSince1970, accuracy: 0.001,
                           "element \(index) came back with a different creation date")
        }
    }

    func testAnEmptyNotebookRoundTrips() throws {
        let context = try makeContext()
        let notebook = Notebook(title: "Empty")
        context.insert(notebook)
        let restored = try roundTrip(notebook)
        XCTAssertEqual(restored.title, "Empty")
        XCTAssertTrue(restored.pages.isEmpty)
    }

    func testAFileThatIsNotAnArchiveIsRejected() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-an-archive-\(UUID().uuidString).betternotes")
        try Data("{\"hello\":\"world\"}".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try CloudTranslator.importArchive(from: url, into: try makeContext())) { error in
            XCTAssertEqual(error as? ArchiveError, .invalidArchive)
        }
    }

    func testCorruptJSONIsRejected() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-\(UUID().uuidString).betternotes")
        try Data([0x00, 0xFF, 0x00, 0xFF]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try CloudTranslator.importArchive(from: url, into: try makeContext()))
    }
}
