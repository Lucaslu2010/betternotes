import Foundation
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Notebook

@Model
final class Notebook {
    /// Stable local/source identity used by citations and editable backups.
    var stableID: UUID = UUID()
    var title: String = "Untitled"
    var subtitle: String = ""
    var coverColorHex: String = "4A6FA5"
    /// Secondary color for gradient/pattern covers.
    var coverColor2Hex: String = "C06C84"
    /// Visual style of the cover: "solid", "gradient", "pattern".
    var coverStyle: String = "solid"
    /// Optional emoji or SF Symbol name displayed on the cover.
    var coverEmoji: String?
    var createdAt: Date = Date.now
    var modifiedAt: Date = Date.now
    /// Stable sync identity. Kept separate from user-visible metadata.
    var cloudID: String?
    var folderName: String = ""
    var tagsText: String = ""
    var isFavorite: Bool = false
    var isArchived: Bool = false
    var trashedAt: Date?

    /// Whether the notebook belongs in the main library (the Notes view and
    /// the editor's notebook switcher): archived and trashed notebooks stay out.
    var isInMainLibrary: Bool { trashedAt == nil && !isArchived }
    var defaultLineStyle: String = PageLineStyle.blank.rawValue
    var defaultLineThickness: Double = PageLineAppearance.defaultThickness
    var defaultLineOpacity: Double = PageLineAppearance.defaultOpacity
    var defaultBackgroundHex: String = "FFFFFF"
    var defaultOrientation: String = PageOrientation.portrait.rawValue
    @Relationship(deleteRule: .cascade, originalName: "pages", inverse: \Page.notebook)
    private var storedPages: [Page]?

    var pages: [Page] {
        get { storedPages ?? [] }
        set { storedPages = newValue }
    }

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
        self.defaultLineThickness = PageLineAppearance.defaultThickness
        self.defaultLineOpacity = PageLineAppearance.defaultOpacity
        self.defaultBackgroundHex = "FFFFFF"
        self.defaultOrientation = PageOrientation.portrait.rawValue
        self.storedPages = []
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
        case .solid:    return AppLocalization.text("Solid")
        case .gradient: return AppLocalization.text("Gradient")
        case .pattern:  return AppLocalization.text("Pattern")
        case .diagonal: return AppLocalization.text("Diagonal")
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
    var index: Int = 0
    var title: String = ""
    var isBookmarked: Bool = false
    var inkData: Data?
    var ocrText: String = ""
    var ocrUpdatedAt: Date?
    var createdAt: Date = Date.now
    var modifiedAt: Date = Date.now
    var trashedAt: Date?
    var notebook: Notebook?
    @Relationship(deleteRule: .cascade, originalName: "elements", inverse: \PageElement.page)
    private var storedElements: [PageElement]?

    var elements: [PageElement] {
        get { storedElements ?? [] }
        set { storedElements = newValue }
    }

    // Page style
    var backgroundHex: String = "FFFFFF"
    var lineStyle: String = "blank"
    var lineThickness: Double = PageLineAppearance.defaultThickness
    var lineOpacity: Double = PageLineAppearance.defaultOpacity
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
        self.storedElements = []
        self.backgroundHex = "FFFFFF"
        self.lineStyle = PageLineStyle.blank.rawValue
        self.lineThickness = PageLineAppearance.defaultThickness
        self.lineOpacity = PageLineAppearance.defaultOpacity
        self.orientation = PageOrientation.portrait.rawValue
    }

    /// Elements in their persisted stacking order, bottom to top. `createdAt`
    /// breaks ties so a page written before zIndex existed still comes back in
    /// the order it was drawn.
    var orderedElements: [PageElement] {
        elements.sorted { ($0.zIndex, $0.createdAt) < ($1.zIndex, $1.createdAt) }
    }

    /// Adds an element on top of the stack: SwiftUI draws `elements` in array
    /// order, so a new element must also take a `zIndex` above every existing
    /// one or it would sink to the bottom on the next load.
    func appendElement(_ element: PageElement) {
        element.zIndex = (elements.map(\.zIndex).max() ?? -1) + 1
        element.page = self
        elements.append(element)
    }

    /// Rewrites `elements` into its persisted order. Call when a page is
    /// loaded, before anything reads the array positionally.
    func restoreElementOrder() {
        elements = orderedElements
    }

    /// Records the current array order into `zIndex`. Call before saving, so
    /// the layering the user sees is the layering that persists.
    func stampElementOrder() {
        for (offset, element) in elements.enumerated() where element.zIndex != offset {
            element.zIndex = offset
        }
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

    var effectiveLineThickness: Double { PageLineAppearance.thickness(lineThickness) }
    var effectiveLineOpacity: Double { PageLineAppearance.opacity(lineOpacity) }

    var pageOrientation: PageOrientation {
        PageOrientation(rawValue: orientation) ?? .portrait
    }
}

// MARK: - Page style enums

enum PageLineAppearance {
    static let defaultThickness = 0.5
    static let defaultOpacity = 0.15
    static let thicknessRange = 0.25...3.0
    static let opacityRange = 0.1...1.0

