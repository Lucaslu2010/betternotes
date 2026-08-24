import Foundation
import PDFKit
import UIKit

enum PDFImportError: LocalizedError {
    case unreadableDocument

    var errorDescription: String? {
        switch self {
        case .unreadableDocument:
            return "The selected PDF could not be opened."
        }
    }
}

enum PDFImporter {
    struct ImportedPage: Sendable {
        let orientation: String
        let imageData: Data?
        let imageFrame: CGRect
        let extractedText: String
    }

    static func pages(from url: URL) throws -> [ImportedPage] {
        let hasScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw PDFImportError.unreadableDocument
        }

        var importedPages: [ImportedPage] = []
        for pdfPageIndex in 0..<document.pageCount {
            // Wrap each page in an autoreleasepool so the full-resolution
            // UIImage is released immediately after JPEG encoding, not held
            // in memory until the loop ends. Without this, importing a 100+
            // page PDF accumulates all images simultaneously and can OOM.
            let page: ImportedPage? = autoreleasepool {
                guard let pdfPage = document.page(at: pdfPageIndex) else { return nil }

                let pdfBounds = pdfPage.bounds(for: .mediaBox)
                let orientation: PageOrientation = pdfBounds.width > pdfBounds.height ? .landscape : .portrait
                let pageSize = orientation.size
                let fitRect = aspectFitRect(contentSize: pdfBounds.size, in: pageSize)
                let extractedText = pdfPage.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return ImportedPage(
                    orientation: orientation.rawValue,
                    imageData: render(pdfPage, bounds: pdfBounds, size: fitRect.size),
                    imageFrame: fitRect,
                    extractedText: extractedText
                )
            }
            if let page {
                importedPages.append(page)
            }
        }

        return importedPages
    }

    private static func aspectFitRect(contentSize: CGSize, in pageSize: CGSize) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0 else {
            return CGRect(origin: .zero, size: pageSize)
        }
        let scale = min(pageSize.width / contentSize.width, pageSize.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(
            x: (pageSize.width - size.width) / 2,
            y: (pageSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func render(_ page: PDFPage, bounds: CGRect, size: CGSize) -> Data? {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true

        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let scale = min(size.width / bounds.width, size.height / bounds.height)
            context.cgContext.saveGState()
            context.cgContext.translateBy(x: -bounds.minX * scale, y: size.height + bounds.minY * scale)
            context.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context.cgContext)
            context.cgContext.restoreGState()
        }

        return image.jpegData(compressionQuality: 0.92) ?? image.pngData()
    }
}
