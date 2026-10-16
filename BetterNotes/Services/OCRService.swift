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
