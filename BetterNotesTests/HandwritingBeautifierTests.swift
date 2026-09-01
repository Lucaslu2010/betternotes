import XCTest
import PencilKit
import UIKit
@testable import BetterNotes

/// The beautifier rewrites strokes the user has already written, in place.
/// It had no coverage, and the failure modes are quiet ones: ink that drifts
/// away from where it was drawn, a colour that changes, a pass that empties a
/// stroke. None of them announce themselves — you notice a week later that
/// your notes moved.
final class HandwritingBeautifierTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HandwritingBeautifier.resetProfile()
    }

    override func tearDown() {
        HandwritingBeautifier.resetProfile()
        super.tearDown()
    }

    private func stroke(_ points: [CGPoint], color: UIColor = .black) -> PKStroke {
        let controlPoints = points.enumerated().map { index, point in
            PKStrokePoint(
                location: point,
                timeOffset: TimeInterval(index) * 0.004,
                size: CGSize(width: 3, height: 3),
                opacity: 1,
                force: 0.7,
                azimuth: 0.25,
                altitude: .pi / 3
            )
        }
        return PKStroke(ink: PKInk(.pen, color: color),
                        path: PKStrokePath(controlPoints: controlPoints, creationDate: .now))
    }

    /// A shaky horizontal line — the thing the beautifier exists to clean up.
    private func shakyLine(points count: Int = 40) -> [CGPoint] {
        (0..<count).map { index in
            CGPoint(x: 40 + CGFloat(index) * 5,
                    y: 100 + (index % 2 == 0 ? 1.5 : -1.5))
        }
    }

    func testBeautifyingKeepsEveryStrokeAndEveryPoint() {
        let strokes = [stroke(shakyLine()), stroke(shakyLine(points: 12))]
        let result = HandwritingBeautifier.beautified(strokes: strokes)
        XCTAssertEqual(result.count, strokes.count)
        for (before, after) in zip(strokes, result) {
            XCTAssertEqual(Array(after.path).count, Array(before.path).count,
                           "the beautifier changed how many points a stroke has")
        }
    }

    func testTheEndpointsDoNotMove() {
        // Writing that drifts is worse than writing that shakes: a smoothed
        // word must still start and end where the user put it.
        let source = stroke(shakyLine())
        let result = HandwritingBeautifier.beautified(strokes: [source])[0]
        let before = Array(source.path), after = Array(result.path)
        XCTAssertEqual(after.first!.location.x, before.first!.location.x, accuracy: 0.001)
        XCTAssertEqual(after.first!.location.y, before.first!.location.y, accuracy: 0.001)
        XCTAssertEqual(after.last!.location.x, before.last!.location.x, accuracy: 0.001)
        XCTAssertEqual(after.last!.location.y, before.last!.location.y, accuracy: 0.001)
    }

    func testSmoothingActuallyReducesTremor() {
        let source = stroke(shakyLine())
        let result = HandwritingBeautifier.beautified(strokes: [source])[0]
        func tremor(_ stroke: PKStroke) -> CGFloat {
            let ys = Array(stroke.path).map(\.location.y)
            return zip(ys, ys.dropFirst()).reduce(0) { $0 + abs($1.0 - $1.1) }
        }
        XCTAssertLessThan(tremor(result), tremor(source) * 0.9,
                          "beautifying left the shake untouched")
    }

    func testInkAndPerPointAttributesSurvive() {
        let source = stroke(shakyLine(), color: .systemBlue)
        let result = HandwritingBeautifier.beautified(strokes: [source])[0]
        XCTAssertEqual(result.ink.color, source.ink.color, "the stroke changed colour")
        XCTAssertEqual(result.ink.inkType, source.ink.inkType)
        let before = Array(source.path)[5], after = Array(result.path)[5]
        XCTAssertEqual(after.force, before.force, accuracy: 0.0001)
        XCTAssertEqual(after.size.width, before.size.width, accuracy: 0.0001)
        XCTAssertEqual(after.opacity, before.opacity, accuracy: 0.0001)
        XCTAssertEqual(after.timeOffset, before.timeOffset, accuracy: 0.0001)
    }

    func testAStrokeStaysWhereItWasDrawn() {
        let source = stroke(shakyLine())
        let result = HandwritingBeautifier.beautified(strokes: [source])[0]
        XCTAssertEqual(result.renderBounds.midX, source.renderBounds.midX, accuracy: 2)
        XCTAssertEqual(result.renderBounds.midY, source.renderBounds.midY, accuracy: 2)
    }

    func testAStrokeTooShortToSmoothIsReturnedUnchanged() {
        // Three points, and a path under the length floor: a dot on the page
        // must come back as the same dot.
        let dot = stroke([CGPoint(x: 10, y: 10), CGPoint(x: 11, y: 10), CGPoint(x: 12, y: 10)])
        let result = HandwritingBeautifier.beautified(strokes: [dot])[0]
        XCTAssertEqual(Array(result.path).map(\.location),
                       Array(dot.path).map(\.location))
    }

    func testABeautifiedDrawingKeepsItsStrokes() {
        let drawing = PKDrawing(strokes: [stroke(shakyLine()), stroke(shakyLine(points: 20))])
        let result = HandwritingBeautifier.beautified(drawing: drawing)
        XCTAssertEqual(result.strokes.count, 2)
        XCTAssertFalse(result.bounds.isEmpty)
    }

    // MARK: - The learned profile

    func testAFreshProfileSmoothsWithinItsDeclaredRange() {
        let profile = HandwritingBeautifier.profile
        XCTAssertEqual(profile.sampleCount, 0)
        XCTAssertGreaterThanOrEqual(profile.smoothingStrength, 0.28)
        XCTAssertLessThanOrEqual(profile.smoothingStrength, 0.52)
    }

    func testLearningRaisesConfidenceAndStaysInRange() {
        for _ in 0..<20 {
            HandwritingBeautifier.learn(from: [stroke(shakyLine())])
        }
        let profile = HandwritingBeautifier.profile
        XCTAssertGreaterThan(profile.sampleCount, 0, "learning recorded nothing")
        XCTAssertGreaterThan(profile.confidence, 0)
        XCTAssertLessThanOrEqual(profile.confidence, 1)
        // However much it learns, smoothing must stay inside the band the
        // profile promises — an unbounded strength would erase handwriting.
        XCTAssertGreaterThanOrEqual(profile.smoothingStrength, 0.28)
        XCTAssertLessThanOrEqual(profile.smoothingStrength, 0.52)
    }

    func testResettingForgetsWhatWasLearned() {
        for _ in 0..<5 { HandwritingBeautifier.learn(from: [stroke(shakyLine())]) }
        XCTAssertGreaterThan(HandwritingBeautifier.profile.sampleCount, 0)
        HandwritingBeautifier.resetProfile()
        XCTAssertEqual(HandwritingBeautifier.profile.sampleCount, 0)
    }
}
