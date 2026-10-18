import XCTest
import SwiftData
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import BetterNotes

@MainActor
final class DocumentSupportTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        temporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryURLs = []
        super.tearDown()
    }

    private func context() throws -> ModelContext {
        let schema = Schema([Notebook.self, NotebookFolder.self, Page.self, PageElement.self])
        return ModelContext(try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        ]))
    }

    private func url(_ suffix: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Document-\(UUID().uuidString).\(suffix)")
        temporaryURLs.append(url)
        return url
    }

    func testEmptyFolderPersistsWithoutAnyNotebooks() throws {
        let directory = url("folder-test")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let schema = Schema([Notebook.self, NotebookFolder.self, Page.self, PageElement.self])
        let configuration = ModelConfiguration(schema: schema, url: directory.appendingPathComponent("folders.store"))
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let folder = try NotebookFolders.create("  School  ", in: container.mainContext)
            XCTAssertEqual(folder.name, "School")
            XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Notebook>()), 0)
        }
        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        XCTAssertEqual(try reopened.mainContext.fetch(FetchDescriptor<NotebookFolder>()).map(\.name), ["School"])
    }

    func testFolderValidationAndLegacyNamesArePreserved() throws {
        let context = try context()
        let notebook = Notebook(title: "Existing")
        notebook.folderName = "Old Folder"
        context.insert(notebook)
        try context.save()
        XCTAssertThrowsError(try NotebookFolders.create(" \n ", in: context))
        XCTAssertThrowsError(try NotebookFolders.create("old folder", in: context))
        try NotebookFolders.preserveMemberships(in: context)
        try NotebookFolders.preserveMemberships(in: context)
        context.delete(notebook)
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<NotebookFolder>()).map(\.name), ["Old Folder"])
        XCTAssertThrowsError(try NotebookFolders.create("OLD FOLDER", in: context))
    }

    func testFolderRenameUpdatesAllDescendantsWithoutTouchingSiblingPrefixes() throws {
        let context = try context()
        let school = try NotebookFolders.create("School", in: context)
        let child = try NotebookFolders.create("Math", in: context, parentPath: school.path)
        let nested = Notebook(title: "Homework")
        nested.folderName = child.path
        nested.trashedAt = Date(timeIntervalSince1970: 100)
        let sibling = Notebook(title: "Different folder")
        sibling.folderName = "Schoolwork"
        context.insert(nested); context.insert(sibling)
        school.colorHex = "C06C84"; school.isFavorite = true
        try context.save()
        try NotebookFolders.rename(school, to: "Classes", in: context)
        XCTAssertEqual(child.path, "Classes/Math")
        XCTAssertEqual(nested.folderName, "Classes/Math")
        XCTAssertEqual(sibling.folderName, "Schoolwork")
        XCTAssertNotNil(nested.trashedAt)
        XCTAssertEqual(school.colorHex, "C06C84")
        XCTAssertTrue(school.isFavorite)
        _ = try NotebookFolders.create("Taken", in: context)
        XCTAssertThrowsError(try NotebookFolders.rename(school, to: "taken", in: context))
        XCTAssertEqual(child.path, "Classes/Math", "A failed rename must not change any memberships")
    }

    func testFolderArchiveIsInheritedAndPreservesIndividualNotebookArchive() throws {
        let context = try context()
        let folder = try NotebookFolders.create("School", in: context)
        let child = try NotebookFolders.create("Math", in: context, parentPath: folder.path)
        let regular = Notebook(title: "Current")
        regular.folderName = child.path
        let archived = Notebook(title: "Old")
        archived.folderName = child.path; archived.isArchived = true
        context.insert(regular); context.insert(archived)
        folder.isArchived = true
        try context.save()
        XCTAssertTrue(regular.isEffectivelyArchived)
        XCTAssertTrue(NoteCorpusStore.sources(from: [regular]).allSatisfy(\.isArchived))
        XCTAssertThrowsError(try NotebookFolders.move(notebookIDs: [archived.stableID], to: child.path, in: context))
        folder.isArchived = false
        try context.save()
        XCTAssertFalse(regular.isEffectivelyArchived)
        XCTAssertTrue(archived.isEffectivelyArchived)
        XCTAssertFalse(regular.isArchived, "Archiving a folder must preserve individual notebook flags")
    }

    func testFolderTrashRestoresOnlyContentsDeletedWithItAfterRelaunch() throws {
        let directory = url("folder-trash-test")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let schema = Schema([Notebook.self, NotebookFolder.self, Page.self, PageElement.self])
        let configuration = ModelConfiguration(schema: schema, url: directory.appendingPathComponent("folders.store"))
        let now = Date(timeIntervalSince1970: 1_800_000_000.123)
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext
            let folder = try NotebookFolders.create("School", in: context)
            let child = try NotebookFolders.create("Old", in: context, parentPath: folder.path)
            let live = Notebook(title: "Current")
            live.folderName = folder.path
            let alreadyDeleted = Notebook(title: "Deleted earlier")
            alreadyDeleted.folderName = folder.path; alreadyDeleted.trashedAt = now.addingTimeInterval(-100)
            let deletedChildNote = Notebook(title: "Inside old folder")
            deletedChildNote.folderName = child.path
            context.insert(live); context.insert(alreadyDeleted); context.insert(deletedChildNote)
            try context.save()
            try NotebookFolders.trash(child, in: context, now: now.addingTimeInterval(-50))
            try NotebookFolders.trash(folder, in: context, now: now)
            XCTAssertEqual(live.trashedAt, now)
            XCTAssertTrue(NoteCorpusStore.sources(from: [live, alreadyDeleted, deletedChildNote]).isEmpty)
            XCTAssertFalse(try NotebookFolders.move(notebookIDs: [live.stableID], to: "", in: context))
        }
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let folders = try context.fetch(FetchDescriptor<NotebookFolder>())
        let root = try XCTUnwrap(folders.first { $0.path == "School" })
        try NotebookFolders.restore(root, in: context)
        let notebooks = try context.fetch(FetchDescriptor<Notebook>())
        XCTAssertNil(notebooks.first { $0.title == "Current" }?.trashedAt)
        XCTAssertNotNil(notebooks.first { $0.title == "Deleted earlier" }?.trashedAt)
        XCTAssertNotNil(notebooks.first { $0.title == "Inside old folder" }?.trashedAt)
        XCTAssertNotNil(folders.first { $0.path == "School/Old" }?.trashedAt)
    }

    func testHierarchySeparatesRootAndNestedFolderContents() throws {
        let context = try context()
        let school = try NotebookFolders.create("School", in: context)
        let personal = try NotebookFolders.create("Personal", in: context)
        let math = try NotebookFolders.create("Notes", in: context, parentPath: school.path)
        _ = try NotebookFolders.create("Notes", in: context, parentPath: personal.path)
        XCTAssertEqual(math.path, "School/Notes")
        let paths = try context.fetch(FetchDescriptor<NotebookFolder>()).map(\.path)
        XCTAssertEqual(FolderPath.children(of: "", in: paths), ["Personal", "School"])
        XCTAssertEqual(FolderPath.children(of: school.path, in: paths), ["School/Notes"])
        XCTAssertFalse(FolderPath.containsNotebook("School/Notes", at: ""))
        XCTAssertFalse(FolderPath.containsNotebook("School/Notes", at: "School"))
        XCTAssertTrue(FolderPath.containsNotebook("School/Notes", at: "School/Notes"))
        XCTAssertEqual(FolderPath.ancestors(including: "School/Notes"), ["School", "School/Notes"])
        XCTAssertThrowsError(try NotebookFolders.create("notes", in: context, parentPath: school.path))
        for name in [".", "..", "School/Math"] {
            XCTAssertThrowsError(try NotebookFolders.create(name, in: context))
        }
    }

    func testDropMoveChangesOnlyMembershipAndCanMoveBackToRoot() throws {
        let context = try context()
        let folder = try NotebookFolders.create("School", in: context)
        let notebook = Notebook(title: "My notes")
        let page = Page(index: 0)
        page.inkData = Data([1, 2, 3])
        page.notebook = notebook
        notebook.pages.append(page)
        context.insert(notebook)
        try context.save()
        XCTAssertTrue(try NotebookFolders.move(notebookIDs: [notebook.stableID], to: folder.path, in: context))
        XCTAssertEqual(notebook.folderName, folder.path)
        XCTAssertEqual(notebook.pages[0].inkData, Data([1, 2, 3]))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Notebook>()), 1)
        XCTAssertFalse(try NotebookFolders.move(notebookIDs: [notebook.stableID], to: folder.path, in: context))
        XCTAssertTrue(try NotebookFolders.move(notebookIDs: [notebook.stableID], to: "", in: context))
        XCTAssertEqual(notebook.folderName, "")
        XCTAssertFalse(try NotebookFolders.move(notebookIDs: [notebook.stableID, UUID()], to: folder.path, in: context))
        XCTAssertEqual(notebook.folderName, "", "An invalid drag must not move part of its selection")
        XCTAssertThrowsError(try NotebookFolders.move(notebookIDs: [notebook.stableID], to: "Missing", in: context))
        notebook.trashedAt = .now
        XCTAssertFalse(try NotebookFolders.move(notebookIDs: [notebook.stableID], to: folder.path, in: context))
    }

    func testLegacyNestedMembershipCreatesAllAncestorFolders() throws {
        let context = try context()
        let notebook = Notebook(title: "Imported backup")
        notebook.folderName = "School/Science/Biology"
        context.insert(notebook)
        try context.save()
        try NotebookFolders.preserveMemberships(in: context)
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<NotebookFolder>()).map(\.path)),
                       ["School", "School/Science", "School/Science/Biology"])
        XCTAssertEqual(notebook.folderName, "School/Science/Biology")
    }

    func testPDFImportCreatesAnnotatablePagesWithSearchableText() async throws {
        let context = try context()
        let url = url("PDF")
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { context in
            for _ in 0..<2 {
                context.beginPage()
                ("A document question" as NSString).draw(at: CGPoint(x: 30, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            }
        }
        try data.write(to: url)
        let notebook = try await DocumentImporter.importDocument(from: url, into: context, folderName: "School")
        XCTAssertEqual(notebook.title, url.deletingPathExtension().lastPathComponent)
        XCTAssertEqual(notebook.folderName, "School")
        XCTAssertEqual(notebook.pages.count, 2)
        for page in notebook.pages {
            XCTAssertTrue(page.pdfText.contains("A document question"))
            XCTAssertEqual(page.elements.count, 1)
            XCTAssertTrue(page.elements[0].isLocked)
            XCTAssertNotNil(page.elements[0].imageData)
            XCTAssertTrue(page.notebook === notebook)
            XCTAssertNil(page.lastHandwrittenQuestionFingerprint)
        }
    }

    func testPNGAndJPEGImportAsCenteredLockedImages() async throws {
        let context = try context()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 300)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
        }
        for suffix in ["png", "jpg"] {
            let url = url(suffix)
            try XCTUnwrap(suffix == "png" ? image.pngData() : image.jpegData(compressionQuality: 0.9)).write(to: url)
            let notebook = try await DocumentImporter.importDocument(from: url, into: context)
            let page = try XCTUnwrap(notebook.pages.first)
            XCTAssertEqual(page.orientation, PageOrientation.landscape.rawValue)
            let element = try XCTUnwrap(page.elements.first)
            XCTAssertTrue(element.isLocked)
            XCTAssertNotNil(UIImage(data: try XCTUnwrap(element.imageData)))
            XCTAssertEqual(element.posX, 512, accuracy: 0.01)
            XCTAssertEqual(element.posY, 384, accuracy: 0.01)
            XCTAssertEqual(element.width / element.height, 2, accuracy: 0.01)
        }
    }

    func testOpeningBackupTwiceCreatesDistinctNavigableNotebooks() async throws {
        let context = try context()
        let original = Notebook(title: "Backup")
        original.isArchived = true
        context.insert(original)
        try context.save()
        let url = url("betternotes")
        try CloudTranslator.archiveData(for: original).write(to: url)
        let first = try await DocumentImporter.importDocument(from: url, into: context, folderName: "School")
        let second = try await DocumentImporter.importDocument(from: url, into: context)
        XCTAssertEqual(Set([original.stableID, first.stableID, second.stableID]).count, 3)
        XCTAssertEqual(first.folderName, "School")
        XCTAssertFalse(first.isArchived)
        XCTAssertFalse(second.isArchived)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Notebook>()), 3)
    }

    func testInvalidAndUnsupportedFilesDoNotCreateNotebooks() async throws {
        let context = try context()
        for suffix in ["pdf", "png", "betternotes", "docx", "pptx", "xlsx", "txt"] {
            let url = url(suffix)
            try Data("Not a document".utf8).write(to: url)
            do {
                _ = try await DocumentImporter.importDocument(from: url, into: context)
                XCTFail("Invalid \(suffix) was accepted")
            } catch { /* Expected: show an error without a partial notebook. */ }
        }
        XCTAssertThrowsError(try DocumentImporter.kind(for: URL(string: "https://example.com/document.pdf")!))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Notebook>()), 0)
    }

    func testFailedArchiveConfigurationDoesNotLeaveAPartialNotebook() throws {
        let context = try context()
        let url = url("betternotes")
        try CloudTranslator.archiveData(for: Notebook(title: "A backup")).write(to: url)
        XCTAssertThrowsError(try CloudTranslator.importArchive(from: url, into: context) { _ in
            throw DocumentImporter.ImportError.noPages
        })
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Notebook>()), 0)
    }

    func testBuiltBundleRegistersExactlyTheSupportedDocumentTypes() throws {
        let declarations = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]])
        let registered = Set(declarations.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        XCTAssertEqual(registered, Set(DocumentImporter.supportedTypes.map(\.identifier)))
        XCTAssertEqual(Bundle.main.infoDictionary?["LSSupportsOpeningDocumentsInPlace"] as? Bool, true)
        XCTAssertEqual(UTType(filenameExtension: "betternotes"), .betterNotesArchive)
        let decoders = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
        for type in DocumentImporter.imageTypes {
            XCTAssertTrue(decoders.contains(type.identifier), "No system decoder for \(type.identifier)")
        }
    }
}
