import Foundation
import PencilKit
import UIKit
import Vision

enum HandwritingOCR {
    static func recognizeText(from inkData: Data?, pageSize: CGSize) async -> String {
        guard let inkData,
              let drawing = try? PKDrawing(data: inkData) else {
            return ""
        }
        return await recognizeText(from: drawing, pageSize: pageSize)
    }

    static func recognizeLines(from inkData: Data?, pageSize: CGSize) async -> [RecognizedLine] {
        guard let inkData,
              let drawing = try? PKDrawing(data: inkData) else {
            return []
        }
        return await recognizeLines(from: drawing, pageSize: pageSize)
    }

    /// One recognized line, with where it sits **in page coordinates**.
    ///
    /// Vision reports a normalized box inside the cropped image it was handed;
    /// on its own that is unusable for placing anything on the page, so the
    /// crop rect is folded back in here rather than at each call site.
    struct RecognizedLine: Equatable, Sendable {
        let text: String
        let bounds: CGRect
        /// Vision's confidence in `text`, 0...1. Nothing downstream enforces
        /// a threshold on this yet -- it exists so a low-confidence line can
        /// be told apart from a high-confidence one instead of both looking
        /// like equally-trustworthy text.
        let confidence: Float
    }

    /// Recognize a drawing directly, without a round trip through `Data`.
    ///
    /// The lasso hands us a `PKDrawing` assembled from the selected strokes, so
    /// re-encoding it only to decode it again would be pure waste. Every helper
    /// below already worked on a drawing; this is the entry point that says so.
    static func recognizeText(from drawing: PKDrawing, pageSize: CGSize) async -> String {
        let lines = await recognizeLines(from: drawing, pageSize: pageSize)
        return lines.map(\.text).joined(separator: "\n")
    }

    static func recognizeLines(from drawing: PKDrawing, pageSize: CGSize) async -> [RecognizedLine] {
        guard !drawing.strokes.isEmpty else { return [] }

        let recognitionDrawing = normalizedDrawing(for: drawing)
        let recognitionRect = cropRect(for: recognitionDrawing, pageSize: pageSize)
        let image = await renderImage(
            for: recognitionDrawing,
            rect: recognitionRect,
            scale: renderScale(for: recognitionRect)
        )
        guard let cgImage = image.cgImage else { return [] }

        return await withTaskCancellationHandler(operation: {
            await Task.detached(priority: .utility) {
                performRecognition(on: cgImage, cropRect: recognitionRect)
            }.value
        }, onCancel: {
            // The Vision request runs synchronously inside performRecognition,
            // so we can't truly cancel mid-flight. But wrapping in the
            // cancellation handler lets the awaiter bail if the Task was
            // cancelled before we entered the detached call.
        })
    }

    @MainActor
    static func renderImage(for drawing: PKDrawing, rect: CGRect, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        format.preferredRange = .standard

        let outputRect = CGRect(origin: .zero, size: rect.size)
        let renderer = UIGraphicsImageRenderer(size: rect.size, format: format)
        var image = UIImage()
        // PencilKit adapts black ink to white under Dark Mode even when the
        // receiving bitmap has a white background. Vision then sees a blank
        // page and cannot recognize a newly written question.
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = renderer.image { context in
                UIColor.white.setFill()
                context.fill(outputRect)

                drawing.image(from: rect, scale: scale).draw(in: outputRect)
            }
        }
        return image
    }

    private static func performRecognition(on cgImage: CGImage, cropRect: CGRect) -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        if #available(iOS 16.0, *) {
            request.revision = VNRecognizeTextRequestRevision3
        }
        request.recognitionLevel = .accurate
        // Confirmed live against real handwritten math (arctan/arcsin
        // homework): with language correction and auto language-detection on,
        // Vision "corrects" handwriting toward whatever language's dictionary
        // it guessed -- observed substituting whole runs of random Chinese
        // characters into what was actually English math notation, and
        // separately collapsing a literal "??" (the ink-question trigger,
        // see InkQuestionDetector) down to a single "?". Both behaviors bias
        // toward natural-language prose, which handwritten equations and
        // short symbol-heavy annotations are not. Pin to English and take
        // Vision's raw stroke-shape reading over its "corrected" guess.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        // minimumTextHeight MUST be > 0; 0 is rejected by Vision and makes
        // the entire request throw, silently returning no recognized text.
        // 0.02 keeps short words/captions detectable while filtering noise.
        request.minimumTextHeight = 0.02
        // Foreground tier: the calling Task.detached already moves us off the
        // main actor. Background processing adds multi-second latency that is
        // not acceptable for an interactive recognize-now action.
        request.preferBackgroundProcessing = false

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            // Distinguish "Vision threw" from "there was no text" -- both
            // used to collapse into the same empty result, which made a
            // real Vision-level failure indistinguishable from blank ink.
            #if DEBUG
            print("[HandwritingOCR] VNImageRequestHandler.perform failed: \(error)")
            #endif
            return []
        }

        return recognizedLines(from: request.results ?? [], cropRect: cropRect)
    }

    private static func recognizedLines(
        from observations: [VNRecognizedTextObservation],
        cropRect: CGRect
    ) -> [RecognizedLine] {
        observations
            .sorted { lhs, rhs in
                let rowDistance = abs(lhs.boundingBox.midY - rhs.boundingBox.midY)
                if rowDistance > 0.025 {
                    return lhs.boundingBox.midY > rhs.boundingBox.midY
                }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            .compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return RecognizedLine(
                    text: text,
                    bounds: pageRect(of: observation.boundingBox, in: cropRect),
                    confidence: candidate.confidence
                )
            }
    }

    /// Vision's normalized, bottom-left-origin box mapped back onto the page.
    private static func pageRect(of boundingBox: CGRect, in cropRect: CGRect) -> CGRect {
        CGRect(
            x: cropRect.minX + boundingBox.minX * cropRect.width,
            y: cropRect.minY + (1 - boundingBox.maxY) * cropRect.height,
            width: boundingBox.width * cropRect.width,
            height: boundingBox.height * cropRect.height
        )
    }

    private static func normalizedDrawing(for drawing: PKDrawing) -> PKDrawing {
        let recognitionInk = PKInk(.pen, color: .black)
        let strokes = drawing.strokes.map { stroke in
            PKStroke(
                ink: recognitionInk,
                path: stroke.path,
                transform: stroke.transform,
                mask: stroke.mask
            )
        }
        return PKDrawing(strokes: strokes)
    }

    private static func cropRect(for drawing: PKDrawing, pageSize: CGSize) -> CGRect {
        let pageRect = CGRect(origin: .zero, size: pageSize)
        let bounds = drawing.bounds
        guard bounds.isNull == false,
              bounds.isEmpty == false,
              bounds.width.isFinite,
              bounds.height.isFinite else {
            return pageRect
        }

        let margin = max(36, max(bounds.width, bounds.height) * 0.08)
        let expanded = bounds.insetBy(dx: -margin, dy: -margin)
        let clipped = expanded.intersection(pageRect)
        guard clipped.isNull == false, clipped.isEmpty == false else {
            return pageRect
        }
        return clipped.integral
    }

    private static func renderScale(for rect: CGRect) -> CGFloat {
        let longestEdge = max(rect.width, rect.height)
        guard longestEdge.isFinite, longestEdge > 0 else { return 3 }

        let targetLongestEdge: CGFloat = 3600
        return min(max(targetLongestEdge / longestEdge, 3), 6)
    }
}
