import Foundation
import SwiftData

/// Separate from notebook membership so an empty folder survives a relaunch.
@Model
final class NotebookFolder {
    var name: String
    var parentPath: String = ""
    var createdAt: Date = Date.now
    var isFavorite: Bool = false
    var isArchived: Bool = false
    var colorHex: String = "4A6FA5"
    var trashedAt: Date?
    /// When the folder's own state last changed. Nearby sync keeps the newer
    /// side of a folder that both devices edited.
    var modifiedAt: Date = Date.now

    init(name: String, parentPath: String = "") {
        self.name = name
        self.parentPath = parentPath
    }

    var path: String { FolderPath.appending(name, to: parentPath) }
}

/// Paths are library locations, never filesystem paths. Existing flat folder
/// names remain valid root folders; notebook backups retain their membership.
enum FolderPath {
    static func appending(_ name: String, to parent: String) -> String {
        parent.isEmpty ? name : parent + "/" + name
    }

    static func parent(of path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }

    static func name(of path: String) -> String { String(path.split(separator: "/").last ?? "") }

    static func ancestors(including path: String) -> [String] {
        let parts = path.split(separator: "/")
        return parts.indices.map { parts[...$0].joined(separator: "/") }
    }

    static func children(of parent: String, in paths: [String]) -> [String] {
        paths.filter { self.parent(of: $0) == parent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func contains(_ path: String, in ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor + "/")
    }

    static func replacingAncestor(in path: String, from old: String, to new: String) -> String {
        guard contains(path, in: old) else { return path }
        return new + path.dropFirst(old.count)
    }

    static func containsNotebook(_ membership: String, at location: String) -> Bool {
        membership == location
    }
}

@MainActor
enum NotebookFolders {
    enum FolderError: LocalizedError {
        case emptyName, duplicateName, invalidName, unavailableFolder
        var errorDescription: String? {
            switch self {
            case .emptyName: return AppLocalization.text("Enter a folder name.")
            case .duplicateName: return AppLocalization.text("A folder with this name already exists.")
            case .invalidName: return AppLocalization.text("Use a folder name without a slash; the names “.” and “..” are not allowed.")
            case .unavailableFolder: return AppLocalization.text("This folder is no longer available.")
            }
        }
    }

    static func isArchived(_ path: String, in folders: [NotebookFolder]) -> Bool {
        folders.contains { $0.isArchived && FolderPath.contains(path, in: $0.path) }
    }

    static func isTrashed(_ path: String, in folders: [NotebookFolder]) -> Bool {
        folders.contains { $0.trashedAt != nil && FolderPath.contains(path, in: $0.path) }
    }

    static func isAvailable(_ path: String, in folders: [NotebookFolder]) -> Bool {
        path.isEmpty || (folders.contains { $0.path == path } && !isTrashed(path, in: folders) && !isArchived(path, in: folders))
    }

    static func create(_ name: String, in context: ModelContext, parentPath: String = "") throws -> NotebookFolder {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FolderError.emptyName }
        guard !name.contains("/"), name != ".", name != ".." else { throw FolderError.invalidName }
        let folders = try context.fetch(FetchDescriptor<NotebookFolder>())
        let notebooks = try context.fetch(FetchDescriptor<Notebook>())
        let paths = folders.map(\.path) + notebooks.map(\.folderName)
        guard parentPath.isEmpty || (paths.contains(parentPath) && !isTrashed(parentPath, in: folders) && !isArchived(parentPath, in: folders)) else { throw FolderError.unavailableFolder }
        let path = FolderPath.appending(name, to: parentPath)
        guard !paths.contains(where: { $0.localizedCaseInsensitiveCompare(path) == .orderedSame }) else {
            throw FolderError.duplicateName
        }
        let folder = NotebookFolder(name: name, parentPath: parentPath)
        context.insert(folder)
        do { try context.save() }
        catch { context.delete(folder); throw error }
        return folder
    }

    /// Preserve the names used by older versions and by restored backups.
    static func preserveMemberships(in context: ModelContext) throws {
        let existing = Set(try context.fetch(FetchDescriptor<NotebookFolder>()).map(\.path))
        let memberships = try context.fetch(FetchDescriptor<Notebook>()).map(\.folderName)
        let needed = Set((memberships + Array(existing)).flatMap { FolderPath.ancestors(including: $0) })
        let added = needed.subtracting(existing).map {
            NotebookFolder(name: FolderPath.name(of: $0), parentPath: FolderPath.parent(of: $0))
        }
        guard !added.isEmpty else { return }
        added.forEach(context.insert)
        do { try context.save() }
        catch { added.forEach(context.delete); throw error }
    }

