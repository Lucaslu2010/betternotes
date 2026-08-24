import CryptoKit
import Foundation
import NaturalLanguage

struct NoteCorpusSource: Sendable, Equatable {
    let notebookID: UUID
    let pageID: UUID?
    let notebookTitle: String
    let pageTitle: String?
    let sourceKind: NoteSourceKind
    let label: String
    let text: String
    let modifiedAt: Date
    let isBookmarked: Bool
    let isArchived: Bool
    let sourceOrdinal: Int
}

actor NoteCorpusIndexer {
    private struct PersistedIndex: Codable {
        let version: Int
        let chunks: [NoteChunk]
    }

    static let indexVersion = 1
    private let persistenceURL: URL?
    private var chunksByID: [String: NoteChunk] = [:]
    private let sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: .english)

    init(persistenceURL: URL? = NoteCorpusIndexer.defaultPersistenceURL()) {
        self.persistenceURL = persistenceURL
        guard let persistenceURL,
              let data = try? Data(contentsOf: persistenceURL),
              let stored = try? JSONDecoder().decode(PersistedIndex.self, from: data),
              stored.version == Self.indexVersion else { return }
        self.chunksByID = Dictionary(uniqueKeysWithValues: stored.chunks.map { ($0.id, $0) })
    }

    var chunkCount: Int { chunksByID.count }

    func rebuild(from sources: [NoteCorpusSource]) {
        var rebuilt: [String: NoteChunk] = [:]
        rebuilt.reserveCapacity(sources.count * 2)

        for source in sources {
            let passages = Self.chunkText(source.text)
            for (chunkIndex, passage) in passages.enumerated() {
                let id = Self.chunkID(for: source, chunkIndex: chunkIndex)
                let fingerprint = Self.fingerprint(
                    "\(source.notebookTitle)|\(source.pageTitle ?? "")|\(source.label)|\(passage)"
                )
                if let existing = chunksByID[id], existing.fingerprint == fingerprint {
                    rebuilt[id] = existing
                    continue
                }
                let terms = Self.termFrequencies(in: passage)
                let embedding = sentenceEmbedding?.vector(for: passage)
                rebuilt[id] = NoteChunk(
                    id: id,
                    notebookID: source.notebookID,
                    pageID: source.pageID,
                    notebookTitle: source.notebookTitle,
                    pageTitle: source.pageTitle,
                    sourceKind: source.sourceKind,
                    label: source.label,
                    text: passage,
                    terms: terms,
                    embedding: embedding,
                    fingerprint: fingerprint,
                    modifiedAt: source.modifiedAt,
                    isBookmarked: source.isBookmarked,
                    isArchived: source.isArchived
                )
            }
        }

        chunksByID = rebuilt
        persist()
    }

    func search(_ query: SearchQuery) -> [SearchResult] {
        let normalizedQuery = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryTerms = Self.tokenize(normalizedQuery)
        guard !queryTerms.isEmpty else { return [] }

        let candidates = chunksByID.values.filter { chunk in
            let filters = query.filters
            if let notebookID = filters.notebookID, chunk.notebookID != notebookID { return false }
            if let pageID = filters.pageID, chunk.pageID != pageID { return false }
            if !filters.contentKinds.isEmpty && !filters.contentKinds.contains(chunk.sourceKind) { return false }
            if let after = filters.modifiedAfter, chunk.modifiedAt < after { return false }
            if let before = filters.modifiedBefore, chunk.modifiedAt > before { return false }
            if filters.bookmarkedOnly && !chunk.isBookmarked { return false }
            if !filters.includeArchived && chunk.isArchived { return false }
            return true
        }
        guard !candidates.isEmpty else { return [] }

        let documentCount = Double(candidates.count)
        let averageLength = max(1, Double(candidates.reduce(0) { $0 + $1.terms.values.reduce(0, +) }) / documentCount)
        let documentFrequency = Dictionary(uniqueKeysWithValues: Set(queryTerms).map { term in
            (term, Double(candidates.reduce(0) { $0 + ($1.terms[term] == nil ? 0 : 1) }))
        })
        let queryEmbedding = sentenceEmbedding?.vector(for: normalizedQuery)

        let ranked = candidates.compactMap { chunk -> SearchResult? in
            let length = Double(chunk.terms.values.reduce(0, +))
            let lexical = queryTerms.reduce(0.0) { total, term in
                guard let frequency = chunk.terms[term] else { return total }
                let tf = Double(frequency)
                let df = documentFrequency[term] ?? 0
                let idf = log(1 + (documentCount - df + 0.5) / (df + 0.5))
                let denominator = tf + 1.2 * (0.25 + 0.75 * length / averageLength)
                return total + idf * (tf * 2.2 / denominator)
            }
            let metadata = "\(chunk.notebookTitle) \(chunk.pageTitle ?? "") \(chunk.label)"
            let fuzzy = Self.fuzzySimilarity(normalizedQuery, metadata)
            let semantic = Self.cosineSimilarity(queryEmbedding, chunk.embedding)
            let exactBoost = chunk.text.localizedCaseInsensitiveContains(normalizedQuery) ? 1.6 : 0
            let score = chunk.sourceKind.fieldWeight * (lexical + exactBoost) + fuzzy * 1.4 + semantic * 1.1
            guard score > 0.05 else { return nil }
            return SearchResult(
                id: chunk.id,
                chunk: chunk,
                score: score,
                snippet: Self.snippet(in: chunk.text, matching: queryTerms),
                highlights: Array(Set(queryTerms.filter { chunk.terms[$0] != nil })).sorted()
            )
        }
        return ranked.sorted {
            $0.score == $1.score ? $0.chunk.modifiedAt > $1.chunk.modifiedAt : $0.score > $1.score
        }.prefix(max(1, query.limit)).map { $0 }
    }

    static func chunkText(_ text: String, targetLength: Int = 750, overlap: Int = 120) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        guard normalized.count > 900 else { return [normalized] }

        var passages: [String] = []
        var start = normalized.startIndex
        while start < normalized.endIndex {
            let targetEnd = normalized.index(start, offsetBy: targetLength, limitedBy: normalized.endIndex) ?? normalized.endIndex
            var end = targetEnd
            if targetEnd < normalized.endIndex,
               let boundary = normalized[start..<targetEnd].lastIndex(where: { ".!?\n".contains($0) }),
               normalized.distance(from: start, to: boundary) >= 480 {
                end = normalized.index(after: boundary)
            }
            let passage = normalized[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !passage.isEmpty { passages.append(passage) }
            guard end < normalized.endIndex else { break }
            let next = normalized.index(end, offsetBy: -min(overlap, normalized.distance(from: start, to: end)))
            start = next > start ? next : end
        }
        return passages
    }

    static func tokenize(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count > 1 && !stopWords.contains($0) }
    }

    static func termFrequencies(in text: String) -> [String: Int] {
        Dictionary(tokenize(text).map { ($0, 1) }, uniquingKeysWith: +)
    }

    static func fuzzySimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = tokenize(lhs).joined(separator: " ")
        let right = tokenize(rhs).joined(separator: " ")
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if right.contains(left) { return 1 }
        let shorter = left.count <= right.count ? left : right
        let longer = left.count <= right.count ? right : left
        let distance = levenshtein(shorter, String(longer.prefix(max(shorter.count * 2, shorter.count))))
        return max(0, 1 - Double(distance) / Double(max(shorter.count, 1)))
    }

    private static func levenshtein(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs), right = Array(rhs)
        var previous = Array(0...right.count)
        for (i, a) in left.enumerated() {
            var current = [i + 1]
            for (j, b) in right.enumerated() {
                current.append(min(min(current[j] + 1, previous[j + 1] + 1), previous[j] + (a == b ? 0 : 1)))
            }
            previous = current
        }
        return previous.last ?? 0
    }

    private static func chunkID(for source: NoteCorpusSource, chunkIndex: Int) -> String {
        [
            source.notebookID.uuidString,
            source.pageID?.uuidString ?? "notebook",
            source.sourceKind.rawValue,
            String(source.sourceOrdinal),
            String(chunkIndex),
        ].joined(separator: ":")
    }

    private static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func cosineSimilarity(_ lhs: [Double]?, _ rhs: [Double]?) -> Double {
        guard let lhs, let rhs, lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot = 0.0, leftMagnitude = 0.0, rightMagnitude = 0.0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            leftMagnitude += lhs[index] * lhs[index]
            rightMagnitude += rhs[index] * rhs[index]
        }
        guard leftMagnitude > 0, rightMagnitude > 0 else { return 0 }
        return max(0, dot / (sqrt(leftMagnitude) * sqrt(rightMagnitude)))
    }

    private static func snippet(in text: String, matching terms: [String]) -> String {
        let lower = text.lowercased()
        let location = terms.compactMap { lower.range(of: $0)?.lowerBound }.min() ?? text.startIndex
        let before = text.distance(from: text.startIndex, to: location)
        let start = text.index(text.startIndex, offsetBy: max(0, before - 90))
        let end = text.index(start, offsetBy: min(260, text.distance(from: start, to: text.endIndex)))
        let value = text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return (start > text.startIndex ? "..." : "") + value + (end < text.endIndex ? "..." : "")
    }

    private func persist() {
        guard let persistenceURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let stored = PersistedIndex(version: Self.indexVersion, chunks: Array(chunksByID.values))
            try JSONEncoder().encode(stored).write(to: persistenceURL, options: .atomic)
        } catch {
            // The index is derived data; a later rebuild can safely retry persistence.
        }
    }

    static func defaultPersistenceURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BetterNotes", isDirectory: true)
            .appendingPathComponent("NoteCorpus-v\(indexVersion).json")
    }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in", "is", "it", "of", "on", "or", "that", "the", "this", "to", "was", "what", "when", "where", "which", "who", "why", "with"
    ]
}

