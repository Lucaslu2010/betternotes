import SwiftUI
import PencilKit

// MARK: - Drawing tool model

enum DrawingTool: String, Hashable, CaseIterable {
    case pen
    case pencil
    case marker
    case eraser
    case lasso

    static var allCases: [DrawingTool] {
        [.pen, .pencil, .marker, .eraser, .lasso]
    }

    var inkType: PKInkingTool.InkType? {
        switch self {
        case .pen:         return .pen
        case .pencil:      return .pencil
        case .marker:      return .marker
        case .eraser:      return nil
        case .lasso:       return nil
        }
    }

    var supportsSize: Bool {
        switch self {
        case .pen, .pencil, .marker, .eraser: return true
        case .lasso: return false
        }
    }

    var supportsColor: Bool {
        switch self {
        case .pen, .pencil, .marker: return true
        case .eraser, .lasso: return false
        }
    }

    var icon: String {
        switch self {
        case .pen:    return "pencil.tip.crop.circle"
        case .pencil: return "applepencil"
        case .marker: return "highlighter"
        case .eraser: return "eraser"
        case .lasso:  return "lasso"
        }
    }

    var label: String {
        switch self {
        case .pen:    return AppLocalization.text("Pen")
        case .pencil: return AppLocalization.text("Pencil")
        case .marker: return AppLocalization.text("Highlighter")
        case .eraser: return AppLocalization.text("Eraser")
        case .lasso:  return AppLocalization.text("Lasso")
        }
    }
}

enum LassoMode: String, CaseIterable, Hashable {
    case freeform
    case rectangle

    var label: String {
        switch self {
        case .freeform: return AppLocalization.text("Free")
        case .rectangle: return AppLocalization.text("Rect")
        }
    }

    var icon: String {
        switch self {
        case .freeform: return "lasso"
        case .rectangle: return "rectangle.dashed"
        }
    }
}

// MARK: - Eraser style

enum EraserStyle: String, CaseIterable, Hashable {
    case bitmap   // pixel eraser (erases touched parts of strokes)
    case vector   // stroke eraser (removes whole strokes)

    var pkKind: PKEraserTool.EraserType {
        switch self {
        case .bitmap: return .bitmap
        case .vector: return .vector
        }
    }

    var label: String {
        switch self {
        case .bitmap: return AppLocalization.text("Pixel Eraser")
        case .vector: return AppLocalization.text("Stroke Eraser")
        }
    }

    var icon: String {
        switch self {
        case .bitmap: return "eraser.line.dashed"
        case .vector: return "rectangle.dashed"
        }
    }
}

// MARK: - Adaptive editor toolbar

enum ToolbarDock: String { case top, bottom, left, right }

struct ToolbarObstruction: Equatable {
    var dock: ToolbarDock
    var size: CGSize

    static let none = ToolbarObstruction(dock: .top, size: .zero)

    var bottomClearance: CGFloat {
        dock == .bottom ? size.height : 0
    }
}

enum EditorToolbarLayout: Equatable {
    case expanded
    case compact
    case narrow

    static let expandedMinimumWidth: CGFloat = 500
    static let compactMinimumWidth: CGFloat = 280
    static let maximumFrameWidth: CGFloat = 570
    static let frameHorizontalInset: CGFloat = 32
    static let toolbarChromeWidth: CGFloat = 42

    static func select(for availableWidth: CGFloat) -> EditorToolbarLayout {
        if availableWidth >= expandedMinimumWidth {
            return .expanded
        }
        if availableWidth >= compactMinimumWidth {
            return .compact
        }
        return .narrow
    }

    static func frameWidth(for containerWidth: CGFloat) -> CGFloat {
        min(max(containerWidth - frameHorizontalInset, 1), maximumFrameWidth)
    }

    static func contentWidth(for containerWidth: CGFloat) -> CGFloat {
        max(frameWidth(for: containerWidth) - toolbarChromeWidth, 1)
    }

    static func select(forContainerWidth containerWidth: CGFloat) -> EditorToolbarLayout {
        select(for: contentWidth(for: containerWidth))
    }
}

