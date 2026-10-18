import Foundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers

extension UTType {
    static let betterNotesArchive = UTType(exportedAs: "com.betternotes.archive", conformingTo: .json)
}

enum DocumentImporter {
    enum Kind { case pdf, image, archive }
    enum ImportError: LocalizedError {
        case unsupportedType, unreadableImage, noPages
        var errorDescription: String? {
            switch self {
            case .unsupportedType: return "Open a PDF, BetterNotes backup, or supported image file."
            case .unreadableImage: return "The selected image could not be opened."
            case .noPages: return "The document does not contain any readable pages."
            }
        }
    }

    static let imageTypes: [UTType] = [.jpeg, .png, .heic, .heif, .tiff, .gif, .bmp, .webP]
    static let supportedTypes: [UTType] = [.pdf, .betterNotesArchive] + imageTypes

    static func kind(for url: URL) throws -> Kind {
        guard url.isFileURL else { throw ImportError.unsupportedType }
        // An extension is available even before a file provider grants access.
        if url.pathExtension.lowercased() == "betternotes" { return .archive }
        let type = UTType(filenameExtension: url.pathExtension)
            ?? (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
        if type?.conforms(to: .pdf) == true { return .pdf }
        if type?.conforms(to: .betterNotesArchive) == true { return .archive }
        if let type, imageTypes.contains(where: { type.conforms(to: $0) }) { return .image }
        throw ImportError.unsupportedType
    }

    @MainActor
    static func importDocument(from url: URL, into context: ModelContext, folderName: String? = nil) async throws -> Notebook {
        let kind = try kind(for: url)
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()

        if kind == .archive {
            return try CloudTranslator.importArchive(from: url, into: context) { notebook in
                // Prepare the copy before the archive's single save, so a
                // failed import cannot leave a duplicate navigation identity.
                let id = notebook.stableID
                if try context.fetch(FetchDescriptor<Notebook>()).contains(where: { $0 !== notebook && $0.stableID == id }) {
                    notebook.stableID = UUID()
                    for page in notebook.pages { page.stableID = UUID() }
                }
                if let folderName { notebook.folderName = folderName }
                notebook.isArchived = false
                notebook.trashedAt = nil
            }
        }

        let worker = Task.detached(priority: .userInitiated) {
            switch kind {
            case .pdf: return try PDFImporter.pages(from: url)
            case .image: return [try imagePage(from: url)]
            case .archive: return []
            }
        }
        let pages = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard !pages.isEmpty else { throw ImportError.noPages }
        let name = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let notebook = Notebook(title: name.isEmpty ? "Imported Document" : name)
        notebook.folderName = folderName ?? ""
        for (index, importedPage) in pages.enumerated() {
            let page = PDFImporter.makePage(from: importedPage, index: index)
            page.notebook = notebook
            notebook.pages.append(page)
        }
        context.insert(notebook)
        do { try context.save() }
        catch { context.delete(notebook); throw error }
        return notebook
    }

    private static func imagePage(from url: URL) throws -> PDFImporter.ImportedPage {
        try Task.checkCancellation()
        return try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 3200,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw ImportError.unreadableImage }
            let size = CGSize(width: thumbnail.width, height: thumbnail.height)
            let orientation: PageOrientation = size.width > size.height ? .landscape : .portrait
            let pageSize = orientation.size
            let scale = min(pageSize.width / size.width, pageSize.height / size.height)
            let frame = CGRect(x: (pageSize.width - size.width * scale) / 2,
                               y: (pageSize.height - size.height * scale) / 2,
                               width: size.width * scale, height: size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                UIImage(cgImage: thumbnail).draw(in: CGRect(origin: .zero, size: size))
            }
            guard let data = image.jpegData(compressionQuality: 0.92) else { throw ImportError.unreadableImage }
            return PDFImporter.ImportedPage(orientation: orientation.rawValue, imageData: data, imageFrame: frame, extractedText: "")
        }
    }
}
