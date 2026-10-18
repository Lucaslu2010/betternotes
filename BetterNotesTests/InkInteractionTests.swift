import XCTest
import PencilKit
import SwiftUI
@testable import BetterNotes

@MainActor
final class InkInteractionTests: XCTestCase {
    private let scratchPoints = [
        CGPoint(x: 25, y: 42), CGPoint(x: 145, y: 46),
        CGPoint(x: 25, y: 50), CGPoint(x: 145, y: 54),
        CGPoint(x: 25, y: 58), CGPoint(x: 145, y: 62)
    ]

    func testScratchErasesCrossedInkAndItsOwnStrokeButKeepsNearbyWriting() throws {
        let first = stroke([CGPoint(x: 60, y: 25), CGPoint(x: 60, y: 80)])
        let second = stroke([CGPoint(x: 100, y: 25), CGPoint(x: 100, y: 80)])
        let nearby = stroke([CGPoint(x: 220, y: 25), CGPoint(x: 220, y: 80)])
        let drawing = PKDrawing(strokes: [first, second, nearby, stroke(scratchPoints)])
        let result = try XCTUnwrap(ScribbleEraser.erasing(in: drawing, newStrokesFrom: 3))
        XCTAssertEqual(result.strokes.count, 1)
        XCTAssertEqual(result.strokes[0].path[0].location, nearby.path[0].location)
    }

    func testScratchOnBlankAreaStaysInk() {
        let distant = stroke([CGPoint(x: 220, y: 25), CGPoint(x: 220, y: 80)])
        let drawing = PKDrawing(strokes: [distant, stroke(scratchPoints)])
        XCTAssertNil(ScribbleEraser.erasing(in: drawing, newStrokesFrom: 1))
        XCTAssertTrue(ScribbleEraser.containsScratch(in: drawing, newStrokesFrom: 1),
                      "A blank-area scratch must also stay out of automatic OCR")
        XCTAssertFalse(ScribbleEraser.containsScratch(in: drawing, newStrokesFrom: 2))
    }

    func testThreePassScratchAlsoRemovesNearbyQuestionDot() throws {
        let body = stroke([CGPoint(x: 60, y: 25), CGPoint(x: 60, y: 72)])
        let dot = stroke([CGPoint(x: 60, y: 85), CGPoint(x: 61, y: 85)])
        let adjacentDot = stroke([CGPoint(x: 180, y: 85), CGPoint(x: 181, y: 85)])
        let lighterScratch = stroke(Array(scratchPoints.prefix(4)))
        let result = try XCTUnwrap(ScribbleEraser.erasing(
            in: PKDrawing(strokes: [body, dot, adjacentDot, lighterScratch]), newStrokesFrom: 3
        ))
        XCTAssertEqual(result.strokes.count, 1)
        XCTAssertEqual(result.strokes[0].path[0].location, adjacentDot.path[0].location)
    }

    func testLassoRemembersTheLastModeAndDefaultsToFreeform() {
        let name = "InkInteractionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = ToolSettings(defaults: defaults)
        XCTAssertEqual(first.lassoMode, .freeform)
        first.setLassoMode(.rectangle)
        let anotherNotebook = ToolSettings(defaults: defaults)
        XCTAssertEqual(anotherNotebook.lassoMode, .rectangle)
        anotherNotebook.setLassoMode(.freeform)
        first.restoreLastLassoMode()
        XCTAssertEqual(first.lassoMode, .freeform)
    }

    func testViewportRasterUsesPhysicalZoomWithoutAllocatingAFullZoomedPage() {
        XCTAssertEqual(InkRasterBudget.scale(for: CGSize(width: 200, height: 300), requested: 8), 8)
        let wholePage = CGSize(width: 600, height: 800)
        let scale = InkRasterBudget.scale(for: wholePage, requested: 8)
        XCTAssertLessThanOrEqual(wholePage.width * wholePage.height * scale * scale, 6_000_001)
    }

    func testSelectionPreviewDoesNotMutateTheDrawingUntilCommit() {
        let canvas = PencilInputCanvasView()
        let original = PKDrawing(strokes: [stroke([CGPoint(x: 60, y: 25), CGPoint(x: 60, y: 80)])])
        canvas.drawing = original
        let viewport = InkCanvasViewport(canvas: canvas)
        viewport.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        viewport.update(pageSize: viewport.bounds.size, zoom: 3)
        viewport.beginSelectionPreview(indices: [0])
        for step in 1...120 {
            viewport.updateSelectionPreview(transform: CGAffineTransform(translationX: CGFloat(step), y: 20))
        }
        XCTAssertEqual(canvas.drawing, original)
        viewport.endSelectionPreview()
        XCTAssertEqual(canvas.drawing, original)
    }

    func testOrdinaryWritingUnderlinesAndCirclesAreNotScratchGestures() {
        XCTAssertFalse(ScribbleEraser.isScratch((0..<20).map { CGPoint(x: CGFloat($0) * 8, y: $0.isMultiple(of: 2) ? 30 : 60) }))
        XCTAssertFalse(ScribbleEraser.isScratch((0..<20).map { CGPoint(x: CGFloat($0) * 8, y: 40) }))
        let circle = (0...60).map { index -> CGPoint in
            let angle = CGFloat(index) / 60 * 2 * .pi
            return CGPoint(x: 80 + cos(angle) * 50, y: 80 + sin(angle) * 50)
        }
        XCTAssertFalse(ScribbleEraser.isScratch(circle))
        let eight = (0...120).map { index -> CGPoint in
            let t = CGFloat(index) / 120 * 2 * .pi
            return CGPoint(x: 15 * sin(2 * t), y: 30 * sin(t))
        }
        let infinity = (0...120).map { index -> CGPoint in
            let t = CGFloat(index) / 120 * 2 * .pi
            return CGPoint(x: 40 * sin(t), y: 15 * sin(2 * t))
        }
        XCTAssertFalse(ScribbleEraser.isScratch(eight))
        XCTAssertFalse(ScribbleEraser.isScratch(infinity))
        XCTAssertTrue(ScribbleEraser.isScratch(scratchPoints.flatMap { [$0, $0] }))
    }

