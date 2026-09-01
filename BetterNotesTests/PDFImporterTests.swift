import XCTest
import PDFKit
import UIKit
@testable import BetterNotes

/// Importing a PDF is how most lecture handouts get into a notebook, and it
/// had no coverage. What matters is that every page arrives, that a page is
/// laid out the way round it is actually drawn, and that its artwork is
/// centred rather than stretched.
final class PDFImporterTests: XCTestCase {

    private var scratch: [URL] = []

    override func tearDown() {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch = []
        super.tearDown()
    }

    /// Writes a PDF whose pages carry the given media-box sizes and a line of
    /// text each, and returns its URL.
    private func makePDF(pageSizes: [CGSize], rotation: Int = 0, text: String = "Lecture 4") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString).pdf")
        scratch.append(url)

        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data)!
        var context: CGContext?
        for size in pageSizes {
            var box = CGRect(origin: .zero, size: size)
            if context == nil { context = CGContext(consumer: consumer, mediaBox: &box, nil) }
            context?.beginPage(mediaBox: &box)
            context?.setFillColor(UIColor.white.cgColor)
            context?.fill(box)
            UIGraphicsPushContext(context!)
            (text as NSString).draw(
                at: CGPoint(x: 40, y: 40),
                withAttributes: [.font: UIFont.systemFont(ofSize: 28),
                                 .foregroundColor: UIColor.black]
            )
            UIGraphicsPopContext()
            context?.endPage()
        }
        context?.closePDF()

        guard rotation != 0 else {
            try (data as Data).write(to: url)
            return url
        }
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        for index in 0..<document.pageCount {
            document.page(at: index)?.rotation = rotation
        }
        try XCTUnwrap(document.dataRepresentation()).write(to: url)
        return url
    }

    func testEveryPageIsImported() throws {
        let url = try makePDF(pageSizes: Array(repeating: CGSize(width: 612, height: 792), count: 3))
        let pages = try PDFImporter.pages(from: url)
        XCTAssertEqual(pages.count, 3)
        XCTAssertTrue(pages.allSatisfy { $0.imageData != nil }, "a page came in with no artwork")
    }

    func testTextIsPulledOutOfThePage() throws {
        let url = try makePDF(pageSizes: [CGSize(width: 612, height: 792)], text: "Photosynthesis")
        let page = try XCTUnwrap(try PDFImporter.pages(from: url).first)
        XCTAssertTrue(page.extractedText.contains("Photosynthesis"),
                      "extracted \(page.extractedText)")
    }

    func testOrientationFollowsThePageShape() throws {
        let portrait = try PDFImporter.pages(from: try makePDF(pageSizes: [CGSize(width: 612, height: 792)]))
        XCTAssertEqual(portrait.first?.orientation, PageOrientation.portrait.rawValue)

        let landscape = try PDFImporter.pages(from: try makePDF(pageSizes: [CGSize(width: 792, height: 612)]))
        XCTAssertEqual(landscape.first?.orientation, PageOrientation.landscape.rawValue)
    }

    func testARotatedPageIsLaidOutTheWayItIsDrawn() throws {
        // /Rotate 90 on a portrait media box is a landscape page: PDFPage.draw
        // honours the rotation, so a layout derived from the unrotated media
        // box would fit landscape artwork into a portrait frame.
        let url = try makePDF(pageSizes: [CGSize(width: 612, height: 792)], rotation: 90)
        let page = try XCTUnwrap(try PDFImporter.pages(from: url).first)
        XCTAssertEqual(page.orientation, PageOrientation.landscape.rawValue,
                       "a page rotated 90° was imported as portrait")
        XCTAssertGreaterThan(page.imageFrame.width, page.imageFrame.height,
                             "the frame does not match the shape the page draws in")
    }

    func testArtworkIsCentredAndKeepsItsAspectRatio() throws {
        let url = try makePDF(pageSizes: [CGSize(width: 400, height: 800)])
        let page = try XCTUnwrap(try PDFImporter.pages(from: url).first)
        let canvas = PageOrientation.portrait.size

        XCTAssertEqual(page.imageFrame.midX, canvas.width / 2, accuracy: 0.5, "not centred horizontally")
        XCTAssertEqual(page.imageFrame.midY, canvas.height / 2, accuracy: 0.5, "not centred vertically")
        XCTAssertEqual(page.imageFrame.width / page.imageFrame.height, 400.0 / 800.0, accuracy: 0.01,
                       "the page was stretched instead of fitted")
        XCTAssertLessThanOrEqual(page.imageFrame.width, canvas.width + 0.5)
        XCTAssertLessThanOrEqual(page.imageFrame.height, canvas.height + 0.5)
    }

    func testThePageContentActuallyLandsInTheImage() throws {
        // The renderer leans on PDFPage.draw to place the content. If the
        // transform were wrong the import would still succeed and still be the
        // right shape — it would just be a blank white rectangle.
        for rotation in [0, 90, 180, 270] {
            let url = try makePDF(pageSizes: [CGSize(width: 612, height: 792)],
                                  rotation: rotation, text: "CONTENT")
            let page = try XCTUnwrap(try PDFImporter.pages(from: url).first)
            let image = try XCTUnwrap(UIImage(data: try XCTUnwrap(page.imageData)))
            XCTAssertTrue(hasDarkPixels(image), "the page rendered blank at \(rotation)°")
        }
    }

    /// True when the image contains something appreciably darker than the
    /// white background — i.e. the page's own content.
    private func hasDarkPixels(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return false }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels.contains { $0 < 128 }
    }

    func testAFileThatIsNotAPDFIsRejected() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-pdf-\(UUID().uuidString).pdf")
        scratch.append(url)
        try Data("plain text, not a PDF".utf8).write(to: url)
        XCTAssertThrowsError(try PDFImporter.pages(from: url)) { error in
            XCTAssertEqual(error as? PDFImportError, .unreadableDocument)
        }
    }
}
