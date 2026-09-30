import CoreGraphics
import Foundation

/// A question the user asked with ink rather than with the chat box.
///
/// `bounds` is in page coordinates and is what the answer is placed relative
/// to, so it travels with the text instead of being recomputed later from a
/// selection that may already have been cleared.
struct InkQuestion: Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String
    var bounds: CGRect

    init(id: UUID = UUID(), text: String, bounds: CGRect) {
        self.id = id
        self.text = text
        self.bounds = bounds
    }

    /// Stable identity for "have we already offered to answer this?".
    ///
    /// Handwriting OCR reruns on every stroke change, so the same sentence is
    /// recognized over and over. Hashing the normalized text -- rather than the
    /// raw recognition, which drifts by a character as neighbouring strokes
    /// change -- is what stops one question being offered a dozen times.
    var fingerprint: Int {
        Self.fingerprint(of: text)
    }

    static func fingerprint(of text: String) -> Int {
        normalized(text).hashValue
    }

    static func normalized(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Finds a handwritten question in recognized page text.
///
/// The trigger is a doubled question mark. A single `?` is far too common in
/// ordinary notes -- and Vision routinely hallucinates one out of a stray
/// descender -- so requiring two makes the gesture deliberate.
enum InkQuestionDetector {
    /// The last line ending in `??` that has not already been answered.
    ///
    /// Scans from the bottom because the question the user just wrote is the
    /// one they mean, not an older one further up the page.
    static func question(in recognizedText: String, alreadyAnswered: Set<Int> = []) -> String? {
        for line in candidateLines(in: recognizedText).reversed() {
            let fingerprint = InkQuestion.fingerprint(of: line)
            guard !alreadyAnswered.contains(fingerprint) else { continue }
            return line
        }
        return nil
    }

    /// Every line that reads as a question, oldest first.
    static func candidateLines(in recognizedText: String) -> [String] {
        recognizedText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { isQuestion($0) }
            .map { stripped($0) }
            .filter { !$0.isEmpty }
    }

    static func isQuestion(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("??") else { return false }
        // "??" on its own is a shrug, not a question.
        return !stripped(trimmed).isEmpty
    }

    /// The question without its trigger marks, restored to a single `?`.
    static func stripped(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("?") {
            text.removeLast()
        }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "" : text + "?"
    }
}

/// Chooses where an answer goes on the page.
///
/// Placing it at the page centre (which is what `insertAssistantResult` does)
/// drops it on top of whatever the user was writing. This looks for real
/// whitespace next to the question instead, and only falls back to overlapping
/// when the page has none left.
enum AnswerPlacement {
    /// Minimum gap between the answer and the thing it answers.
    static let gap: CGFloat = 16
    /// Keep the card off the very edge of the paper.
    static let margin: CGFloat = 20

    /// A **centre-based** frame, matching `PageElement.posX`/`posY` semantics.
    ///
    /// Candidates are tried below the question first (that is where a reply
    /// belongs when you are writing top to bottom), then to the right, left and
    /// above. The first candidate that fits the page and collides with nothing
    /// in `occupied` wins; if none does, the least-crowded candidate is used.
    static func frame(
        for size: CGSize,
        near questionBounds: CGRect,
        avoiding occupied: [CGRect],
        pageSize: CGSize
    ) -> CGRect {
        let size = CGSize(
            width: min(size.width, max(pageSize.width - margin * 2, 1)),
            height: min(size.height, max(pageSize.height - margin * 2, 1))
        )
        let anchor = questionBounds.isNull || questionBounds.isEmpty
            ? CGRect(x: pageSize.width / 2, y: pageSize.height / 3, width: 0, height: 0)
            : questionBounds

        let candidates = [
            CGPoint(x: anchor.midX, y: anchor.maxY + gap + size.height / 2),
            CGPoint(x: anchor.maxX + gap + size.width / 2, y: anchor.midY),
            CGPoint(x: anchor.minX - gap - size.width / 2, y: anchor.midY),
            CGPoint(x: anchor.midX, y: anchor.minY - gap - size.height / 2)
        ]

        var best: (frame: CGRect, overlap: CGFloat)?
        for candidate in candidates {
            let clamped = clampedCentre(candidate, size: size, pageSize: pageSize)
            let rect = centred(clamped, size: size)
            let overlap = overlapArea(of: rect, with: occupied + [anchor])
            if overlap == 0 { return rect }
            if best == nil || overlap < best!.overlap {
                best = (rect, overlap)
            }
        }
        return best?.frame ?? centred(
            clampedCentre(CGPoint(x: anchor.midX, y: anchor.maxY + gap + size.height / 2), size: size, pageSize: pageSize),
            size: size
        )
    }

    static func centred(_ centre: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
    }

    static func clampedCentre(_ centre: CGPoint, size: CGSize, pageSize: CGSize) -> CGPoint {
        let minX = size.width / 2 + margin
        let maxX = pageSize.width - size.width / 2 - margin
        let minY = size.height / 2 + margin
        let maxY = pageSize.height - size.height / 2 - margin
        return CGPoint(
            x: minX <= maxX ? min(max(centre.x, minX), maxX) : pageSize.width / 2,
            y: minY <= maxY ? min(max(centre.y, minY), maxY) : pageSize.height / 2
        )
    }

    private static func overlapArea(of rect: CGRect, with others: [CGRect]) -> CGFloat {
        others.reduce(0) { total, other in
            guard !other.isNull, !other.isEmpty else { return total }
            let intersection = rect.intersection(other)
            guard !intersection.isNull, !intersection.isEmpty else { return total }
            return total + intersection.width * intersection.height
        }
    }
}

/// What an `.assistantNote` element carries beyond its answer text.
///
/// One `Data` blob rather than four new `PageElement` properties: SwiftData has
/// to migrate every stored property, and the citation encoding already has a
/// precedent in `AssistantMessage.citationsData`.
struct AssistantNotePayload: Codable, Equatable, Sendable {
    var question: String
    var citations: [SourceCitation]
    var anchorX: Double
    var anchorY: Double
    var isStreaming: Bool
    var notice: String?
    /// Nil on older cards; false for completed answers, true for failed or
    /// interrupted attempts. Failed drafts must not become conversation memory.
    var didFail: Bool?

    init(
        question: String,
        citations: [SourceCitation] = [],
        anchor: CGPoint = .zero,
        isStreaming: Bool = false,
        notice: String? = nil,
        didFail: Bool? = nil
    ) {
        self.question = question
        self.citations = citations
        self.anchorX = Double(anchor.x)
        self.anchorY = Double(anchor.y)
        self.isStreaming = isStreaming
        self.notice = notice
        self.didFail = didFail
    }

    var anchor: CGPoint {
        get { CGPoint(x: anchorX, y: anchorY) }
        set {
            anchorX = Double(newValue.x)
            anchorY = Double(newValue.y)
        }
    }

    var encoded: Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(_ data: Data?) -> AssistantNotePayload? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(AssistantNotePayload.self, from: data)
    }
}
