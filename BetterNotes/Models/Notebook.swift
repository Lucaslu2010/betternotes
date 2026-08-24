import Foundation
import SwiftData
import SwiftUI
import UIKit

// MARK: - Notebook

@Model
final class Notebook {
    /// Stable local/source identity used by citations and editable backups.
    var stableID: UUID = UUID()
    var title: String
    var subtitle: String
    var coverColorHex: String
    /// Secondary color for gradient/pattern covers.
    var coverColor2Hex: String
    /// Visual style of the cover: "solid", "gradient", "pattern".
    var coverStyle: String
    /// Optional emoji or SF Symbol name displayed on the cover.
    var coverEmoji: String?
    var createdAt: Date
    var modifiedAt: Date
    /// Stable sync identity. Kept separate from user-visible metadata.
    var cloudID: String?
    var folderName: String = ""
    var tagsText: String = ""
    var isFavorite: Bool = false
    var isArchived: Bool = false
    var trashedAt: Date?
    var defaultLineStyle: String = PageLineStyle.blank.rawValue
    var defaultBackgroundHex: String = "FFFFFF"
    var defaultOrientation: String = PageOrientation.portrait.rawValue
    @Relationship(deleteRule: .cascade, inverse: \Page.notebook)
    var pages: [Page]

    init(
        title: String,
        subtitle: String = "",
        coverColorHex: String = "4A6FA5",
        coverColor2Hex: String = "C06C84",
        coverStyle: String = NotebookCoverStyle.solid.rawValue,
        coverEmoji: String? = nil
    ) {
        self.stableID = UUID()
        self.title = title
        self.subtitle = subtitle
        self.coverColorHex = coverColorHex
        self.coverColor2Hex = coverColor2Hex
        self.coverStyle = coverStyle
        self.coverEmoji = coverEmoji
        self.createdAt = .now
        self.modifiedAt = .now
        self.cloudID = nil
        self.folderName = ""
        self.tagsText = ""
        self.isFavorite = false
        self.isArchived = false
        self.trashedAt = nil
        self.defaultLineStyle = PageLineStyle.blank.rawValue
        self.defaultBackgroundHex = "FFFFFF"
        self.defaultOrientation = PageOrientation.portrait.rawValue
        self.pages = []
    }

    var coverColor: Color {
        Color(hex: coverColorHex) ?? Color.blue
    }

    var coverColor2: Color {
        Color(hex: coverColor2Hex) ?? Color.pink
    }

    var style: NotebookCoverStyle {
        NotebookCoverStyle(rawValue: coverStyle) ?? .solid
    }

