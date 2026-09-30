import XCTest
import UIKit
@testable import BetterNotes

/// OCR may scale an image for recognition, but the imported bytes and full
/// frame must survive unchanged so the page remains editable and searchable.
final class SmartImageExtractorTests: XCTestCase {

    /// Renders text onto a white canvas — a stand-in for a photographed note.
    private func imageData(text: String,
                           size: CGSize = CGSize(width: 1200, height: 900),
                           fontSize: CGFloat = 150,
                           inset: CGFloat = 260) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            guard !text.isEmpty else { return }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: UIColor.black
            ]
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            (text as NSString).draw(in: bounds, withAttributes: attributes)
        }
        return image.pngData()!
    }

    func testUnreadableDataIsHandedBackUntouched() async {
        // Not an image at all. The import path must not lose the user's file.
        let junk = Data("this is not an image".utf8)
        let result = await SmartImageExtractor.extract(from: junk)
        XCTAssertEqual(result.extractedText, "")
        XCTAssertFalse(result.hasExtractedText)
        XCTAssertEqual(result.originalImageData, junk, "the original data was dropped")
    }

    func testTextInAPhotoIsRead() async {
        let result = await SmartImageExtractor.extract(from: imageData(text: "HELLO"))
        XCTAssertTrue(result.hasExtractedText, "no text was recognised at all")
        XCTAssertTrue(result.extractedText.uppercased().contains("HELLO"),
                      "recognised \(result.extractedText) instead of HELLO")
    }

    func testThePhotoRetainsItsFullFrame() async {
        let size = CGSize(width: 1200, height: 900)
        let original = imageData(text: "HELLO", size: size)
        let result = await SmartImageExtractor.extract(from: original)
        XCTAssertEqual(result.originalImageData, original)
        XCTAssertEqual(result.originalImageSize.width, size.width, accuracy: 1)
        XCTAssertEqual(result.originalImageSize.height, size.height, accuracy: 1)
    }

    func testRecognitionUpscaleDoesNotChangeTheStoredImage() async {
        // Recognition upscales small images to ~2200px. That upscale is for
        // Vision only; if it reached the output, every imported photo would be
        // stored several times larger than the one the user picked.
        let size = CGSize(width: 640, height: 480)
        let original = imageData(text: "NOTE", size: size, fontSize: 90, inset: 130)
        let result = await SmartImageExtractor.extract(from: original)
        XCTAssertEqual(result.originalImageData, original)
        XCTAssertEqual(result.originalImageSize.width, size.width, accuracy: 1)
        XCTAssertEqual(result.originalImageSize.height, size.height, accuracy: 1)
    }

    func testABlankPhotoKeepsItsFullFrame() async {
        // A blank image is still the user's content and keeps its full frame.
        let size = CGSize(width: 800, height: 600)
        let result = await SmartImageExtractor.extract(from: imageData(text: "", size: size))
        XCTAssertFalse(result.hasExtractedText)
        XCTAssertEqual(result.originalImageSize.width, size.width, accuracy: 1)
        XCTAssertEqual(result.originalImageSize.height, size.height, accuracy: 1)
    }

    func testTheOriginalDataIsAnImageOfTheStatedSize() async {
        let result = await SmartImageExtractor.extract(from: imageData(text: "HELLO"))
        let decoded = UIImage(data: result.originalImageData)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.size.width ?? 0, result.originalImageSize.width, accuracy: 1)
        XCTAssertEqual(decoded?.size.height ?? 0, result.originalImageSize.height, accuracy: 1)
    }

    func testMultipleLinesComeBackInReadingOrder() async {
        let size = CGSize(width: 1400, height: 1000)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 130, weight: .semibold),
                .foregroundColor: UIColor.black
            ]
            ("FIRST" as NSString).draw(at: CGPoint(x: 200, y: 220), withAttributes: attributes)
            ("SECOND" as NSString).draw(at: CGPoint(x: 200, y: 560), withAttributes: attributes)
        }
        let result = await SmartImageExtractor.extract(from: image.pngData()!)
        let text = result.extractedText.uppercased()
        guard let first = text.range(of: "FIRST"), let second = text.range(of: "SECOND") else {
            return XCTFail("expected both lines, recognised: \(result.extractedText)")
        }
        XCTAssertLessThan(first.lowerBound, second.lowerBound,
                          "lines came back bottom-up: \(result.extractedText)")
    }
}
