import Foundation
import SwiftData

/// Translates between SwiftData models and the cloud document JSON format.
///
/// The cloud format is:
///   clientId: "ipad-<uuid>"     — stable per notebook
///   title: notebook title
///   body: markdown export of text across all pages (linear reading view)
///   blocks: [[page: [elements...]], ...] spatial canvas state
///   revision: monotonic counter
///
/// The iPad owns the `blocks` representation; `body` is a best-effort markdown
/// export for the web to display. When pulling, we restore `blocks` into the
/// SwiftData graph and ignore `body` (the web may have edited it; we treat
/// iPad-side edits as authoritative for `blocks`).
struct CloudTranslator {

    static func archiveData(for notebook: Notebook) throws -> Data {
        var archive: [String: Any] = [
            "format": "com.betternotes.archive",
            "version": 2,
            "stableID": notebook.stableID.uuidString,
            "title": notebook.title,
            "coverColorHex": notebook.coverColorHex,
            "coverColor2Hex": notebook.coverColor2Hex,
            "coverStyle": notebook.coverStyle,
            "blocks": exportBlocks(notebook),
        ]
        if let coverEmoji = notebook.coverEmoji { archive["coverEmoji"] = coverEmoji }
        return try JSONSerialization.data(withJSONObject: archive, options: [.prettyPrinted, .sortedKeys])
    }

