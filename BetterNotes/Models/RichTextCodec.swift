import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
private typealias NativeFont = UIFont
private typealias NativeColor = UIColor
#else
import AppKit
private typealias NativeFont = NSFont
private typealias NativeColor = NSColor
#endif

/// A platform-neutral replacement for NSKeyedArchiver payloads containing UIFont.
enum RichTextCodec {
    private struct Run: Codable {
        let text: String
        let fontName: String
        let fontSize: Double
        let bold: Bool
        let italic: Bool
        let underline: Bool
        let alignment: String
        let colorHex: String
    }

    private struct Document: Codable {
        let format: String
        let runs: [Run]
    }

    static func isPortable(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(Document.self, from: data))?.format == "betternotes-richtext-1"
    }

    static func encode(_ value: NSAttributedString) -> Data? {
        var runs: [Run] = []
        value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attrs, range, _ in
            let text = (value.string as NSString).substring(with: range)
            let font = attrs[.font] as? NativeFont ?? NativeFont.systemFont(ofSize: 16)
            let color = attrs[.foregroundColor] as? NativeColor ?? .black
            let paragraph = attrs[.paragraphStyle] as? NSParagraphStyle
            let alignment: String
            switch paragraph?.alignment {
            case .center: alignment = "center"
            case .right: alignment = "trailing"
            default: alignment = "leading"
            }
#if canImport(UIKit)
            let traits = font.fontDescriptor.symbolicTraits
            let bold = traits.contains(.traitBold)
            let italic = traits.contains(.traitItalic)
            let native = color
#else
            let traits = font.fontDescriptor.symbolicTraits
            let bold = traits.contains(.bold)
            let italic = traits.contains(.italic)
            let native = color.usingColorSpace(.deviceRGB) ?? .black
#endif
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            native.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            let hex = String(format: "%02X%02X%02X",
                             Int(red * 255), Int(green * 255), Int(blue * 255))
            runs.append(Run(text: text, fontName: font.fontName, fontSize: font.pointSize,
                            bold: bold, italic: italic,
                            underline: (attrs[.underlineStyle] as? Int ?? 0) != 0,
                            alignment: alignment, colorHex: hex))
        }
        return try? JSONEncoder().encode(Document(format: "betternotes-richtext-1", runs: runs))
    }

    static func decode(_ data: Data) -> NSAttributedString? {
        guard let document = try? JSONDecoder().decode(Document.self, from: data),
              document.format == "betternotes-richtext-1" else { return nil }
        let result = NSMutableAttributedString(string: "")
        for run in document.runs {
            let font = NativeFont(name: run.fontName, size: run.fontSize)
                ?? NativeFont.systemFont(ofSize: run.fontSize,
                                           weight: run.bold ? .bold : .regular)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = TextAlign(rawValue: run.alignment)?.nsTextAlignment ?? .left
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraph,
                .foregroundColor: NativeColor.fixedFromHex(run.colorHex),
            ]
            if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }
}

#if canImport(AppKit)
private extension NSColor {
    static func fixedFromHex(_ hex: String) -> NSColor {
        guard let value = UInt32(hex, radix: 16) else { return .black }
        return NSColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
#endif
