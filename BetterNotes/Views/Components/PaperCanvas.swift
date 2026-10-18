import SwiftUI
import PencilKit
import QuartzCore

/// Lets PencilKit draw with Apple Pencil or, optionally, a finger while
/// preserving direct interaction with SwiftUI page elements underneath.
final class PencilInputCanvasView: PKCanvasView {
    private let memoryActivity = MemoryDiagnostics.begin("canvas")
    var elementInteractionRects: [CGRect] = []
    var fingerDrawingAllowed = false

    func pagePoint(from point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x + contentOffset.x) / zoomScale,
                y: (point.y + contentOffset.y) / zoomScale)
    }

    /// Lets a UI test read how many strokes the canvas holds; PencilKit's ink
    /// is otherwise invisible to the accessibility tree.
    override var accessibilityValue: String? {
        get {
            ProcessInfo.processInfo.arguments.contains("-ui-testing")
                ? String(drawing.strokes.count)
                : super.accessibilityValue
        }
        set { super.accessibilityValue = newValue }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard event?.type == .touches else {
            return super.hitTest(point, with: event)
        }

        // Apple Pencil always belongs to PencilKit, including over images.
        // Only a *known finger* passes through to an element. During some
        // hit-test phases the event has no touches yet; treating that as a
        // finger made Pencil strokes drag the object instead of drawing.
        let touches = event?.allTouches ?? []
        // XCTest's synthetic touch events can arrive at hitTest without a
        // UITouch. Treat those as fingers only in UI tests so element drag
        // coverage still exercises the pass-through path.
        let forceCanvasFinger = ProcessInfo.processInfo.arguments.contains("-ui-testing-force-canvas-finger")
            || PaperCanvas.fingerStandsInForPencil
        let simulatedFinger = touches.isEmpty
            && ProcessInfo.processInfo.arguments.contains("-ui-testing")
        let isFingerTouch = !forceCanvasFinger
            && (simulatedFinger || (!touches.isEmpty && touches.allSatisfy { $0.type == .direct }))
        if isFingerTouch {
            // `point` is in canvas-local viewport coordinates; element rects
            // are page coordinates, so convert before comparing.
            let localPoint = pagePoint(from: point)
            if elementInteractionRects.contains(where: { $0.contains(localPoint) }) {
                return nil
            }
        }
        return super.hitTest(point, with: event)
    }
}

enum FingerElementDragEvent {
    case began(CGPoint)
    case changed(CGPoint)
    case ended(CGPoint)
    case cancelled
}

private final class FingerElementTouchRecognizer: UIGestureRecognizer {
    var canBegin: (CGPoint) -> Bool = { _ in false }
    var onEvent: (FingerElementDragEvent) -> Void = { _ in }
    private weak var activeTouch: UITouch?

    /// Touch location in page coordinates; the canvas is magnified by the
    /// viewport, so its own coordinates are page coordinates times the zoom.
    private func pageLocation(of touch: UITouch, in view: UIView) -> CGPoint {
        let point = touch.location(in: view)
        guard let canvas = view as? PKCanvasView else { return point }
        return CGPoint(x: (point.x + canvas.contentOffset.x) / canvas.zoomScale,
                       y: (point.y + canvas.contentOffset.y) / canvas.zoomScale)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let view, let touch = touches.first(where: { $0.type == .direct }) else {
            state = .failed
            return
        }
        let point = pageLocation(of: touch, in: view)
        guard canBegin(point) else {
            state = .failed
            return
        }
        activeTouch = touch
        state = .began
        onEvent(.began(point))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let view, let activeTouch, touches.contains(activeTouch) else { return }
        onEvent(.changed(pageLocation(of: activeTouch, in: view)))
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let view, let activeTouch, touches.contains(activeTouch) else { return }
        onEvent(.ended(pageLocation(of: activeTouch, in: view)))
        state = .ended
        self.activeTouch = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard activeTouch != nil else { return }
        onEvent(.cancelled)
        state = .cancelled
        activeTouch = nil
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        preventedGestureRecognizer is UIPanGestureRecognizer
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// Gives PencilKit the real display zoom, while keeping the SwiftUI page and
/// all ink/selection coordinates at their original size. Magnifying a canvas
/// whose native zoom stays at 1 only stretches its existing raster tiles.
final class InkCanvasViewport: UIView {
    private static let renderQueue = DispatchQueue(label: "BetterNotes.ink-viewport", qos: .userInitiated)
    let canvas: PKCanvasView
    private let displayImage = UIImageView()
    private let selectionContainer = UIView()
    private let selectionImage = UIImageView()
    private let hiddenInkMask = CAShapeLayer()
    private var visibleRect: CGRect = .zero
    private var hasViewportMeasurement = false
    private var rasterIsCurrent = false
    private var renderGeneration = 0
    private var pendingRender: DispatchWorkItem?
    private var previewsSelection = false
    var inkOpacity: CGFloat = 1 { didSet { updatePresentation() } }
    private var pageSize: CGSize = .zero
    private var requestedZoom: CGFloat = 1
    private var appliedZoom: CGFloat = 0
    var isUsingTool = false {
        didSet {
            if isUsingTool {
                pendingRender?.cancel()
                renderGeneration &+= 1
                rasterIsCurrent = false
            } else {
                layoutCanvas()
                scheduleRaster()
            }
            updatePresentation()
        }
    }

    init(canvas: PKCanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        backgroundColor = .clear
        addSubview(canvas)
        displayImage.isUserInteractionEnabled = false
        addSubview(displayImage)
        selectionContainer.isUserInteractionEnabled = false
        selectionContainer.layer.anchorPoint = .zero
        selectionContainer.layer.position = .zero
        selectionContainer.addSubview(selectionImage)
        addSubview(selectionContainer)
        hiddenInkMask.path = CGMutablePath()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { pendingRender?.cancel() }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, isUserInteractionEnabled, alpha > 0.01,
              self.point(inside: point, with: event) else { return nil }
        // Display images never intercept input. Preserve the canvas's nil
        // result over page elements and when the SwiftUI lasso owns input.
        return canvas.hitTest(canvas.convert(point, from: self), with: event)
    }

    func update(pageSize: CGSize, zoom: CGFloat) {
        guard pageSize.width > 0, pageSize.height > 0 else { return }
        if self.pageSize != pageSize {
            self.pageSize = pageSize
            appliedZoom = 0
        }
        updateZoom(zoom)
    }

    func updateZoom(_ zoom: CGFloat) {
        guard zoom.isFinite, zoom > 0 else { return }
        let next = min(max(zoom, 0.1), 8)
        let changed = abs(requestedZoom - next) > 0.001
        requestedZoom = next
        layoutCanvas()
        if changed { scheduleRaster() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutCanvas()
        if !hasViewportMeasurement, let window, !bounds.isEmpty {
            updateVisibleRect(convert(window.bounds, from: window))
        }
    }

    private func layoutCanvas() {
        guard !isUsingTool, pageSize.width > 0, pageSize.height > 0,
              abs(appliedZoom - requestedZoom) > 0.001 else { return }
        let zoom = requestedZoom
        appliedZoom = zoom
        let viewportSize = CGSize(width: pageSize.width * zoom, height: pageSize.height * zoom)
        canvas.transform = .identity
        canvas.frame = CGRect(origin: .zero, size: viewportSize)
        canvas.minimumZoomScale = 0.1
        canvas.maximumZoomScale = 8
        canvas.setZoomScale(zoom, animated: false)
        canvas.contentSize = viewportSize
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.contentInset = .zero
        canvas.contentOffset = .zero
        // The outer scroll view already supplies this magnification. Cancel
        // it for the viewport, so only PencilKit's native ink zoom remains.
        canvas.transform = CGAffineTransform(scaleX: 1 / zoom, y: 1 / zoom)
        canvas.center = CGPoint(x: pageSize.width / 2, y: pageSize.height / 2)
    }

    func updateVisibleRect(_ rect: CGRect) {
        hasViewportMeasurement = true
        let clipped = rect.intersection(CGRect(origin: .zero, size: pageSize))
        guard clipped != visibleRect else { return }
        visibleRect = clipped
        if clipped.isNull || clipped.isEmpty {
            pendingRender?.cancel()
            renderGeneration &+= 1
            displayImage.image = nil
            rasterIsCurrent = false
            updatePresentation()
        } else { scheduleRaster() }
    }

    func drawingDidChange() {
        rasterIsCurrent = false
        displayImage.isHidden = true
        renderGeneration &+= 1
        pendingRender?.cancel()
        if !isUsingTool { scheduleRaster() }
        updatePresentation()
    }

    private func scheduleRaster() {
        guard !isUsingTool, !previewsSelection, !visibleRect.isEmpty, !visibleRect.isNull else { return }
        pendingRender?.cancel()
        renderGeneration &+= 1
        let generation = renderGeneration
        rasterIsCurrent = false
        updatePresentation()
        let drawing = canvas.drawing
        let rect = visibleRect.insetBy(dx: -8 / requestedZoom, dy: -8 / requestedZoom)
            .intersection(CGRect(origin: .zero, size: pageSize))
        let scale = InkRasterBudget.scale(for: rect.size, requested: requestedZoom * (window?.screen.scale ?? 2))
        let work = DispatchWorkItem { [weak self] in
            autoreleasepool {
                let image = Self.rasterize(drawing, rect: rect, scale: scale)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.renderGeneration == generation, !self.isUsingTool, !self.previewsSelection else { return }
                    self.displayImage.image = image
                    self.displayImage.frame = rect
                    self.rasterIsCurrent = true
                    self.updatePresentation()
                    MemoryDiagnostics.record("ink-raster scale=\(scale) pixels=\(image.cgImage?.width ?? 0)x\(image.cgImage?.height ?? 0)")
                }
            }
        }
        pendingRender = work
        Self.renderQueue.asyncAfter(deadline: .now() + 0.035, execute: work)
    }

    private func updatePresentation() {
        canvas.alpha = inkOpacity
        displayImage.alpha = inkOpacity
        displayImage.isHidden = isUsingTool || (!rasterIsCurrent && !previewsSelection)
        // A transparent layer mask hides old native tiles without disabling
        // UIKit hit testing, unlike setting the canvas alpha close to zero.
        canvas.layer.mask = (rasterIsCurrent || previewsSelection) && !isUsingTool ? hiddenInkMask : nil
        selectionContainer.isHidden = !previewsSelection
    }

    private static func rasterize(_ drawing: PKDrawing, rect: CGRect, scale: CGFloat) -> UIImage {
        guard !drawing.strokes.isEmpty else { return UIImage() }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        format.preferredRange = .standard
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
                drawing.image(from: rect, scale: scale).draw(in: CGRect(origin: .zero, size: rect.size))
            }
        }
        return image
    }

