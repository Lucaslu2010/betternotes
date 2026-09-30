import Foundation
import SwiftData

/// Translates between SwiftData models and editable `.betternotes` archives.
/// The former server document shape remains for backward-compatible backups;
/// nearby device sync uses version 4 snapshots of the same editable data.
///
/// The cloud format is:
///   clientId: "ipad-<uuid>"     — stable per notebook
///   title: notebook title
///   body: markdown export of text across all pages (linear reading view)
///   blocks: [[page: [elements...]], ...] spatial canvas state
///   revision: monotonic counter
///
/// `blocks` carries the full page state; `body` remains a linear markdown
/// export for older consumers of this format.
struct CloudTranslator {

    static func archiveData(for notebook: Notebook) throws -> Data {
        try JSONSerialization.data(withJSONObject: archiveDictionary(for: notebook, includingTrash: false), options: [.prettyPrinted, .sortedKeys])
    }

    /// Complete, deterministic notebook snapshot for nearby device exchange.
    /// Unlike an exported backup, this includes items in Trash so they cannot
    /// silently reappear after a transfer.
    static func syncArchiveData(for notebook: Notebook) throws -> Data {
        try JSONSerialization.data(withJSONObject: archiveDictionary(for: notebook, includingTrash: true), options: [.sortedKeys])
    }

    /// SwiftData can round a date by one floating-point step when the same
    /// archive moves between iPad and Mac. That is about 0.12 microseconds,
    /// but an exact JSON hash would mistake it for an edit and create a
    /// conflict copy on every exchange. Sync needs only millisecond precision.
    private static func timestamp(_ date: Date, forSync: Bool) -> Double {
        let seconds = date.timeIntervalSince1970
        return forSync ? (seconds * 1_000).rounded() / 1_000 : seconds
    }

