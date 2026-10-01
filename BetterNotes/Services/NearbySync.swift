import CryptoKit
import Foundation
import MultipeerConnectivity
import SwiftData
import SwiftUI
#if os(iOS)
import UIKit
#endif

private struct NearbySyncEntry: Codable {
    let id: UUID
    let hash: String
    let archive: Data
    /// Sender's last agreed version with this peer, if known.
    let sharedHash: String?
    /// When the sender last edited the notebook, for "newest edit wins".
    let modifiedAt: Double?
}

private struct NearbySyncPackage: Codable {
    let version: Int
    let deviceID: UUID
    let deviceName: String
    let entries: [NearbySyncEntry]
    /// Hashes from the first half of the exchange that this peer accepted.
    let accepted: [NearbySyncAcknowledgement]?
    /// The sender's conflict setting. Devices that disagree keep both copies.
    let conflictPolicy: String?
}

private struct NearbySyncMessage: Codable {
    let kind: String
    let accepted: [NearbySyncAcknowledgement]?
}

struct NearbySyncAcknowledgement: Codable, Equatable {
    let id: UUID
    let hash: String
}

enum NearbySyncAcknowledgements {
    /// Never trust an acknowledgement for a version this device did not send.
    static func confirmed(sent: [UUID: String], accepted: [NearbySyncAcknowledgement]) -> [UUID: String] {
        var result: [UUID: String] = [:]
        for item in accepted where sent[item.id] == item.hash {
            result[item.id] = item.hash
        }
        return result
    }
}

/// Organizes legacy sync conflict suffixes without losing content. Exact
/// repeats go to Trash; distinct versions go to Archive for manual review.
enum NearbyConflictCleanup {
    @MainActor
    static func redundantCopyIDs(in context: ModelContext) throws -> [UUID] {
        let notebooks = try context.fetch(FetchDescriptor<Notebook>()).filter { $0.trashedAt == nil }
        var groups: [String: [Notebook]] = [:]
        for notebook in notebooks {
            groups[try contentFingerprint(notebook), default: []].append(notebook)
        }
        return groups.values.flatMap { group -> [UUID] in
            guard group.count > 1 else { return [] }
            let ordered = group.sorted {
                let leftCopy = isGeneratedCopy($0.title)
                let rightCopy = isGeneratedCopy($1.title)
                if leftCopy != rightCopy { return !leftCopy }
                if $0.title.count != $1.title.count { return $0.title.count < $1.title.count }
                return $0.stableID.uuidString < $1.stableID.uuidString
            }
            return ordered.dropFirst().filter { isGeneratedCopy($0.title) }.map(\.stableID)
        }.sorted { $0.uuidString < $1.uuidString }
    }

    @MainActor
    @discardableResult
    static func organizeLegacyCopies(in context: ModelContext) throws -> (trashed: Int, archived: Int) {
        let ids = Set(try redundantCopyIDs(in: context))
        let notebooks = try context.fetch(FetchDescriptor<Notebook>())
        var archived = 0
        for notebook in notebooks where notebook.trashedAt == nil {
            if ids.contains(notebook.stableID) {
                notebook.trashedAt = .now
                notebook.modifiedAt = .now
            } else if isGeneratedCopy(notebook.title) && !notebook.isArchived {
                notebook.isArchived = true
                notebook.modifiedAt = .now
                archived += 1
            }
        }
        if !ids.isEmpty || archived > 0 { try context.save() }
        return (ids.count, archived)
    }

    private static func isGeneratedCopy(_ title: String) -> Bool {
        title.contains(" (from ") && title.hasSuffix(")")
    }

