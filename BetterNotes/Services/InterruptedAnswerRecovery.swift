import SwiftData

/// No response task survives an app launch. Settle any saved draft cards
/// before a page is shown so they offer an explicit retry.
@MainActor
enum InterruptedAnswerRecovery {
    static func run(in container: ModelContainer) throws {
        let context = ModelContext(container)
        let elements = try context.fetch(FetchDescriptor<PageElement>())
        var changed = false
        for element in elements {
            guard var payload = element.assistantPayload, payload.isStreaming else { continue }
            payload.isStreaming = false
            payload.notice = "The answer was interrupted. Tap Retry to try again."
            element.assistantPayload = payload
            changed = true
        }
        if changed { try context.save() }
    }
}
