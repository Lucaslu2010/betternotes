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
}