    func beginSelectionPreview(indices: Set<Int>) {
        let strokes = canvas.drawing.strokes
        let selected = PKDrawing(strokes: strokes.enumerated().filter { indices.contains($0.offset) }.map(\.element))
        guard !selected.strokes.isEmpty else { return }
        pendingRender?.cancel()
        renderGeneration &+= 1
        previewsSelection = true
        let base = PKDrawing(strokes: strokes.enumerated().filter { !indices.contains($0.offset) }.map(\.element))
        let rect = visibleRect.isEmpty || visibleRect.isNull ? bounds : visibleRect
        let displayScale = requestedZoom * (window?.screen.scale ?? 2)
        displayImage.image = Self.rasterize(base, rect: rect, scale: InkRasterBudget.scale(for: rect.size, requested: displayScale))
        displayImage.frame = rect
        let selectedRect = selected.bounds.insetBy(dx: -2, dy: -2)
        selectionImage.image = Self.rasterize(selected, rect: selectedRect, scale: InkRasterBudget.scale(for: selectedRect.size, requested: displayScale))
        selectionImage.frame = selectedRect
        selectionContainer.bounds = CGRect(origin: .zero, size: pageSize)
        selectionContainer.layer.position = .zero
        selectionContainer.transform = .identity
        updatePresentation()
    }

    func updateSelectionPreview(transform: CGAffineTransform) {
        guard previewsSelection else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionContainer.layer.setAffineTransform(transform)
        CATransaction.commit()
    }

    func endSelectionPreview() {
        previewsSelection = false
        selectionImage.image = nil
        selectionContainer.transform = .identity
        rasterIsCurrent = false
        drawingDidChange()
    }
}

enum InkRasterBudget {
    static func scale(for size: CGSize, requested: CGFloat) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        return min(max(requested, 0.1), 16, 4096 / max(size.width, size.height),
                   sqrt(6_000_000 / (size.width * size.height)))
    }
}

