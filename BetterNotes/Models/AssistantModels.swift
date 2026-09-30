import Foundation
import SwiftData

@Model
final class AssistantThread {
    var stableID: UUID = UUID()
    var title: String = "New conversation"
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var scopeRawValue: String = "allNotes"
    @Relationship(deleteRule: .cascade, originalName: "messages", inverse: \AssistantMessage.thread)
    private var storedMessages: [AssistantMessage]?

    var messages: [AssistantMessage] {
        get { storedMessages ?? [] }
        set { storedMessages = newValue }
    }

    init(title: String = "New conversation", scope: AssistantScope = .allNotes) {
        self.stableID = UUID()
        self.title = title
        self.createdAt = .now
        self.updatedAt = .now
        self.scopeRawValue = scope.rawValue
        self.storedMessages = []
    }

    var scope: AssistantScope {
        get { AssistantScope(rawValue: scopeRawValue) ?? .allNotes }
        set { scopeRawValue = newValue.rawValue }
    }

    var orderedMessages: [AssistantMessage] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }

    /// Erases every conversation, and through the cascade rule every message
    /// (and the note excerpts they quote). Page answer cards are page
    /// elements, not threads, so notes are untouched.
    static func deleteAll(in context: ModelContext) throws {
        for thread in try context.fetch(FetchDescriptor<AssistantThread>()) {
            context.delete(thread)
        }
        try context.save()
    }
}

@Model
final class AssistantMessage {
    var stableID: UUID = UUID()
    var roleRawValue: String = "user"
    var content: String = ""
    var createdAt: Date = Date.now
    var citationsData: Data?
    var providerNotice: String?
    var isFailure: Bool = false
    var thread: AssistantThread?

    init(
        role: AIMessageRole,
        content: String,
        citations: [SourceCitation] = [],
        providerNotice: String? = nil,
        isFailure: Bool = false
    ) {
        self.stableID = UUID()
        self.roleRawValue = role.rawValue
        self.content = content
        self.createdAt = .now
        self.citationsData = try? JSONEncoder().encode(citations)
        self.providerNotice = providerNotice
        self.isFailure = isFailure
        self.thread = nil
    }

    var role: AIMessageRole {
        AIMessageRole(rawValue: roleRawValue) ?? .assistant
    }

    var citations: [SourceCitation] {
        guard let citationsData else { return [] }
        return (try? JSONDecoder().decode([SourceCitation].self, from: citationsData)) ?? []
    }
}