    private static func contentFingerprint(_ notebook: Notebook) throws -> String {
        let pages = CloudTranslator.exportBlocks(notebook, includingTrash: true).map { page -> [String: Any] in
            var content = page
            for key in ["stableID", "createdAt", "modifiedAt", "ocrUpdatedAt", "notebookMetadata"] {
                content.removeValue(forKey: key)
            }
            if content["trashedAt"] != nil { content["trashedAt"] = true }
            content["elements"] = (page["elements"] as? [[String: Any]] ?? []).map { element in
                var content = element
                content.removeValue(forKey: "createdAt")
                return content
            }
            return content
        }
        let content: [String: Any] = [
            "subtitle": notebook.subtitle,
            "folderName": notebook.folderName,
            "tagsText": notebook.tagsText,
            "isFavorite": notebook.isFavorite,
            "isArchived": notebook.isArchived,
            "coverColorHex": notebook.coverColorHex,
            "coverColor2Hex": notebook.coverColor2Hex,
            "coverStyle": notebook.coverStyle,
            "coverEmoji": notebook.coverEmoji ?? "",
            "defaultLineStyle": notebook.defaultLineStyle,
            "defaultLineThickness": notebook.defaultLineThickness,
            "defaultLineOpacity": notebook.defaultLineOpacity,
            "defaultBackgroundHex": notebook.defaultBackgroundHex,
            "defaultOrientation": notebook.defaultOrientation,
            "pages": pages,
        ]
        let data = try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// What to do when both devices edited the same notebook since they last
/// agreed. Each option is device-neutral, so two devices with the same setting
/// reach the same winner without talking to each other.
enum NearbyConflictPolicy: String, CaseIterable, Identifiable {
    case keepBoth, newestWins, preferIPad, preferMac

    var id: String { rawValue }
    static let defaultsKey = "nearbySync.conflictPolicy"

    static var stored: NearbyConflictPolicy {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(NearbyConflictPolicy.init) ?? .keepBoth
    }

    /// Whether this device's version or the incoming one wins, or nil to keep
    /// both (also when the policy cannot pick: equal or unknown edit times).
    func winner(localModified: Date?, incomingModified: Date?, localIsMac: Bool) -> Winner? {
        switch self {
        case .keepBoth:
            return nil
        case .newestWins:
            guard let localModified, let incomingModified, localModified != incomingModified else { return nil }
            return localModified > incomingModified ? .local : .incoming
        case .preferIPad:
            return localIsMac ? .incoming : .local
        case .preferMac:
            return localIsMac ? .local : .incoming
        }
    }

    enum Winner: Equatable { case local, incoming }

    /// The policy to apply to an exchange. A winning policy discards an edit,
    /// so it is used only when the peer chose the same one; any disagreement,
    /// or a peer that does not say, keeps both copies.
    static func effective(local: NearbyConflictPolicy, remote: String?) -> NearbyConflictPolicy {
        remote == local.rawValue ? local : .keepBoth
    }

    var title: String {
        switch self {
        case .keepBoth: return AppLocalization.text("Keep both copies")
        case .newestWins: return AppLocalization.text("Newest edit wins")
        case .preferIPad: return AppLocalization.text("Always prefer iPad")
        case .preferMac: return AppLocalization.text("Always prefer Mac")
        }
    }
}

enum NearbyMergeDecision: Equatable {
    case unchanged, importNew, replaceLocal, keepLocal
    case preserveLocalAndReplace, saveConflictCopy, alreadySavedConflict

    /// Whether applying this decision deletes and re-creates the local notebook.
    var replacesLocal: Bool { self == .replaceLocal || self == .preserveLocalAndReplace }

    static func decide(localHash: String?, incomingHash: String, lastSharedHash: String?,
                       lastConflictHash: String?, remoteSharedHash: String? = nil,
                       receivingFirst: Bool = false,
                       policy: NearbyConflictPolicy = .keepBoth,
                       localModified: Date? = nil, incomingModified: Date? = nil,
                       localIsMac: Bool = false) -> Self {
        guard let localHash else { return lastSharedHash == nil ? .importNew : .keepLocal }
        if localHash == incomingHash { return .unchanged }
        // The sender can prove its current version has not changed since its
        // own last exchange. A newer local edit should not become a conflict
        // copy merely because this device's older baseline was not advanced.
        if remoteSharedHash == incomingHash { return .keepLocal }
        if lastSharedHash == localHash { return .replaceLocal }
        if lastSharedHash == incomingHash { return .keepLocal }
        // Both devices changed it. A winning policy discards the other edit;
        // otherwise fall through and keep both.
        if let winner = policy.winner(localModified: localModified, incomingModified: incomingModified,
                                      localIsMac: localIsMac) {
            return winner == .local ? .keepLocal : .replaceLocal
        }
        // The receiver of the first snapshot keeps one copy of its own edit,
        // then adopts the sender's version under the original ID. The reply
        // therefore carries one converged original plus one conflict copy.
        // Making a copy of the incoming version on both sides caused copies
        // of copies to spread through the library on later exchanges.
        if receivingFirst { return .preserveLocalAndReplace }
        return lastConflictHash == incomingHash ? .alreadySavedConflict : .saveConflictCopy
    }
}

/// A foreground library exchange, started automatically after initial pairing.
/// Both peers send complete
/// editable snapshots. A changed notebook is replaced only when its local
/// content still matches the last version shared with that peer.
@MainActor
final class NearbySyncCoordinator: NSObject, ObservableObject {
    @Published private(set) var peers: [MCPeerID] = []
    @Published private(set) var status = UserDefaults.standard.string(forKey: "nearbySync.lastStatus") ?? "Not paired"
    @Published private(set) var invitationName: String?
    @Published private(set) var isBusy = false {
        didSet {
            if isBusy { armWatchdog() } else { busyWatchdog?.cancel(); busyWatchdog = nil }
        }
    }
    /// Open notebooks whose replacement was postponed by the last exchange.
    @Published private(set) var deferredCount = 0
    /// What to do when both devices edited the same notebook.
    @Published var conflictPolicy = NearbyConflictPolicy.stored {
        didSet { UserDefaults.standard.set(conflictPolicy.rawValue, forKey: NearbyConflictPolicy.defaultsKey) }
    }
    /// True when the other device's conflict setting differs from this one's,
    /// in which case both copies are kept so nothing is lost.
    @Published private(set) var policyMismatch = false
    /// Stable IDs of notebooks an editor currently has open. Replacing one
    /// deletes its model under the editor and discards edits made since the
    /// exchange began, so those notebooks wait until they are closed.
    var openNotebookIDs: Set<UUID> = []

    private static let serviceType = "better-notes"
    private let deviceID: UUID
    private let localPeer: MCPeerID
    private let session: MCSession
    private let browser: MCNearbyServiceBrowser
    private let advertiser: MCNearbyServiceAdvertiser
    private var context: ModelContext?
    private var invitationHandler: ((Bool, MCSession?) -> Void)?
    private var activePeer: MCPeerID?
    private var activePeerDeviceID: UUID?
    private var discoveredPeerDeviceIDs: [MCPeerID: UUID] = [:]
    private var initiated = false
    private var transferURLs: [URL] = []
    private var refreshTask: Task<Void, Never>?
    private var lastLocalDigest: String?
    private var lastReceiveSummary = ""
    private var lastSentHashes: [UUID: String] = [:]
    private var acceptedIncoming: [NearbySyncAcknowledgement] = []
    private var deferredNotebookIDs: Set<UUID> = []
    private var busyWatchdog: Task<Void, Never>?
    /// Seconds without any sync event before a busy exchange is abandoned.
    private static let busyTimeout = 300

    var isPaired: Bool { pairedPeer != nil }
    private var pairedPeer: MCPeerID? {
        guard let data = UserDefaults.standard.data(forKey: "nearbySync.pairedPeer") else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data)
    }

    private static var platform: String {
#if os(macOS)
        "mac"
#else
        "ipad"
#endif
    }

    override init() {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: "nearbySync.deviceID").flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(id.uuidString, forKey: "nearbySync.deviceID")
        deviceID = id
#if os(macOS)
        let name = Host.current().localizedName ?? "BetterNotes Mac"
#else
        let name = UIDevice.current.name
#endif
        if let data = defaults.data(forKey: "nearbySync.localPeer"),
           let saved = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data) {
            localPeer = saved
        } else {
            localPeer = MCPeerID(displayName: String(name.prefix(63)))
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: localPeer, requiringSecureCoding: true) {
                defaults.set(data, forKey: "nearbySync.localPeer")
            }
        }
        session = MCSession(peer: localPeer, securityIdentity: nil, encryptionPreference: .required)
        browser = MCNearbyServiceBrowser(peer: localPeer, serviceType: Self.serviceType)
        advertiser = MCNearbyServiceAdvertiser(peer: localPeer,
                                                discoveryInfo: ["id": id.uuidString, "platform": Self.platform],
                                                serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        browser.delegate = self
        advertiser.delegate = self
    }

    func start(context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
        browser.startBrowsingForPeers()
        advertiser.startAdvertisingPeer()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled, let self else { break }
                self.refreshConnectedPeer()
            }
        }
    }

    func stop() {
        if isBusy { status = "Nearby sync paused. Reopen BetterNotes on both devices to retry." }
        isBusy = false
        activePeer = nil
        activePeerDeviceID = nil
        // A stale list makes the next foundPeer look like a repeat and skips
        // the automatic reconnect after the app returns to the foreground.
        peers.removeAll()
        discoveredPeerDeviceIDs.removeAll()
        deferredNotebookIDs.removeAll()
        deferredCount = 0
        browser.stopBrowsingForPeers()
        advertiser.stopAdvertisingPeer()
        session.disconnect()
        refreshTask?.cancel()
        refreshTask = nil
        invitationHandler = nil
        context = nil
        for url in transferURLs { try? FileManager.default.removeItem(at: url) }
        transferURLs.removeAll()
        lastSentHashes.removeAll()
        acceptedIncoming.removeAll()
    }

    func invite(_ peer: MCPeerID) {
        guard !isBusy else { return }
        activePeer = peer
        activePeerDeviceID = discoveredPeerDeviceIDs[peer]
            ?? (pairedPeer == peer ? UserDefaults.standard.string(forKey: "nearbySync.pairedDeviceID")
                .flatMap(UUID.init(uuidString:)) : nil)
        initiated = true
        isBusy = true
        status = "Connecting to \(peer.displayName)…"
        browser.invitePeer(peer, to: session,
                           withContext: Data("\(Self.platform):\(deviceID.uuidString)".utf8), timeout: 30)
    }

    func answerInvitation(accept: Bool) {
        invitationHandler?(accept, accept ? session : nil)
        invitationHandler = nil
        invitationName = nil
        if accept {
            isBusy = true
            status = "Waiting for the other device…"
        }
    }

    func forgetPair() {
        let currentContext = context
        stop()
        UserDefaults.standard.removeObject(forKey: "nearbySync.pairedPeer")
        UserDefaults.standard.removeObject(forKey: "nearbySync.pairedDeviceID")
        if let currentContext { start(context: currentContext) }
        status = "Pairing removed. Choose your other device to pair again."
    }

    @discardableResult
    private func sendMessage(_ kind: String, to peer: MCPeerID,
                             accepted: [NearbySyncAcknowledgement]? = nil) -> Bool {
        do {
            if kind == "request" { initiated = true }
            let data = try JSONEncoder().encode(NearbySyncMessage(kind: kind, accepted: accepted))
            try session.send(data, toPeers: [peer], with: .reliable)
            return true
        } catch {
            fail("Could not send sync request: \(error.localizedDescription)")
            return false
        }
    }

    private func sendLibrary(to peer: MCPeerID) {
        guard let context else { fail("The notes library is unavailable."); return }
        do {
            // Flush editor changes before making a transfer snapshot.
            try context.save()
            let notebooks = try context.fetch(FetchDescriptor<Notebook>())
            let remoteID = activePeerDeviceID ?? discoveredPeerDeviceIDs[peer]
            let entries = try notebooks.map { notebook in
                let archive = try CloudTranslator.syncArchiveData(for: notebook)
                let sharedHash = remoteID.flatMap { id in
                    UserDefaults.standard.string(forKey:
                        "nearbySync.shared.\(id.uuidString).\(notebook.stableID.uuidString)")
                }
                return NearbySyncEntry(id: notebook.stableID, hash: Self.hash(archive),
                                       archive: archive, sharedHash: sharedHash,
                                       modifiedAt: notebook.modifiedAt.timeIntervalSince1970)
            }
            lastSentHashes = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.hash) })
            lastLocalDigest = Self.hash(Data(entries.sorted { $0.id.uuidString < $1.id.uuidString }
                .map { $0.id.uuidString + $0.hash }.joined().utf8))
            let package = NearbySyncPackage(version: 5, deviceID: deviceID,
                                            deviceName: localPeer.displayName, entries: entries,
                                            accepted: acceptedIncoming,
                                            conflictPolicy: conflictPolicy.rawValue)
            acceptedIncoming.removeAll()
            let data = try JSONEncoder().encode(package)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("BetterNotes-Nearby-\(UUID().uuidString).json")
            try data.write(to: url, options: .atomic)
            transferURLs.append(url)
            status = "Sending \(entries.count) notebooks to \(peer.displayName)…"
            guard session.sendResource(at: url, withName: "betternotes-library.json", toPeer: peer,
                                       withCompletionHandler: { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.transferURLs.removeAll { $0 == url }
                    try? FileManager.default.removeItem(at: url)
                    if let error { self.fail("Transfer failed: \(error.localizedDescription)") }
                }
            }) != nil else {
                fail("Could not start the library transfer.")
                return
            }
        } catch {
            fail("Could not prepare the notes library: \(error.localizedDescription)")
        }
    }

    private func receive(_ data: Data, from peer: MCPeerID) {
        guard let context else { fail("The notes library is unavailable."); return }
        do {
            let package = try JSONDecoder().decode(NearbySyncPackage.self, from: data)
            guard package.version == 5 else { throw NearbySyncError.unsupportedVersion }
            guard package.deviceID != deviceID,
                  Set(package.entries.map(\.id)).count == package.entries.count else {
                throw NearbySyncError.invalidPackage
            }
            for entry in package.entries {
                guard entry.hash == Self.hash(entry.archive),
                      let archive = try JSONSerialization.jsonObject(with: entry.archive) as? [String: Any],
                      (archive["stableID"] as? String).flatMap(UUID.init(uuidString:)) == entry.id,
                      archive["version"] as? Int == 4 else { throw NearbySyncError.invalidPackage }
            }
            if let activePeerDeviceID, activePeerDeviceID != package.deviceID {
                throw NearbySyncError.invalidPackage
            }
            activePeerDeviceID = package.deviceID
            rememberAccepted(package.accepted ?? [], from: package.deviceID)
            let remoteName = String(package.deviceName.prefix(40))
            var imported = 0
            var updated = 0
            var conflicts = 0
            let peerKey = package.deviceID.uuidString
            // Winning policies discard an edit, so they apply only when both
            // devices chose the same one.
            let effectivePolicy = NearbyConflictPolicy.effective(local: conflictPolicy,
                                                                 remote: package.conflictPolicy)
            policyMismatch = package.conflictPolicy != conflictPolicy.rawValue
            var accepted: [NearbySyncAcknowledgement] = []
            var deferred: Set<UUID> = []
            for entry in package.entries {
                let existing = try context.fetch(FetchDescriptor<Notebook>()).first { $0.stableID == entry.id }
                let baselineKey = "nearbySync.shared.\(peerKey).\(entry.id.uuidString)"
                let seenConflictKey = "nearbySync.conflict.\(peerKey).\(entry.id.uuidString)"
                let localHash = try existing.map { Self.hash(try CloudTranslator.syncArchiveData(for: $0)) }
                let baseline = UserDefaults.standard.string(forKey: baselineKey)
                let decision = NearbyMergeDecision.decide(
                    localHash: localHash, incomingHash: entry.hash, lastSharedHash: baseline,
                    lastConflictHash: UserDefaults.standard.string(forKey: seenConflictKey),
                    remoteSharedHash: entry.sharedHash, receivingFirst: initiated,
                    policy: effectivePolicy,
                    localModified: existing?.modifiedAt,
                    incomingModified: entry.modifiedAt.map(Date.init(timeIntervalSince1970:)),
                    localIsMac: Self.platform == "mac"
                )
                // Not acknowledged and no baseline written, so the next
                // exchange reaches the same decision once the editor closes.
                if decision.replacesLocal, openNotebookIDs.contains(entry.id) {
                    deferred.insert(entry.id)
                    continue
                }
                switch decision {
                case .unchanged:
                        UserDefaults.standard.set(entry.hash, forKey: baselineKey)
                        accepted.append(NearbySyncAcknowledgement(id: entry.id, hash: entry.hash))
                case .replaceLocal:
                    if let existing {
                        _ = try CloudTranslator.importArchiveData(entry.archive, into: context, replacing: existing)
                        UserDefaults.standard.set(entry.hash, forKey: baselineKey)
                        accepted.append(NearbySyncAcknowledgement(id: entry.id, hash: entry.hash))
                        updated += 1
                    }
                case .saveConflictCopy:
                    _ = try CloudTranslator.importArchiveData(entry.archive, into: context,
                                                             conflictSuffix: remoteName)
                    UserDefaults.standard.set(entry.hash, forKey: seenConflictKey)
                    conflicts += 1
                case .preserveLocalAndReplace:
                    if let existing {
                        // Save the local version while it still exists. A
                        // failed remote import leaves that original intact;
                        // only acknowledge once the replacement was saved.
                        let localArchive = try CloudTranslator.syncArchiveData(for: existing)
                        _ = try CloudTranslator.importArchiveData(localArchive, into: context,
                                                                 conflictSuffix: localPeer.displayName)
                        _ = try CloudTranslator.importArchiveData(entry.archive, into: context,
                                                                 replacing: existing)
                        UserDefaults.standard.set(entry.hash, forKey: baselineKey)
                        accepted.append(NearbySyncAcknowledgement(id: entry.id, hash: entry.hash))
                        updated += 1
                        conflicts += 1
                    }
                case .importNew:
                    _ = try CloudTranslator.importArchiveData(entry.archive, into: context)
                    UserDefaults.standard.set(entry.hash, forKey: baselineKey)
                    accepted.append(NearbySyncAcknowledgement(id: entry.id, hash: entry.hash))
                    imported += 1
                case .keepLocal:
                    if localHash != nil, entry.sharedHash == entry.hash || baseline == entry.hash {
                        UserDefaults.standard.set(entry.hash, forKey: baselineKey)
                        accepted.append(NearbySyncAcknowledgement(id: entry.id, hash: entry.hash))
                    }
                case .alreadySavedConflict:
                    break
                }
            }
            deferredNotebookIDs = deferred
            deferredCount = deferred.count
            lastReceiveSummary = "\(imported) new, \(updated) updated, \(conflicts) conflict copies"
            status = "Received \(lastReceiveSummary) from \(remoteName)."
            if initiated {
                acceptedIncoming = accepted
                sendLibrary(to: peer)
            } else {
                lastLocalDigest = try localDigest()
                if sendMessage("complete", to: peer, accepted: accepted) {
                    rememberPair(peer)
                    complete(with: peer)
                    isBusy = false
                    lastSentHashes.removeAll()
                }
            }
        } catch {
            fail("Could not import the nearby library: \(error.localizedDescription)")
        }
    }

    private func fail(_ message: String, notifyPeer: Bool = true) {
        // Without this the other device stays "busy" until its connection
        // drops, and never retries.
        if notifyPeer, isBusy, let peer = activePeer, session.connectedPeers.contains(peer),
           let data = try? JSONEncoder().encode(NearbySyncMessage(kind: "failed", accepted: nil)) {
            try? session.send(data, toPeers: [peer], with: .reliable)
        }
        status = message
        UserDefaults.standard.set(message, forKey: "nearbySync.lastStatus")
        isBusy = false
        lastReceiveSummary = ""
        lastSentHashes.removeAll()
        acceptedIncoming.removeAll()
    }

    private func armWatchdog() {
        busyWatchdog?.cancel()
        busyWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.busyTimeout))
            guard !Task.isCancelled, let self, self.isBusy else { return }
            self.fail("Sync timed out. Reopen Nearby Sync on both devices to retry.")
            self.session.disconnect()
        }
    }

    private func rememberAccepted(_ accepted: [NearbySyncAcknowledgement], from deviceID: UUID) {
        for (id, hash) in NearbySyncAcknowledgements.confirmed(sent: lastSentHashes, accepted: accepted) {
            UserDefaults.standard.set(hash, forKey: "nearbySync.shared.\(deviceID.uuidString).\(id.uuidString)")
        }
    }

    private func complete(with peer: MCPeerID) {
        let summary = lastReceiveSummary.isEmpty ? "" : " · \(lastReceiveSummary)"
        var cleanupSummary = ""
#if os(macOS)
        let cleanupKey = "nearbySync.legacyConflictOrganization.v1"
        if !UserDefaults.standard.bool(forKey: cleanupKey), let context {
            do {
                let result = try NearbyConflictCleanup.organizeLegacyCopies(in: context)
                UserDefaults.standard.set(true, forKey: cleanupKey)
                if result.trashed > 0 || result.archived > 0 {
                    cleanupSummary = " · \(result.trashed) exact copies to Trash, \(result.archived) conflict versions to Archive"
                }
            } catch {
                cleanupSummary = " · duplicate cleanup failed: \(error.localizedDescription)"
            }
        }
#endif
        status = "Synced with \(peer.displayName) at \(Date.now.formatted(date: .abbreviated, time: .shortened))\(summary)\(cleanupSummary)"
        UserDefaults.standard.set(status, forKey: "nearbySync.lastStatus")
        lastReceiveSummary = ""
    }

    private func rememberPair(_ peer: MCPeerID) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: peer, requiringSecureCoding: true) else { return }
        UserDefaults.standard.set(data, forKey: "nearbySync.pairedPeer")
        if let activePeerDeviceID {
            UserDefaults.standard.set(activePeerDeviceID.uuidString, forKey: "nearbySync.pairedDeviceID")
        }
    }

    private func refreshConnectedPeer() {
        guard let peer = activePeer, session.connectedPeers.contains(peer), !isBusy else { return }
        // A postponed replacement is retried once its notebook is closed,
        // even though nothing changed locally.
        let retryDeferred = !deferredNotebookIDs.isEmpty && deferredNotebookIDs.isDisjoint(with: openNotebookIDs)
        do {
            let digest = try localDigest()
            guard digest != lastLocalDigest || retryDeferred else { return }
        } catch {
            fail("Could not check local changes: \(error.localizedDescription)")
            return
        }
#if os(macOS)
        // The iPad drives each exchange; the Mac announces new local edits.
        sendMessage("changed", to: peer)
#else
        isBusy = true
        sendMessage("request", to: peer)
#endif
    }

    private func localDigest() throws -> String {
        guard let context else { throw NearbySyncError.invalidPackage }
        try context.save()
        let notebooks = try context.fetch(FetchDescriptor<Notebook>())
        let components = try notebooks.map { notebook in
            notebook.stableID.uuidString + Self.hash(try CloudTranslator.syncArchiveData(for: notebook))
        }.sorted()
        return Self.hash(Data(components.joined().utf8))
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension NearbySyncCoordinator: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor [weak self] in
            guard let self, info?["platform"] != Self.platform else { return }
            if let id = info?["id"].flatMap(UUID.init(uuidString:)) {
                self.discoveredPeerDeviceIDs[peerID] = id
            }
            if !self.peers.contains(peerID) { self.peers.append(peerID) }
#if !os(macOS)
            if self.pairedPeer == peerID, !self.isBusy, !self.session.connectedPeers.contains(peerID) {
                self.invite(peerID)
            }
#endif
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor [weak self] in
            self?.peers.removeAll { $0 == peerID }
            self?.discoveredPeerDeviceIDs.removeValue(forKey: peerID)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor [weak self] in self?.fail("Nearby search failed: \(error.localizedDescription)") }
    }
}