    func testScratchCoordinatesRespectMovedAndScaledInk() throws {
        let transform = CGAffineTransform(translationX: 80, y: 200).scaledBy(x: 1.5, y: 1.5)
        let ink = PKDrawing(strokes: [stroke([CGPoint(x: 60, y: 25), CGPoint(x: 60, y: 80)]), stroke(scratchPoints)])
            .transformed(using: transform)
        XCTAssertEqual(try XCTUnwrap(ScribbleEraser.erasing(in: ink, newStrokesFrom: 1)).strokes.count, 0)
    }

    func testScribbleToggleControlsTheSettledStrokePipeline() async throws {
        for enabled in [false, true] {
            let canvas = PKCanvasView()
            let oldInk = stroke([CGPoint(x: 60, y: 25), CGPoint(x: 60, y: 80)])
            canvas.drawing = PKDrawing(strokes: [oldInk])
            var parent = PaperCanvas(canvasView: .constant(canvas), tool: .pen, color: .black, lineWidth: 3,
                                     generatedShapeStyle: GeneratedShapeStyle(inkType: .pen, color: .black, opacity: 1, width: 3),
                                     eraserWidth: 20, eraserStyle: .vector, lassoMode: .freeform,
                                     isReadOnly: false, allowsFingerDrawing: true, elementInteractionRects: [],
                                     inkData: nil, canvasInkOpacity: 1,
                                     scribbleToErase: enabled)
            var ended = false
            parent.onToolUseChange = { if !$0 { ended = true } }
            let coordinator = PaperCanvas.Coordinator(parent: parent)
            coordinator.canvas = canvas
            coordinator.canvasViewDidBeginUsingTool(canvas)
            canvas.drawing = PKDrawing(strokes: [oldInk, stroke(scratchPoints)])
            coordinator.canvasViewDrawingDidChange(canvas)
            coordinator.canvasViewDidEndUsingTool(canvas)
            try await Task.sleep(for: .milliseconds(240))
            XCTAssertTrue(ended)
            XCTAssertEqual(canvas.drawing.strokes.count, enabled ? 0 : 2)
            XCTAssertEqual(coordinator.lastInkEditWasScribble, enabled,
                           "Scratch completion must suppress handwriting OCR and question detection")
            coordinator.canvasViewDidBeginUsingTool(canvas)
            XCTAssertFalse(coordinator.lastInkEditWasScribble, "Ordinary new handwriting must resume recognition")
            coordinator.cancelShapeRecognition()
        }
    }

    func testNativeInkZoomPreservesPageGeometryAndTouchCoordinates() {
        let canvas = PencilInputCanvasView()
        canvas.isScrollEnabled = false
        let original = PKDrawing(strokes: [stroke([CGPoint(x: 60, y: 25), CGPoint(x: 60, y: 80)])])
        canvas.drawing = original
        let viewport = InkCanvasViewport(canvas: canvas)
        viewport.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        for zoom: CGFloat in [0.7, 1, 2, 4] {
            viewport.update(pageSize: viewport.bounds.size, zoom: zoom)
            XCTAssertEqual(canvas.zoomScale, zoom, accuracy: 0.001)
            XCTAssertEqual(canvas.frame.width, 600, accuracy: 0.01)
            XCTAssertEqual(canvas.frame.height, 800, accuracy: 0.01)
            let point = CGPoint(x: 90, y: 140)
            let local = canvas.convert(point, from: viewport)
            let pagePoint = canvas.pagePoint(from: local)
            XCTAssertEqual(pagePoint.x, point.x, accuracy: 0.01)
            XCTAssertEqual(pagePoint.y, point.y, accuracy: 0.01)
            XCTAssertEqual(canvas.drawing, original)
        }
    }

    func testNativeInkZoomWaitsUntilThePenLifts() {
        let canvas = PencilInputCanvasView()
        let viewport = InkCanvasViewport(canvas: canvas)
        viewport.update(pageSize: CGSize(width: 600, height: 800), zoom: 1)
        viewport.isUsingTool = true
        viewport.updateZoom(3)
        XCTAssertEqual(canvas.zoomScale, 1)
        viewport.isUsingTool = false
        XCTAssertEqual(canvas.zoomScale, 3)
    }

    private func stroke(_ locations: [CGPoint]) -> PKStroke {
        // Pencil input supplies dense control points; a six-point synthetic
        // zigzag is smoothed into a different curve by PKStrokePath itself.
        var dense: [CGPoint] = []
        for (a, b) in zip(locations, locations.dropFirst()) {
            let count = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 4))
            for step in 0..<count {
                let t = CGFloat(step) / CGFloat(count)
                dense.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        if let last = locations.last { dense.append(last) }
        let points = dense.enumerated().map { index, location in
            PKStrokePoint(location: location, timeOffset: Double(index) * 0.02, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: .now))
    }
}
