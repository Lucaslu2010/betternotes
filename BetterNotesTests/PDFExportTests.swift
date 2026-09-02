import XCTest
import PDFKit
import UIKit
@testable import BetterNotes

/// Exporting to PDF is how a notebook leaves the app — handed to a teacher,
/// printed, filed. The existing suite checks that an export happens; these
/// check that what comes out looks like what was on screen.
@MainActor
final class PDFExportTests: XCTestCase {

    private func solidImage(_ color: UIColor, size: CGSize = CGSize(width: 40, height: 40)) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    /// Rasterises the first page of an exported PDF so its pixels can be read.
    private func raster(_ pdf: Data, scale: CGFloat = 1) throws -> (image: UIImage, size: CGSize) {
        let document = try XCTUnwrap(PDFDocument(data: pdf))
        let page = try XCTUnwrap(document.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: bounds.size))
            context.cgContext.translateBy(x: 0, y: bounds.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: context.cgContext)
        }
        return (image, bounds.size)
    }

    private func pixels(_ image: UIImage) throws -> (data: [UInt8], width: Int, height: Int) {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &buffer, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (buffer, width, height)
    }

    /// Bounding box of every pixel matching `match`, in image coordinates.
    private func boundingBox(of image: UIImage,
                             match: (UInt8, UInt8, UInt8) -> Bool) throws -> CGRect? {
        let (buffer, width, height) = try pixels(image)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                guard match(buffer[i], buffer[i + 1], buffer[i + 2]) else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func colorAt(_ point: CGPoint, in image: UIImage) throws -> (UInt8, UInt8, UInt8) {
        let (buffer, width, _) = try pixels(image)
        let i = (Int(point.y) * width + Int(point.x)) * 4
        return (buffer[i], buffer[i + 1], buffer[i + 2])
    }

    private func page(with elements: [PageElement]) -> Page {
        let page = Page(index: 0)
        for element in elements { page.appendElement(element) }
        return page
    }

    private func imageElement(_ color: UIColor, at center: CGPoint,
                              size: CGSize, rotation: Double = 0) -> PageElement {
        let element = PageElement(type: .image, x: center.x, y: center.y,
                                  width: size.width, height: size.height, rotation: rotation)
        element.imageData = solidImage(color)
        return element
    }

    // MARK: -

    func testAnExportedPageIsThePageSize() throws {
        let page = Page(index: 0)
        let (_, size) = try raster(PDFExport.renderPage(page))
        XCTAssertEqual(size.width, PageOrientation.portrait.size.width, accuracy: 1)
        XCTAssertEqual(size.height, PageOrientation.portrait.size.height, accuracy: 1)
    }

    func testAnElementIsExportedWhereItSitsOnThePage() throws {
        let center = CGPoint(x: 300, y: 400)
        let page = page(with: [imageElement(.black, at: center, size: CGSize(width: 100, height: 60))])
        let (image, _) = try raster(PDFExport.renderPage(page))
        let box = try XCTUnwrap(try boundingBox(of: image) { r, g, b in r < 80 && g < 80 && b < 80 },
                                "the element did not appear in the export at all")
        XCTAssertEqual(box.midX, center.x, accuracy: 3)
        XCTAssertEqual(box.midY, center.y, accuracy: 3)
        XCTAssertEqual(box.width, 100, accuracy: 3)
        XCTAssertEqual(box.height, 60, accuracy: 3)
    }

    func testARotatedElementIsExportedRotated() throws {
        // Every on-screen renderer applies element.rotation. An export that
        // ignores it silently straightens the user's layout.
        let page = page(with: [imageElement(.black, at: CGPoint(x: 300, y: 400),
                                            size: CGSize(width: 200, height: 60), rotation: 90)])
        let (image, _) = try raster(PDFExport.renderPage(page))
        let box = try XCTUnwrap(try boundingBox(of: image) { r, g, b in r < 80 && g < 80 && b < 80 })
        XCTAssertEqual(box.width, 60, accuracy: 4, "a 90°-rotated element exported at its unrotated width")
        XCTAssertEqual(box.height, 200, accuracy: 4)
    }

    func testStackingOrderIsHonouredInTheExport() throws {
        // Two elements on the same spot: whichever is on top on screen must be
        // on top in the PDF. Tape covering an answer depends on exactly this.
        let center = CGPoint(x: 300, y: 400)
        let size = CGSize(width: 120, height: 120)
        let bottom = imageElement(.red, at: center, size: size)
        let top = imageElement(.blue, at: center, size: size)
        let page = page(with: [bottom, top])

        var (image, _) = try raster(PDFExport.renderPage(page))
        var (r, g, b) = try colorAt(center, in: image)
        XCTAssertTrue(b > 150 && r < 100, "the top element was not on top: rgb(\(r), \(g), \(b))")

        // Send it to the back, exactly as moveSelectedElement does, then
        // scramble the array itself — which is what a SwiftData to-many
        // relationship is free to do on the way back out of the store. The
        // export must follow the persisted layering, not the array it is
        // handed.
        page.elements.swapAt(0, 1)
        page.stampElementOrder()
        page.elements.reverse()
        (image, _) = try raster(PDFExport.renderPage(page))
        (r, g, b) = try colorAt(center, in: image)
        XCTAssertTrue(r > 150 && b < 100, "layering was ignored by the export: rgb(\(r), \(g), \(b))")
    }

    func testANotebookExportsEveryPageInOrderAndSkipsTheTrash() throws {
        let notebook = Notebook(title: "Export")
        for index in 0..<3 {
            let page = Page(index: index)
            page.notebook = notebook
            notebook.pages.append(page)
        }
        let trashed = Page(index: 3)
        trashed.trashedAt = .now
        trashed.notebook = notebook
        notebook.pages.append(trashed)

        let document = try XCTUnwrap(PDFDocument(data: PDFExport.renderNotebook(notebook)))
        XCTAssertEqual(document.pageCount, 3, "the trashed page was exported")
    }

    func testAMixedOrientationNotebookKeepsEachPageItsOwnShape() throws {
        let notebook = Notebook(title: "Mixed")
        let portrait = Page(index: 0)
        portrait.orientation = PageOrientation.portrait.rawValue
        let landscape = Page(index: 1)
        landscape.orientation = PageOrientation.landscape.rawValue
        for page in [portrait, landscape] {
            page.notebook = notebook
            notebook.pages.append(page)
        }

        let document = try XCTUnwrap(PDFDocument(data: PDFExport.renderNotebook(notebook)))
        let first = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        let second = try XCTUnwrap(document.page(at: 1)).bounds(for: .mediaBox)
        XCTAssertGreaterThan(first.height, first.width, "page 1 should be portrait")
        XCTAssertGreaterThan(second.width, second.height, "page 2 should be landscape")
    }

    func testAnEmptyNotebookStillProducesAReadablePDF() throws {
        let document = try XCTUnwrap(PDFDocument(data: PDFExport.renderNotebook(Notebook(title: "Empty"))))
        XCTAssertEqual(document.pageCount, 1)
    }
}
