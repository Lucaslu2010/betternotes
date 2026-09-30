import Foundation
import UIKit
import Vision

enum SmartImageExtractor {
    struct Extraction {
        let extractedText: String
        let originalImageData: Data
        let originalImageSize: CGSize

        var hasExtractedText: Bool {
            !extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private struct TextRegion {
        let text: String
        let confidence: Float
        let boundingBox: CGRect
    }

    static func extract(from imageData: Data) async -> Extraction {
        guard let image = UIImage(data: imageData),
              let normalized = normalizedImage(image),
              let cgImage = normalized.cgImage else {
            return Extraction(extractedText: "", originalImageData: imageData, originalImageSize: .zero)
        }

        // Vision's text recognition is markedly more accurate on handwriting
        // when the image's longest edge is at least ~2000px. Upscale small
        // source photos before recognition so short notes/captions don't get
        // misread. The stored image remains the original data.
        let recognitionImage = upscaleForRecognition(cgImage)

        let regions = await recognizeTextRegions(in: recognitionImage)
        let extractedText = recognizedText(from: regions)
        return Extraction(
            extractedText: extractedText,
            originalImageData: imageData,
            originalImageSize: CGSize(width: cgImage.width, height: cgImage.height)
        )
    }

    private static func recognizeTextRegions(in cgImage: CGImage) async -> [TextRegion] {
        await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            if #available(iOS 16.0, *) {
                request.revision = VNRecognizeTextRequestRevision3
                request.automaticallyDetectsLanguage = true
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // minimumTextHeight must be > 0; 0 is rejected by Vision and would
            // make the whole request throw. A small value keeps short labels/
            // captions detectable while filtering out single-pixel noise.
            request.minimumTextHeight = 0.02
            // Interactive import: keep recognition on-device but in the
            // foreground tier so the user isn't blocked for several seconds
            // after picking a photo. Task.detached already moves us off the
            // main actor.
            request.preferBackgroundProcessing = false

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return []
            }

            return (request.results ?? []).compactMap { observation in
                // Pull up to 3 candidates and pick the highest-confidence one
                // that isn't empty. Using more than 1 candidate lets Vision's
                // language model recover words it would otherwise drop.
                let candidate = observation.topCandidates(3)
                    .map { ($0.string, $0.confidence) }
                    .max(by: { $0.1 < $1.1 })
                guard let candidate else { return nil }
                let text = candidate.0.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TextRegion(
                    text: text,
                    confidence: candidate.1,
                    boundingBox: observation.boundingBox
                )
            }
        }.value
    }

    private static func recognizedText(from regions: [TextRegion]) -> String {
        regions
            .filter { $0.confidence >= 0.18 }
            .sorted { lhs, rhs in
                let rowDistance = abs(lhs.boundingBox.midY - rhs.boundingBox.midY)
                if rowDistance > 0.025 {
                    return lhs.boundingBox.midY > rhs.boundingBox.midY
                }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            .map(\.text)
            .joined(separator: "\n")
    }

    private static func normalizedImage(_ image: UIImage) -> UIImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }

        let pixelSize = CGSize(
            width: max(1, image.size.width * image.scale),
            height: max(1, image.size.height * image.scale)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard

        return UIGraphicsImageRenderer(size: pixelSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: pixelSize))
            image.draw(in: CGRect(origin: .zero, size: pixelSize))
        }
    }

    /// Upscales small images so the longest edge is at least ~2200px before
    /// handing them to Vision. Vision's handwriting model is trained on
    /// reasonably high-resolution input; phone photos of small notes are often
    /// 600–1200px on the long edge, which produces weak or empty recognition.
    /// Upscaling improves recognition without changing the stored image.
    private static func upscaleForRecognition(_ cgImage: CGImage) -> CGImage {
        let longestEdge = max(cgImage.width, cgImage.height)
        let target: CGFloat = 2200
        guard CGFloat(longestEdge) < target else { return cgImage }

        let scale = target / CGFloat(longestEdge)
        let newWidth = Int((CGFloat(cgImage.width) * scale).rounded())
        let newHeight = Int((CGFloat(cgImage.height) * scale).rounded())

        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return cgImage
        }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage() ?? cgImage
    }
}
