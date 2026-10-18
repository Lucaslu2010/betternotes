import SwiftUI
import PencilKit

enum AppPreferenceKey {
    static let allowsFingerDrawing = "drawing.allowsFingerDrawing"
    static let librarySort = "library.sort"
    static let beautifyHandwriting = "beautifyHandwriting"
    static let scribbleToErase = "drawing.scribbleToErase"
    static let recentColors = "drawing.recentColors"
    static let toolbarDock = "drawing.toolbarDock"
    static let toolbarHintSeen = "hints.toolbar"
    static let panHintSeen = "hints.twoFingerPan"
    static let fingerHintSeen = "hints.fingerDrawing"
    static let lassoHintSeen = "hints.lassoTransform"
    static let automaticWritingSuggestions = "ai.automaticWritingSuggestions"
    static let assistantEnabled = "ai.assistantEnabled"
    static let searchAnswersEnabled = "ai.searchAnswersEnabled"
    static let scrollMode = "display.scrollMode"
    static let pencilDoubleTapEnabled = "pencil.doubleTapEnabled"
    static let pencilDoubleTapTool = "pencil.doubleTapTool"
}

/// Display mode for pages within a notebook.
enum ScrollMode: String, CaseIterable {
    case singlePage
    case verticalScroll

    var label: String {
        switch self {
        case .singlePage:     return "Single Page"
        case .verticalScroll: return "Vertical Scroll"
        }
    }

    var icon: String {
        switch self {
        case .singlePage:     return "doc"
        case .verticalScroll: return "scroll"
        }
    }
}

/// Remembers per-tool settings (color, size) so switching between tools
/// preserves each tool's last-used configuration.
@MainActor
final class ToolSettings: ObservableObject {
    // Per-tool ink color
    @Published var penColor: Color = .black
    @Published var pencilColor: Color = .black
    @Published var markerColor: Color = .yellow

    // Per-tool line width
    @Published var penWidth: CGFloat = 3
    @Published var pencilWidth: CGFloat = 3
    @Published var markerWidth: CGFloat = 8
    @Published var highlighterOpacity: Double = 0.45

    // Eraser
    @Published var eraserWidth: CGFloat = 25
    @Published var eraserStyle: EraserStyle = .bitmap

    // Lasso
    @Published var lassoMode: LassoMode = .freeform

    // Handwriting
    @Published var beautifyHandwriting: Bool = true

    @Published private(set) var recentColorHexes: [String] = []

    // Persistence via UserDefaults
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Color per tool

    func color(for tool: DrawingTool) -> Color {
        switch tool {
        case .pen:    return penColor
        case .pencil: return pencilColor
        case .marker: return markerColor
        default:      return .black
        }
    }

    /// Returns a FIXED (non-dynamic) UIColor for the given tool, resolved from
    /// the stored hex string. This is necessary because the page background is
    /// always white (FFFFFF), so ink colors must NOT adapt to dark mode.
    /// Using `UIColor(Color.black)` creates a dynamic color that flips to white
    /// in dark mode, making black ink invisible on white paper.
    func fixedUIColor(for tool: DrawingTool) -> UIColor {
        let hex: String
        switch tool {
        case .pen:    hex = penColor.hexString
        case .pencil: hex = pencilColor.hexString
        case .marker: hex = markerColor.hexString
        default:      hex = "000000"
        }
        let color = UIColor.fixedFromHex(hex)
        return tool == .marker ? color.withAlphaComponent(highlighterOpacity) : color
    }

    func generatedShapeStyle(for tool: DrawingTool) -> GeneratedShapeStyle {
        let sourceTool = tool.inkType == nil ? DrawingTool.pen : tool
        return GeneratedShapeStyle(
            inkType: sourceTool.inkType ?? .pen,
            color: UIColor.fixedFromHex(color(for: sourceTool).hexString),
            opacity: sourceTool == .marker ? CGFloat(highlighterOpacity) : 1,
            width: width(for: sourceTool)
        )
    }

