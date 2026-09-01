import XCTest
import PencilKit
import UIKit
@testable import BetterNotes

/// ShapeSnapper is 568 lines of pure geometry with no coverage at all, and it
/// runs on every held stroke: get it wrong and a circle becomes a triangle
/// under the user's pen. The strokes here are drawn the way a hand draws
/// them — sampled densely, closed loosely, with a little jitter — because a
/// mathematically perfect polygon is not the input this code ever sees.
final class ShapeSnapperTests: XCTestCase {

    // MARK: - Building strokes a hand would plausibly make

    private func style() -> GeneratedShapeStyle {
        GeneratedShapeStyle(inkType: .pen, color: .black, opacity: 1, width: 3)
    }

    private func stroke(_ points: [CGPoint]) -> PKStroke {
        let controlPoints = points.enumerated().map { index, point in
            PKStrokePoint(
                location: point,
                timeOffset: TimeInterval(index) * 0.004,
                size: CGSize(width: 3, height: 3),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        return PKStroke(ink: PKInk(.pen, color: .black),
                        path: PKStrokePath(controlPoints: controlPoints, creationDate: .now))
    }

    /// Deterministic jitter, so a failure is reproducible.
    private func jitter(_ index: Int, _ amount: CGFloat) -> CGFloat {
        amount * CGFloat(sin(Double(index) * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
    }

    private func circlePoints(center: CGPoint, radius: CGFloat,
                              samples: Int = 64, wobble: CGFloat = 0) -> [CGPoint] {
        (0...samples).map { index in
            let angle = CGFloat(index) / CGFloat(samples) * 2 * .pi
            let r = radius + jitter(index, wobble)
            return CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
        }
    }

    /// Walks the outline so consecutive samples are close together, as a pen is.
    private func polygonPoints(_ vertices: [CGPoint], perEdge: Int = 16,
                               wobble: CGFloat = 0) -> [CGPoint] {
        var result: [CGPoint] = []
        for (index, start) in vertices.enumerated() {
            let end = vertices[(index + 1) % vertices.count]
            for step in 0..<perEdge {
                let t = CGFloat(step) / CGFloat(perEdge)
                result.append(CGPoint(
                    x: start.x + (end.x - start.x) * t + jitter(result.count, wobble),
                    y: start.y + (end.y - start.y) * t + jitter(result.count + 7, wobble)
                ))
            }
        }
        result.append(vertices[0])
        return result
    }

    // MARK: - What the snapper must recognise

    func testACleanCircleIsRecognisedAsAnEllipse() {
        let detected = ShapeSnapper.detect(from: stroke(circlePoints(center: CGPoint(x: 200, y: 200), radius: 80)))
        guard case .ellipse(let rect)? = detected else {
            return XCTFail("expected an ellipse, got \(String(describing: detected))")
        }
        XCTAssertEqual(rect.midX, 200, accuracy: 6)
        XCTAssertEqual(rect.midY, 200, accuracy: 6)
        XCTAssertEqual(rect.width, 160, accuracy: 12)
        XCTAssertEqual(rect.height, 160, accuracy: 12)
    }

    func testAHandDrawnCircleWithWobbleIsStillAnEllipse() {
        // A real circle is never clean. If a few points of wobble drop it out
        // of ellipse detection, the feature is useless on a real hand.
        let detected = ShapeSnapper.detect(from: stroke(
            circlePoints(center: CGPoint(x: 150, y: 150), radius: 70, wobble: 3)))
        guard case .ellipse = detected else {
            return XCTFail("expected an ellipse, got \(String(describing: detected))")
        }
    }

    func testAnOvalKeepsItsAspectRatherThanBecomingACircle() {
        let points = (0...64).map { index -> CGPoint in
            let angle = CGFloat(index) / 64 * 2 * .pi
            return CGPoint(x: 200 + cos(angle) * 120, y: 200 + sin(angle) * 50)
        }
        guard case .ellipse(let rect)? = ShapeSnapper.detect(from: stroke(points)) else {
            return XCTFail("expected an ellipse")
        }
        XCTAssertGreaterThan(rect.width / rect.height, 1.8,
                             "an oval flattened into a circle: \(rect)")
    }

    func testASquareIsRecognisedAsARectangle() {
        let square = [CGPoint(x: 100, y: 100), CGPoint(x: 260, y: 100),
                      CGPoint(x: 260, y: 260), CGPoint(x: 100, y: 260)]
        let detected = ShapeSnapper.detect(from: stroke(polygonPoints(square)))
        guard case .rectangle(let vertices)? = detected else {
            return XCTFail("expected a rectangle, got \(String(describing: detected))")
        }
        XCTAssertEqual(vertices.count, 4)
    }

    func testATriangleIsRecognisedAsAPolygonWithThreeVertices() {
        let triangle = [CGPoint(x: 200, y: 80), CGPoint(x: 300, y: 260), CGPoint(x: 100, y: 260)]
        let detected = ShapeSnapper.detect(from: stroke(polygonPoints(triangle)))
        switch detected {
        case .polygon(let vertices), .rectangle(let vertices):
            XCTAssertEqual(vertices.count, 3, "a triangle came back with \(vertices.count) vertices")
        default:
            XCTFail("expected a polygon, got \(String(describing: detected))")
        }
    }

    func testAStraightStrokeIsRecognisedAsALine() {
        let points = (0...40).map { CGPoint(x: 60 + CGFloat($0) * 6, y: 200) }
        guard case .line(let from, let to)? = ShapeSnapper.detect(from: stroke(points)) else {
            return XCTFail("expected a line, got \(String(describing: ShapeSnapper.detect(from: stroke(points))))")
        }
        XCTAssertEqual(from.y, to.y, accuracy: 2)
        XCTAssertEqual(abs(to.x - from.x), 240, accuracy: 6)
    }

    // MARK: - What it must NOT claim

    func testAShortScribbleIsLeftAlone() {
        // Below the size floor: snapping a stray dot would eat real ink.
        let points = [CGPoint(x: 10, y: 10), CGPoint(x: 13, y: 12), CGPoint(x: 15, y: 11)]
        XCTAssertNil(ShapeSnapper.detect(from: stroke(points)))
    }

    func testAnOpenSquiggleIsNotForcedIntoALine() {
        // A deliberate S-curve: open, long, and nowhere near straight.
        let points = (0...60).map { index -> CGPoint in
            let t = CGFloat(index) / 60
            return CGPoint(x: 60 + t * 240, y: 200 + sin(t * .pi * 2) * 60)
        }
        let detected = ShapeSnapper.detect(from: stroke(points))
        if case .line = detected {
            XCTFail("an S-curve was straightened into a line")
        }
    }

    func testTheSizeFloorIsWhatKeepsSmallMarksAsInk() {
        // detect() runs only after the press-and-hold recogniser fires, so a
        // deliberate hold over a small loop *should* snap — the user asked.
        // The floor is the whole protection against a stray dot or the tail
        // of a letter being rewritten, so pin it either side rather than
        // asserting a vaguer "handwriting is safe", which it is not required
        // to be.
        let tiny = circlePoints(center: CGPoint(x: 100, y: 100), radius: 4)
        XCTAssertNil(ShapeSnapper.detect(from: stroke(tiny)),
                     "a mark below the floor was snapped")

        let justBig = circlePoints(center: CGPoint(x: 100, y: 100), radius: 12)
        XCTAssertNotNil(ShapeSnapper.detect(from: stroke(justBig)),
                        "a deliberate small circle was refused")
    }

    // MARK: - The replacement stroke

    func testTheRenderedStrokeCarriesTheRequestedStyleAndStaysInPlace() {
        let source = stroke(circlePoints(center: CGPoint(x: 200, y: 200), radius: 60))
        guard let detected = ShapeSnapper.detect(from: source) else {
            return XCTFail("expected a shape")
        }
        let rendered = detected.renderedStroke(style: style())
        XCTAssertFalse(rendered.path.isEmpty)
        // It must replace the ink where it was drawn, not somewhere else.
        let bounds = rendered.renderBounds
        XCTAssertEqual(bounds.midX, source.renderBounds.midX, accuracy: 12)
        XCTAssertEqual(bounds.midY, source.renderBounds.midY, accuracy: 12)
    }

    func testEveryOfferedShapeKindProducesInk() {
        // makeShape backs the Insert > Shape menu; a kind that silently
        // produced nothing would put an empty selection on the page.
        let rect = CGRect(x: 50, y: 50, width: 120, height: 90)
        for kind in ShapeKind.allCases {
            let strokes = ShapeSnapper.makeShape(kind, in: rect, style: style())
            XCTAssertFalse(strokes.isEmpty, "\(kind) produced no strokes")
            for stroke in strokes {
                XCTAssertFalse(stroke.path.isEmpty, "\(kind) produced an empty path")
            }
        }
    }
}
