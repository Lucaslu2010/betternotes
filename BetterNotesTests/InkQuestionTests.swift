import CoreGraphics
import XCTest
@testable import BetterNotes

/// Asking a question by writing it has two halves that can be wrong quietly.
///
/// The detector decides whether a request is sent at all -- fire it on ordinary
/// punctuation and the app spends the user's own provider key uninvited; fire
/// it twice on the same sentence and it does so repeatedly. The placement
/// decides where the answer lands, and an answer dropped on top of the
/// handwriting it answers destroys the note it was meant to serve.
final class InkQuestionTests: XCTestCase {

    // MARK: - Detecting the question

    func testADoubledQuestionMarkIsTheTrigger() {
        XCTAssertTrue(InkQuestionDetector.isQuestion("why is the h silent??"))
        XCTAssertFalse(InkQuestionDetector.isQuestion("why is the h silent?"))
        XCTAssertFalse(InkQuestionDetector.isQuestion("why is the h silent"))
    }

    func testAnOrdinaryQuestionInNotesIsNotAsked() {
        // A single "?" is normal punctuation, and Vision routinely invents one
        // out of a stray descender. Only the deliberate doubling counts.
        let text = "Lecture 4\nDoes stress shift with the vowel?\nCheck Gorner p.12"
        XCTAssertNil(InkQuestionDetector.question(in: text))
    }

    func testTheTriggerMarksAreStrippedFromTheQuestionSent() {
        XCTAssertEqual(
            InkQuestionDetector.question(in: "why is the h silent??"),
            "why is the h silent?"
        )
    }

    func testBareQuestionMarksAreNotAQuestion() {
        XCTAssertFalse(InkQuestionDetector.isQuestion("??"))
        XCTAssertNil(InkQuestionDetector.question(in: "??"))
    }

    func testTheMostRecentQuestionWins() {
        let text = "an older thought??\nsome notes\nthe one I just wrote??"
        XCTAssertEqual(InkQuestionDetector.question(in: text), "the one I just wrote?")
    }

    func testAnAlreadyAnsweredQuestionIsNotOfferedAgain() {
        // OCR reruns a second after every stroke. Without the fingerprint
        // guard, one sentence is offered over and over as the page is written.
        let text = "why is the h silent??"
        let first = try! XCTUnwrap(InkQuestionDetector.question(in: text))
        let handled: Set<Int> = [InkQuestion.fingerprint(of: first)]
        XCTAssertNil(InkQuestionDetector.question(in: text, alreadyAnswered: handled))
    }

    func testRecognitionDriftDoesNotCountAsANewQuestion() {
        // Vision's output wobbles in case and punctuation between passes over
        // the same ink; the fingerprint has to see through that.
        XCTAssertEqual(
            InkQuestion.fingerprint(of: "Why is the H silent?"),
            InkQuestion.fingerprint(of: "why is the h  silent")
        )
    }

    // MARK: - Placing the answer

    private let pageSize = CGSize(width: 768, height: 1024)

    func testAnAnswerGoesBelowTheQuestionWhenThereIsRoom() {
        let question = CGRect(x: 80, y: 200, width: 300, height: 40)
        let frame = AnswerPlacement.frame(
            for: CGSize(width: 320, height: 150),
            near: question,
            avoiding: [],
            pageSize: pageSize
        )
        XCTAssertGreaterThanOrEqual(frame.minY, question.maxY, "the answer covered the question")
        XCTAssertFalse(frame.intersects(question))
    }

    func testAnAnswerMovesAsideWhenTheSpaceBelowIsTaken() {
        let question = CGRect(x: 60, y: 200, width: 260, height: 40)
        let occupied = CGRect(x: 40, y: 250, width: 320, height: 400)
        let frame = AnswerPlacement.frame(
            for: CGSize(width: 300, height: 150),
            near: question,
            avoiding: [occupied],
            pageSize: pageSize
        )
        XCTAssertFalse(frame.intersects(occupied), "the answer landed on existing content")
        XCTAssertFalse(frame.intersects(question))
    }

    func testAnAnswerNextToTheBottomEdgeStaysOnThePage() {
        let question = CGRect(x: 300, y: 990, width: 200, height: 30)
        let frame = AnswerPlacement.frame(
            for: CGSize(width: 320, height: 200),
            near: question,
            avoiding: [],
            pageSize: pageSize
        )
        XCTAssertTrue(
            CGRect(origin: .zero, size: pageSize).contains(frame),
            "the answer was placed off the page: \(frame)"
        )
    }

    func testAnAnswerWiderThanThePageIsNarrowedRatherThanClipped() {
        let frame = AnswerPlacement.frame(
            for: CGSize(width: 5_000, height: 150),
            near: CGRect(x: 100, y: 100, width: 100, height: 20),
            avoiding: [],
            pageSize: pageSize
        )
        XCTAssertTrue(CGRect(origin: .zero, size: pageSize).contains(frame), "\(frame)")
    }

    func testACrowdedPageStillPlacesTheAnswerSomewhereOnIt() {
        // Every candidate collides. It has to land somewhere visible rather
        // than nowhere, so the least-crowded choice is taken.
        let question = CGRect(x: 300, y: 500, width: 160, height: 30)
        let wall = (0..<8).map { CGRect(x: 0, y: $0 * 128, width: 768, height: 128) }
        let frame = AnswerPlacement.frame(
            for: CGSize(width: 300, height: 150),
            near: question,
            avoiding: wall,
            pageSize: pageSize
        )
        XCTAssertTrue(CGRect(origin: .zero, size: pageSize).contains(frame), "\(frame)")
    }

    // MARK: - What the element carries

    func testTheAnswerPayloadSurvivesEncoding() {
        let citation = SourceCitation(
            notebookID: UUID(), pageID: UUID(),
            sourceLabel: "Gorner", excerpt: "…", token: "S1"
        )
        let payload = AssistantNotePayload(
            question: "why is the h silent?",
            citations: [citation],
            anchor: CGPoint(x: 120, y: 240),
            isStreaming: true,
            notice: "on device"
        )
        let decoded = AssistantNotePayload.decode(payload.encoded)
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded?.anchor, CGPoint(x: 120, y: 240))
    }

    func testADecodeOfNothingIsNothing() {
        XCTAssertNil(AssistantNotePayload.decode(nil))
        XCTAssertNil(AssistantNotePayload.decode(Data("not json".utf8)))
    }

    func testOlderAnswerCardWithoutFailureFlagStillDecodes() throws {
        let oldCard = Data(#"{"question":"Why?","citations":[],"anchorX":0,"anchorY":0,"isStreaming":false}"#.utf8)
        let payload = try XCTUnwrap(AssistantNotePayload.decode(oldCard))
        XCTAssertNil(payload.didFail)
        XCTAssertEqual(payload.question, "Why?")
    }

    // MARK: - The assistant's own answers are not evidence

    func testAnAssistantAnswerIsIndexedButNeverCited() {
        // Retrieval that offered these back as sources would let the model
        // cite its own earlier guess as though a note had said it.
        XCTAssertFalse(NoteSourceKind.assistantAnswer.isCitable)
        XCTAssertTrue(NoteSourceKind.ocr.isCitable)
        XCTAssertLessThan(
            NoteSourceKind.assistantAnswer.fieldWeight,
            NoteSourceKind.ocr.fieldWeight,
            "an assistant answer outranked the user's own handwriting"
        )
    }
}