    func setColor(_ color: Color, for tool: DrawingTool) {
        switch tool {
        case .pen:    penColor = color
        case .pencil: pencilColor = color
        case .marker: markerColor = color
        default: break
        }
        rememberColor(color.hexString)
        save()
    }

    // MARK: - Width per tool

    func width(for tool: DrawingTool) -> CGFloat {
        switch tool {
        case .pen:    return penWidth
        case .pencil: return pencilWidth
        case .marker: return markerWidth
        default:      return 3
        }
    }

    func setWidth(_ width: CGFloat, for tool: DrawingTool) {
        switch tool {
        case .pen:    penWidth = width
        case .pencil: pencilWidth = width
        case .marker: markerWidth = width
        default: break
        }
        save()
    }

    func setEraserWidth(_ width: CGFloat) {
        eraserWidth = width
        save()
    }

    func setEraserStyle(_ style: EraserStyle) {
        eraserStyle = style
        save()
    }

    func setLassoMode(_ mode: LassoMode) {
        lassoMode = mode
        save()
    }

    func restoreLastLassoMode() {
        lassoMode = LassoMode(rawValue: defaults.string(forKey: "lassoMode") ?? "") ?? .freeform
    }

    // MARK: - Persistence

    private func load() {
        if let hex = defaults.string(forKey: "penColor") { penColor = Color(hex: hex) ?? .black }
        if let hex = defaults.string(forKey: "pencilColor") { pencilColor = Color(hex: hex) ?? .black }
        if let hex = defaults.string(forKey: "markerColor") { markerColor = Color(hex: hex) ?? .yellow }
        penWidth = defaults.object(forKey: "penWidth") as? CGFloat ?? 3
        pencilWidth = defaults.object(forKey: "pencilWidth") as? CGFloat ?? 3
        markerWidth = defaults.object(forKey: "markerWidth") as? CGFloat ?? 8
        eraserWidth = defaults.object(forKey: "eraserWidth") as? CGFloat ?? 25
        highlighterOpacity = defaults.object(forKey: "highlighterOpacity") as? Double ?? 0.45
        eraserStyle = EraserStyle(rawValue: defaults.string(forKey: "eraserStyle") ?? "") ?? .bitmap
        lassoMode = LassoMode(rawValue: defaults.string(forKey: "lassoMode") ?? "") ?? .freeform
        if defaults.object(forKey: AppPreferenceKey.beautifyHandwriting) != nil {
            beautifyHandwriting = defaults.bool(forKey: AppPreferenceKey.beautifyHandwriting)
        }
        recentColorHexes = defaults.stringArray(forKey: AppPreferenceKey.recentColors) ?? []
    }

    func setBeautifyHandwriting(_ isEnabled: Bool) {
        beautifyHandwriting = isEnabled
        save()
    }

    func setHighlighterOpacity(_ opacity: Double) {
        highlighterOpacity = min(max(opacity, 0.15), 1)
        save()
    }

    func rememberColor(_ hex: String) {
        let normalized = hex.uppercased()
        recentColorHexes.removeAll { $0 == normalized }
        recentColorHexes.insert(normalized, at: 0)
        recentColorHexes = Array(recentColorHexes.prefix(6))
        save()
    }

    private func save() {
        defaults.set(penColor.hexString, forKey: "penColor")
        defaults.set(pencilColor.hexString, forKey: "pencilColor")
        defaults.set(markerColor.hexString, forKey: "markerColor")
        defaults.set(penWidth, forKey: "penWidth")
        defaults.set(pencilWidth, forKey: "pencilWidth")
        defaults.set(markerWidth, forKey: "markerWidth")
        defaults.set(highlighterOpacity, forKey: "highlighterOpacity")
        defaults.set(eraserWidth, forKey: "eraserWidth")
        defaults.set(eraserStyle.rawValue, forKey: "eraserStyle")
        defaults.set(lassoMode.rawValue, forKey: "lassoMode")
        defaults.set(beautifyHandwriting, forKey: AppPreferenceKey.beautifyHandwriting)
        defaults.set(recentColorHexes, forKey: AppPreferenceKey.recentColors)
    }
}
