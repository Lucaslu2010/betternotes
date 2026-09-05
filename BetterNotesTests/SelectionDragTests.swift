import CoreGraphics
import XCTest
@testable import BetterNotes

/// Gesture streams as a finger actually produces them.
///
/// The oscillating-drag bug was found by driving a real iPad and tracing the
/// gesture frame by frame, because the accumulation lived inside a SwiftUI
/// view and nothing could reach it. `IncrementalDrag` exists so that class of
/// defect is reachable from a test, and these are written as sequences of
/// frames rather than single calls -- one call can never expose an
/// accumulation error.
final class IncrementalDragTests: XCTestCase {

    /// Feeds cumulative translations and returns the deltas, the way the
    /// gesture handler consumes them.
    private func deltas(_ translations: [CGSize]) -> [CGSize] {
        var drag = IncrementalDrag()
        return translations.map { drag.consume($0) }
    }

    /// The sum of the deltas is where the finger ended up. This is the whole
    /// contract: whatever the frame rate or the step size, a drag moves the
    /// selection by exactly the distance travelled.
    private func assertTracksFinger(
        _ translations: [CGSize], file: StaticString = #filePath, line: UInt = #line
    ) {
        let applied = deltas(translations).reduce(CGSize.zero) {
            CGSize(width: $0.width + $1.width, height: $0.height + $1.height)
        }
        let expected = translations.last ?? .zero
        XCTAssertEqual(applied.width, expected.width, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(applied.height, expected.height, accuracy: 0.0001, file: file, line: line)
    }

    // MARK: - The defect this type was extracted for

    func testASteadyDragNeverReversesDirection() {
        // The trace that exposed the bug read +12.3, -10.0, +13.3, -9.7 for a
        // drag that only ever went one way. No delta may be negative here.
        let frames = (1...40).map { CGSize(width: CGFloat($0) * 12.3, height: 0) }
        for delta in deltas(frames) {
            XCTAssertGreaterThan(delta.width, 0, "a one-direction drag produced a reversal")
        }
    }

    func testTheSelectionMovesExactlyAsFarAsTheFinger() {
        assertTracksFinger((1...40).map { CGSize(width: CGFloat($0) * 12.3, height: 0) })
    }

    func testCumulativeTranslationIsNotAppliedTwice() {
        // Applying `value.translation` directly -- the original mistake --
        // would move the selection 1+2+3 = 6 for a finger that travelled 3.
        let applied = deltas([
            CGSize(width: 1, height: 0),
            CGSize(width: 2, height: 0),
            CGSize(width: 3, height: 0),
        ]).reduce(0) { $0 + $1.width }
        XCTAssertEqual(applied, 3, accuracy: 0.0001)
    }

    // MARK: - Speed

    func testAFastFlickTracksTheFinger() {
        // A fast drag on a 120Hz display still reports every frame, but the
        // steps are large. Speed must not change the result.
        assertTracksFinger((1...20).map { CGSize(width: CGFloat($0) * 180, height: CGFloat($0) * -140) })
    }

    func testAFingerFasterThanTheFrameRateStillTracks() {
        // Frames dropped under load: the translation jumps in one step.
        assertTracksFinger([
            CGSize(width: 4, height: 4),
            CGSize(width: 900, height: -650),
            CGSize(width: 905, height: -655),
        ])
    }

    func testASingleFrameGestureAppliesTheWholeTranslation() {
        XCTAssertEqual(deltas([CGSize(width: 250, height: 130)]).first?.width, 250)
        XCTAssertEqual(deltas([CGSize(width: 250, height: 130)]).first?.height, 130)
    }

    func testSlowDragsWithSubPixelStepsAccumulateWithoutDrift() {
        // A slow, deliberate drag reports tiny steps. 600 of them must still
        // land exactly where the finger did, not somewhere 600 roundings away.
        assertTracksFinger((1...600).map { CGSize(width: CGFloat($0) * 0.05, height: CGFloat($0) * 0.05) })
    }

    // MARK: - Directions and reversals

    func testAGenuineReversalIsReported() {
        // Direction changes must survive: the guard is against phantom
        // reversals, not real ones.
        let frames = [
            CGSize(width: 50, height: 0),
            CGSize(width: 80, height: 0),
            CGSize(width: 30, height: 0),
        ]
        let result = deltas(frames)
        XCTAssertEqual(result[1].width, 30, accuracy: 0.0001)
        XCTAssertEqual(result[2].width, -50, accuracy: 0.0001)
    }

    func testADragBackToTheStartNetsZero() {
        assertTracksFinger([
            CGSize(width: 0, height: 0),
            CGSize(width: 120, height: 90),
            CGSize(width: 40, height: 20),
            CGSize(width: 0, height: 0),
        ])
    }

    func testBothAxesAreTrackedIndependently() {
        let result = deltas([
            CGSize(width: 10, height: 0),
            CGSize(width: 10, height: 25),
        ])
        XCTAssertEqual(result[1].width, 0, accuracy: 0.0001)
        XCTAssertEqual(result[1].height, 25, accuracy: 0.0001)
    }

    // MARK: - Repeated and interleaved gestures

    func testAStationaryFrameProducesNoMovement() {
        let result = deltas([
            CGSize(width: 30, height: 30),
            CGSize(width: 30, height: 30),
        ])
        XCTAssertEqual(result[1], .zero)
    }

    func testSkippingAZeroDeltaDoesNotDesynchronise() {
        // The call sites skip `onMove` when the delta is zero. Recording the
        // reading anyway must be harmless, or a pause mid-drag would jump.
        var drag = IncrementalDrag()
        _ = drag.consume(CGSize(width: 20, height: 0))
        _ = drag.consume(CGSize(width: 20, height: 0))   // pause; caller skips
        let resumed = drag.consume(CGSize(width: 26, height: 0))
        XCTAssertEqual(resumed.width, 6, accuracy: 0.0001)
    }

    func testASecondGestureStartsFromZeroAfterReset() {
        var drag = IncrementalDrag()
        _ = drag.consume(CGSize(width: 400, height: 400))
        drag.reset()
        // Without the reset this reads -390: the selection would leap back
        // across the page on the first frame of the next drag.
        XCTAssertEqual(drag.consume(CGSize(width: 10, height: 10)).width, 10, accuracy: 0.0001)
    }

    func testResettingMidGestureRebasesRatherThanRewinding() {
        var drag = IncrementalDrag()
        _ = drag.consume(CGSize(width: 100, height: 0))
        drag.reset()
        XCTAssertEqual(drag.consume(CGSize(width: 100, height: 0)).width, 100, accuracy: 0.0001)
    }

    func testManyGesturesInARowEachTrackTheirOwnFinger() {
        var drag = IncrementalDrag()
        for gesture in 1...25 {
            let travel = CGFloat(gesture) * 7
            var applied: CGFloat = 0
            for step in 1...6 {
                applied += drag.consume(CGSize(width: travel * CGFloat(step) / 6, height: 0)).width
            }
            XCTAssertEqual(applied, travel, accuracy: 0.0001, "gesture \(gesture) drifted")
            drag.reset()
        }
    }

    func testResetOnAFreshAccumulatorIsHarmless() {
        var drag = IncrementalDrag()
        drag.reset()
        XCTAssertEqual(drag.consume(CGSize(width: 5, height: 5)).width, 5, accuracy: 0.0001)
    }

    // MARK: - Degenerate input

    func testNegativeOnlyDragsTrack() {
        assertTracksFinger((1...30).map { CGSize(width: CGFloat($0) * -22, height: CGFloat($0) * -9) })
    }

    func testAZeroLengthGestureAppliesNothing() {
        XCTAssertEqual(deltas([.zero, .zero, .zero]).reduce(CGSize.zero) {
            CGSize(width: $0.width + $1.width, height: $0.height + $1.height)
        }, .zero)
    }
}

/// What the deltas are then applied to. A drag that tracks the finger can
/// still put the selection somewhere unusable, and these are the rules that
/// stop it.
final class SelectionDragClampingTests: XCTestCase {
    private let page = CGSize(width: 612, height: 792)

