import SwiftData
import UIKit
import XCTest
@testable import BetterNotes

@MainActor
final class RichTextMigrationTests: XCTestCase {
    func testLegacyRichTextAndAudioSurviveMigrationAndEditableBackup() throws {
        let schema = Schema([Notebook.self, Page.self, PageElement.self])
        let sourceConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let source = try ModelContainer(for: schema, configurations: [sourceConfig])
        let context = ModelContext(source)

        let notebook = Notebook(title: "Older lecture")
        let page = Page(index: 0)
        page.notebook = notebook
        notebook.pages = [page]
        let text = PageElement(type: .textBox, x: 100, y: 100)
        let legacyText = NSAttributedString(string: "Key idea", attributes: [
            .font: UIFont.boldSystemFont(ofSize: 20),
        ])
        text.richTextData = try NSKeyedArchiver.archivedData(
            withRootObject: legacyText, requiringSecureCoding: true
        )
        text.text = legacyText.string
        text.page = page
        let audio = PageElement(type: .audioRecording, x: 100, y: 250)
        audio.audioData = Data([1, 2, 3, 4])
        audio.audioDuration = 12
        audio.page = page
        page.elements = [text, audio]
        context.insert(notebook)
        try context.save()

        try RichTextMigration.run(in: source)
        let migrated = try XCTUnwrap(ModelContext(source).fetch(FetchDescriptor<PageElement>())
            .first { $0.type == .textBox })
        XCTAssertTrue(RichTextCodec.isPortable(try XCTUnwrap(migrated.richTextData)))
        XCTAssertEqual(migrated.resolvedRichText.string, "Key idea")

        let exportContext = ModelContext(source)
        let migratedNotebook = try XCTUnwrap(exportContext.fetch(FetchDescriptor<Notebook>()).first)
        let archive = try CloudTranslator.writeArchive(for: migratedNotebook)
        defer { try? FileManager.default.removeItem(at: archive) }
        let destinationConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let destination = try ModelContainer(for: schema, configurations: [destinationConfig])
        let restored = try CloudTranslator.importArchive(from: archive, into: ModelContext(destination))
        let restoredPage = try XCTUnwrap(restored.pages.first)
        let restoredText = try XCTUnwrap(restoredPage.elements.first { $0.type == .textBox })
        let restoredAudio = try XCTUnwrap(restoredPage.elements.first { $0.type == .audioRecording })
        XCTAssertTrue(RichTextCodec.isPortable(try XCTUnwrap(restoredText.richTextData)))
        XCTAssertEqual(restoredText.resolvedRichText.string, "Key idea")
        XCTAssertEqual(restoredAudio.audioData, Data([1, 2, 3, 4]))
        XCTAssertEqual(restoredAudio.audioDuration, 12)
    }

    /// The portable format has no strikethrough field. Migrating such a
    /// payload would silently erase the strikethrough, so it must stay in the
    /// legacy format (which iOS still reads) while plain payloads migrate.
    func testMigrationLeavesPayloadsItCannotRepresentUntouched() throws {
        let schema = Schema([Notebook.self, Page.self, PageElement.self])
        let container = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let notebook = Notebook(title: "Mixed")
        let page = Page(index: 0)
        page.notebook = notebook
        notebook.pages = [page]

        func legacyBox(_ text: String, _ extra: [NSAttributedString.Key: Any]) throws -> (PageElement, Data) {
            let box = PageElement(type: .textBox, x: 10, y: 10)
            var attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 18)]
            attributes.merge(extra) { $1 }
            let data = try NSKeyedArchiver.archivedData(
                withRootObject: NSAttributedString(string: text, attributes: attributes),
                requiringSecureCoding: true
            )
            box.richTextData = data
            box.text = text
            box.page = page
            return (box, data)
        }
        let (struck, struckData) = try legacyBox("struck", [.strikethroughStyle: NSUnderlineStyle.single.rawValue])
        let (plain, _) = try legacyBox("plain", [:])
        page.elements = [struck, plain]
        context.insert(notebook)
        try context.save()

        try RichTextMigration.run(in: container)

        let elements = try ModelContext(container).fetch(FetchDescriptor<PageElement>())
        let struckAfter = try XCTUnwrap(elements.first { $0.text == "struck" })
        let plainAfter = try XCTUnwrap(elements.first { $0.text == "plain" })
        XCTAssertEqual(struckAfter.richTextData, struckData, "a payload the codec cannot represent was rewritten")
        XCTAssertNotNil(struckAfter.resolvedRichText.attribute(.strikethroughStyle, at: 0, effectiveRange: nil))
        XCTAssertTrue(RichTextCodec.isPortable(try XCTUnwrap(plainAfter.richTextData)))
    }
}
