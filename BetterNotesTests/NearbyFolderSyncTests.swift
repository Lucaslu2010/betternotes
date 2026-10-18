import XCTest
import SwiftData
@testable import BetterNotes

/// Folders are identified by path, so the merge is a three-way comparison of
/// path sets against the paths both devices had after the last exchange.
@MainActor
final class NearbyFolderSyncTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([Notebook.self, NotebookFolder.self, Page.self, PageElement.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
    }

    private func remote(_ path: String, color: String = "4A6FA5", favorite: Bool = false,
                        archived: Bool = false, trashedAt: Double? = nil,
                        modifiedAt: Double = 1_800_000_000) -> NearbySyncFolder {
        NearbySyncFolder(path: path, colorHex: color, isFavorite: favorite, isArchived: archived,
                         trashedAt: trashedAt, modifiedAt: modifiedAt)
    }

    private func paths(_ context: ModelContext) throws -> Set<String> {
        Set(try context.fetch(FetchDescriptor<NotebookFolder>()).map(\.path))
    }

    func testFirstExchangeAddsMissingFoldersAndTheirAncestors() throws {
        let context = try makeContext()
        let result = try NearbyFolderSync.merge([remote("School/Science/Biology")], baseline: nil, in: context)
        let expected: Set<String> = ["School", "School/Science", "School/Science/Biology"]
        XCTAssertEqual(try paths(context), expected)
        XCTAssertEqual(result, expected)
    }

    func testFirstExchangeNeverDeletesALocalFolder() throws {
        let context = try makeContext()
        _ = try NotebookFolders.create("Local only", in: context)
        let result = try NearbyFolderSync.merge([remote("Remote only")], baseline: nil, in: context)
        XCTAssertEqual(try paths(context), ["Local only", "Remote only"])
        XCTAssertEqual(result, ["Local only", "Remote only"])
    }

    func testFolderDeletedOnThePeerSinceTheLastExchangeIsDeletedHere() throws {
        let context = try makeContext()
        _ = try NotebookFolders.create("Kept", in: context)
        _ = try NotebookFolders.create("Removed", in: context)
        let result = try NearbyFolderSync.merge([remote("Kept")], baseline: ["Kept", "Removed"], in: context)
        XCTAssertEqual(try paths(context), ["Kept"])
        XCTAssertEqual(result, ["Kept"])
    }

    func testFolderDeletedHereIsNotRecreatedFromThePeersStaleList() throws {
        let context = try makeContext()
        _ = try NotebookFolders.create("Kept", in: context)
        let result = try NearbyFolderSync.merge([remote("Kept"), remote("Deleted here")],
                                                baseline: ["Kept", "Deleted here"], in: context)
        XCTAssertEqual(try paths(context), ["Kept"])
        XCTAssertEqual(result, ["Kept"])
    }

    func testFolderCreatedHereSinceTheLastExchangeIsKept() throws {
        let context = try makeContext()
        _ = try NotebookFolders.create("Shared", in: context)
        _ = try NotebookFolders.create("Brand new", in: context)
        let result = try NearbyFolderSync.merge([remote("Shared")], baseline: ["Shared"], in: context)
        XCTAssertEqual(try paths(context), ["Shared", "Brand new"])
        XCTAssertEqual(result, ["Shared", "Brand new"])
    }

    func testFolderCreatedOnThePeerSinceTheLastExchangeIsAdded() throws {
        let context = try makeContext()
        _ = try NotebookFolders.create("Shared", in: context)
        let result = try NearbyFolderSync.merge([remote("Shared"), remote("From peer", color: "C06C84", favorite: true)],
                                                baseline: ["Shared"], in: context)
        XCTAssertEqual(result, ["Shared", "From peer"])
        let added = try XCTUnwrap(context.fetch(FetchDescriptor<NotebookFolder>()).first { $0.path == "From peer" })
        XCTAssertEqual(added.colorHex, "C06C84")
        XCTAssertTrue(added.isFavorite)
    }

    func testARenameArrivesAsOneFolderGoneAndOneCreated() throws {
        let context = try makeContext()
        _ = try NotebookFolders.create("School", in: context)
        let result = try NearbyFolderSync.merge([remote("Classes")], baseline: ["School"], in: context)
        XCTAssertEqual(try paths(context), ["Classes"])
        XCTAssertEqual(result, ["Classes"])
    }

    func testNewerPeerStateWinsAndOlderPeerStateIsIgnored() throws {
        let context = try makeContext()
        let newer = try NotebookFolders.create("Newer elsewhere", in: context)
        let older = try NotebookFolders.create("Newer here", in: context)
        newer.modifiedAt = Date(timeIntervalSince1970: 1_000)
        older.modifiedAt = Date(timeIntervalSince1970: 3_000)
        try context.save()
        _ = try NearbyFolderSync.merge([
            remote("Newer elsewhere", color: "C06C84", favorite: true, archived: true,
                   trashedAt: 2_000, modifiedAt: 2_000),
            remote("Newer here", color: "000000", favorite: true, modifiedAt: 2_000)
        ], baseline: ["Newer elsewhere", "Newer here"], in: context)
        XCTAssertEqual(newer.colorHex, "C06C84")
        XCTAssertTrue(newer.isFavorite)
        XCTAssertTrue(newer.isArchived)
        XCTAssertEqual(newer.trashedAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(newer.modifiedAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertNotEqual(older.colorHex, "000000")
        XCTAssertFalse(older.isFavorite)
        XCTAssertEqual(older.modifiedAt, Date(timeIntervalSince1970: 3_000))
    }

    func testRestoringAFolderOnThePeerClearsItsTrashDateHere() throws {
        let context = try makeContext()
        let folder = try NotebookFolders.create("Restored", in: context)
        folder.trashedAt = Date(timeIntervalSince1970: 1_000)
        folder.modifiedAt = Date(timeIntervalSince1970: 1_000)
        try context.save()
        _ = try NearbyFolderSync.merge([remote("Restored", trashedAt: nil, modifiedAt: 2_000)],
                                       baseline: ["Restored"], in: context)
        XCTAssertNil(folder.trashedAt)
    }

    func testInvalidRemotePathsAreIgnored() throws {
        let context = try makeContext()
        let bad = ["", "/", "A//B", "../Escape", "A/../B", "A/.", "/Leading", "Trailing/", String(repeating: "x", count: 401)]
        let result = try NearbyFolderSync.merge(bad.map { remote($0) } + [remote("Fine")], baseline: nil, in: context)
        XCTAssertEqual(try paths(context), ["Fine"])
        XCTAssertEqual(result, ["Fine"])
    }

    func testNotebooksStillInADeletedFolderKeepItAlive() throws {
        let context = try makeContext()
        _ = try NotebookFolders.create("School", in: context)
        let notebook = Notebook(title: "Homework")
        notebook.folderName = "School"
        context.insert(notebook)
        try context.save()
        let result = try NearbyFolderSync.merge([], baseline: ["School"], in: context)
        XCTAssertEqual(try paths(context), ["School"], "A folder with notebooks in it must not disappear")
        XCTAssertEqual(result, ["School"])
    }

    func testMergeReturnsExactlyTheResultingPathsAsTheNextBaseline() throws {
        let context = try makeContext()
        _ = try NotebookFolders.create("A", in: context)
        let result = try NearbyFolderSync.merge([remote("B/C")], baseline: nil, in: context)
        XCTAssertEqual(result, try paths(context))
        XCTAssertEqual(result, ["A", "B", "B/C"])
    }

    func testSnapshotIsSortedAndRoundedToMilliseconds() throws {
        let context = try makeContext()
        let b = try NotebookFolders.create("B", in: context)
        _ = try NotebookFolders.create("A", in: context, parentPath: "")
        b.modifiedAt = Date(timeIntervalSince1970: 1_800_000_000.123_456)
        b.trashedAt = Date(timeIntervalSince1970: 1_800_000_001.987_654)
        try context.save()
        let snapshot = try NearbyFolderSync.snapshot(in: context)
        XCTAssertEqual(snapshot.map(\.path), ["A", "B"])
        let entry = try XCTUnwrap(snapshot.last)
        XCTAssertEqual(entry.modifiedAt, 1_800_000_000.123, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(entry.trashedAt), 1_800_000_001.988, accuracy: 0.000_001)
    }

    func testSnapshotRoundTripsThroughJSONAndMergesToAnIdenticalLibrary() throws {
        let source = try makeContext()
        let folder = try NotebookFolders.create("School", in: source)
        _ = try NotebookFolders.create("Math", in: source, parentPath: folder.path)
        folder.colorHex = "C06C84"; folder.isFavorite = true
        folder.modifiedAt = .now
        try source.save()
        let data = try JSONEncoder().encode(try NearbyFolderSync.snapshot(in: source))
        let decoded = try JSONDecoder().decode([NearbySyncFolder].self, from: data)
        let target = try makeContext()
        _ = try NearbyFolderSync.merge(decoded, baseline: nil, in: target)
        XCTAssertEqual(try NearbyFolderSync.snapshot(in: target).map(\.path), ["School", "School/Math"])
        let copy = try XCTUnwrap(target.fetch(FetchDescriptor<NotebookFolder>()).first { $0.path == "School" })
        XCTAssertEqual(copy.colorHex, "C06C84")
        XCTAssertTrue(copy.isFavorite)
    }
}