    var tags: [String] {
        tagsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Cover Style

enum NotebookCoverStyle: String, CaseIterable, Codable {
    case solid
    case gradient
    case pattern
    case diagonal

    var label: String {
        switch self {
        case .solid:    return "Solid"
        case .gradient: return "Gradient"
        case .pattern:  return "Pattern"
        case .diagonal: return "Diagonal"
        }
    }

    var icon: String {
        switch self {
        case .solid:    return "square.fill"
        case .gradient: return "circle.lefthalf.filled"
        case .pattern:  return "circle.grid.3x3.fill"
        case .diagonal: return "rectangle.split.2x1"
        }
    }
}

/// Shared color palette for notebook covers.
enum CoverPalette {
    static let colors: [String] = [
        "4A6FA5", "C06C84", "6B9080", "F18F01",
        "355C7D", "6C5B7B", "F67280", "99B898",
        "2C3E50", "E74C3C", "3498DB", "1ABC9C",
        "9B59B6", "34495E", "E67E22", "F39C12",
    ]

    static let emojis: [String] = [
        "📚", "📝", "📓", "📔", "🧠", "💡", "🔬", "🧪",
        "📐", "🎨", "✏️", "🖊️", "🌍", "⚖️", "💻", "🎵",
        "🩺", "🏥", "📊", "📈", "🌱", "🚀", "⭐", "🎯",
    ]
}

// MARK: - Page

@Model
final class Page {
    /// Stable local/source identity used by citations and the derived index.
    var stableID: UUID = UUID()
    var index: Int
    var title: String = ""
    var isBookmarked: Bool = false
    var inkData: Data?
    var ocrText: String = ""
    var ocrUpdatedAt: Date?
    var createdAt: Date
    var modifiedAt: Date = Date.now
    var trashedAt: Date?
    var notebook: Notebook?
    @Relationship(deleteRule: .cascade, inverse: \PageElement.page)
    var elements: [PageElement]

    // Page style
    var backgroundHex: String = "FFFFFF"
    var lineStyle: String = "blank"
    var orientation: String = "portrait"

    init(index: Int = 0) {
        self.stableID = UUID()
        self.index = index
        self.title = ""
        self.isBookmarked = false
        self.inkData = nil
        self.ocrText = ""
        self.ocrUpdatedAt = nil
        self.createdAt = .now
        self.modifiedAt = .now
        self.trashedAt = nil
        self.notebook = nil
        self.elements = []
        self.backgroundHex = "FFFFFF"
        self.lineStyle = PageLineStyle.blank.rawValue
        self.orientation = PageOrientation.portrait.rawValue
    }

    var hasContent: Bool {
        if let ink = inkData, !ink.isEmpty { return true }
        return !elements.isEmpty || !ocrText.isEmpty
    }

    var background: Color {
        Color(hex: backgroundHex) ?? .white
    }

    var lines: PageLineStyle {
        PageLineStyle(rawValue: lineStyle) ?? .blank
    }

    var pageOrientation: PageOrientation {
        PageOrientation(rawValue: orientation) ?? .portrait
    }
}

// MARK: - Page style enums

enum PageLineStyle: String, CaseIterable, Codable {
    case blank
    case ruled       // horizontal lines
    case grid        // square grid
    case dots        // dot grid
    case cornell
    case checklist
    case weeklyPlanner

    var label: String {
        switch self {
        case .blank: return "Blank"
        case .ruled: return "Ruled"
        case .grid:  return "Grid"
        case .dots:  return "Dots"
        case .cornell: return "Cornell Notes"
        case .checklist: return "Checklist"
        case .weeklyPlanner: return "Weekly Planner"
        }
    }

    var icon: String {
        switch self {
        case .blank: return "rectangle"
        case .ruled: return "text.alignleft"
        case .grid:  return "square.grid.3x3"
        case .dots:  return "circle.grid.2x2"
        case .cornell: return "rectangle.split.3x1"
        case .checklist: return "checklist"
        case .weeklyPlanner: return "calendar"
        }
    }
}

enum PageOrientation: String, CaseIterable, Codable {
    case portrait
    case landscape

    var label: String {
        switch self {
        case .portrait:  return "Portrait"
        case .landscape: return "Landscape"
        }
    }

    var icon: String {
        switch self {
        case .portrait:  return "rectangle.portrait"
        case .landscape: return "rectangle"
        }
    }

    /// Page dimensions in points (at screen scale 1).
    var size: CGSize {
        switch self {
        case .portrait:  return CGSize(width: 768, height: 1024)
        case .landscape: return CGSize(width: 1024, height: 768)
        }
    }
}

// MARK: - Page Element (text, image, shape, sticky note, audio recording, tape)

@Model
final class PageElement {
    var elementType: String
    var posX: Double
    var posY: Double
    var width: Double
    var height: Double
    var rotation: Double
    var createdAt: Date

    // Text content (text box + sticky note)
    var text: String?
    /// Optional rich-text payload for per-range formatting.
    var richTextData: Data?

    // Rich text formatting
    var fontName: String = "System"
    var fontSize: Double = 16
    var isBold: Bool = false
    var isItalic: Bool = false
    var isUnderline: Bool = false
    var textAlignment: String = "leading" // leading/center/trailing

    // Shape kind (circle, rectangle, arrow, line, star)
    var shapeKind: String?

    // Color (hex string) for shapes / sticky
    var colorHex: String?

    // Image data
    var imageData: Data?

    // Audio recording
    var audioData: Data?
    var audioDuration: Double?
    var transcript: String?

    // Tape: when true, covers what's beneath; tap to toggle
    var isRevealed: Bool = false

    // Prevent accidental move/resize/edit while still allowing selection.
    var isLocked: Bool = false

    var page: Page?

    init(
        type: ElementType,
        x: Double, y: Double,
        width: Double = 200, height: Double = 120,
        rotation: Double = 0
    ) {
        self.elementType = type.rawValue
        self.posX = x
        self.posY = y
        self.width = width
        self.height = height
        self.rotation = rotation
        self.createdAt = .now
        self.text = nil
        self.richTextData = nil
        self.fontName = "System"
        self.fontSize = 16
        self.isBold = false
        self.isItalic = false
        self.isUnderline = false
        self.textAlignment = "leading"
        self.shapeKind = nil
        self.colorHex = nil
        self.imageData = nil
        self.audioData = nil
        self.audioDuration = nil
        self.transcript = nil
        self.isRevealed = false
        self.isLocked = false
        self.page = nil
    }

    var type: ElementType {
        ElementType(rawValue: elementType) ?? .textBox
    }

    var tint: Color {
        Color(hex: colorHex ?? "4A6FA5") ?? .accentColor
    }

    var alignment: TextAlign {
        TextAlign(rawValue: textAlignment) ?? .leading
    }
}

enum ElementType: String, CaseIterable, Codable {
    case textBox
    case stickyNote
    case shape
    case image
    case audioRecording
    case tape
}

extension PageElement {
    var defaultTextAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment.nsTextAlignment

        var attrs: [NSAttributedString.Key: Any] = [
            .font: resolvedFont(),
            .paragraphStyle: paragraph,
            .foregroundColor: UIColor.black
        ]
        if isUnderline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
    }

    var resolvedRichText: NSAttributedString {
        if let richTextData,
           let decoded = Self.decodeRichText(from: richTextData) {
            return decoded
        }
        return NSAttributedString(string: text ?? "", attributes: defaultTextAttributes)
    }

    func resolvedRichText(forFallbackText fallbackText: String) -> NSAttributedString {
        if let richTextData,
           let decoded = Self.decodeRichText(from: richTextData) {
            return decoded
        }
        return NSAttributedString(string: fallbackText, attributes: defaultTextAttributes)
    }

    private func resolvedFont() -> UIFont {
        let size = CGFloat(fontSize)
        let weight: UIFont.Weight = isBold ? .bold : .regular
        let base = fontName == "System"
            ? UIFont.systemFont(ofSize: size, weight: weight)
            : (UIFont(name: fontName, size: size) ?? UIFont.systemFont(ofSize: size, weight: weight))

        guard isItalic || isBold else {
            return base
        }
        var traits = base.fontDescriptor.symbolicTraits
        if isItalic { traits.insert(.traitItalic) }
        if isBold { traits.insert(.traitBold) }
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }

    static func encodeRichText(_ attributedString: NSAttributedString) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: attributedString, requiringSecureCoding: true)
    }

    static func decodeRichText(from data: Data) -> NSAttributedString? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data)
    }

    static func copy(of source: PageElement) -> PageElement {
        let copy = PageElement(
            type: source.type,
            x: source.posX,
            y: source.posY,
            width: source.width,
            height: source.height,
            rotation: source.rotation
        )
        copy.elementType = source.elementType
        copy.text = source.text
        copy.richTextData = source.richTextData
        copy.fontName = source.fontName
        copy.fontSize = source.fontSize
        copy.isBold = source.isBold
        copy.isItalic = source.isItalic
        copy.isUnderline = source.isUnderline
        copy.textAlignment = source.textAlignment
        copy.shapeKind = source.shapeKind
        copy.colorHex = source.colorHex
        copy.imageData = source.imageData
        copy.audioData = source.audioData
        copy.audioDuration = source.audioDuration
        copy.transcript = source.transcript
        copy.isRevealed = source.isRevealed
        copy.isLocked = source.isLocked
        return copy
    }
}