    func testAFastDragOffThePageIsBroughtBack() {
        // The realistic failure of a fast flick: the finger leaves the page.
        let flung = CGRect(x: 900, y: -400, width: 100, height: 80)
        let recovery = SelectionTransform.recoveryTranslation(for: flung, pageSize: page)
        let landed = flung.offsetBy(dx: recovery.width, dy: recovery.height)
        XCTAssertGreaterThanOrEqual(landed.minX, 0)
        XCTAssertGreaterThanOrEqual(landed.minY, 0)
        XCTAssertLessThanOrEqual(landed.maxX, page.width)
        XCTAssertLessThanOrEqual(landed.maxY, page.height)
    }

    func testASelectionAlreadyOnThePageIsNotNudged() {
        let settled = CGRect(x: 100, y: 100, width: 120, height: 90)
        XCTAssertEqual(SelectionTransform.recoveryTranslation(for: settled, pageSize: page), .zero)
    }

    func testASelectionWiderThanThePageIsCentredNotShoved() {
        let huge = CGRect(x: -300, y: 100, width: 1400, height: 90)
        let recovery = SelectionTransform.recoveryTranslation(for: huge, pageSize: page)
        XCTAssertEqual(huge.midX + recovery.width, page.width / 2, accuracy: 0.0001)
    }

    func testResizingToNothingIsFloored() {
        // Dragging a corner past the opposite one must not invert or vanish
        // the selection.
        let collapsed = CGRect(x: 50, y: 50, width: 0, height: 0)
        let clamped = SelectionTransform.clampedBounds(collapsed, pageSize: page)
        XCTAssertGreaterThanOrEqual(clamped.width, SelectionTransform.minimumDimension)
        XCTAssertGreaterThanOrEqual(clamped.height, SelectionTransform.minimumDimension)
    }

    func testClampingIsIdempotent() {
        // Every frame of a resize clamps. Clamping an already-clamped box must
        // not creep, or a held resize would walk the selection across the page.
        let once = SelectionTransform.clampedBounds(
            CGRect(x: -50, y: -50, width: 4000, height: 4000), pageSize: page)
        let twice = SelectionTransform.clampedBounds(once, pageSize: page)
        XCTAssertEqual(once, twice)
    }

    func testRecoveryIsIdempotent() {
        let flung = CGRect(x: 900, y: -400, width: 100, height: 80)
        let first = SelectionTransform.recoveryTranslation(for: flung, pageSize: page)
        let landed = flung.offsetBy(dx: first.width, dy: first.height)
        XCTAssertEqual(SelectionTransform.recoveryTranslation(for: landed, pageSize: page), .zero)
    }
}