    /// Rewrite every membership in one save, including archived/trashed descendants.
    static func rename(_ folder: NotebookFolder, to proposedName: String, in context: ModelContext) throws {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FolderError.emptyName }
        guard !name.contains("/"), name != ".", name != ".." else { throw FolderError.invalidName }
        let folders = try context.fetch(FetchDescriptor<NotebookFolder>())
        let notebooks = try context.fetch(FetchDescriptor<Notebook>())
        let old = folder.path
        let new = FolderPath.appending(name, to: folder.parentPath)
        guard !folders.contains(where: { $0 !== folder && $0.path.localizedCaseInsensitiveCompare(new) == .orderedSame }),
              !notebooks.contains(where: { !FolderPath.contains($0.folderName, in: old) && $0.folderName.localizedCaseInsensitiveCompare(new) == .orderedSame }) else {
            throw FolderError.duplicateName
        }
        let folderBefore = folders.filter { FolderPath.contains($0.path, in: old) }.map { ($0, $0.name, $0.parentPath) }
        let notebookBefore = notebooks.filter { FolderPath.contains($0.folderName, in: old) }.map { ($0, $0.folderName) }
        let renamedAt = Date.now
        for (child, _, parent) in folderBefore where child !== folder {
            child.parentPath = FolderPath.replacingAncestor(in: parent, from: old, to: new)
            child.modifiedAt = renamedAt
        }
        folder.name = name
        folder.modifiedAt = renamedAt
        for (notebook, path) in notebookBefore {
            notebook.folderName = FolderPath.replacingAncestor(in: path, from: old, to: new)
        }
        do { try context.save() }
        catch {
            for (child, name, parent) in folderBefore { child.name = name; child.parentPath = parent }
            for (notebook, path) in notebookBefore { notebook.folderName = path }
            throw error
        }
    }

    /// A shared deletion date identifies only notebooks deleted with this folder.
    /// Previously deleted descendants keep their own deletion date and state.
    static func trash(_ folder: NotebookFolder, in context: ModelContext, now: Date = .now) throws {
        guard folder.trashedAt == nil else { return }
        let notebooks = try context.fetch(FetchDescriptor<Notebook>()).filter {
            $0.trashedAt == nil && FolderPath.contains($0.folderName, in: folder.path)
        }
        let before = notebooks.map { ($0, $0.modifiedAt) }
        let folderModified = folder.modifiedAt
        folder.trashedAt = now
        folder.modifiedAt = now
        for notebook in notebooks { notebook.trashedAt = now; notebook.modifiedAt = now }
        do { try context.save() }
        catch {
            folder.trashedAt = nil
            folder.modifiedAt = folderModified
            for (notebook, modified) in before { notebook.trashedAt = nil; notebook.modifiedAt = modified }
            throw error
        }
    }

    static func restore(_ folder: NotebookFolder, in context: ModelContext) throws {
        guard let date = folder.trashedAt else { return }
        let folders = try context.fetch(FetchDescriptor<NotebookFolder>())
        guard !folders.contains(where: { $0 !== folder && $0.trashedAt != nil && FolderPath.contains(folder.path, in: $0.path) }) else {
            throw FolderError.unavailableFolder
        }
        let notebooks = try context.fetch(FetchDescriptor<Notebook>()).filter { notebook in
            notebook.trashedAt == date && FolderPath.contains(notebook.folderName, in: folder.path)
                && !folders.contains(where: { $0 !== folder && $0.trashedAt != nil && FolderPath.contains(notebook.folderName, in: $0.path) })
        }
        let before = notebooks.map { ($0, $0.modifiedAt) }
        let folderModified = folder.modifiedAt
        folder.trashedAt = nil
        folder.modifiedAt = .now
        for notebook in notebooks { notebook.trashedAt = nil; notebook.modifiedAt = .now }
        do { try context.save() }
        catch {
            folder.trashedAt = date
            folder.modifiedAt = folderModified
            for (notebook, modified) in before { notebook.trashedAt = date; notebook.modifiedAt = modified }
            throw error
        }
    }

    /// Caller saves with other retention deletions in the same transaction.
    static func removeContents(of folder: NotebookFolder, in context: ModelContext) throws {
        let path = folder.path
        let notebooks = try context.fetch(FetchDescriptor<Notebook>())
        let folders = try context.fetch(FetchDescriptor<NotebookFolder>())
        for notebook in notebooks where FolderPath.contains(notebook.folderName, in: path) { context.delete(notebook) }
        for child in folders where FolderPath.contains(child.path, in: path) { context.delete(child) }
    }

    @discardableResult
    static func move(notebookIDs: [UUID], to destination: String, in context: ModelContext) throws -> Bool {
        let folders = try context.fetch(FetchDescriptor<NotebookFolder>())
        guard isAvailable(destination, in: folders) else {
            throw FolderError.unavailableFolder
        }
        let ids = Set(notebookIDs)
        let notebooks = try context.fetch(FetchDescriptor<Notebook>()).filter {
            ids.contains($0.stableID) && $0.trashedAt == nil
        }
        guard !ids.isEmpty, Set(notebooks.map(\.stableID)) == ids else { return false }
        let changed = notebooks.filter { $0.folderName != destination }
        guard !changed.isEmpty else { return false }
        let before = changed.map { ($0, $0.folderName, $0.modifiedAt) }
        for notebook in changed { notebook.folderName = destination; notebook.modifiedAt = .now }
        do { try context.save() }
        catch {
            for (notebook, path, date) in before { notebook.folderName = path; notebook.modifiedAt = date }
            throw error
        }
        return true
    }
}