    private static func archiveDictionary(for notebook: Notebook, includingTrash: Bool) -> [String: Any] {
        var archive: [String: Any] = [
            "format": "com.betternotes.archive",
            "version": includingTrash ? 4 : 3,
            "stableID": notebook.stableID.uuidString,
            "title": notebook.title,
            "coverColorHex": notebook.coverColorHex,
            "coverColor2Hex": notebook.coverColor2Hex,
            "coverStyle": notebook.coverStyle,
            "subtitle": notebook.subtitle,
            "folderName": notebook.folderName,
            "tagsText": notebook.tagsText,
            "isFavorite": notebook.isFavorite,
            "isArchived": notebook.isArchived,
            "defaultLineStyle": notebook.defaultLineStyle,
            "defaultLineThickness": notebook.defaultLineThickness,
            "defaultLineOpacity": notebook.defaultLineOpacity,
            "defaultBackgroundHex": notebook.defaultBackgroundHex,
            "defaultOrientation": notebook.defaultOrientation,
            "createdAt": timestamp(notebook.createdAt, forSync: includingTrash),
            "modifiedAt": timestamp(notebook.modifiedAt, forSync: includingTrash),
            "blocks": exportBlocks(notebook, includingTrash: includingTrash),
        ]
        if includingTrash, let trashedAt = notebook.trashedAt {
            archive["trashedAt"] = timestamp(trashedAt, forSync: true)
        }
        if let coverEmoji = notebook.coverEmoji { archive["coverEmoji"] = coverEmoji }
        return archive
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
    static func importArchive(from url: URL, into context: ModelContext) throws -> Notebook {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        return try importArchiveData(data, into: context)
    }

    @MainActor
    static func importArchiveData(
        _ data: Data,
        into context: ModelContext,
        replacing existing: Notebook? = nil,
        conflictSuffix: String? = nil
    ) throws -> Notebook {
        let existingNotebookIDs = Set(try context.fetch(FetchDescriptor<Notebook>()).map(\.stableID))
        let existingPageIDs = Set(try context.fetch(FetchDescriptor<Page>()).map(\.stableID))
        guard let archive = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              archive["format"] as? String == "com.betternotes.archive",
              let version = archive["version"] as? Int,
              (1...4).contains(version),
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
        // `apply` has already inserted the new notebook, and replacing marks
        // the old one deleted. If anything below throws, leaving that pending
        // state in the context lets a later save persist a duplicate or erase
        // the original, so roll the whole import back.
        var committed = false
        defer { if !committed { context.rollback() } }
        notebook.cloudID = nil
        let sourceNotebookID = (archive["stableID"] as? String).flatMap(UUID.init(uuidString:))
        if let stableID = sourceNotebookID {
            notebook.stableID = stableID
        }
        // Restoring into the same library creates a copy. Duplicate stable
        // IDs would make navigation and AI source citations ambiguous.
        if existingNotebookIDs.contains(notebook.stableID) && existing == nil {
            notebook.stableID = UUID()
        }
        var pageIDs: [UUID: UUID] = [:]
        for page in notebook.pages {
            let sourcePageID = page.stableID
            if existingPageIDs.contains(sourcePageID) && existing == nil {
                page.stableID = UUID()
            }
            pageIDs[sourcePageID] = page.stableID
        }
        if notebook.stableID != sourceNotebookID {
            for page in notebook.pages {
                for element in page.elements {
                    guard var payload = element.assistantPayload else { continue }
                    payload.citations = payload.citations.map { citation in
                        guard citation.notebookID == sourceNotebookID else { return citation }
                        return SourceCitation(
                            notebookID: notebook.stableID,
                            pageID: citation.pageID.flatMap { pageIDs[$0] },
                            sourceLabel: citation.sourceLabel,
                            excerpt: citation.excerpt,
                            token: citation.token
                        )
                    }
                    element.assistantPayload = payload
                }
            }
        }
        notebook.title = conflictSuffix.map { title + " (from \($0))" } ?? title
        notebook.coverColorHex = archive["coverColorHex"] as? String ?? notebook.coverColorHex
        notebook.coverColor2Hex = archive["coverColor2Hex"] as? String ?? notebook.coverColor2Hex
        notebook.coverStyle = archive["coverStyle"] as? String ?? notebook.coverStyle
        notebook.coverEmoji = archive["coverEmoji"] as? String
        // Root metadata is also present in snapshots with no pages.
        if archive["subtitle"] != nil {
            notebook.subtitle = archive["subtitle"] as? String ?? ""
            notebook.folderName = archive["folderName"] as? String ?? ""
            notebook.tagsText = archive["tagsText"] as? String ?? ""
            notebook.isFavorite = archive["isFavorite"] as? Bool ?? false
            notebook.isArchived = archive["isArchived"] as? Bool ?? false
            notebook.defaultLineStyle = archive["defaultLineStyle"] as? String ?? PageLineStyle.blank.rawValue
            notebook.defaultLineThickness = PageLineAppearance.thickness(archive["defaultLineThickness"] as? Double ?? PageLineAppearance.defaultThickness)
            notebook.defaultLineOpacity = PageLineAppearance.opacity(archive["defaultLineOpacity"] as? Double ?? PageLineAppearance.defaultOpacity)
            notebook.defaultBackgroundHex = archive["defaultBackgroundHex"] as? String ?? "FFFFFF"
            notebook.defaultOrientation = archive["defaultOrientation"] as? String ?? PageOrientation.portrait.rawValue
        }
        if let created = archive["createdAt"] as? Double {
            notebook.createdAt = Date(timeIntervalSince1970: created)
        }
        if let modified = archive["modifiedAt"] as? Double {
            notebook.modifiedAt = Date(timeIntervalSince1970: modified)
        } else {
            notebook.modifiedAt = .now
        }
        if version >= 4, let trashed = archive["trashedAt"] as? Double {
            notebook.trashedAt = Date(timeIntervalSince1970: trashed)
        }
        if let existing {
            context.delete(existing)
        }
        try context.save()
        committed = true
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
    static func exportBlocks(_ notebook: Notebook, includingTrash: Bool = false) -> [[String: Any]] {
        // Older notebooks can contain several pages with the same index.
        // SwiftData returns their relationship in a different order on iPad
        // and Mac; a sync hash must use the same tie-breaker on both devices.
        let activePages = notebook.pages.filter { includingTrash || $0.trashedAt == nil }.sorted {
            ($0.index, $0.stableID.uuidString) < ($1.index, $1.stableID.uuidString)
        }
        return activePages.enumerated().map { offset, page in
            var pageDict: [String: Any] = [
                "stableID": page.stableID.uuidString,
                "index": page.index,
                "title": page.title,
                "isBookmarked": page.isBookmarked,
                "backgroundHex": page.backgroundHex,
                "lineStyle": page.lineStyle,
                "lineThickness": page.lineThickness,
                "lineOpacity": page.lineOpacity,
                "orientation": page.orientation,
                "ocrText": page.ocrText,
                "createdAt": timestamp(page.createdAt, forSync: includingTrash),
                "modifiedAt": timestamp(page.modifiedAt, forSync: includingTrash),
            ]
            if includingTrash, let trashedAt = page.trashedAt {
                pageDict["trashedAt"] = timestamp(trashedAt, forSync: true)
            }
            if let ocrUpdatedAt = page.ocrUpdatedAt {
                pageDict["ocrUpdatedAt"] = timestamp(ocrUpdatedAt, forSync: includingTrash)
            }
            if offset == 0 {
                pageDict["notebookMetadata"] = [
                    "stableID": notebook.stableID.uuidString,
                    "subtitle": notebook.subtitle,
                    "folderName": notebook.folderName,
                    "tagsText": notebook.tagsText,
                    "isFavorite": notebook.isFavorite,
                    "isArchived": notebook.isArchived,
                    "defaultLineStyle": notebook.defaultLineStyle,
                    "defaultLineThickness": notebook.defaultLineThickness,
                    "defaultLineOpacity": notebook.defaultLineOpacity,
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
                if let assistant = elem.assistantData { e["assistantData"] = assistant.base64EncodedString() }
                e["isRevealed"] = elem.isRevealed
                e["isLocked"] = elem.isLocked
                e["zIndex"] = elem.zIndex
                e["createdAt"] = timestamp(elem.createdAt, forSync: includingTrash)
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
            notebook.defaultLineThickness = PageLineAppearance.thickness(metadata["defaultLineThickness"] as? Double ?? PageLineAppearance.defaultThickness)
            notebook.defaultLineOpacity = PageLineAppearance.opacity(metadata["defaultLineOpacity"] as? Double ?? PageLineAppearance.defaultOpacity)
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
            page.lineThickness = PageLineAppearance.thickness(pageDict["lineThickness"] as? Double ?? PageLineAppearance.defaultThickness)
            page.lineOpacity = PageLineAppearance.opacity(pageDict["lineOpacity"] as? Double ?? PageLineAppearance.defaultOpacity)
            page.orientation = (pageDict["orientation"] as? String) ?? "portrait"
            page.ocrText = pageDict["ocrText"] as? String ?? ""
            if let created = pageDict["createdAt"] as? Double { page.createdAt = Date(timeIntervalSince1970: created) }
            if let modified = pageDict["modifiedAt"] as? Double { page.modifiedAt = Date(timeIntervalSince1970: modified) }
            if let trashed = pageDict["trashedAt"] as? Double { page.trashedAt = Date(timeIntervalSince1970: trashed) }
            if let updated = pageDict["ocrUpdatedAt"] as? Double { page.ocrUpdatedAt = Date(timeIntervalSince1970: updated) }

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
                    if let assistantB64 = elemDict["assistantData"] as? String,
                       let assistantData = Data(base64Encoded: assistantB64) {
                        element.assistantData = assistantData
                    }
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
        AppLocalization.text("This file is not a supported BetterNotes backup.")
    }
}