private struct InkSwatch: Identifiable {
    let name: String
    let hex: String
    var id: String { hex }
}

struct EditorToolbar: View {
    @Binding var tool: DrawingTool
    @Binding var color: Color
    @Binding var lineWidth: CGFloat
    @Binding var eraserWidth: CGFloat
    @Binding var eraserStyle: EraserStyle
    @Binding var lassoMode: LassoMode
    @ObservedObject var toolSettings: ToolSettings
    let availableWidth: CGFloat
    var preferredLayout: EditorToolbarLayout? = nil
    /// Where the toolbar currently sits, so its popovers open away from the
    /// screen edge it's docked against instead of always trying to appear
    /// below it — which clips or pushes them off-screen entirely once the
    /// toolbar is docked at the bottom.
    var dock: ToolbarDock = .top
    let isReadOnly: Bool
    let canUndo: Bool
    let canRedo: Bool
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onInsert: (InsertKind) -> Void
    var onInsertShape: () -> Void

    @State private var showingColorPopover = false
    @State private var showingSizePopover = false
    @State private var showingLassoModes = false

    private var popoverArrowEdge: Edge {
        switch dock {
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .leading
        case .right: return .trailing
        }
    }

    private let swatches = [
        InkSwatch(name: "Black", hex: "000000"), InkSwatch(name: "Graphite", hex: "444444"),
        InkSwatch(name: "Gray", hex: "777777"), InkSwatch(name: "Red", hex: "E53935"),
        InkSwatch(name: "Orange", hex: "F57C00"), InkSwatch(name: "Yellow", hex: "FBC02D"),
        InkSwatch(name: "Green", hex: "2E7D32"), InkSwatch(name: "Teal", hex: "00897B"),
        InkSwatch(name: "Dark Blue", hex: "1D4E89"), InkSwatch(name: "Blue", hex: "1976D2"),
        InkSwatch(name: "Purple", hex: "7B1FA2"), InkSwatch(name: "Pink", hex: "D81B60")
    ]

    var body: some View {
        let layout = preferredLayout ?? EditorToolbarLayout.select(for: availableWidth)
        Group {
            if dock == .left || dock == .right {
                verticalLayout
            } else if layout == .expanded {
                expandedLayout
            } else if layout == .compact {
                compactLayout
            } else {
                narrowLayout
            }
        }
        .padding(.horizontal, dock == .left || dock == .right || layout == .narrow ? 0 : 6)
        .padding(.vertical, 4)
    }