extension NearbySyncCoordinator: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor [weak self] in
            guard let invitation = context.flatMap({ String(data: $0, encoding: .utf8) }),
                  let platform = invitation.split(separator: ":", maxSplits: 1).first,
                  platform != Self.platform else { invitationHandler(false, nil); return }
            guard let self, !self.isBusy, self.invitationHandler == nil else { invitationHandler(false, nil); return }
            self.activePeerDeviceID = invitation.split(separator: ":", maxSplits: 1).last
                .flatMap { UUID(uuidString: String($0)) }
                ?? self.discoveredPeerDeviceIDs[peerID]
            if self.pairedPeer == peerID {
                self.activePeer = peerID
                self.initiated = false
                self.isBusy = true
                invitationHandler(true, self.session)
                return
            }
            self.activePeer = peerID
            self.initiated = false
            self.invitationHandler = invitationHandler
            self.invitationName = peerID.displayName
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor [weak self] in self?.fail("Nearby sharing failed: \(error.localizedDescription)") }
    }
}

extension NearbySyncCoordinator: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch state {
            case .connected:
                self.activePeer = peerID
                self.status = "Connected to \(peerID.displayName)."
                if self.initiated { self.sendMessage("request", to: peerID) }
            case .notConnected:
                if self.isBusy { self.fail("Connection to \(peerID.displayName) ended before sync finished.") }
#if !os(macOS)
                if self.context != nil, self.pairedPeer == peerID, self.peers.contains(peerID) {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(5))
                        guard let self, self.context != nil, !self.isBusy,
                              self.peers.contains(peerID), !self.session.connectedPeers.contains(peerID) else { return }
                        self.invite(peerID)
                    }
                }