    static func thickness(_ value: Double) -> Double {
        value.isFinite ? min(max(value, thicknessRange.lowerBound), thicknessRange.upperBound) : defaultThickness
    }

    static func opacity(_ value: Double) -> Double {
        value.isFinite ? min(max(value, opacityRange.lowerBound), opacityRange.upperBound) : defaultOpacity
    }
}

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
        case .blank: return AppLocalization.text("Blank")
        case .ruled: return AppLocalization.text("Ruled")
        case .grid:  return AppLocalization.text("Grid")
        case .dots:  return AppLocalization.text("Dots")
        case .cornell: return AppLocalization.text("Cornell Notes")
        case .checklist: return AppLocalization.text("Checklist")
        case .weeklyPlanner: return AppLocalization.text("Weekly Planner")
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
        case .portrait:  return AppLocalization.text("Portrait")
        case .landscape: return AppLocalization.text("Landscape")
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
    var elementType: String = "textBox"
    var posX: Double = 0
    var posY: Double = 0
    var width: Double = 200
    var height: Double = 120
    var rotation: Double = 0
    var createdAt: Date = Date.now

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

    /// Persisted stacking order within the page, low to high. SwiftData does
    /// not guarantee the order of a to-many relationship, so the position of
    /// an element in `page.elements` cannot survive a relaunch on its own —
    /// and Bring Forward / Send Backward work purely by reordering that array.
    /// This is where that layering is actually kept.
    var zIndex: Int = 0

    /// Extra state for an `.assistantNote`: the question it answers, its
    /// validated `[S#]` citations, the point on the page it points back to, and
    /// whether the answer is still streaming in.
    ///
    /// One optional blob rather than five stored properties -- SwiftData has to
    /// migrate every property that exists, and `AssistantMessage.citationsData`
    /// already sets the precedent for encoding citations this way. Decode with
    /// `assistantPayload`.
    var assistantData: Data?

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
        self.assistantData = nil
        self.page = nil
    }

    var type: ElementType {
        ElementType(rawValue: elementType) ?? .textBox
    }

    var assistantPayload: AssistantNotePayload? {
        get { AssistantNotePayload.decode(assistantData) }
        set { assistantData = newValue?.encoded }
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
    /// An answer the assistant wrote onto the page, in reply to ink.
    case assistantNote
}

/// Tape uses existing element color and dimensions, including in old notes.
/// Resolve an absent color to the original neutral appearance at full opacity.
enum TapeStyle {
    static let defaultColorHex = "C6CBD2"
    static let palette = ["C6CBD2", "FFF0A6", "F2B8BC", "B9DDC6", "BBD8F1", "D9C7EE"]

    static func colorHex(for element: PageElement) -> String {
        element.colorHex ?? defaultColorHex
    }

    static func usesDarkForeground(_ hex: String) -> Bool {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xC6CBD2
        let red = Double((value >> 16) & 0xFF)
        let green = Double((value >> 8) & 0xFF)
        let blue = Double(value & 0xFF)
        return (red * 0.2126 + green * 0.7152 + blue * 0.0722) >= 145
    }
}

extension PageElement {
#if canImport(UIKit)
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
        RichTextCodec.encode(attributedString)
    }

    static func decodeRichText(from data: Data) -> NSAttributedString? {
        RichTextCodec.decode(data)
            ?? (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data))
    }
#else
    var defaultTextAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment.nsTextAlignment
        return [
            .font: NSFont(name: fontName, size: fontSize)
                ?? NSFont.systemFont(ofSize: fontSize, weight: isBold ? .bold : .regular),
            .paragraphStyle: paragraph,
            .foregroundColor: NSColor.black,
        ]
    }

    var resolvedRichText: NSAttributedString {
        if let richTextData, let portable = RichTextCodec.decode(richTextData) {
            return portable
        }
        return NSAttributedString(string: text ?? "", attributes: defaultTextAttributes)
    }

    func resolvedRichText(forFallbackText fallbackText: String) -> NSAttributedString {
        if let richTextData, let portable = RichTextCodec.decode(richTextData) {
            return portable
        }
        return NSAttributedString(string: fallbackText, attributes: defaultTextAttributes)
    }
#endif

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
        copy.zIndex = source.zIndex
        copy.assistantData = source.assistantData
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
        case .circle:    return AppLocalization.text("Circle")
        case .rectangle: return AppLocalization.text("Rectangle")
        case .arrow:     return AppLocalization.text("Arrow")
        case .line:      return AppLocalization.text("Line")
        case .star:      return AppLocalization.text("Star")
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
#if canImport(UIKit)
        let nativeColor = UIColor(self)
        guard nativeColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "000000"
        }
#else
        let nativeColor = NSColor(self).usingColorSpace(.deviceRGB) ?? .black
        nativeColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
#endif
        func channel(_ value: CGFloat) -> Int {
            Int((min(max(value, 0), 1) * 255).rounded())
        }
        return String(format: "%02X%02X%02X", channel(red), channel(green), channel(blue))
    }
}

#if canImport(UIKit)
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
#endif