    private var verticalLayout: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ForEach(DrawingTool.allCases, id: \.self) { drawingTool in
                    drawingToolButton(drawingTool)
                }
            }
            Divider().frame(width: 30)
            VStack(spacing: 0) { activeToolControls }
            Divider().frame(width: 30)
            VStack(spacing: 0) { commandButtons }
        }
    }

    private var expandedLayout: some View {
        HStack(spacing: 4) {
            drawingTools
            Divider().frame(height: 30)
            activeToolControls
            commandControls
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 2) {
            drawingTools
            HStack(spacing: 4) {
                activeToolControls
                commandControls
            }
        }
    }

    private var narrowLayout: some View {
        VStack(spacing: 2) {
            drawingTools
            HStack(spacing: 0) {
                activeToolControls
            }
            .frame(minHeight: 44)
            commandControls
        }
    }

    private var drawingTools: some View {
        HStack(spacing: 0) {
            ForEach(DrawingTool.allCases, id: \.self) { drawingTool in
                drawingToolButton(drawingTool)
            }
        }
    }

    private func drawingToolButton(_ drawingTool: DrawingTool) -> some View {
        Button {
            if drawingTool == .lasso {
                // The first tap activates the saved mode; another tap on the
                // active lasso opens the mode choices.
                if tool == .lasso {
                    showingLassoModes = true
                } else {
                    toolSettings.restoreLastLassoMode()
                    lassoMode = toolSettings.lassoMode
                    tool = .lasso
                }
            } else {
                tool = drawingTool
            }
        } label: {
            Image(systemName: drawingTool == .lasso ? lassoMode.icon : drawingTool.icon)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .foregroundStyle(tool == drawingTool ? .white : .primary)
                .background(tool == drawingTool ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(drawingTool.label)
        .accessibilityValue(drawingTool == .lasso ? lassoMode.label : "")
        .accessibilityIdentifier("drawing-tool-\(drawingTool.rawValue)")
        .accessibilityAddTraits(tool == drawingTool ? .isSelected : [])
        .disabled(isReadOnly)
        .popover(isPresented: drawingTool == .lasso ? $showingLassoModes : .constant(false), arrowEdge: popoverArrowEdge) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(LassoMode.allCases, id: \.self) { mode in
                    Button {
                        lassoMode = mode
                        showingLassoModes = false
                    } label: {
                        HStack {
                            Label(mode.label, systemImage: mode.icon)
                            Spacer()
                            if lassoMode == mode { Image(systemName: "checkmark") }
                        }
                        .frame(minWidth: 130, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .presentationCompactAdaptation(.popover)
        }
    }

    @ViewBuilder private var activeToolControls: some View {
        if tool == .lasso {
            Text(lassoMode.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 32)
                .accessibilityLabel("Selection shape: \(lassoMode.label). Tap Lasso again to change.")
        } else {
            if tool.supportsColor { colorButton }
            if tool.supportsSize { sizeButton }
        }
    }

    private var commandControls: some View {
        HStack(spacing: 0) {
            commandButtons
        }
    }

    @ViewBuilder private var commandButtons: some View {
        Menu {
                Button("Shape", systemImage: "square.grid.2x2", action: onInsertShape)
                ForEach(InsertKind.allCases, id: \.label) { kind in
                    Button(kind.label, systemImage: kind.icon) { onInsert(kind) }
                }
        } label: { toolbarImage("plus") }
        .accessibilityLabel("Insert")
        .disabled(isReadOnly)

        commandButton("arrow.uturn.backward", label: "Undo", enabled: canUndo, action: onUndo)
        commandButton("arrow.uturn.forward", label: "Redo", enabled: canRedo, action: onRedo)
    }

    private var colorButton: some View {
        Button { showingColorPopover.toggle() } label: {
            Circle().fill(color).frame(width: 24, height: 24)
                .overlay(Circle().stroke(.primary.opacity(0.35), lineWidth: 1))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ink Color")
        .disabled(isReadOnly)
        .popover(isPresented: $showingColorPopover, attachmentAnchor: .rect(.bounds), arrowEdge: popoverArrowEdge) {
            colorPanel
                .frame(idealWidth: 330, idealHeight: 350)
                .presentationCompactAdaptation(.sheet)
        }
    }

    private var colorPanel: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !toolSettings.recentColorHexes.isEmpty {
                        Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        swatchGrid(toolSettings.recentColorHexes.map { InkSwatch(name: "Recent \($0)", hex: $0) })
                    }
                    Text("Colors").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    swatchGrid(swatches)
                    Divider()
                    ColorPicker("Custom Color", selection: $color, supportsOpacity: false)
                        .onChange(of: color) { _, newColor in toolSettings.rememberColor(newColor.hexString) }
                }
                .padding(16)
            }
            .navigationTitle("Ink Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingColorPopover = false }
                        .accessibilityIdentifier("ink-color-done")
                }
            }
        }
    }

    private func swatchGrid(_ colors: [InkSwatch]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
            ForEach(colors) { swatch in
                Button {
                    color = Color(hex: swatch.hex) ?? .black
                    toolSettings.rememberColor(swatch.hex)
                } label: {
                    Circle().fill(Color(hex: swatch.hex) ?? .black)
                        .frame(width: 38, height: 38)
                        .overlay(Circle().stroke(color.hexString == swatch.hex ? Color.primary : .clear, lineWidth: 3))
                        .overlay(
                            Image(systemName: "checkmark")
                                .font(.caption.bold())
                                .foregroundStyle(Color.white)
                                .shadow(color: .black.opacity(0.6), radius: 0, x: 0.5, y: 0.5)
                                .opacity(color.hexString == swatch.hex ? 1 : 0)
                        )
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(swatch.name)
                .accessibilityAddTraits(color.hexString == swatch.hex ? .isSelected : [])
            }
        }
    }

    private var sizeButton: some View {
        Button { showingSizePopover.toggle() } label: {
            Image(systemName: tool == .eraser ? "circle.dashed" : "line.diagonal")
                .font(.system(size: 17, weight: .medium)).frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool == .eraser ? "Eraser Size" : "Stroke Thickness")
        .disabled(isReadOnly)
        .popover(isPresented: $showingSizePopover, attachmentAnchor: .rect(.bounds), arrowEdge: popoverArrowEdge) {
            sizePanel.frame(idealWidth: 330, idealHeight: 230).presentationCompactAdaptation(.sheet)
        }
    }

    private var sizePanel: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Canvas { context, size in
                    var path = Path(); path.move(to: CGPoint(x: 16, y: size.height / 2)); path.addLine(to: CGPoint(x: size.width - 16, y: size.height / 2))
                    context.stroke(path, with: .color(tool == .eraser ? .secondary : color), style: StrokeStyle(lineWidth: previewWidth, lineCap: .round))
                }
                .frame(height: 54)
                if tool == .eraser {
                    Picker("Eraser Style", selection: $eraserStyle) {
                        ForEach(EraserStyle.allCases, id: \.self) { Label($0.label, systemImage: $0.icon).tag($0) }
                    }.pickerStyle(.segmented)
                    Slider(value: $eraserWidth, in: 8...80, step: 1)
                    Text("\(Int(eraserWidth)) pt").monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Slider(value: $lineWidth, in: widthRange, step: 0.5)
                    Text(String(format: "%.1f pt", lineWidth)).monospacedDigit().foregroundStyle(.secondary)
                    if tool == .marker {
                        LabeledContent("Opacity", value: "\(Int(toolSettings.highlighterOpacity * 100))%")
                        Slider(value: Binding(
                            get: { toolSettings.highlighterOpacity },
                            set: { toolSettings.setHighlighterOpacity($0) }
                        ), in: 0.15...1, step: 0.05)
                        .accessibilityLabel("Highlighter Opacity")
                    }
                }
            }
            .padding(18)
            .navigationTitle(tool == .eraser ? "Eraser" : "Stroke Thickness")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingSizePopover = false }
                        .accessibilityIdentifier("stroke-size-done")
                }
            }
        }
    }

    private var widthRange: ClosedRange<CGFloat> {
        switch tool { case .pen: return 0.5...12; case .pencil: return 1...10; case .marker: return 4...30; default: return 1...20 }
    }

    private var previewWidth: CGFloat { tool == .eraser ? min(eraserWidth, 24) : min(lineWidth, 24) }

    private func toolbarImage(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 17, weight: .medium)).frame(width: 44, height: 44)
    }

    private func commandButton(_ name: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { toolbarImage(name) }
            .buttonStyle(.plain).accessibilityLabel(label).disabled(isReadOnly || !enabled)
    }
}

// MARK: - Insert kinds

enum InsertKind: CaseIterable, Equatable {
    case textBox, stickyNote, image, audioRecording, tape

    var icon: String {
        switch self {
        case .textBox:        return "character.textbox"
        case .stickyNote:     return "note.text"
        case .image:          return "photo"
        case .audioRecording: return "waveform"
        case .tape:           return "bandage.fill"
        }
    }

    var label: String {
        switch self {
        case .textBox:        return AppLocalization.text("Text Box")
        case .stickyNote:     return AppLocalization.text("Sticky Note")
        case .image:          return AppLocalization.text("Image")
        case .audioRecording: return AppLocalization.text("Recording")
        case .tape:           return AppLocalization.text("Tape")
        }
    }
}

struct ToolbarSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}
