import SwiftUI
import PencilKit
import QuartzCore

/// Lets PencilKit draw with Apple Pencil or, optionally, a finger while
/// preserving direct interaction with SwiftUI page elements underneath.
final class PencilInputCanvasView: PKCanvasView {
    var elementInteractionRects: [CGRect] = []
    var fingerDrawingAllowed = false

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
        let simulatedFinger = touches.isEmpty
            && ProcessInfo.processInfo.arguments.contains("-ui-testing")
        let isFingerTouch = !forceCanvasFinger
            && (simulatedFinger || (!touches.isEmpty && touches.allSatisfy { $0.type == .direct }))
        if isFingerTouch {
            // `point` is already expressed in this view's local coordinates.
            // Converting it from the superview again offsets hit regions,
            // especially after zooming the page.
            if elementInteractionRects.contains(where: { $0.contains(point) }) {
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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let view, let touch = touches.first(where: { $0.type == .direct }) else {
            state = .failed
            return
        }
        let point = touch.location(in: view)
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
        onEvent(.changed(activeTouch.location(in: view)))
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let view, let activeTouch, touches.contains(activeTouch) else { return }
        onEvent(.ended(activeTouch.location(in: view)))
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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = observedTouch(in: touches), let view else {
            state = .failed
            return
        }
        state = .began
        onBegan?(touch.location(in: view), touch.type)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = observedTouch(in: touches), let view else { return }
        let samples = event.coalescedTouches(for: touch) ?? [touch]
        for sample in samples {
            onMoved?(sample.location(in: view))
        }
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = observedTouch(in: touches), let view {
            onEnded?(touch.location(in: view))
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
    let inkData: Data?
    let canvasInkOpacity: CGFloat
    var onDrawingChange: ((Int) -> Void)?
    var onToolUseChange: ((Bool) -> Void)?
    var onShapePreviewChange: ((PKDrawing?) -> Void)?
    var coordinatorHolder: CoordinatorHolder?

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(parent: self)
        coordinatorHolder?.coordinator = c
        return c
    }

    func makeUIView(context: Context) -> PKCanvasView {
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
        // The PKCanvasView is nested inside ZoomablePageView's UIScrollView.
        // Disable the canvas's own scroll/zoom so the outer scroll view handles
        // pinch-to-zoom and panning. Otherwise the inner scroll view swallows
        // the gestures and does nothing (its zoom is locked to 1.0).
        c.isScrollEnabled = false
        c.bounces = false
        c.alwaysBounceHorizontal = false
        c.alwaysBounceVertical = false
        c.minimumZoomScale = 1.0
        c.maximumZoomScale = 1.0
        c.zoomScale = 1.0
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
        c.tool = context.coordinator.makeTool()
        c.isUserInteractionEnabled = context.coordinator.canvasAcceptsInput
        c.delegate = context.coordinator
        context.coordinator.canvas = c
        context.coordinator.attachDrawingGesture(to: c)
        context.coordinator.attachFingerElementDrag(to: c)
        return c
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        uiView.overrideUserInterfaceStyle = .light
        uiView.drawingPolicy = allowsFingerDrawing ? .anyInput : .pencilOnly
        if let interactiveCanvas = uiView as? PencilInputCanvasView {
            interactiveCanvas.elementInteractionRects = elementInteractionRects
            interactiveCanvas.fingerDrawingAllowed = allowsFingerDrawing
        }
        uiView.isUserInteractionEnabled = context.coordinator.canvasAcceptsInput
        uiView.isScrollEnabled = false
        uiView.alpha = canvasInkOpacity
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
        private var strokeCountAtToolBegin = 0
        private var drawingChangeObservedForToolUse = false
        private var isApplyingProgrammaticDrawing = false
        private var suppressesProgrammaticDrawingNotification = false
        private var pencilObserver: PencilStrokeObserverGestureRecognizer?
        private weak var fingerElementTouch: FingerElementTouchRecognizer?
        private var isCapturingPencilStroke = false
        private var activeTouchType: UITouch.TouchType?
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

        // MARK: UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            nil
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
            canvas.tool = makeTool()
        }

        // Called whenever the drawing changes (stroke added/erased).
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let count = canvasView.drawing.strokes.count

            if isApplyingProgrammaticDrawing {
                lastStrokeCount = count
                if !suppressesProgrammaticDrawingNotification {
                    parent.onDrawingChange?(count)
                }
                return
            }

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
                } else if count > 0 {
                    strokeCountAtToolBegin = count - 1
                }
                drawingChangeObservedForToolUse = true
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

        private func beginPencilStroke(at point: CGPoint, touchType: UITouch.TouchType, on canvas: PKCanvasView) {
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
            endToolUse(on: canvas)
        }

        private func beginToolUse(on canvas: PKCanvasView) {
            guard !isUsingTool else { return }
            strokeCountAtToolBegin = canvas.drawing.strokes.count
            drawingChangeObservedForToolUse = false
            isUsingTool = true
            parent.onToolUseChange?(true)
            committedShapePreview = nil
            shapeCommitClearTimer?.invalidate()
            shapeCommitClearTimer = nil
        }

        private func endToolUse(on canvas: PKCanvasView) {
            guard isUsingTool else { return }
            isUsingTool = false
            shapeHoldTimer?.invalidate()
            shapeHoldTimer = nil
            strokeCountAtToolBegin = canvas.drawing.strokes.count
            drawingChangeObservedForToolUse = false
            parent.onToolUseChange?(false)
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
            guard let preview = pendingShapeCommit else { return false }
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
            clearShapeRecognitionState(hidesPreview: true)
            isCapturingPencilStroke = false
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
/// Draws ink that has been lifted out of the main canvas for a live drag.
///
/// The drawing is assigned only when `generation` changes. The transform comes
/// from a `.transformEffect` on the SwiftUI side, so a drag repaints nothing
/// here -- it only re-composites an already-rendered layer, which is what lets
/// the ink keep up with the selection outline.
struct LiftedInkOverlay: UIViewRepresentable {
    let drawing: PKDrawing
    let generation: Int

    final class Assigned { var generation = -1 }

    func makeCoordinator() -> Assigned { Assigned() }

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
        guard context.coordinator.generation != generation else { return }
        context.coordinator.generation = generation
        uiView.drawing = drawing
    }
}

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
