import Foundation
import PencilKit
import UIKit
import Vision

enum HandwritingOCR {
    static func recognizeText(from inkData: Data?, pageSize: CGSize) async -> String {
        guard let inkData,
              let drawing = try? PKDrawing(data: inkData),
              !drawing.strokes.isEmpty else {
            return ""
        }

        let recognitionDrawing = normalizedDrawing(for: drawing)
        let recognitionRect = cropRect(for: recognitionDrawing, pageSize: pageSize)
        let image = await renderImage(
            for: recognitionDrawing,
            rect: recognitionRect,
            scale: renderScale(for: recognitionRect)
        )
        guard let cgImage = image.cgImage else { return "" }

        return await withTaskCancellationHandler(operation: {
            await Task.detached(priority: .utility) {
                performRecognition(on: cgImage)
            }.value
        }, onCancel: {
            // The Vision request runs synchronously inside performRecognition,
            // so we can't truly cancel mid-flight. But wrapping in the
            // cancellation handler lets the awaiter bail if the Task was
            // cancelled before we entered the detached call.
        })
    }

    @MainActor
    private static func renderImage(for drawing: PKDrawing, rect: CGRect, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        format.preferredRange = .standard

        let outputRect = CGRect(origin: .zero, size: rect.size)
        let renderer = UIGraphicsImageRenderer(size: rect.size, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(outputRect)

            let inkImage = drawing.image(from: rect, scale: scale)
            inkImage.draw(in: outputRect)
        }
    }

    private static func performRecognition(on cgImage: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        if #available(iOS 16.0, *) {
            request.revision = VNRecognizeTextRequestRevision3
            request.automaticallyDetectsLanguage = true
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
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
            return ""
        }

        return recognizedText(from: request.results ?? [])
    }

    private static func recognizedText(from observations: [VNRecognizedTextObservation]) -> String {
        observations
            .sorted { lhs, rhs in
                let rowDistance = abs(lhs.boundingBox.midY - rhs.boundingBox.midY)
                if rowDistance > 0.025 {
                    return lhs.boundingBox.midY > rhs.boundingBox.midY
                }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
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