enum ShapeKind: String, CaseIterable, Codable {
    case circle, rectangle, arrow, line, star

    var icon: String {
        switch self {
        case .circle:    return "circle"
        case .rectangle: return "rectangle"
        case .arrow:     return "arrow.up.right"
        case .line:      return "line.diagonal"
        case .star:      return "star"
        }
    }

    var label: String {
        switch self {
        case .circle:    return "Circle"
        case .rectangle: return "Rectangle"
        case .arrow:     return "Arrow"
        case .line:      return "Line"
        case .star:      return "Star"
        }
    }
}

// MARK: - Color Hex Extension

extension Color {
    init?(hex: String) {
        var hex = hex
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard let value = UInt32(hex, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    var hexString: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "000000"
        }
        func channel(_ value: CGFloat) -> Int {
            Int((min(max(value, 0), 1) * 255).rounded())
        }
        return String(format: "%02X%02X%02X", channel(red), channel(green), channel(blue))
    }
}

extension UIColor {
    /// Creates a FIXED (non-dynamic) UIColor from a hex string. Unlike
    /// `UIColor(SwiftUI.Color)`, this does NOT adapt to light/dark mode.
    func fixedFromHex(_ hex: String) -> UIColor {
        var hex = hex
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard let value = UInt32(hex, radix: 16) else { return .black }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }

    static func fixedFromHex(_ hex: String) -> UIColor {
        UIColor().fixedFromHex(hex)
    }
}
