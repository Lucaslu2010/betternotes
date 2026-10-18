import Combine
import CryptoKit
import Foundation
import PencilKit
import UIKit

/// A local marker match handed to the notebook before content OCR starts.
struct HandwrittenQuestionRequest {
    let page: Page
    let inkData: Data
    let pageSize: CGSize
    let region: CGRect
    let fingerprint: String
    var anchorBounds: CGRect? = nil
}

/// PKDrawing(strokes:) creates new archive identity even for identical ink.
/// Hash the visible stroke content instead of those archive bytes. Small
/// coordinate quantization tolerates floating-point archive round trips.
enum QuestionInkFingerprint {
    static func make(in drawing: PKDrawing, region: CGRect) -> String {
        var hash = SHA256()
        func number(_ value: CGFloat) {
            let rounded = (value * 1024).rounded() / 1024
            var bits = Double(rounded == 0 ? 0 : rounded).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { hash.update(bufferPointer: $0) }
        }
        let strokes = drawing.strokes.filter { $0.renderBounds.intersects(region) }
        number(CGFloat(strokes.count))
        for stroke in strokes {
            let t = stroke.transform
            for value in [t.a, t.b, t.c, t.d, t.tx, t.ty] { number(value) }
            number(CGFloat(stroke.path.count))
            for point in stroke.path {
                for value in [point.location.x, point.location.y, point.size.width, point.size.height,
                              point.opacity, point.force, point.azimuth, point.altitude, point.secondaryScale] {
                    number(value)
                }
            }
            if let mask = stroke.mask {
                number(1)
                number(mask.usesEvenOddFillRule ? 1 : 0)
                mask.cgPath.applyWithBlock { element in
                    let element = element.pointee
                    number(CGFloat(element.type.rawValue))
                    let count: Int
                    switch element.type {
                    case .moveToPoint, .addLineToPoint: count = 1
                    case .addQuadCurveToPoint: count = 2
                    case .addCurveToPoint: count = 3
                    case .closeSubpath: count = 0
                    @unknown default: count = 0
                    }
                    for index in 0..<count {
                        number(element.points[index].x)
                        number(element.points[index].y)
                    }
                }
            } else { number(0) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class OCRService: ObservableObject {
    let settings: OCRSettingsStore
    let client: OCRClient

    init(settings: OCRSettingsStore, client: OCRClient = OCRClient()) {
        self.settings = settings
        self.client = client
    }

    func recognizeInk(_ data: Data?, pageSize: CGSize, region: CGRect? = nil) async throws -> String {
        try Task.checkCancellation()
        guard let data else { return "" }
        guard let drawing = try? PKDrawing(data: data) else { throw OCRError.unreadableImage }
        guard !drawing.strokes.isEmpty else { return "" }
        let identity = settings.identity
        let text: String
        if settings.provider == .local {
            text = await HandwritingOCR.recognizeText(from: data, pageSize: pageSize, region: region)
        } else {
            guard let configuration = settings.configuration else { throw OCRError.missingToken }
            let image = await HandwritingOCR.imageData(from: data, pageSize: pageSize, region: region)
            try Task.checkCancellation()
            guard let image else { throw OCRError.unreadableImage }
            text = try await client.recognize(imageData: image, configuration: configuration)
        }
        try Task.checkCancellation()
        guard settings.identity == identity else { throw CancellationError() }
        return text
    }

    /// Refresh only changed ink. Called for explicit search/assistant requests;
    /// ordinary custom-mode drawing only scans for the local ?? marker.
    func refresh(pages: [Page], force: Bool = false) async throws {
        let activity = MemoryDiagnostics.begin("ocr-refresh", details: "pages=\(pages.count)")
        defer { activity.end() }
        for page in pages {
            try Task.checkCancellation()
            guard page.modelContext != nil, page.trashedAt == nil else { continue }
            let data = page.inkData
            let fingerprint = Self.fingerprint(data)
            let identity = settings.identity
            if force || page.ocrInkFingerprint != fingerprint || page.ocrProviderIdentity != identity {
                let text = try await recognizeInk(data, pageSize: page.pageOrientation.size)
                try Task.checkCancellation()
                guard page.modelContext != nil, page.trashedAt == nil,
                      page.inkData == data, settings.identity == identity else { throw CancellationError() }
                page.prepareOCRStorage()
                page.ocrText = text
                page.ocrUpdatedAt = .now
                page.ocrInkFingerprint = fingerprint
                page.ocrProviderIdentity = identity
            }
            for element in page.elements where element.type == .image {
                // Native PDF text is already exact; only scanned PDF images
                // need recognition. Other photos use the selected provider.
                if element.isLocked && !page.pdfText.isEmpty { continue }
                guard let image = element.imageData else { continue }
                let fingerprint = Self.fingerprint(image)
                if !force && element.ocrImageFingerprint == fingerprint && element.imageOCRProviderIdentity == identity { continue }
                let text: String
                if settings.provider == .custom {
                    guard let configuration = settings.configuration else { throw OCRError.missingToken }
                    guard let png = await HandwritingOCR.preparedImageData(from: image) else { throw OCRError.unreadableImage }
                    try Task.checkCancellation()
                    text = try await client.recognize(imageData: png, configuration: configuration)
                } else {
                    text = await HandwritingOCR.recognizeImage(from: image)
                }
                try Task.checkCancellation()
                guard page.modelContext != nil, page.trashedAt == nil,
                      element.modelContext != nil, element.imageData == image,
                      settings.identity == identity else { throw CancellationError() }
                element.text = text
                element.ocrImageFingerprint = fingerprint
                element.imageOCRProviderIdentity = identity
            }
        }
    }

    nonisolated static func fingerprint(_ data: Data?) -> String {
        SHA256.hash(data: data ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
}