/// Observes Apple Pencil locations without taking ownership of PencilKit's
/// drawing gesture. PencilKit does not consistently expose its in-progress
/// stroke through `canvas.drawing`, so hold-to-shape recognition uses this path.
final class PencilStrokeObserverGestureRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onBegan: ((CGPoint, UITouch.TouchType) -> Void)?
    var onMoved: ((CGPoint) -> Void)?
    var onEnded: ((CGPoint) -> Void)?
    var onCancelled: (() -> Void)?
    var observedTouchTypes: [UITouch.TouchType] = [.pencil]

    private func observedTouch(in touches: Set<UITouch>) -> UITouch? {
        touches.first { observedTouchTypes.contains($0.type) }
    }

    private func pageLocation(of touch: UITouch, in view: UIView) -> CGPoint {
        let point = touch.location(in: view)
        guard let canvas = view as? PKCanvasView else { return point }
        return CGPoint(x: (point.x + canvas.contentOffset.x) / canvas.zoomScale,
                       y: (point.y + canvas.contentOffset.y) / canvas.zoomScale)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = observedTouch(in: touches), let view else {
            state = .failed
            return
        }
        state = .began
        onBegan?(pageLocation(of: touch, in: view), touch.type)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = observedTouch(in: touches), let view else { return }
        let samples = event.coalescedTouches(for: touch) ?? [touch]
        for sample in samples {
            onMoved?(pageLocation(of: sample, in: view))
        }
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = observedTouch(in: touches), let view {
            onEnded?(pageLocation(of: touch, in: view))
        }
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        onCancelled?()
        state = .cancelled
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

/// Wraps PKCanvasView with: smart shape detection, undo/redo, and shape insertion.
struct PaperCanvas: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    let tool: DrawingTool
    let color: UIColor
    let lineWidth: CGFloat
    let generatedShapeStyle: GeneratedShapeStyle
    let eraserWidth: CGFloat
    let eraserStyle: EraserStyle
    let lassoMode: LassoMode
    let isReadOnly: Bool
    let allowsFingerDrawing: Bool
    let elementInteractionRects: [CGRect]
    var canBeginFingerElementDrag: (CGPoint) -> Bool = { _ in false }
    var onFingerElementDrag: (FingerElementDragEvent) -> Void = { _ in }
    /// A short Apple Pencil tap that lands on a tappable element (tape) acts
    /// on that element instead of leaving a dot of ink.
    var canPencilTapElement: (CGPoint) -> Bool = { _ in false }
    var onPencilTapElement: (CGPoint) -> Void = { _ in }
    let inkData: Data?
    let canvasInkOpacity: CGFloat
    var scribbleToErase = false
    var pageSize: CGSize = .zero
    var pageZoomScale: CGFloat = 1
    var onDrawingChange: ((Int) -> Void)?
    var onToolUseChange: ((Bool) -> Void)?
    var onShapePreviewChange: ((PKDrawing?) -> Void)?
    var coordinatorHolder: CoordinatorHolder?

    /// UI tests cannot synthesise Apple Pencil touches. With this launch
    /// argument a finger is routed to the canvas and read as a Pencil, so the
    /// Pencil-only paths can be driven end to end.
    static let fingerStandsInForPencil = ProcessInfo.processInfo.arguments
        .contains("-ui-testing-finger-as-pencil")

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(parent: self)
        coordinatorHolder?.coordinator = c
        return c
    }

    func makeUIView(context: Context) -> InkCanvasViewport {
        let c = canvasView
        c.drawingPolicy = allowsFingerDrawing ? .anyInput : .pencilOnly
        if let interactiveCanvas = c as? PencilInputCanvasView {
            interactiveCanvas.elementInteractionRects = elementInteractionRects
            interactiveCanvas.fingerDrawingAllowed = allowsFingerDrawing
        }
        c.backgroundColor = .clear
        c.isOpaque = false
        // PencilKit adaptively swaps black and white ink in dark appearance.
        // Pages use explicit colors, so render ink with literal light-mode
        // color semantics regardless of the surrounding app appearance.
        c.overrideUserInterfaceStyle = .light
        c.alpha = canvasInkOpacity
        c.clipsToBounds = false
        // Outer scrolling owns pan and pinch gestures. InkCanvasViewport
        // updates PencilKit's native zoom without enabling competing gestures.
        c.isScrollEnabled = false
        c.bounces = false
        c.alwaysBounceHorizontal = false
        c.alwaysBounceVertical = false
        // Remove the canvas's built-in pinch/pan recognizers so they don't
        // compete with the outer UIScrollView.
        for gr in c.gestureRecognizers ?? [] {
            if gr === c.drawingGestureRecognizer { continue }
            if gr is UIPinchGestureRecognizer || gr is UIPanGestureRecognizer {
                gr.isEnabled = false
            }
        }
        // NOTE: Do NOT load ink from the `inkData` parameter here. The shared
        // PKCanvasView (held in @State by PageEditorView) is loaded exclusively
        // by PageEditorView.onAppear → loadInk() for the first page, and by
        // switchLoadedPage() for subsequent page swipes. If makeUIView loads
        // inkData here, a SwiftUI view-tree rebuild during a page switch can
        // clobber the shared canvas with the NEW page's ink BEFORE
        // switchLoadedPage() has saved the OLD page's ink — permanently
        // destroying the previous page's content.
        // The ink surface itself, so a test can aim at it rather than at the
        // outer zoomable scroll view that wraps it. Without this there is no
        // way to address PencilKit from the accessibility tree, which is why
        // the handwriting path had no automated coverage at all.
        c.accessibilityIdentifier = "ink-canvas"
        context.coordinator.updateToolIfIdle(on: c)
        c.isUserInteractionEnabled = context.coordinator.canvasAcceptsInput
        c.delegate = context.coordinator
        context.coordinator.canvas = c
        context.coordinator.attachDrawingGesture(to: c)
        context.coordinator.attachFingerElementDrag(to: c)
        let viewport = InkCanvasViewport(canvas: c)
        viewport.update(pageSize: pageSize, zoom: pageZoomScale)
        return viewport
    }

    func updateUIView(_ viewport: InkCanvasViewport, context: Context) {
        let uiView = viewport.canvas
        context.coordinator.parent = self
        uiView.overrideUserInterfaceStyle = .light
        uiView.drawingPolicy = allowsFingerDrawing ? .anyInput : .pencilOnly
        if let interactiveCanvas = uiView as? PencilInputCanvasView {
            interactiveCanvas.elementInteractionRects = elementInteractionRects
            interactiveCanvas.fingerDrawingAllowed = allowsFingerDrawing
        }
        uiView.isUserInteractionEnabled = context.coordinator.canvasAcceptsInput
        uiView.isScrollEnabled = false
        viewport.inkOpacity = canvasInkOpacity
        // Re-disable pinch/pan on the inner canvas (PKCanvasView can re-enable
        // them internally on tool changes).
        for gr in uiView.gestureRecognizers ?? [] {
            if gr === uiView.drawingGestureRecognizer { continue }
            if gr is UIPinchGestureRecognizer || gr is UIPanGestureRecognizer {
                gr.isEnabled = false
            }
        }
        context.coordinator.updateToolIfIdle(on: uiView)
        context.coordinator.attachDrawingGesture(to: uiView)
        context.coordinator.attachFingerElementDrag(to: uiView)
        viewport.update(pageSize: pageSize, zoom: pageZoomScale)
    }

    /// Lightweight holder so parent SwiftUI views can reach the coordinator
    /// (used for programmatic shape insertion).
    final class CoordinatorHolder {
        weak var coordinator: Coordinator?
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIScrollViewDelegate {
        var parent: PaperCanvas
        weak var canvas: PKCanvasView?
        private var shapeHoldTimer: Timer?
        private var shapeCommitClearTimer: Timer?
        private var lastStrokeCount: Int = 0
        private var isUsingTool = false
        private(set) var lastInkEditWasScribble = false
        private var strokeCountAtToolBegin = 0
        private var drawingChangeObservedForToolUse = false
        private var pendingToolFinish: DispatchWorkItem?
        private var toolFinishGeneration = 0
        private var appliedToolConfiguration: ToolConfiguration?
        private var isApplyingProgrammaticDrawing = false
        private var suppressesProgrammaticDrawingNotification = false
        private var pencilObserver: PencilStrokeObserverGestureRecognizer?
        private weak var fingerElementTouch: FingerElementTouchRecognizer?
        private var isCapturingPencilStroke = false
        private var activeTouchType: UITouch.TouchType?
        private var pencilStrokeBegan: CFTimeInterval = 0
        private var tapDotBaseline: PKDrawing?
        private var tapDotTimer: Timer?
        private var capturedPencilPoints: [CGPoint] = []
        private var settledDrawingAtToolBegin = PKDrawing()
        private var awaitingResurrectionCheck = false
        private var shapeHoldAnchor: CGPoint?
        private var shapePreviewLocation: CGPoint?
        private var shapePreview: ShapePreview?
        private var pendingShapeCommit: ShapePreview?
        private var pendingShapeCommitTimer: Timer?
        private var committedShapePreview: CommittedShapePreview?

        private let shapeHoldDelay: TimeInterval = 0.6
        private let pendingShapeCommitDelay: TimeInterval = 0.8
        private let committedShapeProtectionDelay: TimeInterval = 1.0
        private let continuationDistance: CGFloat = 8
        private let meaningfulMovementDistance: CGFloat = 3
        private let strokeSettlingDelay: TimeInterval = 0.12

        private struct ToolConfiguration: Equatable {
            let tool: DrawingTool
            let color: UIColor
            let lineWidth: CGFloat
            let eraserWidth: CGFloat
            let eraserStyle: EraserStyle
            let lassoMode: LassoMode
        }

        private struct ShapePreview {
            let strokeIndex: Int
            let renderedStroke: PKStroke
        }

        private struct CommittedShapePreview {
            let strokeIndex: Int
            let originalStroke: PKStroke
            let renderedStroke: PKStroke
        }

        private struct StrokeFingerprint: Equatable {
            let pointCount: Int
            let start: CGPoint
            let end: CGPoint
            let bounds: CGRect
            let meanOpacity: CGFloat
        }

        init(parent: PaperCanvas) { self.parent = parent }

        deinit {
            pendingToolFinish?.cancel()
            shapeHoldTimer?.invalidate()
            pendingShapeCommitTimer?.invalidate()
            shapeCommitClearTimer?.invalidate()
            if let pencilObserver {
                pencilObserver.view?.removeGestureRecognizer(pencilObserver)
            }
            if let fingerElementTouch {
                fingerElementTouch.view?.removeGestureRecognizer(fingerElementTouch)
            }
        }

        var canvasAcceptsInput: Bool {
            guard !parent.isReadOnly else { return false }
            guard parent.tool != .lasso else { return false }
            // Element interaction is handled via elementInteractionRects, so
            // the canvas itself is never disabled by tool choice.
            return true
        }

        func attachDrawingGesture(to canvas: PKCanvasView) {
            let observedTouchTypes: [UITouch.TouchType] = parent.allowsFingerDrawing ? [.pencil, .direct] : [.pencil]
            if let pencilObserver, pencilObserver.view === canvas {
                pencilObserver.observedTouchTypes = observedTouchTypes
                pencilObserver.allowedTouchTypes = observedTouchTypes.map { NSNumber(value: $0.rawValue) }
                return
            }

            if let pencilObserver {
                pencilObserver.view?.removeGestureRecognizer(pencilObserver)
            }

            let observer = PencilStrokeObserverGestureRecognizer()
            observer.delegate = observer
            observer.observedTouchTypes = observedTouchTypes
            observer.allowedTouchTypes = observer.observedTouchTypes.map { NSNumber(value: $0.rawValue) }
            observer.cancelsTouchesInView = false
            observer.delaysTouchesBegan = false
            observer.delaysTouchesEnded = false
            observer.onBegan = { [weak self, weak canvas] point, touchType in
                guard let self, let canvas else { return }
                self.beginPencilStroke(at: point, touchType: touchType, on: canvas)
            }
            observer.onMoved = { [weak self, weak canvas] point in
                guard let self, let canvas else { return }
                self.movePencilStroke(to: point, on: canvas)
            }
            observer.onEnded = { [weak self, weak canvas] point in
                guard let self, let canvas else { return }
                self.endPencilStroke(at: point, on: canvas, commitsShape: true)
            }
            observer.onCancelled = { [weak self, weak canvas] in
                guard let self, let canvas else { return }
                self.endPencilStroke(at: nil, on: canvas, commitsShape: false)
            }
            canvas.addGestureRecognizer(observer)
            pencilObserver = observer
        }

        func attachFingerElementDrag(to canvas: PKCanvasView) {
            if PaperCanvas.fingerStandsInForPencil { return }
            if fingerElementTouch?.view === canvas { return }
            if let fingerElementTouch {
                fingerElementTouch.view?.removeGestureRecognizer(fingerElementTouch)
            }
            let recognizer = FingerElementTouchRecognizer()
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.canBegin = { [weak self] point in
                self?.parent.canBeginFingerElementDrag(point) ?? false
            }
            recognizer.onEvent = { [weak self] event in
                self?.parent.onFingerElementDrag(event)
            }
            canvas.addGestureRecognizer(recognizer)
            fingerElementTouch = recognizer
        }

        func makeTool() -> PKTool {
            if let ink = parent.tool.inkType {
                return PKInkingTool(ink, color: parent.color, width: parent.lineWidth)
            }
            switch parent.tool {
            case .eraser: return PKEraserTool(parent.eraserStyle.pkKind, width: parent.eraserWidth)
            case .lasso:
                return parent.lassoMode == .freeform ? PKLassoTool() : PKInkingTool(.pen, color: .clear, width: 0.1)
            default:      return PKInkingTool(.pen, color: parent.color, width: parent.lineWidth)
            }
        }

        func updateToolIfIdle(on canvas: PKCanvasView) {
            guard !isUsingTool, !isCapturingPencilStroke else { return }
            let configuration = ToolConfiguration(
                tool: parent.tool, color: parent.color, lineWidth: parent.lineWidth,
                eraserWidth: parent.eraserWidth, eraserStyle: parent.eraserStyle, lassoMode: parent.lassoMode
            )
            guard appliedToolConfiguration != configuration else { return }
            canvas.tool = makeTool()
            appliedToolConfiguration = configuration
        }

        // Called whenever the drawing changes (stroke added/erased).
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            (canvasView.superview as? InkCanvasViewport)?.drawingDidChange()
            let count = canvasView.drawing.strokes.count

            if isApplyingProgrammaticDrawing {
                lastStrokeCount = count
                if !suppressesProgrammaticDrawingNotification {
                    parent.onDrawingChange?(count)
                }
                return
            }

            // A Pencil tap on tape is not ink: drop the dot PencilKit publishes
            // for it before the editor hears about it.
            if removeTapDotIfPublished(on: canvasView) { return }

            // PencilKit can spontaneously republish strokes it had already
            // dropped -- from an undo, a redo, or an erase -- the instant a
            // new stroke begins, before a single point of new ink has
            // landed. reapplyCommittedShapeIfNeeded (below) already works
            // around the same underlying framework behavior for one narrow
            // case (a shape-recognition preview reappearing); this is the
            // general form, confirmed live on-device with real Apple Pencil
            // input: undoing down to N strokes, then starting a new stroke,
            // reported N+3 strokes on the very first delegate callback for
            // that gesture -- before any drawing motion could plausibly
            // explain more than one new stroke.
            //
            // `settledDrawingAtToolBegin`, captured fresh at touch-down in
            // beginPencilStroke, is the one snapshot proven trustworthy (the
            // debug session that found this bug confirmed it still reads the
            // correct post-undo count at that instant). A single stroke
            // gesture can only ever grow that baseline by exactly one
            // PKStroke -- the in-progress one -- until it ends, so any larger
            // jump is resurrected content, not real ink. Trim it back to the
            // baseline plus whatever was genuinely just appended.
            //
            // Gating this on `isCapturingPencilStroke` looked right but wasn't:
            // live logging showed the resurrected jump consistently arriving
            // AFTER touchesEnded had already cleared that flag -- the passive
            // Pencil observer's touch-up races ahead of PencilKit's own
            // internal publish of the finished stroke, so by the time this
            // delegate callback fires for a quick stroke, `isCapturingPencilStroke`
            // is already false and the guard below never ran. `awaitingResurrectionCheck`
            // instead stays keyed to "have we seen the first drawing-change
            // callback since this stroke began," independent of whether the
            // touch itself has already lifted.
            if awaitingResurrectionCheck {
                awaitingResurrectionCheck = false
                let baselineCount = settledDrawingAtToolBegin.strokes.count
                if count > baselineCount + 1, let newest = canvasView.drawing.strokes.last {
                    let corrected = PKDrawing(strokes: settledDrawingAtToolBegin.strokes + [newest])
                    canvasView.drawing = corrected
                    return
                }
            }

            // Depending on the PencilKit release, the first drawing callback
            // can arrive either before or after the begin-tool delegate. Keep
            // the handwriting range anchored to the actual first callback,
            // while shape preview always uses the current final stroke below.
            if isUsingTool, !drawingChangeObservedForToolUse {
                if count > strokeCountAtToolBegin {
                    strokeCountAtToolBegin = count - 1
                }
                drawingChangeObservedForToolUse = true
            }

            // A final drawing callback can follow both pen-up notifications.
            // Give PencilKit another quiet interval before replacing any ink.
            if pendingToolFinish != nil {
                scheduleToolFinish(on: canvasView)
            }

            // PencilKit may publish the completed stroke either before or
            // after the Pencil observer receives touchesEnded. Commit a held
            // shape as soon as its target stroke exists in the drawing.
            if pendingShapeCommit != nil,
               commitPendingShapeIfPossible(on: canvasView) {
                return
            }

            // Eraser/lasso must never trigger shape-preview reapply. The bitmap
            // eraser in particular emits intermediate canvasViewDrawingDidChange
            // callbacks (during the lift) where stroke count is momentarily
            // stable but the stroke is internally dirtied. If we let the
            // committed-shape reapply path run on those callbacks, it
            // resurrects the rendered (snapped) stroke for one frame — causing
            // the "stroke reappears then disappears" flicker. Bail out entirely
            // for non-ink tools.
            let isNonInkTool = parent.tool.inkType == nil

            if isNonInkTool || count < lastStrokeCount {
                if count < lastStrokeCount {
                    committedShapePreview = nil
                    shapeCommitClearTimer?.invalidate()
                    shapeCommitClearTimer = nil
                }
                parent.onDrawingChange?(count)
                lastStrokeCount = count
                return
            }

            if let committedPreview = committedShapePreview,
               !isUsingTool,
               count >= lastStrokeCount,
               reapplyCommittedShapeIfNeeded(committedPreview, on: canvasView) {
                return
            }

            parent.onDrawingChange?(count)
            lastStrokeCount = count
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            beginToolUse(on: canvasView)
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            // Delegate and recognizer end callbacks are not consistently
            // ordered. Let the passive Pencil observer finalize first.
            if isCapturingPencilStroke {
                DispatchQueue.main.async { [weak self, weak canvasView] in
                    guard let self, let canvasView, self.isCapturingPencilStroke else { return }
                    self.endPencilStroke(at: nil, on: canvasView, commitsShape: true)
                }
                return
            }
            endToolUse(on: canvasView)
        }

        private func beginPencilStroke(at point: CGPoint, touchType observedType: UITouch.TouchType, on canvas: PKCanvasView) {
            let touchType: UITouch.TouchType = PaperCanvas.fingerStandsInForPencil ? .pencil : observedType
            // A finger that begins on a page element belongs to its move or
            // selection handles, even when Draw with Finger is enabled.
            // Reporting it as ink use clears the selected element before the
            // finger recognizer can identify a resize or rotation handle.
            if touchType == .direct && parent.canBeginFingerElementDrag(point) { return }
            if pendingShapeCommit != nil {
                _ = commitPendingShapeIfPossible(on: canvas)
            }
            clearShapeRecognitionState(hidesPreview: true)
            isCapturingPencilStroke = true
            activeTouchType = touchType
            pencilStrokeBegan = CACurrentMediaTime()
            capturedPencilPoints = [point]
            settledDrawingAtToolBegin = canvas.drawing
            awaitingResurrectionCheck = true
            shapeHoldAnchor = point
            beginToolUse(on: canvas)
            scheduleShapeHoldIfNeeded(on: canvas)
        }

        private func movePencilStroke(to point: CGPoint, on canvas: PKCanvasView) {
            guard isCapturingPencilStroke else { return }
            if let lastPoint = capturedPencilPoints.last,
               distance(lastPoint, point) >= 0.35 {
                capturedPencilPoints.append(point)
            }

            if let previewLocation = shapePreviewLocation,
               distance(previewLocation, point) > continuationDistance {
                cancelActiveShapePreview()
                shapeHoldAnchor = point
                scheduleShapeHoldIfNeeded(on: canvas)
                return
            }

            guard shapePreview == nil,
                  let anchor = shapeHoldAnchor,
                  distance(anchor, point) >= meaningfulMovementDistance else { return }
            shapeHoldAnchor = point
            scheduleShapeHoldIfNeeded(on: canvas)
        }

        private func endPencilStroke(at point: CGPoint?, on canvas: PKCanvasView, commitsShape: Bool) {
            guard isCapturingPencilStroke else {
                endToolUse(on: canvas)
                return
            }
            if let point,
               let lastPoint = capturedPencilPoints.last,
               distance(lastPoint, point) >= 0.35 {
                capturedPencilPoints.append(point)
            }

            shapeHoldTimer?.invalidate()
            shapeHoldTimer = nil
            let heldPreview = shapePreview
            let tappedElementPoint = pencilTapPoint(commitsShape: commitsShape && heldPreview == nil)
            shapePreview = nil
            shapePreviewLocation = nil
            isCapturingPencilStroke = false
            activeTouchType = nil

            if let heldPreview, commitsShape {
                pendingShapeCommit = heldPreview
                if !commitPendingShapeIfPossible(on: canvas) {
                    schedulePendingShapeCommitClear(on: canvas)
                }
            } else {
                parent.onShapePreviewChange?(nil)
            }

            capturedPencilPoints.removeAll(keepingCapacity: true)
            shapeHoldAnchor = nil
            if let tappedElementPoint {
                discardTapDot(baseline: settledDrawingAtToolBegin, on: canvas)
                parent.onPencilTapElement(tappedElementPoint)
            }
            endToolUse(on: canvas)
        }

        /// Where a Pencil tap on a tappable element landed, or nil when the
        /// stroke was a real stroke: it must be short, brief, still, made with
        /// an inking tool, and begin on such an element.
        private func pencilTapPoint(commitsShape: Bool) -> CGPoint? {
            guard commitsShape,
                  activeTouchType == .pencil,
                  parent.tool.inkType != nil,
                  let first = capturedPencilPoints.first,
                  CACurrentMediaTime() - pencilStrokeBegan < 0.35,
                  capturedPencilPoints.allSatisfy({ distance(first, $0) < 6 }),
                  parent.canPencilTapElement(first) else { return nil }
            return first
        }

        /// PencilKit lays down a dot for any tap, and publishes it after the
        /// touch has ended. Put the drawing back as it was, without telling the
        /// editor, so the tap leaves neither ink nor an undo step.
        private func discardTapDot(baseline: PKDrawing, on canvas: PKCanvasView) {
            tapDotBaseline = baseline
            tapDotTimer?.invalidate()
            let timer = Timer(timeInterval: 0.8, repeats: false) { [weak self] _ in
                self?.tapDotBaseline = nil
                self?.tapDotTimer = nil
            }
            tapDotTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            removeTapDotIfPublished(on: canvas)
        }

        @discardableResult
        private func removeTapDotIfPublished(on canvas: PKCanvasView) -> Bool {
            guard let baseline = tapDotBaseline,
                  canvas.drawing.strokes.count > baseline.strokes.count else { return false }
            tapDotBaseline = nil
            tapDotTimer?.invalidate()
            tapDotTimer = nil
            performProgrammaticDrawingChange(on: canvas, notifiesParent: false) {
                canvas.drawing = baseline
            }
            return true
        }

        private func beginToolUse(on canvas: PKCanvasView) {
            guard !isUsingTool || pendingToolFinish != nil else { return }
            pendingToolFinish?.cancel()
            pendingToolFinish = nil
            toolFinishGeneration &+= 1
            lastInkEditWasScribble = false
            strokeCountAtToolBegin = canvas.drawing.strokes.count
            drawingChangeObservedForToolUse = false
            let wasUsingTool = isUsingTool
            isUsingTool = true
            (canvas.superview as? InkCanvasViewport)?.isUsingTool = true
            if !wasUsingTool { parent.onToolUseChange?(true) }
            committedShapePreview = nil
            shapeCommitClearTimer?.invalidate()
            shapeCommitClearTimer = nil
        }

        private func endToolUse(on canvas: PKCanvasView) {
            guard isUsingTool else { return }
            shapeHoldTimer?.invalidate()
            shapeHoldTimer = nil
            scheduleToolFinish(on: canvas)
        }

        private func scheduleToolFinish(on canvas: PKCanvasView) {
            pendingToolFinish?.cancel()
            toolFinishGeneration &+= 1
            let generation = toolFinishGeneration
            let work = DispatchWorkItem { [weak self, weak canvas] in
                guard let self, let canvas, self.toolFinishGeneration == generation,
                      self.isUsingTool, !self.isCapturingPencilStroke else { return }
                self.pendingToolFinish = nil
                let state = canvas.drawingGestureRecognizer.state
                guard state != .began, state != .changed else {
                    self.scheduleToolFinish(on: canvas)
                    return
                }
                self.isUsingTool = false
                // Classify before removing the scratch stroke. Even a scratch
                // on blank space is a gesture, not newly written question text.
                self.lastInkEditWasScribble = self.parent.scribbleToErase
                    && (self.parent.tool == .pen || self.parent.tool == .pencil)
                    && ScribbleEraser.containsScratch(in: canvas.drawing, newStrokesFrom: self.strokeCountAtToolBegin)
                if self.eraseScribbledInk(on: canvas) {
                    self.clearShapeRecognitionState(hidesPreview: true)
                    self.committedShapePreview = nil
                } else if self.pendingShapeCommit != nil {
                    _ = self.commitPendingShapeIfPossible(on: canvas)
                }
                self.strokeCountAtToolBegin = canvas.drawing.strokes.count
                self.drawingChangeObservedForToolUse = false
                self.updateToolIfIdle(on: canvas)
                (canvas.superview as? InkCanvasViewport)?.isUsingTool = false
                self.parent.onToolUseChange?(false)
            }
            pendingToolFinish = work
            DispatchQueue.main.asyncAfter(deadline: .now() + strokeSettlingDelay, execute: work)
        }

        private func eraseScribbledInk(on canvas: PKCanvasView) -> Bool {
            guard parent.scribbleToErase, parent.tool == .pen || parent.tool == .pencil,
                  let drawing = ScribbleEraser.erasing(in: canvas.drawing, newStrokesFrom: strokeCountAtToolBegin) else { return false }
            performProgrammaticDrawingChange(on: canvas) { canvas.drawing = drawing }
            MemoryDiagnostics.record("scribble-erase applied")
            return true
        }

        private func scheduleShapeHoldIfNeeded(on canvas: PKCanvasView) {
            guard canPreviewShapes,
                  isUsingTool,
                  isCapturingPencilStroke,
                  shapePreview == nil else { return }

            shapeHoldTimer?.invalidate()
            let timer = Timer(timeInterval: shapeHoldDelay, repeats: false) { [weak self, weak canvas] _ in
                guard let self, let canvas else { return }
                self.previewShapeIfAvailable(on: canvas)
            }
            shapeHoldTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        private func previewShapeIfAvailable(on canvas: PKCanvasView) {
            shapeHoldTimer = nil
            guard canPreviewShapes,
                  isUsingTool,
                  isCapturingPencilStroke,
                  shapePreview == nil,
                  let originalStroke = capturedPencilStroke(),
                  let detected = ShapeSnapper.detect(from: originalStroke) else { return }

            let renderedStroke = detected.renderedStroke(style: parent.generatedShapeStyle)
            shapePreview = ShapePreview(
                strokeIndex: settledDrawingAtToolBegin.strokes.count,
                renderedStroke: renderedStroke
            )
            shapePreviewLocation = capturedPencilPoints.last
            parent.onShapePreviewChange?(
                PKDrawing(strokes: settledDrawingAtToolBegin.strokes + [renderedStroke])
            )
        }

        private func cancelActiveShapePreview() {
            guard shapePreview != nil else { return }
            shapeHoldTimer?.invalidate()
            shapeHoldTimer = nil
            shapePreview = nil
            shapePreviewLocation = nil
            parent.onShapePreviewChange?(nil)
        }

        @discardableResult
        private func commitPendingShapeIfPossible(on canvas: PKCanvasView) -> Bool {
            guard !isUsingTool, !isCapturingPencilStroke,
                  let preview = pendingShapeCommit else { return false }
            var strokes = canvas.drawing.strokes
            guard strokes.indices.contains(preview.strokeIndex) else { return false }

            let originalStroke = strokes[preview.strokeIndex]
            strokes[preview.strokeIndex] = preview.renderedStroke
            pendingShapeCommit = nil
            pendingShapeCommitTimer?.invalidate()
            pendingShapeCommitTimer = nil
            parent.onShapePreviewChange?(nil)

            committedShapePreview = CommittedShapePreview(
                strokeIndex: preview.strokeIndex,
                originalStroke: originalStroke,
                renderedStroke: preview.renderedStroke
            )
            performProgrammaticDrawingChange(on: canvas) {
                canvas.drawing = PKDrawing(strokes: strokes)
            }
            scheduleCommittedShapePreviewClear()
            return true
        }

        private func reapplyCommittedShapeIfNeeded(_ preview: CommittedShapePreview, on canvas: PKCanvasView) -> Bool {
            var strokes = canvas.drawing.strokes
            guard strokes.indices.contains(preview.strokeIndex) else {
                committedShapePreview = nil
                return false
            }

            let current = strokes[preview.strokeIndex]
            let currentFingerprint = strokeFingerprint(current)
            if currentFingerprint == strokeFingerprint(preview.renderedStroke) {
                return false
            }

            // PencilKit can publish the original in-progress stroke once more
            // after its gesture ends. Replace only that same geometry so an
            // erase, undo, or page switch cannot resurrect a stale shape.
            guard geometryMatches(currentFingerprint, strokeFingerprint(preview.originalStroke)) else {
                committedShapePreview = nil
                return false
            }

            strokes[preview.strokeIndex] = preview.renderedStroke
            performProgrammaticDrawingChange(on: canvas) {
                canvas.drawing = PKDrawing(strokes: strokes)
            }
            return true
        }

        private func capturedPencilStroke() -> PKStroke? {
            guard parent.tool.inkType != nil,
                  capturedPencilPoints.count >= 2 else { return nil }

            let style = parent.generatedShapeStyle
            let pointSize = CGSize(width: style.width, height: style.width)
            let points = capturedPencilPoints.enumerated().map { index, point in
                PKStrokePoint(
                    location: point,
                    timeOffset: TimeInterval(index) * 0.004,
                    size: pointSize,
                    opacity: style.opacity,
                    force: 1,
                    azimuth: 0,
                    altitude: .pi / 2
                )
            }
            let path = PKStrokePath(controlPoints: points, creationDate: .now)
            return PKStroke(ink: style.ink, path: path)
        }

        private func schedulePendingShapeCommitClear(on canvas: PKCanvasView) {
            pendingShapeCommitTimer?.invalidate()
            let timer = Timer(timeInterval: pendingShapeCommitDelay, repeats: false) { [weak self, weak canvas] _ in
                guard let self else { return }
                if let canvas, self.commitPendingShapeIfPossible(on: canvas) {
                    return
                }
                self.pendingShapeCommit = nil
                self.pendingShapeCommitTimer = nil
                self.parent.onShapePreviewChange?(nil)
            }
            pendingShapeCommitTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        private func clearShapeRecognitionState(hidesPreview: Bool) {
            shapeHoldTimer?.invalidate()
            shapeHoldTimer = nil
            pendingShapeCommitTimer?.invalidate()
            pendingShapeCommitTimer = nil
            shapePreview = nil
            pendingShapeCommit = nil
            shapePreviewLocation = nil
            capturedPencilPoints.removeAll(keepingCapacity: true)
            shapeHoldAnchor = nil
            if hidesPreview {
                parent.onShapePreviewChange?(nil)
            }
        }

        func cancelShapeRecognition() {
            pendingToolFinish?.cancel()
            pendingToolFinish = nil
            toolFinishGeneration &+= 1
            clearShapeRecognitionState(hidesPreview: true)
            isCapturingPencilStroke = false
            (canvas?.superview as? InkCanvasViewport)?.isUsingTool = false
            committedShapePreview = nil
            shapeCommitClearTimer?.invalidate()
            shapeCommitClearTimer = nil
            if isUsingTool {
                isUsingTool = false
                drawingChangeObservedForToolUse = false
                parent.onToolUseChange?(false)
            }
        }

        private func scheduleCommittedShapePreviewClear() {
            shapeCommitClearTimer?.invalidate()
            let timer = Timer(timeInterval: committedShapeProtectionDelay, repeats: false) { [weak self] _ in
                self?.committedShapePreview = nil
                self?.shapeCommitClearTimer = nil
            }
            shapeCommitClearTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        private func performProgrammaticDrawingChange(
            on canvas: PKCanvasView,
            notifiesParent: Bool = true,
            _ changes: () -> Void
        ) {
            isApplyingProgrammaticDrawing = true
            suppressesProgrammaticDrawingNotification = !notifiesParent
            changes()
            lastStrokeCount = canvas.drawing.strokes.count
            if notifiesParent {
                parent.onDrawingChange?(lastStrokeCount)
            }
            isApplyingProgrammaticDrawing = false
            suppressesProgrammaticDrawingNotification = false
        }

        private var canPreviewShapes: Bool {
            guard canvasAcceptsInput, !parent.isReadOnly else { return false }
            switch parent.tool {
            case .pen, .pencil, .marker:
                return true
            case .eraser, .lasso:
                return false
            }
        }

        private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            hypot(b.x - a.x, b.y - a.y)
        }

        private func strokeFingerprint(_ stroke: PKStroke) -> StrokeFingerprint? {
            let strokePoints = Array(stroke.path)
            let points = strokePoints.map(\.location)
            guard let start = points.first, let end = points.last else { return nil }
            let meanOpacity = strokePoints.reduce(CGFloat.zero) { $0 + $1.opacity } / CGFloat(strokePoints.count)
            return StrokeFingerprint(
                pointCount: points.count,
                start: rounded(start),
                end: rounded(end),
                bounds: rounded(boundingBox(of: points)),
                meanOpacity: rounded(meanOpacity)
            )
        }

        private func geometryMatches(_ lhs: StrokeFingerprint?, _ rhs: StrokeFingerprint?) -> Bool {
            guard let lhs, let rhs else { return false }
            return lhs.pointCount == rhs.pointCount
                && lhs.start == rhs.start
                && lhs.end == rhs.end
                && lhs.bounds == rhs.bounds
        }

        private func boundingBox(of points: [CGPoint]) -> CGRect {
            guard let first = points.first else { return .zero }
            var minX = first.x
            var minY = first.y
            var maxX = first.x
            var maxY = first.y
            for point in points {
                minX = min(minX, point.x)
                minY = min(minY, point.y)
                maxX = max(maxX, point.x)
                maxY = max(maxY, point.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        private func rounded(_ point: CGPoint) -> CGPoint {
            CGPoint(x: rounded(point.x), y: rounded(point.y))
        }

        private func rounded(_ rect: CGRect) -> CGRect {
            CGRect(
                x: rounded(rect.origin.x),
                y: rounded(rect.origin.y),
                width: rounded(rect.size.width),
                height: rounded(rect.size.height)
            )
        }

        private func rounded(_ value: CGFloat) -> CGFloat {
            (value * 10).rounded() / 10
        }

        // MARK: Public helpers used by the editor view

        func cancelTentativeFingerMark() {
            guard activeTouchType == .direct, let canvas else { return }
            pendingToolFinish?.cancel()
            pendingToolFinish = nil
            toolFinishGeneration &+= 1
            shapeHoldTimer?.invalidate()
            shapeHoldTimer = nil
            shapePreview = nil
            pendingShapeCommit = nil
            shapePreviewLocation = nil
            capturedPencilPoints.removeAll(keepingCapacity: true)
            shapeHoldAnchor = nil
            isCapturingPencilStroke = false
            activeTouchType = nil
            if isUsingTool {
                isUsingTool = false
                parent.onToolUseChange?(false)
            }
            canvas.drawingGestureRecognizer.isEnabled = false
            performProgrammaticDrawingChange(on: canvas) {
                canvas.drawing = settledDrawingAtToolBegin
            }
            canvas.drawingGestureRecognizer.isEnabled = true
            parent.onShapePreviewChange?(nil)
        }

        func replaceLastStroke(with stroke: PKStroke) {
            guard let canvas else { return }
            var strokes = canvas.drawing.strokes
            if !strokes.isEmpty { strokes.removeLast() }
            strokes.append(stroke)
            canvas.drawing = PKDrawing(strokes: strokes)
        }

        @discardableResult
        func addShape(_ shape: ShapeKind, style: GeneratedShapeStyle, at point: CGPoint, size: CGSize) -> Set<Int> {
            guard let canvas else { return [] }
            let rect = CGRect(origin: point, size: size)
            let generated = ShapeSnapper.makeShape(shape, in: rect, style: style)
            var strokes = canvas.drawing.strokes
            let firstIndex = strokes.count
            strokes.append(contentsOf: generated)
            canvas.drawing = PKDrawing(strokes: strokes)
            return Set(firstIndex..<strokes.count)
        }
    }
}

/// Displays settled ink plus a snapped-shape preview without participating in
/// hit testing or mutating PencilKit's active stroke.
struct ShapePreviewOverlay: UIViewRepresentable {
    let drawing: PKDrawing

    func makeUIView(context: Context) -> PKCanvasView {
        let view = PKCanvasView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        view.overrideUserInterfaceStyle = .light
        return view
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        uiView.drawing = drawing
    }
}

/// A high-resolution, non-interactive display layer for PencilKit ink.
///
/// PKDrawing is already vector data. This overlay redraws that vector data into
/// CATiledLayer tiles at the active page zoom so close zoom levels do not rely
/// on magnifying PKCanvasView's current presentation layer.
struct VectorInkOverlay: UIViewRepresentable {
    let drawingData: Data?
    let pageSize: CGSize
    let zoomScale: CGFloat
    let isEnabled: Bool

    func makeUIView(context: Context) -> TiledInkView {
        let view = TiledInkView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: TiledInkView, context: Context) {
        uiView.update(
            drawingData: drawingData,
            pageSize: pageSize,
            zoomScale: zoomScale,
            isEnabled: isEnabled
        )
    }
}

final class TiledInkView: UIView {
    override class var layerClass: AnyClass {
        CATiledLayer.self
    }

    private var drawing = PKDrawing()
    private let drawingLock = NSLock()
    private var drawingDataFingerprint: Int?
    private var pageSize: CGSize = .zero
    private var renderingScale: CGFloat = UITraitCollection.current.displayScale > 0 ? UITraitCollection.current.displayScale : 2

    override init(frame: CGRect) {
        super.init(frame: frame)
        overrideUserInterfaceStyle = .light
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        overrideUserInterfaceStyle = .light
        configureLayer()
    }

    func update(drawingData: Data?, pageSize: CGSize, zoomScale: CGFloat, isEnabled: Bool) {
        let displayScale = window?.screen.scale ?? (UITraitCollection.current.displayScale > 0 ? UITraitCollection.current.displayScale : 2)
        let nextRenderingScale = min(max(displayScale * max(zoomScale, 1), displayScale), 12)
        let nextFingerprint = drawingData?.hashValue
        var shouldRedraw = false

        isHidden = !isEnabled || drawingData?.isEmpty != false

        if self.pageSize != pageSize {
            drawingLock.lock()
            self.pageSize = pageSize
            drawingLock.unlock()
            frame = CGRect(origin: .zero, size: pageSize)
            shouldRedraw = true
        }

        if abs(renderingScale - nextRenderingScale) >= 0.1 {
            drawingLock.lock()
            renderingScale = nextRenderingScale
            drawingLock.unlock()
            configureLayer()
            shouldRedraw = true
        }

        if drawingDataFingerprint != nextFingerprint {
            drawingDataFingerprint = nextFingerprint
            let newDrawing: PKDrawing
            if let drawingData {
                newDrawing = (try? PKDrawing(data: drawingData)) ?? PKDrawing()
            } else {
                newDrawing = PKDrawing()
            }
            drawingLock.lock()
            drawing = newDrawing
            drawingLock.unlock()
            shouldRedraw = true
        }

        if shouldRedraw {
            layer.setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        // CATiledLayer calls draw(_:) on background threads. The main thread
        // can mutate `drawing`, `pageSize`, and `renderingScale` (via update())
        // concurrently while zooming or erasing, causing transient render
        // glitches or EXC_BAD_ACCESS. Snapshot ALL mutable state under the lock.
        drawingLock.lock()
        let snapshot = drawing
        let snapshotPageSize = pageSize
        let snapshotRenderingScale = renderingScale
        let snapshotHidden = isHidden
        drawingLock.unlock()

        guard !snapshotHidden, !snapshot.strokes.isEmpty else { return }

        let clippedRect = rect.intersection(CGRect(origin: .zero, size: snapshotPageSize))
        guard !clippedRect.isNull, clippedRect.width > 0, clippedRect.height > 0 else { return }

        let image = snapshot.image(from: clippedRect, scale: snapshotRenderingScale)
        image.draw(in: clippedRect)
    }

    private func configureLayer() {
        guard let tiledLayer = layer as? CATiledLayer else { return }
        tiledLayer.contentsScale = renderingScale
        tiledLayer.rasterizationScale = renderingScale
        tiledLayer.levelsOfDetail = 1
        tiledLayer.levelsOfDetailBias = 4
        tiledLayer.tileSize = CGSize(width: 512, height: 512)
        tiledLayer.backgroundColor = UIColor.clear.cgColor
        tiledLayer.isOpaque = false
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }
}