    static func writeArchive(for notebook: Notebook) throws -> URL {
        let safeName = notebook.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName)-\(Int(Date().timeIntervalSince1970)).betternotes")
        try archiveData(for: notebook).write(to: url, options: .atomic)
        return url
    }

    @MainActor
    static func importArchive(from url: URL, into context: ModelContext,
                              configure: ((Notebook) throws -> Void)? = nil) throws -> Notebook {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        guard let archive = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              archive["format"] as? String == "com.betternotes.archive",
              let version = archive["version"] as? Int,
              (1...2).contains(version),
              let blocks = archive["blocks"] as? [[String: Any]] else {
            throw ArchiveError.invalidArchive
        }
        let title = archive["title"] as? String ?? "Recovered Notebook"
        let document: [String: Any] = [
            "clientId": "import-" + UUID().uuidString.lowercased(),
            "title": title,
            "blocks": blocks,
        ]
        guard let notebook = apply(doc: document, into: context) else {
            throw ArchiveError.invalidArchive
        }
        notebook.cloudID = nil
        if let stableID = (archive["stableID"] as? String).flatMap(UUID.init(uuidString:)) {
            notebook.stableID = stableID
        }
        notebook.title = title
        notebook.coverColorHex = archive["coverColorHex"] as? String ?? notebook.coverColorHex
        notebook.coverColor2Hex = archive["coverColor2Hex"] as? String ?? notebook.coverColor2Hex
        notebook.coverStyle = archive["coverStyle"] as? String ?? notebook.coverStyle
        notebook.coverEmoji = archive["coverEmoji"] as? String
        notebook.modifiedAt = .now
        do {
            try configure?(notebook)
            try context.save()
        } catch {
            context.delete(notebook)
            throw error
        }
        return notebook
    }

    // MARK: - Export (Notebook → Cloud JSON)

    /// Stable cloud identity for a notebook. Migrates the legacy subtitle-based
    /// identity once, then keeps it out of user-visible metadata.
    static func clientId(for notebook: Notebook) -> String {
        if let cloudID = notebook.cloudID, !cloudID.isEmpty { return cloudID }
        let prefix = "cloud:"
        if notebook.subtitle.hasPrefix(prefix) {
            let id = String(notebook.subtitle.dropFirst(prefix.count))
            if id.hasPrefix("ipad-") {
                notebook.cloudID = id
                notebook.subtitle = ""
                return id
            }
        }
        let new = "ipad-" + UUID().uuidString.lowercased()
        notebook.cloudID = new
        return new
    }

    /// Export a notebook as a JSON-ready dictionary suitable for POSTing to
    /// `/api/sync/documents`.
    static func export(notebook: Notebook, baseRevision: Int?) -> [String: Any] {
        var payload: [String: Any] = [
            "clientId": clientId(for: notebook),
            "title": notebook.title,
            "format": "hybrid",
            "body": exportMarkdown(notebook),
            "blocks": exportBlocks(notebook),
        ]
        if let rev = baseRevision {
            payload["baseRevision"] = rev
        }
        // Propagate local deletion. Without this a trashed notebook was simply
        // omitted from the push, so the server kept its copy and a later pull
        // could resurrect it.
        if let trashedAt = notebook.trashedAt {
            payload["deletedAt"] = ISO8601DateFormatter().string(from: trashedAt)
        }
        return payload
    }

    /// Linear markdown export: concatenate every text element on every page.
    /// Includes LaTeX if the text contains `$...$` already; otherwise it's
    /// plain text.
    static func exportMarkdown(_ notebook: Notebook) -> String {
        var lines: [String] = ["# \(notebook.title)", ""]
        let sortedPages = notebook.pages.filter { $0.trashedAt == nil }.sorted { $0.index < $1.index }
        for (pageIndex, page) in sortedPages.enumerated() {
            lines.append("## Page \(pageIndex + 1)")
            let textElems = page.elements
                .filter { $0.elementType == "textBox" || $0.elementType == "stickyNote" }
                .sorted { ($0.posY, $0.posX) < ($1.posY, $1.posX) }
            if textElems.isEmpty {
                lines.append("_(no text on this page)_")
            } else {
                for elem in textElems {
                    if let text = elem.text, !text.isEmpty {
                        lines.append(text)
                    }
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Spatial canvas export: pages → array of page objects, each with
    /// positioned elements. Ink (PKDrawing data) is exported as a base64
    /// string under `inkData` so it round-trips losslessly.
    static func exportBlocks(_ notebook: Notebook) -> [[String: Any]] {
        let activePages = notebook.pages.filter { $0.trashedAt == nil }.sorted { $0.index < $1.index }
        return activePages.enumerated().map { offset, page in
            var pageDict: [String: Any] = [
                "stableID": page.stableID.uuidString,
                "index": page.index,
                "title": page.title,
                "isBookmarked": page.isBookmarked,
                "backgroundHex": page.backgroundHex,
                "lineStyle": page.lineStyle,
                "orientation": page.orientation,
                "ocrText": page.ocrText,
                "pdfText": page.pdfText,
                "ocrStorageVersion": page.ocrStorageVersion,
            ]
            if offset == 0 {
                pageDict["notebookMetadata"] = [
                    "stableID": notebook.stableID.uuidString,
                    "subtitle": notebook.subtitle,
                    "folderName": notebook.folderName,
                    "tagsText": notebook.tagsText,
                    "isFavorite": notebook.isFavorite,
                    "isArchived": notebook.isArchived,
                    "defaultLineStyle": notebook.defaultLineStyle,
                    "defaultBackgroundHex": notebook.defaultBackgroundHex,
                    "defaultOrientation": notebook.defaultOrientation,
                ]
            }
            if let ink = page.inkData, !ink.isEmpty {
                pageDict["inkData"] = ink.base64EncodedString()
            }
            pageDict["elements"] = page.orderedElements.map { elem -> [String: Any] in
                var e: [String: Any] = [
                    "elementType": elem.elementType,
                    "posX": elem.posX,
                    "posY": elem.posY,
                    "width": elem.width,
                    "height": elem.height,
                    "rotation": elem.rotation,
                ]
                if let text = elem.text { e["text"] = text }
                if let richTextData = elem.richTextData { e["richTextData"] = richTextData.base64EncodedString() }
                e["fontName"] = elem.fontName
                e["fontSize"] = elem.fontSize
                e["isBold"] = elem.isBold
                e["isItalic"] = elem.isItalic
                e["isUnderline"] = elem.isUnderline
                e["textAlignment"] = elem.textAlignment
                if let shapeKind = elem.shapeKind { e["shapeKind"] = shapeKind }
                if let colorHex = elem.colorHex { e["colorHex"] = colorHex }
                if let img = elem.imageData { e["imageData"] = img.base64EncodedString() }
                if let audio = elem.audioData { e["audioData"] = audio.base64EncodedString() }
                if let dur = elem.audioDuration { e["audioDuration"] = dur }
                if let transcript = elem.transcript { e["transcript"] = transcript }
                e["isRevealed"] = elem.isRevealed
                e["isLocked"] = elem.isLocked
                e["zIndex"] = elem.zIndex
                e["createdAt"] = elem.createdAt.timeIntervalSince1970
                return e
            }
            return pageDict
        }
    }

    // MARK: - Import (Cloud JSON → SwiftData)

    /// Apply a cloud document into a SwiftData notebook. If the notebook
    /// doesn't exist locally (new clientId), create one. Otherwise replace
    /// the local content with the server's version (last-write-wins).
    ///
    /// - Parameters:
    ///   - doc: The cloud document dict from the server.
    ///   - context: SwiftData context to insert/update into.
    /// - Returns: the notebook (existing or new).
    @MainActor
    static func apply(doc: [String: Any], into context: ModelContext) -> Notebook? {
        guard let clientId = doc["clientId"] as? String else { return nil }

        // Find existing notebook with this cloud id.
        let notebook = findOrCreateNotebook(clientId: clientId, in: context)

        if let title = doc["title"] as? String { notebook.title = title }
        notebook.cloudID = clientId

        // Replace pages.
        for page in notebook.pages { context.delete(page) }
        notebook.pages = []

        let blocks = (doc["blocks"] as? [[String: Any]]) ?? []
        if let metadata = blocks.first?["notebookMetadata"] as? [String: Any] {
            if let stableID = (metadata["stableID"] as? String).flatMap(UUID.init(uuidString:)) {
                notebook.stableID = stableID
            }
            notebook.subtitle = metadata["subtitle"] as? String ?? notebook.subtitle
            notebook.folderName = metadata["folderName"] as? String ?? ""
            notebook.tagsText = metadata["tagsText"] as? String ?? ""
            notebook.isFavorite = metadata["isFavorite"] as? Bool ?? false
            notebook.isArchived = metadata["isArchived"] as? Bool ?? false
            notebook.defaultLineStyle = metadata["defaultLineStyle"] as? String ?? PageLineStyle.blank.rawValue
            notebook.defaultBackgroundHex = metadata["defaultBackgroundHex"] as? String ?? "FFFFFF"
            notebook.defaultOrientation = metadata["defaultOrientation"] as? String ?? PageOrientation.portrait.rawValue
        }
        for (idx, pageDict) in blocks.enumerated() {
            let page = Page(index: pageDict["index"] as? Int ?? idx)
            if let stableID = (pageDict["stableID"] as? String).flatMap(UUID.init(uuidString:)) {
                page.stableID = stableID
            }
            page.title = pageDict["title"] as? String ?? ""
            page.isBookmarked = pageDict["isBookmarked"] as? Bool ?? false
            page.notebook = notebook
            page.backgroundHex = (pageDict["backgroundHex"] as? String) ?? "FFFFFF"
            page.lineStyle = (pageDict["lineStyle"] as? String) ?? "blank"
            page.orientation = (pageDict["orientation"] as? String) ?? "portrait"
            page.ocrText = pageDict["ocrText"] as? String ?? ""
            page.pdfText = pageDict["pdfText"] as? String ?? ""
            page.ocrStorageVersion = pageDict["ocrStorageVersion"] as? Int ?? 0

            // Restore ink data.
            if let inkB64 = pageDict["inkData"] as? String,
               let inkData = Data(base64Encoded: inkB64) {
                page.inkData = inkData
            }

            // Restore elements.
            if let elems = pageDict["elements"] as? [[String: Any]] {
                for (elemIndex, elemDict) in elems.enumerated() {
                    let typeStr = elemDict["elementType"] as? String ?? "textBox"
                    let type = ElementType(rawValue: typeStr) ?? .textBox
                    let element = PageElement(
                        type: type,
                        x: elemDict["posX"] as? Double ?? 0,
                        y: elemDict["posY"] as? Double ?? 0,
                        width: elemDict["width"] as? Double ?? 200,
                        height: elemDict["height"] as? Double ?? 120,
                        rotation: elemDict["rotation"] as? Double ?? 0
                    )
                    element.text = elemDict["text"] as? String
                    if let richTextB64 = elemDict["richTextData"] as? String,
                       let richTextData = Data(base64Encoded: richTextB64) {
                        element.richTextData = richTextData
                    }
                    element.fontName = (elemDict["fontName"] as? String) ?? "System"
                    element.fontSize = (elemDict["fontSize"] as? Double) ?? 16
                    element.isBold = (elemDict["isBold"] as? Bool) ?? false
                    element.isItalic = (elemDict["isItalic"] as? Bool) ?? false
                    element.isUnderline = (elemDict["isUnderline"] as? Bool) ?? false
                    element.textAlignment = (elemDict["textAlignment"] as? String) ?? "leading"
                    element.shapeKind = elemDict["shapeKind"] as? String
                    element.colorHex = elemDict["colorHex"] as? String
                    if let imgB64 = elemDict["imageData"] as? String,
                       let imgData = Data(base64Encoded: imgB64) {
                        element.imageData = imgData
                    }
                    if let audioB64 = elemDict["audioData"] as? String,
                       let audioData = Data(base64Encoded: audioB64) {
                        element.audioData = audioData
                    }
                    element.audioDuration = elemDict["audioDuration"] as? Double
                    element.transcript = elemDict["transcript"] as? String
                    element.isRevealed = (elemDict["isRevealed"] as? Bool) ?? false
                    element.isLocked = (elemDict["isLocked"] as? Bool) ?? false
                    // Stacking order and creation dates are content, not
                    // metadata: the canvas is drawn in zIndex order, and the
                    // corpus index cites elements by createdAt order. Archives
                    // written before these were exported fall back to the
                    // position in the array, which is the order they were
                    // written out in.
                    element.zIndex = (elemDict["zIndex"] as? Int) ?? elemIndex
                    if let created = elemDict["createdAt"] as? Double {
                        element.createdAt = Date(timeIntervalSince1970: created)
                    }

                    element.page = page
                    page.elements.append(element)
                }
            }

            page.restoreElementOrder()
            notebook.pages.append(page)
        }

        notebook.modifiedAt = .now
        return notebook
    }

    // MARK: - Helpers

    @MainActor
    private static func findOrCreateNotebook(clientId: String, in context: ModelContext) -> Notebook {
        let descriptor = FetchDescriptor<Notebook>()
        if let all = try? context.fetch(descriptor) {
            for nb in all {
                if nb.cloudID == clientId || nb.subtitle == "cloud:\(clientId)" {
                    nb.cloudID = clientId
                    if nb.subtitle == "cloud:\(clientId)" { nb.subtitle = "" }
                    return nb
                }
            }
        }
        // Not found — create.
        let nb = Notebook(title: "Untitled")
        nb.cloudID = clientId
        context.insert(nb)
        return nb
    }
}

enum ArchiveError: LocalizedError {
    case invalidArchive

    var errorDescription: String? {
        "This file is not a supported BetterNotes backup."
    }
}