@MainActor
final class NoteCorpusStore: ObservableObject {
    @Published private(set) var isIndexing = false
    @Published private(set) var indexedChunkCount = 0
    let indexer: NoteCorpusIndexer
    private var scheduledRebuild: Task<Void, Never>?

    init(indexer: NoteCorpusIndexer = NoteCorpusIndexer()) {
        self.indexer = indexer
    }

    func rebuild(notebooks: [Notebook]) async {
        scheduledRebuild?.cancel()
        isIndexing = true
        let sources = Self.sources(from: notebooks)
        await indexer.rebuild(from: sources)
        indexedChunkCount = await indexer.chunkCount
        isIndexing = false
    }

    func scheduleRebuild(notebooks: [Notebook]) {
        scheduledRebuild?.cancel()
        scheduledRebuild = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            // Walk the model graph AFTER the debounce, not before it.
            // `.noteCorpusDidChange` is posted from every autosave — i.e. after
            // every stroke batch, element drag, and paste — so building the
            // source list up front meant paying for a full
            // notebook → page → element traversal on the main thread each time,
            // only to throw the result away when the next save superseded it.
            // Skip models deleted during the debounce window; touching a
            // deleted SwiftData object can crash.
            let live = notebooks.filter { $0.modelContext != nil }
            let sources = Self.sources(from: live)
            guard !Task.isCancelled else { return }
            isIndexing = true
            await indexer.rebuild(from: sources)
            indexedChunkCount = await indexer.chunkCount
            isIndexing = false
        }
    }

    static func sources(from notebooks: [Notebook]) -> [NoteCorpusSource] {
        var sources: [NoteCorpusSource] = []
        for notebook in notebooks where notebook.trashedAt == nil {
            func add(_ kind: NoteSourceKind, _ label: String, _ text: String, page: Page? = nil, ordinal: Int = 0) {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return }
                sources.append(NoteCorpusSource(
                    notebookID: notebook.stableID,
                    pageID: page?.stableID,
                    notebookTitle: notebook.title,
                    pageTitle: page.map { $0.title.isEmpty ? "Page \($0.index + 1)" : $0.title },
                    sourceKind: kind,
                    label: label,
                    text: value,
                    modifiedAt: page?.modifiedAt ?? notebook.modifiedAt,
                    isBookmarked: page?.isBookmarked ?? false,
                    isArchived: notebook.isArchived,
                    sourceOrdinal: ordinal
                ))
            }

            add(.notebookTitle, notebook.title, [notebook.title, notebook.subtitle, notebook.folderName].joined(separator: " "))
            add(.tags, "\(notebook.title) tags", notebook.tagsText, ordinal: 1)
            for page in notebook.pages where page.trashedAt == nil {
                let pageLabel = page.title.isEmpty ? "Page \(page.index + 1)" : page.title
                add(.pageTitle, "\(notebook.title) - \(pageLabel)", pageLabel, page: page)
                add(.ocr, "\(notebook.title) - \(pageLabel) - OCR", page.ocrText, page: page)
                for (ordinal, element) in page.elements.sorted(by: { $0.createdAt < $1.createdAt }).enumerated() {
                    if let text = element.text {
                        let kind: NoteSourceKind = element.type == .image ? .imageText : .typedText
                        add(kind, "\(notebook.title) - \(pageLabel) - \(kind.label)", text, page: page, ordinal: ordinal)
                    }
                    if let transcript = element.transcript {
                        add(.transcript, "\(notebook.title) - \(pageLabel) - Transcript", transcript, page: page, ordinal: ordinal)
                    }
                }
            }
        }
        return sources
    }
}
