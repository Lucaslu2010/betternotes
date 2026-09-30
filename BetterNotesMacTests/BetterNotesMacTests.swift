import AppKit
import PencilKit
import SwiftData
import XCTest
@testable import BetterNotesMac

@MainActor
final class BetterNotesMacTests: XCTestCase {
    func testNotebookPageAndImagePersistAcrossContainerReload() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-notes-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        let schema = Schema([Notebook.self, Page.self, PageElement.self])
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            let notebook = Notebook(title: "Mac Capture")
            context.insert(notebook)
            let page = Page()
            page.notebook = notebook
            context.insert(page)
            notebook.pages.append(page)
            let element = PageElement(type: .image, x: 384, y: 240, width: 320, height: 160)
            element.imageData = Data([1, 2, 3, 4])
            page.appendElement(element)
            context.insert(element)
            try context.save()
        }
        let reopened = try ModelContainer(for: schema, configurations: [config])
        let notebooks = try ModelContext(reopened).fetch(FetchDescriptor<Notebook>())
        let notebook = try XCTUnwrap(notebooks.first)
        XCTAssertEqual(notebook.title, "Mac Capture")
        let page = try XCTUnwrap(notebook.pages.first)
        let image = try XCTUnwrap(page.elements.first)
        XCTAssertEqual(image.imageData, Data([1, 2, 3, 4]))
        XCTAssertEqual(image.posX, 384)
        XCTAssertEqual(image.posY, 240)
    }

    func testPortableRichTextDecodesOnMac() throws {
        let text = NSAttributedString(string: "A styled note", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 20),
            .foregroundColor: NSColor.red,
        ])
        let data = try XCTUnwrap(RichTextCodec.encode(text))
        let decoded = try XCTUnwrap(RichTextCodec.decode(data))
        XCTAssertEqual(decoded.string, text.string)
        XCTAssertEqual((decoded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 20)
    }

    func testTextFileBecomesEditablePageElement() throws {
        let schema = Schema([Notebook.self, Page.self, PageElement.self])
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)
        let notebook = Notebook(title: "Imported text")
        let page = Page()
        context.insert(notebook)
        context.insert(page)
        page.notebook = notebook
        notebook.pages.append(page)
        let element = try MacTextImporter.add(data: Data("A paragraph from a file".utf8), to: page, in: context)
        try context.save()
        XCTAssertEqual(element.type, .textBox)
        XCTAssertEqual(page.elements.first?.text, "A paragraph from a file")
        XCTAssertThrowsError(try MacTextImporter.add(data: Data([0xFF]), to: page, in: context))
    }

    func testBlackInkRendersOnWhitePaperInDarkAppearance() throws {
        func stroke(_ color: NSColor, y: CGFloat) -> PKStroke {
            let points = [CGPoint(x: 30, y: y), CGPoint(x: 270, y: y)].map { point in
                PKStrokePoint(location: point, timeOffset: 0, size: CGSize(width: 8, height: 8),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: color),
                            path: PKStrokePath(controlPoints: points, creationDate: .now))
        }
        let drawing = PKDrawing(strokes: [stroke(.black, y: 40), stroke(.red, y: 100)])
        var image = NSImage()
        try XCTUnwrap(NSAppearance(named: .darkAqua)).performAsCurrentDrawingAppearance {
            image = MacInkRenderer.image(from: drawing,
                in: CGRect(x: 0, y: 0, width: 300, height: 150))
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        var blackPixels = 0
        var redPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      pixel.alphaComponent > 0.5 else { continue }
                if pixel.redComponent < 0.35 && pixel.greenComponent < 0.35 && pixel.blueComponent < 0.35 {
                    blackPixels += 1
                }
                if pixel.redComponent > 0.6 && pixel.greenComponent < 0.35 && pixel.blueComponent < 0.35 {
                    redPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(blackPixels, 100, "Black strokes disappeared in Dark Mode")
        XCTAssertGreaterThan(redPixels, 100, "Colored strokes disappeared")
    }

}
