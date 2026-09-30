import PencilKit
import UIKit
import XCTest
@testable import BetterNotes

@MainActor
final class HandwritingOCRTests: XCTestCase {
    func testBlackInkRemainsVisibleToOCRInDarkMode() throws {
        let points = [CGPoint(x: 25, y: 50), CGPoint(x: 175, y: 50)].map { point in
            PKStrokePoint(location: point, timeOffset: 0, size: CGSize(width: 9, height: 9),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let drawing = PKDrawing(strokes: [PKStroke(
            ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: points, creationDate: .now)
        )])
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            image = HandwritingOCR.renderImage(for: drawing,
                rect: CGRect(x: 0, y: 0, width: 200, height: 100), scale: 1)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: cgImage.width, height: cgImage.height,
            bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        var darkPixels = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[offset] < 100 && pixels[offset + 1] < 100 && pixels[offset + 2] < 100 {
                darkPixels += 1
            }
        }
        XCTAssertGreaterThan(darkPixels, 100, "Vision would receive a blank white page")
    }
}
