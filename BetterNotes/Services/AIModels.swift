import Foundation

enum AssistantScope: String, CaseIterable, Codable, Sendable {
    case currentPage
    case currentNotebook
    case allNotes

    var label: String {
        switch self {
        case .currentPage: return "Current Page"
        case .currentNotebook: return "Current Notebook"
        case .allNotes: return "All Notes"
        }
    }
}

enum AIMessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}

struct AIConversationMessage: Codable, Sendable, Equatable {
    let role: AIMessageRole
    let content: String
}

enum AIFeatureOrigin: String, Codable, Sendable {
    case assistant
    case search
    case writingSuggestion
    case providerTest
}

struct AIRequest: Sendable {
    let systemInstructions: String
    let conversationMessages: [AIConversationMessage]
    let retrievedSources: [NoteChunk]
    let outputLimit: Int
    let featureOrigin: AIFeatureOrigin
}

enum AIStreamEvent: Sendable, Equatable {
    case responseDelta(String)
    case completed(String)
    case providerNotice(String)
    case failure(String)
}

enum NoteSourceKind: String, CaseIterable, Codable, Sendable {
    case notebookTitle
    case tags
    case pageTitle
    case typedText
    case ocr
    case imageText
    case transcript

    var label: String {
        switch self {
        case .notebookTitle: return "Notebook"
        case .tags: return "Tags"
        case .pageTitle: return "Page title"
        case .typedText: return "Typed text"
        case .ocr: return "OCR"
        case .imageText: return "Image text"
        case .transcript: return "Transcript"
        }
    }

    var fieldWeight: Double {
        switch self {
        case .notebookTitle: return 3.0
        case .tags: return 2.7
        case .pageTitle: return 2.8
        case .typedText: return 2.2
        case .ocr: return 1.45
        case .imageText: return 1.35
        case .transcript: return 1.65
        }
    }
}

struct NoteChunk: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let notebookID: UUID
    let pageID: UUID?
    let notebookTitle: String
    let pageTitle: String?
    let sourceKind: NoteSourceKind
    let label: String
    let text: String
    let terms: [String: Int]
    let embedding: [Double]?
    let fingerprint: String
    let modifiedAt: Date
    let isBookmarked: Bool
    let isArchived: Bool
}

struct SearchFilters: Codable, Sendable, Equatable {
    var notebookID: UUID?
    var pageID: UUID?
    var contentKinds: Set<NoteSourceKind>
    var modifiedAfter: Date?
    var modifiedBefore: Date?
    var bookmarkedOnly: Bool
    var includeArchived: Bool

    init(
        notebookID: UUID? = nil,
        pageID: UUID? = nil,
        contentKinds: Set<NoteSourceKind> = [],
        modifiedAfter: Date? = nil,
        modifiedBefore: Date? = nil,
        bookmarkedOnly: Bool = false,
        includeArchived: Bool = true
    ) {
        self.notebookID = notebookID
        self.pageID = pageID
        self.contentKinds = contentKinds
        self.modifiedAfter = modifiedAfter
        self.modifiedBefore = modifiedBefore
        self.bookmarkedOnly = bookmarkedOnly
        self.includeArchived = includeArchived
    }
}

struct SearchQuery: Sendable, Equatable {
    let text: String
    var filters: SearchFilters
    var limit: Int

    init(text: String, filters: SearchFilters = SearchFilters(), limit: Int = 20) {
        self.text = text
        self.filters = filters
        self.limit = limit
    }
}

struct SearchResult: Identifiable, Sendable, Equatable {
    let id: String
    let chunk: NoteChunk
    let score: Double
    let snippet: String
    let highlights: [String]
}

struct SourceCitation: Codable, Identifiable, Sendable, Equatable {
    var id: String { token }
    let notebookID: UUID
    let pageID: UUID?
    let sourceLabel: String
    let excerpt: String
    let token: String
}

enum WritingSuggestionMode: String, CaseIterable, Codable, Sendable {
    case improveClarity
    case makeConcise
    case explain
    case outline
    case continueWriting

    var label: String {
        switch self {
        case .improveClarity: return "Improve Clarity"
        case .makeConcise: return "Make Concise"
        case .explain: return "Explain"
        case .outline: return "Outline"
        case .continueWriting: return "Continue Writing"
        }
    }
}

struct WritingSuggestion: Identifiable, Sendable, Equatable {
    let id: UUID
    let sourceRange: NSRange
    let originalText: String
    let replacementText: String
    let mode: WritingSuggestionMode
    let requestRevision: Int
}

extension Notification.Name {
    static let noteCorpusDidChange = Notification.Name("BetterNotes.noteCorpusDidChange")
}
