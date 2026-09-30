import CoreGraphics
import XCTest
import SwiftData
@testable import BetterNotes

/// `.betternotes` archives are the editable recovery path alongside nearby sync.
/// If a field does not survive export and re-import,
/// a user who restores from their own backup silently loses it. These tests
/// walk a fully-populated notebook out to an archive and back, and compare.
@MainActor
final class ArchiveRoundTripTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Notebook.self, Page.self, PageElement.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
    }

    /// A notebook with every field the archive claims to carry set to a value
    /// that is not its default — so a dropped field shows up as a failure
    /// rather than coincidentally matching.
    private func populatedNotebook(in context: ModelContext) -> Notebook {
        let notebook = Notebook(title: "Organic Chemistry")
        notebook.subtitle = "Michaelmas"
        notebook.folderName = "Year 12"
        notebook.tagsText = "chem,revision"
        notebook.isFavorite = true
        notebook.isArchived = true
        notebook.coverColorHex = "3366CC"
        notebook.coverColor2Hex = "88AAFF"
        notebook.coverStyle = "gradient"
        notebook.coverEmoji = "🧪"
        notebook.defaultLineStyle = PageLineStyle.grid.rawValue
        notebook.defaultLineThickness = 1.75
        notebook.defaultLineOpacity = 0.65
        notebook.defaultBackgroundHex = "FFFDF5"
        notebook.defaultOrientation = PageOrientation.landscape.rawValue

        let page = Page(index: 0)
        page.title = "Alkenes"
        page.isBookmarked = true
        page.backgroundHex = "FFF0E0"
        page.lineStyle = PageLineStyle.ruled.rawValue
        page.lineThickness = 2.25
        page.lineOpacity = 0.4
        page.orientation = PageOrientation.landscape.rawValue
        page.ocrText = "electrophilic addition"
        page.inkData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        page.notebook = notebook

        let text = PageElement(type: .textBox, x: 12, y: 34, width: 210, height: 90, rotation: 0.25)
        text.text = "Markovnikov"
        text.richTextData = Data([1, 2, 3])
        text.fontName = "Georgia"
        text.fontSize = 22
        text.isBold = true
        text.isItalic = true
        text.isUnderline = true
        text.textAlignment = "center"
        text.colorHex = "112233"
        text.isLocked = true
        text.page = page

        let media = PageElement(type: .audioRecording, x: 300, y: 400)
        media.imageData = Data([9, 8, 7])
        media.audioData = Data([5, 5, 5, 5])
        media.audioDuration = 42.5
        media.transcript = "recap of the mechanism"
        media.shapeKind = "circle"
        media.isRevealed = true
        media.page = page

        let answer = PageElement(type: .assistantNote, x: 500, y: 600, width: 320, height: 150)
        answer.text = "Because it kept the French stress."
        answer.colorHex = "3C4A6B"
        answer.assistantPayload = AssistantNotePayload(
            question: "why the silent h?",
            citations: [SourceCitation(
                notebookID: notebook.stableID, pageID: page.stableID,
                sourceLabel: "Gorner", excerpt: "stress pattern", token: "S1"
            )],
            anchor: CGPoint(x: 120, y: 240)
        )
        answer.page = page

        page.appendElement(text)
        page.appendElement(media)
        page.appendElement(answer)
        notebook.pages = [page]

        let trashed = Page(index: 1)
        trashed.title = "Deleted draft"
        trashed.trashedAt = .now
        trashed.notebook = notebook
        notebook.pages.append(trashed)

        context.insert(notebook)
        return notebook
    }

    /// Export to a file and import it back into a *fresh* store.
    private func roundTrip(_ notebook: Notebook) throws -> Notebook {
        let url = try CloudTranslator.writeArchive(for: notebook)
        defer { try? FileManager.default.removeItem(at: url) }
        return try CloudTranslator.importArchive(from: url, into: try makeContext())
    }

    func testNotebookMetadataSurvives() throws {
        let original = populatedNotebook(in: try makeContext())
        let restored = try roundTrip(original)

        XCTAssertEqual(restored.title, "Organic Chemistry")
        XCTAssertEqual(restored.stableID, original.stableID)
        XCTAssertEqual(restored.coverColorHex, "3366CC")
        XCTAssertEqual(restored.coverColor2Hex, "88AAFF")
        XCTAssertEqual(restored.coverStyle, "gradient")
        XCTAssertEqual(restored.coverEmoji, "🧪")
        XCTAssertEqual(restored.folderName, "Year 12")
        XCTAssertEqual(restored.tagsText, "chem,revision")
        XCTAssertTrue(restored.isFavorite)
        XCTAssertTrue(restored.isArchived)
        XCTAssertEqual(restored.defaultLineStyle, PageLineStyle.grid.rawValue)
        XCTAssertEqual(restored.defaultLineThickness, 1.75)
        XCTAssertEqual(restored.defaultLineOpacity, 0.65)
        XCTAssertEqual(restored.defaultBackgroundHex, "FFFDF5")
        XCTAssertEqual(restored.defaultOrientation, PageOrientation.landscape.rawValue)
        XCTAssertNil(restored.cloudID, "an imported notebook must not claim the original's cloud identity")
    }

    func testNestedFolderPathSurvivesBackupAndSyncSnapshot() throws {
        let original = populatedNotebook(in: try makeContext())
        original.folderName = "School/Science/Chemistry"

        XCTAssertEqual(try roundTrip(original).folderName, "School/Science/Chemistry")
        let snapshot = try CloudTranslator.syncArchiveData(for: original)
        let restored = try CloudTranslator.importArchiveData(snapshot, into: try makeContext())
        XCTAssertEqual(restored.folderName, "School/Science/Chemistry")
        XCTAssertEqual(restored.defaultLineThickness, 1.75)
        XCTAssertEqual(restored.defaultLineOpacity, 0.65)
        let activePage = try XCTUnwrap(restored.pages.first(where: { $0.trashedAt == nil }))
        XCTAssertEqual(activePage.lineThickness, 2.25)
        XCTAssertEqual(activePage.lineOpacity, 0.4)
    }

    func testTapeColorAndDimensionsSurviveBackupAndSyncSnapshot() throws {
        let context = try makeContext()
        let notebook = Notebook(title: "Tape Study")
        let page = Page(index: 0)
        page.notebook = notebook
        let tape = PageElement(type: .tape, x: 220, y: 300, width: 420, height: 96)
        tape.colorHex = "F2B8BC"
        tape.page = page
        page.appendElement(tape)
        notebook.pages = [page]
        context.insert(notebook)

        let backupTape = try XCTUnwrap(roundTrip(notebook).pages.first?.elements.first)
        XCTAssertEqual(backupTape.colorHex, "F2B8BC")
        XCTAssertEqual(backupTape.width, 420)
        XCTAssertEqual(backupTape.height, 96)

        let snapshot = try CloudTranslator.syncArchiveData(for: notebook)
        let synced = try CloudTranslator.importArchiveData(snapshot, into: try makeContext())
        let syncedTape = try XCTUnwrap(synced.pages.first?.elements.first)
        XCTAssertEqual(syncedTape.colorHex, "F2B8BC")
        XCTAssertEqual(syncedTape.width, 420)
        XCTAssertEqual(syncedTape.height, 96)
    }

    func testPagesAndInkSurvive() throws {
        let original = populatedNotebook(in: try makeContext())
        let restored = try roundTrip(original)

        XCTAssertEqual(restored.pages.count, 1, "trashed pages must not come back")
        let page = try XCTUnwrap(restored.pages.first)
        XCTAssertEqual(page.stableID, original.pages[0].stableID)
        XCTAssertEqual(page.title, "Alkenes")
        XCTAssertTrue(page.isBookmarked)
        XCTAssertEqual(page.backgroundHex, "FFF0E0")
        XCTAssertEqual(page.lineStyle, PageLineStyle.ruled.rawValue)
        XCTAssertEqual(page.lineThickness, 2.25)
        XCTAssertEqual(page.lineOpacity, 0.4)
        XCTAssertEqual(page.orientation, PageOrientation.landscape.rawValue)
        XCTAssertEqual(page.ocrText, "electrophilic addition")
        XCTAssertEqual(page.inkData, Data([0xDE, 0xAD, 0xBE, 0xEF]), "the handwriting was lost")
    }

    func testEveryElementFieldSurvives() throws {
        let original = populatedNotebook(in: try makeContext())
        let restored = try roundTrip(original)
        let elements = try XCTUnwrap(restored.pages.first).orderedElements
        XCTAssertEqual(elements.count, 3)

        let text = elements[0]
        XCTAssertEqual(text.elementType, ElementType.textBox.rawValue)
        XCTAssertEqual(text.posX, 12, accuracy: 0.001)
        XCTAssertEqual(text.posY, 34, accuracy: 0.001)
        XCTAssertEqual(text.width, 210, accuracy: 0.001)
        XCTAssertEqual(text.height, 90, accuracy: 0.001)
        XCTAssertEqual(text.rotation, 0.25, accuracy: 0.001)
        XCTAssertEqual(text.text, "Markovnikov")
        XCTAssertEqual(text.richTextData, Data([1, 2, 3]))
        XCTAssertEqual(text.fontName, "Georgia")
        XCTAssertEqual(text.fontSize, 22, accuracy: 0.001)
        XCTAssertTrue(text.isBold)
        XCTAssertTrue(text.isItalic)
        XCTAssertTrue(text.isUnderline)
        XCTAssertEqual(text.textAlignment, "center")
        XCTAssertEqual(text.colorHex, "112233")
        XCTAssertTrue(text.isLocked)

        let media = elements[1]
        XCTAssertEqual(media.elementType, ElementType.audioRecording.rawValue)
        XCTAssertEqual(media.imageData, Data([9, 8, 7]))
        XCTAssertEqual(media.audioData, Data([5, 5, 5, 5]))
        XCTAssertEqual(media.audioDuration ?? 0, 42.5, accuracy: 0.001)
        XCTAssertEqual(media.transcript, "recap of the mechanism")
        XCTAssertEqual(media.shapeKind, "circle")
        XCTAssertTrue(media.isRevealed)

        // An answer the assistant wrote onto the page is part of the note. An
        // archive that restored the card but lost the question it answers --
        // or its citations -- would hand back something that reads as an
        // unattributed assertion.
        let answer = elements[2]
        XCTAssertEqual(answer.elementType, ElementType.assistantNote.rawValue)
        XCTAssertEqual(answer.text, "Because it kept the French stress.")
        let payload = try XCTUnwrap(answer.assistantPayload)
        XCTAssertEqual(payload.question, "why the silent h?")
        XCTAssertEqual(payload.citations.map(\.token), ["S1"])
        XCTAssertEqual(payload.anchor, CGPoint(x: 120, y: 240))
    }

    func testStackingOrderSurvives() throws {
        // The editor draws page.elements in array order, so the array *is* the
        // z-order. An archive that reorders them re-stacks the user's canvas.
        let original = populatedNotebook(in: try makeContext())
        let restored = try roundTrip(original)
        XCTAssertEqual(try XCTUnwrap(restored.pages.first).orderedElements.map(\.elementType),
                       try XCTUnwrap(original.pages.first).orderedElements.map(\.elementType))
    }

    func testCreationDatesSurvive() throws {
        // NoteCorpusIndexer orders elements by createdAt to assign the stable
        // ordinals the assistant cites, so these are load-bearing, not just
        // metadata.
        let context = try makeContext()
        let original = populatedNotebook(in: context)
        let restored = try roundTrip(original)
        let before = try XCTUnwrap(original.pages.first).orderedElements.map(\.createdAt)
        let after = try XCTUnwrap(restored.pages.first).orderedElements.map(\.createdAt)
        for (index, pair) in zip(before, after).enumerated() {
            XCTAssertEqual(pair.1.timeIntervalSince1970, pair.0.timeIntervalSince1970, accuracy: 0.001,
                           "element \(index) came back with a different creation date")
        }
    }

    func testAnEmptyNotebookRoundTrips() throws {
        let context = try makeContext()
        let notebook = Notebook(title: "Empty")
        context.insert(notebook)
        let restored = try roundTrip(notebook)
        XCTAssertEqual(restored.title, "Empty")
        XCTAssertTrue(restored.pages.isEmpty)
    }

    func testImportingIntoTheSameStoreCreatesDistinctSourceIDs() throws {
        let context = try makeContext()
        let original = populatedNotebook(in: context)
        let url = try CloudTranslator.writeArchive(for: original)
        defer { try? FileManager.default.removeItem(at: url) }
        let copy = try CloudTranslator.importArchive(from: url, into: context)
        let originalActivePage = try XCTUnwrap(original.pages.first { $0.trashedAt == nil })
        XCTAssertNotEqual(copy.stableID, original.stableID)
        XCTAssertNotEqual(copy.pages.first?.stableID, originalActivePage.stableID)
        XCTAssertEqual(copy.pages.first?.inkData, originalActivePage.inkData)
        let answer = try XCTUnwrap(copy.pages.first?.elements.first {
            $0.elementType == ElementType.assistantNote.rawValue
        }?.assistantPayload)
        XCTAssertEqual(answer.citations.first?.notebookID, copy.stableID)
        XCTAssertEqual(answer.citations.first?.pageID, copy.pages.first?.stableID)
    }

    func testAFileThatIsNotAnArchiveIsRejected() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-an-archive-\(UUID().uuidString).betternotes")
        try Data("{\"hello\":\"world\"}".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try CloudTranslator.importArchive(from: url, into: try makeContext())) { error in
            XCTAssertEqual(error as? ArchiveError, .invalidArchive)
        }
    }

    func testCorruptJSONIsRejected() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-\(UUID().uuidString).betternotes")
        try Data([0x00, 0xFF, 0x00, 0xFF]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try CloudTranslator.importArchive(from: url, into: try makeContext()))
    }

    func testNearbySnapshotKeepsTrashAndMedia() throws {
        let source = populatedNotebook(in: try makeContext())
        source.trashedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try CloudTranslator.syncArchiveData(for: source)
        let restored = try CloudTranslator.importArchiveData(data, into: try makeContext())
        XCTAssertEqual(restored.stableID, source.stableID)
        XCTAssertEqual(restored.trashedAt, source.trashedAt)
        XCTAssertEqual(restored.pages.count, 2)
        XCTAssertNotNil(restored.pages.first { $0.title == "Deleted draft" }?.trashedAt)
        let media = try XCTUnwrap(restored.pages.first { $0.title == "Alkenes" }?.elements
            .first { $0.elementType == ElementType.audioRecording.rawValue })
        XCTAssertEqual(media.audioData, Data([5, 5, 5, 5]))
        XCTAssertEqual(media.imageData, Data([9, 8, 7]))
        XCTAssertEqual(try CloudTranslator.syncArchiveData(for: restored), data,
                       "a received notebook should not look edited before anyone changes it")
    }

    func testNearbySnapshotReplacesUnchangedNotebookWithSameIDs() throws {
        let context = try makeContext()
        let original = populatedNotebook(in: context)
        let oldPageID = try XCTUnwrap(original.pages.first { $0.title == "Alkenes" }).stableID
        let source = populatedNotebook(in: try makeContext())
        source.stableID = original.stableID
        source.pages.first { $0.title == "Alkenes" }?.stableID = oldPageID
        source.title = "Updated Chemistry"
        let data = try CloudTranslator.syncArchiveData(for: source)
        let restored = try CloudTranslator.importArchiveData(data, into: context, replacing: original)
        XCTAssertEqual(restored.stableID, source.stableID)
        XCTAssertEqual(restored.title, "Updated Chemistry")
        XCTAssertEqual(restored.pages.first { $0.title == "Alkenes" }?.stableID, oldPageID)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Notebook>()).count, 1)
    }

    func testNearbyMergePreservesConcurrentEdits() {
        XCTAssertEqual(NearbyMergeDecision.decide(localHash: "base", incomingHash: "remote",
                                                  lastSharedHash: "base", lastConflictHash: nil), .replaceLocal)
        XCTAssertEqual(NearbyMergeDecision.decide(localHash: "local", incomingHash: "base",
                                                  lastSharedHash: "base", lastConflictHash: nil), .keepLocal)
        XCTAssertEqual(NearbyMergeDecision.decide(localHash: "local", incomingHash: "remote",
                                                  lastSharedHash: "base", lastConflictHash: nil), .saveConflictCopy)
        XCTAssertEqual(NearbyMergeDecision.decide(localHash: "local", incomingHash: "remote",
                                                  lastSharedHash: "base", lastConflictHash: "remote"), .alreadySavedConflict)
        XCTAssertEqual(NearbyMergeDecision.decide(localHash: nil, incomingHash: "base",
                                                  lastSharedHash: "base", lastConflictHash: nil), .keepLocal)
        XCTAssertEqual(NearbyMergeDecision.decide(
            localHash: "new local edit", incomingHash: "old remote copy",
            lastSharedHash: "stale local baseline", lastConflictHash: nil,
            remoteSharedHash: "old remote copy"
        ), .keepLocal, "an unchanged peer must not create a copy because of a stale baseline")
        XCTAssertEqual(NearbyMergeDecision.decide(
            localHash: "new local edit", incomingHash: "new remote edit",
            lastSharedHash: "shared", lastConflictHash: nil,
            remoteSharedHash: "shared"
        ), .saveConflictCopy, "independent edits on both devices must survive")
        XCTAssertEqual(NearbyMergeDecision.decide(
            localHash: "new local edit", incomingHash: "new remote edit",
            lastSharedHash: "shared", lastConflictHash: nil,
            remoteSharedHash: "shared", receivingFirst: true
        ), .preserveLocalAndReplace,
           "the first receiver must converge the original ID and keep one local copy")
        XCTAssertEqual(NearbyMergeDecision.decide(
            localHash: "new local edit", incomingHash: "new remote edit",
            lastSharedHash: "shared", lastConflictHash: "new remote edit",
            remoteSharedHash: "shared", receivingFirst: true
        ), .preserveLocalAndReplace,
           "an old conflict marker must not block convergence after upgrading")
    }

    func testNearbyConcurrentExchangeConvergesWithOneConflictCopy() throws {
        let macContext = try makeContext()
        let ipadContext = try makeContext()
        let macOriginal = populatedNotebook(in: macContext)
        let sharedSnapshot = try CloudTranslator.syncArchiveData(for: macOriginal)
        let ipadOriginal = try CloudTranslator.importArchiveData(sharedSnapshot, into: ipadContext)
        let originalID = macOriginal.stableID

        macOriginal.title = "Mac edit"
        ipadOriginal.title = "iPad edit"
        let macSnapshot = try CloudTranslator.syncArchiveData(for: macOriginal)
        let ipadSnapshot = try CloudTranslator.syncArchiveData(for: ipadOriginal)

        // The initiator receives the first snapshot, preserves its edit, and
        // adopts the sender's version under the shared notebook identity.
        let conflictCopy = try CloudTranslator.importArchiveData(
            ipadSnapshot, into: ipadContext, conflictSuffix: "iPad"
        )
        let convergedOriginal = try CloudTranslator.importArchiveData(
            macSnapshot, into: ipadContext, replacing: ipadOriginal
        )
        XCTAssertEqual(convergedOriginal.stableID, originalID)
        XCTAssertNotEqual(conflictCopy.stableID, originalID)
        XCTAssertEqual(try CloudTranslator.syncArchiveData(for: convergedOriginal), macSnapshot)

        // The reply contains the converged original and one copy. The other
        // device sees the original unchanged and imports the copy once.
        let replyCopy = try CloudTranslator.syncArchiveData(for: conflictCopy)
        let macCopy = try CloudTranslator.importArchiveData(replyCopy, into: macContext)
        XCTAssertEqual(macCopy.stableID, conflictCopy.stableID)
        XCTAssertEqual(try CloudTranslator.syncArchiveData(for: macCopy), replyCopy)
        XCTAssertEqual(try macContext.fetch(FetchDescriptor<Notebook>()).count, 2)
        XCTAssertEqual(try ipadContext.fetch(FetchDescriptor<Notebook>()).count, 2)
    }

    func testNearbyCleanupTrashesOnlyIdenticalGeneratedCopies() throws {
        let context = try makeContext()
        let original = Notebook(title: "Study")
        let page = Page(index: 0)
        page.inkData = Data([1, 2, 3, 4])
        page.notebook = original
        original.pages = [page]
        context.insert(original)
        let snapshot = try CloudTranslator.syncArchiveData(for: original)
        let identicalCopy = try CloudTranslator.importArchiveData(
            snapshot, into: context, conflictSuffix: "iPad"
        )
        let editedCopy = try CloudTranslator.importArchiveData(
            snapshot, into: context, conflictSuffix: "Mac"
        )
        editedCopy.pages[0].ocrText = "A distinct edit"

        XCTAssertEqual(try NearbyConflictCleanup.redundantCopyIDs(in: context), [identicalCopy.stableID])
        let result = try NearbyConflictCleanup.organizeLegacyCopies(in: context)
        XCTAssertEqual(result.trashed, 1)
        XCTAssertEqual(result.archived, 1)
        XCTAssertNil(original.trashedAt)
        XCTAssertNotNil(identicalCopy.trashedAt)
        XCTAssertNil(editedCopy.trashedAt)
        XCTAssertTrue(editedCopy.isArchived)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Notebook>()).count, 3,
                       "cleanup must keep every notebook recoverable")
    }

    func testNearbyAcknowledgementRecordsOnlyVersionsThePeerAccepted() {
        let sharedID = UUID()
        let otherID = UUID()
        let confirmed = NearbySyncAcknowledgements.confirmed(
            sent: [sharedID: "sent", otherID: "other"],
            accepted: [
                NearbySyncAcknowledgement(id: sharedID, hash: "sent"),
                NearbySyncAcknowledgement(id: otherID, hash: "older"),
                NearbySyncAcknowledgement(id: UUID(), hash: "unknown"),
            ]
        )
        XCTAssertEqual(confirmed, [sharedID: "sent"])
        XCTAssertEqual(NearbyMergeDecision.decide(
            localHash: "new local edit", incomingHash: "sent",
            lastSharedHash: confirmed[sharedID], lastConflictHash: nil
        ), .keepLocal, "a peer echoing an acknowledged version must not create a conflict copy")
        XCTAssertEqual(NearbyMergeDecision.decide(
            localHash: "sent", incomingHash: "new remote edit",
            lastSharedHash: confirmed[sharedID], lastConflictHash: nil
        ), .replaceLocal, "the peer's next edit should advance the shared notebook")
    }

    func testNearbySnapshotIsStableAfterImport() throws {
        let source = populatedNotebook(in: try makeContext())
        let snapshot = try CloudTranslator.syncArchiveData(for: source)
        let restored = try CloudTranslator.importArchiveData(snapshot, into: try makeContext())
        let forwarded = try CloudTranslator.syncArchiveData(for: restored)
        XCTAssertEqual(snapshot, forwarded,
                       "A receiving device changed a notebook's sync hash without an edit, creating conflict copies on the sender")
    }

    func testNearbySnapshotIgnoresCrossDeviceTimestampDrift() throws {
        let source = populatedNotebook(in: try makeContext())
        let base = Date(timeIntervalSince1970: 1_700_000_000.1234)
        source.createdAt = base
        source.modifiedAt = base
        for page in source.pages {
            page.createdAt = base
            page.modifiedAt = base
            page.ocrUpdatedAt = base
            if page.trashedAt != nil { page.trashedAt = base }
            for element in page.elements { element.createdAt = base }
        }
        let snapshot = try CloudTranslator.syncArchiveData(for: source)
        let restored = try CloudTranslator.importArchiveData(snapshot, into: try makeContext())
        let drifted = base.addingTimeInterval(0.0000001192)
        restored.createdAt = drifted
        restored.modifiedAt = drifted
        for page in restored.pages {
            page.createdAt = drifted
            page.modifiedAt = drifted
            page.ocrUpdatedAt = drifted
            if page.trashedAt != nil { page.trashedAt = drifted }
            for element in page.elements { element.createdAt = drifted }
        }
        XCTAssertEqual(snapshot, try CloudTranslator.syncArchiveData(for: restored),
                       "Sub-microsecond SwiftData rounding created a false nearby sync conflict")
    }

    func testNearbySnapshotOrdersPagesWithTheSameIndexDeterministically() throws {
        let source = populatedNotebook(in: try makeContext())
        let second = Page(index: 1)
        second.title = "Another page at index one"
        second.notebook = source
        source.pages.append(second)
        let snapshot = try CloudTranslator.syncArchiveData(for: source)
        let restored = try CloudTranslator.importArchiveData(snapshot, into: try makeContext())
        restored.pages.reverse()
        XCTAssertEqual(snapshot, try CloudTranslator.syncArchiveData(for: restored),
                       "Relationship order changed the sync hash for equal-index pages")
    }
}
