import SwiftData
import XCTest
@testable import BetterNotes

@MainActor
final class InterruptedAnswerRecoveryTests: XCTestCase {
    func testLaunchSettlesAnOrphanedAnswerCard() throws {
        let schema = Schema([Notebook.self, Page.self, PageElement.self])
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)
        let element = PageElement(type: .assistantNote, x: 100, y: 100)
        element.assistantPayload = AssistantNotePayload(question: "How are you?", isStreaming: true)
        context.insert(element)
        try context.save()

        try InterruptedAnswerRecovery.run(in: container)

        let recovered = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<PageElement>()).first)
        let payload = try XCTUnwrap(recovered.assistantPayload)
        XCTAssertFalse(payload.isStreaming)
        XCTAssertEqual(payload.question, "How are you?")
        XCTAssertTrue(payload.notice?.contains("Retry") == true)
    }
}
