import Foundation
import SwiftData

@Model
final class AssistantThread {
    var stableID: UUID = UUID()
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var scopeRawValue: String
    @Relationship(deleteRule: .cascade, inverse: \AssistantMessage.thread)
    var messages: [AssistantMessage]

    init(title: String = "New conversation", scope: AssistantScope = .allNotes) {
        self.stableID = UUID()
        self.title = title
        self.createdAt = .now
        self.updatedAt = .now
        self.scopeRawValue = scope.rawValue
        self.messages = []
    }

    var scope: AssistantScope {
        get { AssistantScope(rawValue: scopeRawValue) ?? .allNotes }
        set { scopeRawValue = newValue.rawValue }
    }

    var orderedMessages: [AssistantMessage] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }
}

@Model
final class AssistantMessage {
    var stableID: UUID = UUID()
    var roleRawValue: String
    var content: String
    var createdAt: Date
    var citationsData: Data?
    var providerNotice: String?
    var isFailure: Bool
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