#endif
            case .connecting:
                self.status = "Connecting to \(peerID.displayName)…"
            @unknown default: break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor [weak self] in
            guard let self, peerID == self.activePeer,
                  let message = try? JSONDecoder().decode(NearbySyncMessage.self, from: data) else { return }
            if self.isBusy { self.armWatchdog() }
            switch message.kind {
            case "failed":
                if self.isBusy { self.fail("The other device could not finish syncing.", notifyPeer: false) }
            case "request": self.initiated = false; self.isBusy = true; self.sendLibrary(to: peerID)
            case "changed":
#if !os(macOS)
                if !self.isBusy { self.isBusy = true; self.sendMessage("request", to: peerID) }
#endif
            case "complete":
                if let remoteDeviceID = self.activePeerDeviceID {
                    self.rememberAccepted(message.accepted ?? [], from: remoteDeviceID)
                }
                self.rememberPair(peerID)
                self.complete(with: peerID)
                self.isBusy = false
                self.lastSentHashes.removeAll()
            default: break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream,
                             withName streamName: String, fromPeer peerID: MCPeerID) {}

    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, with progress: Progress) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.isBusy { self.armWatchdog() }
            self.status = "Receiving notes from \(peerID.displayName)…"
        }
    }

    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        // Multipeer Connectivity owns localURL only for the duration of this callback.
        let data = localURL.flatMap { try? Data(contentsOf: $0) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let error { self.fail("Transfer failed: \(error.localizedDescription)"); return }
            guard peerID == self.activePeer, resourceName == "betternotes-library.json", let data else {
                self.fail("The received library was incomplete.")
                return
            }
            self.receive(data, from: peerID)
        }
    }
}

