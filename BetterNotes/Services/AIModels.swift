import Foundation

enum AssistantScope: String, CaseIterable, Codable, Sendable {
    case currentPage
    case currentNotebook
    case allNotes

    var label: String {
        switch self {
        case .currentPage: return AppLocalization.text("Current Page")
        case .currentNotebook: return AppLocalization.text("Current Notebook")
        case .allNotes: return AppLocalization.text("All Notes")
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
    case providerTest
}

struct AIRequest: Sendable {
    let systemInstructions: String
    let conversationMessages: [AIConversationMessage]
    let retrievedSources: [NoteChunk]
    let imageAttachments: [AIImageAttachment]
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
    /// Text the assistant itself wrote onto a page.
    case assistantAnswer

    var label: String {
        switch self {
        case .notebookTitle: return AppLocalization.text("Notebook")
        case .tags: return AppLocalization.text("Tags")
        case .pageTitle: return AppLocalization.text("Page title")
        case .typedText: return AppLocalization.text("Typed text")
        case .ocr: return AppLocalization.text("OCR")
        case .imageText: return AppLocalization.text("Image text")
        case .transcript: return AppLocalization.text("Transcript")
        case .assistantAnswer: return AppLocalization.text("Assistant answer")
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
        // Deliberately the lowest weight in the set. An assistant answer is
        // still worth finding in search, but it is not evidence: ranking it
        // alongside the user's own writing lets the model retrieve its own
        // earlier output and cite it back as a source.
        case .assistantAnswer: return 0.6
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

/// Whether a passage of this kind may be offered to the model as a citable
/// source. Assistant answers are indexed for search but never cited -- citing
/// them would launder the model's own claims into evidence.
extension NoteSourceKind {
    var isCitable: Bool { self != .assistantAnswer }
}

struct SourceCitation: Codable, Identifiable, Sendable, Equatable {
    var id: String { token }
    let notebookID: UUID
    let pageID: UUID?
    let sourceLabel: String
    let excerpt: String
    let token: String
}

/// A page rendered as an image, attached to a single request turn only --
/// never persisted into conversation history.
struct AIImageAttachment: Sendable, Equatable {
    let pageID: UUID
    let label: String
    let jpegData: Data
}

extension Notification.Name {
    static let noteCorpusDidChange = Notification.Name("BetterNotes.noteCorpusDidChange")
}
