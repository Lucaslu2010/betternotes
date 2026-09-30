import UIKit
import XCTest
@testable import BetterNotes

final class RichTextCodecTests: XCTestCase {
    func testFormattedRunsRoundTripAndOldPayloadRemainsReadable() throws {
        let source = NSMutableAttributedString(string: "Bold plain")
        source.addAttributes([
            .font: UIFont.boldSystemFont(ofSize: 22),
            .foregroundColor: UIColor.red,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ], range: NSRange(location: 0, length: 4))
        let portable = try XCTUnwrap(PageElement.encodeRichText(source))
        XCTAssertTrue(RichTextCodec.isPortable(portable))
        let restored = try XCTUnwrap(PageElement.decodeRichText(from: portable))
        XCTAssertEqual(restored.string, source.string)
        XCTAssertEqual((restored.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize, 22)
        XCTAssertEqual(restored.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int,
                       NSUnderlineStyle.single.rawValue)

        let legacy = try NSKeyedArchiver.archivedData(withRootObject: source, requiringSecureCoding: true)
        XCTAssertEqual(PageElement.decodeRichText(from: legacy)?.string, source.string)
    }

    /// Every edit re-encodes the whole text. A colour that loses one step per
    /// pass (truncating `0.4 * 255` to 101) would drift with each save.
    func testEveryColourChannelSurvivesRepeatedEncoding() throws {
        for value in 0...255 {
            let component = CGFloat(value) / 255
            let colour = UIColor(red: component, green: component, blue: component, alpha: 1)
            var data = try XCTUnwrap(RichTextCodec.encode(NSAttributedString(
                string: "x", attributes: [.foregroundColor: colour, .font: UIFont.systemFont(ofSize: 16)]
            )))
            for _ in 0..<3 {
                let decoded = try XCTUnwrap(RichTextCodec.decode(data))
                data = try XCTUnwrap(RichTextCodec.encode(decoded))
            }
            let final = try XCTUnwrap(RichTextCodec.decode(data))
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            let restored = try XCTUnwrap(final.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)
            restored.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            XCTAssertEqual(Int((red * 255).rounded()), value, "channel \(value) drifted")
        }
    }

    func testAttributesThePortableFormatCannotCarryAreDetected() {
        let plain = NSAttributedString(string: "a", attributes: [.font: UIFont.systemFont(ofSize: 12)])
        XCTAssertTrue(RichTextCodec.canRepresent(plain))
        for attribute: [NSAttributedString.Key: Any] in [
            [.strikethroughStyle: NSUnderlineStyle.single.rawValue],
            [.link: URL(string: "https://example.com") as Any],
            [.backgroundColor: UIColor.yellow],
        ] {
            XCTAssertFalse(RichTextCodec.canRepresent(NSAttributedString(string: "a", attributes: attribute)))
        }
    }
}
