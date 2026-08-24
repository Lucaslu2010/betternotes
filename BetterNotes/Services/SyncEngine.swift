import Foundation
import SwiftData
import SwiftUI

/// Sync engine: pulls cloud documents and pushes local notebooks.
///
/// Last-write-wins semantics, keyed on the per-document `revision` counter.
/// Each notebook stores its last-synced revision in `UserDefaults` keyed by
/// its cloud clientId, so we know which version to send as `baseRevision`
/// when pushing.
///
/// Flow:
///   pull: GET /api/sync/documents?since=<last>  →  apply each to SwiftData
///   push: for each local notebook,
///           POST /api/sync/documents  with baseRevision = last synced rev
///           on 409: server has newer → re-pull that one and skip push
@MainActor
final class SyncEngine: ObservableObject {

    /// Published status for UI binding.
    @Published var isSyncing = false
    @Published var lastSyncDate: Date?
    @Published var lastError: String?
    @Published var conflictCount = 0

    /// Clears the conflict indicator once the user has acknowledged it.
    /// The preserved Conflict Copy notebooks are untouched.
    func acknowledgeConflicts() {
        conflictCount = 0
    }

    private let auth: SyncAuth
    /// Resolved per request so a Settings change takes effect without relaunch.
    private var baseURL: String { SyncConfig.baseURL }

