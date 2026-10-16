import Foundation
import ImageIO
import PencilKit
import UIKit
import Vision

enum HandwritingOCR {
    struct Line: Sendable {
        let text: String
        /// Coordinates in the page's top-left-origin coordinate space.
        let bounds: CGRect
    }

    static func recognizeText(from inkData: Data?, pageSize: CGSize, region: CGRect? = nil) async -> String {
        await scan(from: inkData, pageSize: pageSize, region: region).map(\.text).joined(separator: "\n")
    }

    private static let worker = Worker()

    static func scan(from inkData: Data?, pageSize: CGSize, region: CGRect? = nil) async -> [Line] {
        let cancellation = RecognitionCancellation()
        return await withTaskCancellationHandler {
            await worker.scan(inkData: inkData, pageSize: pageSize, region: region, cancellation: cancellation)
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// OCR refresh needs only text, not the full-resolution crop produced by
    /// the photo-import feature. Decode a thumbnail directly from compressed data.
    static func recognizeImage(from data: Data) async -> String {
        let cancellation = RecognitionCancellation()
        return await withTaskCancellationHandler {
            await worker.scanImage(data, cancellation: cancellation).map(\.text).joined(separator: "\n")
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func imageData(from inkData: Data, pageSize: CGSize, region: CGRect? = nil) async -> Data? {
        await worker.imageData(inkData: inkData, pageSize: pageSize, region: region)
    }

    static func preparedImageData(from data: Data) async -> Data? {
        await worker.preparedImageData(from: data)
    }

    /// All local OCR and image preparation share one worker. No detached
    /// recognitions survive cancellation and accumulate full-page bitmaps.
    private actor Worker {
        func scan(inkData: Data?, pageSize: CGSize, region: CGRect?, cancellation: RecognitionCancellation) -> [Line] {
            let activity = MemoryDiagnostics.begin("vision-ink", details: "bytes=\(inkData?.count ?? 0)")
            defer { activity.end() }
            return autoreleasepool {
                guard !Task.isCancelled, !cancellation.isCancelled, let inkData,
                      let drawing = try? PKDrawing(data: inkData), !drawing.strokes.isEmpty else { return [] }
                let normalized = normalizedDrawing(for: drawing)
                let rect = region ?? cropRect(for: normalized, pageSize: pageSize)
                guard OCRImageBudget.isValid(rect.size), !cancellation.isCancelled else { return [] }
                let image = renderImage(for: normalized, rect: rect, scale: renderScale(for: rect))
                guard let cgImage = image.cgImage, !cancellation.isCancelled else { return [] }
                return performRecognition(on: cgImage, cancellation: cancellation).map { line in
                    Line(text: line.text, bounds: CGRect(
                        x: rect.minX + line.bounds.minX * rect.width,
                        y: rect.minY + (1 - line.bounds.maxY) * rect.height,
                        width: line.bounds.width * rect.width,
                        height: line.bounds.height * rect.height
                    ))
                }
            }
        }

        func scanImage(_ data: Data, cancellation: RecognitionCancellation) -> [Line] {
            let activity = MemoryDiagnostics.begin("vision-image", details: "bytes=\(data.count)")
            defer { activity.end() }
            return autoreleasepool {
                guard !Task.isCancelled, !cancellation.isCancelled,
                      let image = OCRImageBudget.thumbnail(from: data) else { return [] }
                return performRecognition(on: image, cancellation: cancellation)
            }
        }

        func imageData(inkData: Data, pageSize: CGSize, region: CGRect?) -> Data? {
            let activity = MemoryDiagnostics.begin("render-ink", details: "bytes=\(inkData.count)")
            defer { activity.end() }
            return autoreleasepool {
                guard !Task.isCancelled, let drawing = try? PKDrawing(data: inkData), !drawing.strokes.isEmpty else { return nil }
                let normalized = normalizedDrawing(for: drawing)
                let rect = region ?? cropRect(for: normalized, pageSize: pageSize)
                guard OCRImageBudget.isValid(rect.size) else { return nil }
                let image = renderImage(for: normalized, rect: rect, scale: renderScale(for: rect))
                guard !Task.isCancelled else { return nil }
                return image.pngData()
            }
        }

        func preparedImageData(from data: Data) -> Data? {
            let activity = MemoryDiagnostics.begin("render-image", details: "bytes=\(data.count)")
            defer { activity.end() }
            return autoreleasepool {
                guard !Task.isCancelled, let image = OCRImageBudget.thumbnail(from: data) else { return nil }
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination), !Task.isCancelled else { return nil }
                return output as Data
            }
        }
    }

    private static func renderImage(for drawing: PKDrawing, rect: CGRect, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        format.preferredRange = .standard
        let outputRect = CGRect(origin: .zero, size: rect.size)
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(outputRect)
            drawing.image(from: rect, scale: scale).draw(in: outputRect)
        }
    }

    private static func performRecognition(on cgImage: CGImage, cancellation: RecognitionCancellation) -> [Line] {
        let request = VNRecognizeTextRequest()
        guard cancellation.install(request) else { return [] }
        defer { cancellation.finish() }
        if #available(iOS 16.0, *) {
            request.revision = VNRecognizeTextRequestRevision3
            request.automaticallyDetectsLanguage = true
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.customWords = ["??", "？？"]
        request.minimumTextHeight = 0.02
        request.preferBackgroundProcessing = false
        do {
            try VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:]).perform([request])
        } catch { return [] }
        guard !cancellation.isCancelled else { return [] }
        return recognizedLines(from: request.results ?? [])
    }

    private final class RecognitionCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var request: VNRequest?

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func install(_ request: VNRequest) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { return false }
            self.request = request
            return true
        }

        func finish() {
            lock.lock()
            request = nil
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let active = request
            lock.unlock()
            active?.cancel()
        }
    }

    private static func recognizedLines(from observations: [VNRecognizedTextObservation]) -> [Line] {
        observations
            .sorted { lhs, rhs in
                let rowDistance = abs(lhs.boundingBox.midY - rhs.boundingBox.midY)
                if rowDistance > 0.025 {
                    return lhs.boundingBox.midY > rhs.boundingBox.midY
                }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            .compactMap { observation in
                guard let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return nil }
                return Line(text: text, bounds: observation.boundingBox)
            }
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
        OCRImageBudget.scale(for: rect.size, maximumScale: 6)
    }
}

/// Limit decoded OCR bitmaps before allocation, including unusually large
/// source photos and page sizes. Original note images remain untouched.
enum OCRImageBudget {
    static let maximumEdge: CGFloat = 3200
    static let maximumPixels: CGFloat = 6_000_000

    static func isValid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    static func scale(for size: CGSize, maximumScale: CGFloat = 1) -> CGFloat {
        guard isValid(size) else { return 1 }
        return min(maximumScale, maximumEdge / max(size.width, size.height),
                   sqrt(maximumPixels / size.width / size.height))
    }

    static func thumbnail(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        let size = CGSize(width: width, height: height)
        guard isValid(size) else { return nil }
        let edge = max(1, floor(max(width, height) * scale(for: size)))
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: edge
        ] as CFDictionary)
    }
}