private enum NearbySyncError: LocalizedError {
    case invalidPackage
    case unsupportedVersion
    var errorDescription: String? {
        switch self {
        case .invalidPackage: "The other device sent an invalid BetterNotes library."
        case .unsupportedVersion: "Update BetterNotes on both devices before syncing nearby."
        }
    }
}

struct NearbySyncSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var sync: NearbySyncCoordinator

    private var otherDeviceName: String {
#if os(macOS)
        "iPad"
#else
        "Mac"
#endif
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Nearby Devices") {
                    if sync.peers.isEmpty {
                        Text("Open Nearby Sync on your \(otherDeviceName) and keep both devices on the same network.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sync.peers, id: \.self) { peer in
                        Button {
                            sync.invite(peer)
                        } label: {
                            Label(peer.displayName, systemImage: "laptopcomputer.and.ipad")
                        }
                        .disabled(sync.isBusy)
                    }
                }
                Section {
                    Picker("When both edited", selection: $sync.conflictPolicy) {
                        ForEach(NearbyConflictPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .accessibilityIdentifier("conflict-policy-picker")
                    if sync.policyMismatch {
                        Text("The other device uses a different conflict setting, so both copies were kept.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("If both devices edited the same notebook")
                } footer: {
                    Text("Keep both copies saves the other version as a notebook in Archive. The other options discard the edit that loses. Use the same setting on both devices; Newest edit wins relies on both clocks being correct.")
                }
                Section("Activity") {
                    Text(AppLocalization.nearbyStatus(sync.status))
                    if sync.deferredCount > 0 {
                        Text("Open notebooks waiting to update: \(sync.deferredCount). Close them to finish syncing.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("Keep BetterNotes open on both devices until the transfer finishes. Conflicting edits are saved as separate notebooks in Archive.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if sync.isPaired {
                    Section {
                        Button("Forget Paired Device", role: .destructive) { sync.forgetPair() }
                    }
                }
            }
            .navigationTitle("Nearby Sync")
            .toolbar { Button("Done") { dismiss() } }
            .onAppear { sync.start(context: context) }
            .onDisappear { if !sync.isPaired { sync.stop() } }
            .alert("Sync with \(sync.invitationName ?? "device")?", isPresented: Binding(
                get: { sync.invitationName != nil },
                set: { if !$0 { sync.answerInvitation(accept: false) } }
            )) {
                Button("Sync") { sync.answerInvitation(accept: true) }
                Button("Cancel", role: .cancel) { sync.answerInvitation(accept: false) }
            } message: {
                Text("Only accept a device you recognize. Both libraries will exchange editable notebooks.")
            }
        }
    }
}