@MainActor
extension Notebook {
    var isEffectivelyArchived: Bool {
        if isArchived { return true }
        guard !folderName.isEmpty, let context = modelContext,
              let folders = try? context.fetch(FetchDescriptor<NotebookFolder>()) else { return false }
        return NotebookFolders.isArchived(folderName, in: folders)
    }
}

/// A folder as it travels between paired devices. Folders are identified by
/// their path; a rename therefore arrives as one folder gone and one created.
struct NearbySyncFolder: Codable, Equatable {
    let path: String
    let colorHex: String
    let isFavorite: Bool
    let isArchived: Bool
    let trashedAt: Double?
    let modifiedAt: Double
}

@MainActor
enum NearbyFolderSync {
    /// Milliseconds only, as for notebooks: SwiftData can move a date by one
    /// floating-point step in transit, which would look like an edit.
    private static func milliseconds(_ date: Date) -> Double {
        (date.timeIntervalSince1970 * 1_000).rounded() / 1_000
    }

    static func snapshot(in context: ModelContext) throws -> [NearbySyncFolder] {
        try context.fetch(FetchDescriptor<NotebookFolder>())
            .map {
                NearbySyncFolder(path: $0.path, colorHex: $0.colorHex, isFavorite: $0.isFavorite,
                                 isArchived: $0.isArchived, trashedAt: $0.trashedAt.map(milliseconds),
                                 modifiedAt: milliseconds($0.modifiedAt))
            }
            .sorted { $0.path < $1.path }
    }

    private static func isValid(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && path.count <= 400 && parts.count <= 16
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Three-way merge of the peer's folders into this library.
    ///
    /// `baseline` holds the paths both devices had after the previous exchange.
    /// A path in the baseline that one side no longer has was deleted there, so
    /// the other side drops it as well; a path that was never in the baseline is
    /// new and is kept. With no baseline (first exchange) folders are only
    /// added. A folder both devices still have keeps the newer state.
    /// Returns the paths this library has afterwards, the next baseline.
    @discardableResult
    static func merge(_ remote: [NearbySyncFolder], baseline: Set<String>?,
                      in context: ModelContext) throws -> Set<String> {
        let valid = remote.filter { isValid($0.path) }
        let remoteByPath = Dictionary(valid.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let local = try context.fetch(FetchDescriptor<NotebookFolder>())
        var localByPath: [String: NotebookFolder] = [:]
        for folder in local where localByPath[folder.path] == nil { localByPath[folder.path] = folder }
        do {
            for incoming in valid.sorted(by: { $0.path < $1.path }) {
                if let folder = localByPath[incoming.path] {
                    guard incoming.modifiedAt > folder.modifiedAt.timeIntervalSince1970 + 0.001 else { continue }
                    folder.colorHex = incoming.colorHex
                    folder.isFavorite = incoming.isFavorite
                    folder.isArchived = incoming.isArchived
                    folder.trashedAt = incoming.trashedAt.map(Date.init(timeIntervalSince1970:))
                    folder.modifiedAt = Date(timeIntervalSince1970: incoming.modifiedAt)
                } else if baseline?.contains(incoming.path) != true {
                    for ancestor in FolderPath.ancestors(including: incoming.path).dropLast()
                    where localByPath[ancestor] == nil {
                        let created = NotebookFolder(name: FolderPath.name(of: ancestor), parentPath: FolderPath.parent(of: ancestor))
                        context.insert(created)
                        localByPath[ancestor] = created
                    }
                    let created = NotebookFolder(name: FolderPath.name(of: incoming.path), parentPath: FolderPath.parent(of: incoming.path))
                    created.colorHex = incoming.colorHex
                    created.isFavorite = incoming.isFavorite
                    created.isArchived = incoming.isArchived
                    created.trashedAt = incoming.trashedAt.map(Date.init(timeIntervalSince1970:))
                    created.createdAt = Date(timeIntervalSince1970: incoming.modifiedAt)
                    created.modifiedAt = Date(timeIntervalSince1970: incoming.modifiedAt)
                    context.insert(created)
                    localByPath[incoming.path] = created
                }
                // Otherwise it was deleted here since the last exchange; the
                // peer drops it when it receives this library.
            }
            if let baseline {
                for (path, folder) in localByPath where remoteByPath[path] == nil && baseline.contains(path) {
                    context.delete(folder)
                    localByPath[path] = nil
                }
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        // Notebooks that still live in a folder keep it.
        try NotebookFolders.preserveMemberships(in: context)
        return Set(try context.fetch(FetchDescriptor<NotebookFolder>()).map(\.path))
    }
}