    /// Tracks the last server-side revision we've seen per clientId, so we
    /// can pass the correct `baseRevision` on push.
    private var revisionStore: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: "sync.revisions") as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "sync.revisions") }
    }

    init(auth: SyncAuth) {
        self.auth = auth
        let timestamp = UserDefaults.standard.double(forKey: "sync.lastSyncTimestamp")
        if timestamp > 0 { self.lastSyncDate = Date(timeIntervalSince1970: timestamp) }
    }

    // MARK: - Auth header

    /// Builds an authorised URLRequest, attaching the bearer token.
    private func authorised(_ request: inout URLRequest) throws {
        guard let token = auth.bearerToken else {
            throw SyncError.invalidCredentials
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    // MARK: - Pull

    /// Fetch all cloud documents newer than the last sync and apply them.
    /// Safe to call repeatedly; idempotent.
    func pullAll(into context: ModelContext) async {
        guard auth.isLoggedIn else {
            lastError = "Not logged in"
            return
        }
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        let sinceISO = lastSyncDate?.ISO8601Format()
        var components = URLComponents(string: "\(baseURL)/api/sync/documents")
        if let sinceISO {
            components?.queryItems = [URLQueryItem(name: "since", value: sinceISO)]
        }
        guard let url = components?.url else {
            lastError = SyncError.badURL.localizedDescription
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        do { try authorised(&request) } catch {
            lastError = error.localizedDescription
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                lastError = "Server returned an error"
                return
            }

            struct SyncResponse: Decodable {
                let documents: [CloudDocDTO]
            }
            struct CloudDocDTO: Decodable {
                let clientId: String
                let title: String
                let body: String
                let blocks: AnyCodable?
                let revision: Int
                let deletedAt: String?
            }

            let parsed = try JSONDecoder().decode(SyncResponse.self, from: data)

            // Track revisions.
            var revisions = revisionStore
            for doc in parsed.documents {
                revisions[doc.clientId] = doc.revision

                if doc.deletedAt != nil {
                    // Remove local notebook that was deleted elsewhere.
                    try deleteLocalNotebook(clientId: doc.clientId, in: context)
                } else if let blocksJSON = serialize(doc.blocks) {
                    // Apply to SwiftData.
                    let dict: [String: Any] = [
                        "clientId": doc.clientId,
                        "title": doc.title,
                        "body": doc.body,
                        "blocks": blocksJSON,
                    ]
                    _ = CloudTranslator.apply(doc: dict, into: context)
                }
            }
            try context.save()
            revisionStore = revisions
            lastSyncDate = .now
            UserDefaults.standard.set(lastSyncDate?.timeIntervalSince1970, forKey: "sync.lastSyncTimestamp")
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Push

    /// Push every local notebook to the cloud. Notebooks without a cloud id
    /// get one assigned on first push.
    func pushAll(notebooks: [Notebook], into context: ModelContext) async {
        guard auth.isLoggedIn else {
            lastError = "Not logged in"
            return
        }
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        var revisions = revisionStore
        var hadConflict = false
        conflictCount = 0

        for notebook in notebooks {
            let clientId = CloudTranslator.clientId(for: notebook)
            let baseRevision = revisions[clientId] ?? 0

            let payload = CloudTranslator.export(notebook: notebook, baseRevision: baseRevision)

            guard let url = URL(string: "\(baseURL)/api/sync/documents") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do { try authorised(&request) } catch {
                lastError = error.localizedDescription
                continue
            }
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            } catch {
                lastError = error.localizedDescription
                continue
            }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }

                if http.statusCode == 409 {
                    preserveConflictCopy(of: notebook, in: context)
                    revisions[clientId] = parseConflictRevision(data) ?? baseRevision
                    hadConflict = true
                    conflictCount += 1
                    continue
                }

                guard (200...299).contains(http.statusCode) else {
                    lastError = "Sync failed for \(notebook.title) (HTTP \(http.statusCode))."
                    continue
                }

                // Update our tracked revision from the server's response.
                struct UpsertResponse: Decodable {
                    let document: DocDTO
                    struct DocDTO: Decodable { let revision: Int }
                }
                if let parsed = try? JSONDecoder().decode(UpsertResponse.self, from: data) {
                    revisions[clientId] = parsed.document.revision
                }
            } catch {
                lastError = error.localizedDescription
            }
        }

        do {
            try context.save()
            revisionStore = revisions
        } catch {
            lastError = "Cloud changes were received, but local notes could not be saved. \(error.localizedDescription)"
            return
        }
        if lastError == nil {
            lastSyncDate = .now
            UserDefaults.standard.set(lastSyncDate?.timeIntervalSince1970, forKey: "sync.lastSyncTimestamp")
        }

        if hadConflict {
            // Pull the complete server state. The user's local version is safe in
            // a separate unsynced notebook created above.
            lastSyncDate = nil
            UserDefaults.standard.removeObject(forKey: "sync.lastSyncTimestamp")
            await pullAll(into: context)
            lastError = "A newer cloud version was found. Your local edits were preserved in a Conflict Copy."
        }
    }

    /// Convenience: full bidirectional sync — pull first, then push.
    func fullSync(notebooks: [Notebook], into context: ModelContext) async {
        await pullAll(into: context)
        guard lastError == nil else { return }
        await pushAll(notebooks: notebooks, into: context)
    }

    // MARK: - Helpers

    private func serialize(_ anyCodable: AnyCodable?) -> Any? {
        guard let anyCodable else { return nil }
        return anyCodable.value
    }

    private func deleteLocalNotebook(clientId: String, in context: ModelContext) throws {
        let descriptor = FetchDescriptor<Notebook>()
        let all = try context.fetch(descriptor)
        for nb in all where nb.cloudID == clientId {
            context.delete(nb)
        }
    }

    private func parseConflictRevision(_ data: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["serverRevision"] as? Int
    }

    private func preserveConflictCopy(of source: Notebook, in context: ModelContext) {
        let copy = Notebook(
            title: source.title + " - Conflict Copy",
            subtitle: source.subtitle,
            coverColorHex: source.coverColorHex,
            coverColor2Hex: source.coverColor2Hex,
            coverStyle: source.coverStyle,
            coverEmoji: source.coverEmoji
        )
        copy.folderName = source.folderName
        copy.tagsText = source.tagsText
        copy.isFavorite = true
        copy.defaultLineStyle = source.defaultLineStyle
        copy.defaultBackgroundHex = source.defaultBackgroundHex
        copy.defaultOrientation = source.defaultOrientation

        for sourcePage in source.pages.filter({ $0.trashedAt == nil }).sorted(by: { $0.index < $1.index }) {
            let page = Page(index: sourcePage.index)
            page.title = sourcePage.title
            page.isBookmarked = sourcePage.isBookmarked
            page.inkData = sourcePage.inkData
            page.ocrText = sourcePage.ocrText
            page.ocrUpdatedAt = sourcePage.ocrUpdatedAt
            page.backgroundHex = sourcePage.backgroundHex
            page.lineStyle = sourcePage.lineStyle
            page.orientation = sourcePage.orientation
            page.notebook = copy
            for sourceElement in sourcePage.elements {
                let element = PageElement.copy(of: sourceElement)
                element.page = page
                page.elements.append(element)
            }
            copy.pages.append(page)
        }
        context.insert(copy)
    }
}

// MARK: - AnyCodable

/// Type-erased JSON wrapper so we can decode the heterogeneous `blocks` field.
/// (The blocks field can be null, an array, or nested objects — Swift's
/// Codable needs help with that.)
struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = NSNull()
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = dict.mapValues { $0.value }
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else {
            self.value = NSNull()
        }
    }
}
