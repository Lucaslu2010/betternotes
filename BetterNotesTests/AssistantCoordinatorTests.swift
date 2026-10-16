import XCTest
@testable import BetterNotes

/// The assistant is the one place in the app that talks to an outside server,
/// and the one place a wrong answer looks authoritative. What matters is that
/// it degrades honestly when the provider is missing or broken, and that it
/// never presents a citation the retrieval layer did not actually supply.
@MainActor
final class AssistantCoordinatorTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AssistantCoordinatorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        AISettingsStore(defaults: defaults, keychainService: suiteName).clear()
    }

    override func tearDown() {
        AISettingsStore(defaults: defaults, keychainService: suiteName).clear()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeClient(stubs: [MockAIURLProtocol.Stub]) -> AIClient {
        MockAIURLProtocol.install(stubs)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockAIURLProtocol.self]
        return AIClient(session: URLSession(configuration: configuration), retryDelay: .zero)
    }

    private func makeIndexer(withNotes: Bool) async -> NoteCorpusIndexer {
        let indexer = NoteCorpusIndexer(persistenceURL: nil)
        guard withNotes else { return indexer }
        await indexer.rebuild(from: [
            NoteCorpusSource(
                notebookID: UUID(), pageID: UUID(),
                notebookTitle: "Biology", pageTitle: "Photosynthesis",
                sourceKind: .typedText, label: "Photosynthesis",
                text: "Chlorophyll absorbs light in the thylakoid membrane.",
                modifiedAt: .now, isBookmarked: false, isArchived: false, sourceOrdinal: 0
            )
        ])
        return indexer
    }

    private func makeCoordinator(client: AIClient,
                                 configured: Bool,
                                 indexer: NoteCorpusIndexer) throws -> AssistantCoordinator {
        let settings = AISettingsStore(defaults: defaults, keychainService: suiteName)
        if configured {
            try settings.update(apiKey: "test-key", baseURL: "https://example.com/v1", model: "test-model")
        }
        return AssistantCoordinator(settings: settings, client: client, indexer: indexer)
    }

    /// Runs `send` and waits for the single completion callback.
    private func reply(from coordinator: AssistantCoordinator, question: String) async -> AssistantReply {
        await withCheckedContinuation { continuation in
            coordinator.send(
                question: question, scope: .allNotes, notebookID: nil, pageID: nil, history: []
            ) { reply in
                continuation.resume(returning: reply)
            }
        }
    }

    // MARK: - Degrading honestly

    func testWithNoProviderConfiguredItAnswersOnDeviceAndSaysSo() async throws {
        let coordinator = try makeCoordinator(
            client: makeClient(stubs: []), configured: false, indexer: await makeIndexer(withNotes: true)
        )
        let reply = await reply(from: coordinator, question: "chlorophyll")

        XCTAssertNil(reply.error)
        XCTAssertNotNil(reply.notice, "an on-device answer was presented as if it came from the provider")
        XCTAssertTrue(reply.text.contains("thylakoid"), "the local answer did not use the notes: \(reply.text)")
        XCTAssertFalse(coordinator.isResponding)
    }

    func testWithNoNotesItSaysThereIsNotEnoughEvidence() async throws {
        let coordinator = try makeCoordinator(
            client: makeClient(stubs: []), configured: false, indexer: await makeIndexer(withNotes: false)
        )
        let reply = await reply(from: coordinator, question: "chlorophyll")
        XCTAssertTrue(reply.text.contains("could not find enough evidence"), reply.text)
        XCTAssertTrue(reply.citations.isEmpty, "an answer with no evidence still carried citations")
    }

    func testAProviderFailureFallsBackToTheNotesAndReportsTheError() async throws {
        let coordinator = try makeCoordinator(
            client: makeClient(stubs: [.init(statusCode: 500, body: "upstream on fire")]),
            configured: true,
            indexer: await makeIndexer(withNotes: true)
        )
        let reply = await reply(from: coordinator, question: "chlorophyll")

        XCTAssertNotNil(reply.error, "a provider failure was swallowed")
        XCTAssertNotNil(reply.notice)
        XCTAssertTrue(reply.text.contains("thylakoid"), "the fallback did not use the notes: \(reply.text)")
        XCTAssertFalse(coordinator.isResponding, "the spinner was left running after a failure")
    }

    private func chunk(label: String, text: String) -> NoteChunk {
        NoteChunk(
            id: UUID().uuidString, notebookID: UUID(), pageID: UUID(),
            notebookTitle: "Biology", pageTitle: label, sourceKind: .typedText,
            label: label, text: text, terms: [:], embedding: nil,
            fingerprint: UUID().uuidString, modifiedAt: .now,
            isBookmarked: false, isArchived: false
        )
    }

    // MARK: - Citations

    func testACitationTheProviderInventedIsDiscarded() {
        let supplied = AssistantCoordinator.citations(for: [
            chunk(label: "A", text: "first passage"),
            chunk(label: "B", text: "second passage")
        ])
        XCTAssertEqual(supplied.map(\.token), ["S1", "S2"])

        // S7 was never supplied — a model that invents one must not get a
        // clickable citation out of it.
        let validated = AssistantCoordinator.validatedCitations(
            in: "Photosynthesis happens in the chloroplast [S2], mostly [S7].",
            supplied: supplied
        )
        XCTAssertEqual(validated.map(\.token), ["S2"])
    }

    func testARepeatedCitationIsListedOnce() {
        let supplied = AssistantCoordinator.citations(for: [
            chunk(label: "A", text: "first passage")
        ])
        let validated = AssistantCoordinator.validatedCitations(
            in: "One [S1], and again [S1].", supplied: supplied
        )
        XCTAssertEqual(validated.count, 1)
    }

    func testCitationExcerptsAreCappedSoOneSourceCannotFillTheSheet() {
        let long = String(repeating: "a", count: 5_000)
        let supplied = AssistantCoordinator.citations(for: [
            chunk(label: "A", text: long)
        ])
        XCTAssertLessThanOrEqual(supplied[0].excerpt.count, 220)
    }

    // MARK: - Cancellation

    func testCancellingStopsTheSpinner() async throws {
        let coordinator = try makeCoordinator(
            client: makeClient(stubs: [.init(statusCode: 200, body: "{}", delay: 5)]),
            configured: true,
            indexer: await makeIndexer(withNotes: true)
        )
        coordinator.send(question: "chlorophyll", scope: .allNotes,
                         notebookID: nil, pageID: nil, history: []) { _ in }
        XCTAssertTrue(coordinator.isResponding)
        coordinator.cancel()
        XCTAssertFalse(coordinator.isResponding)
    }

    func testClearingTransientStateLeavesNothingBehind() async throws {
        let coordinator = try makeCoordinator(
            client: makeClient(stubs: []), configured: false, indexer: await makeIndexer(withNotes: true)
        )
        _ = await reply(from: coordinator, question: "chlorophyll")
        XCTAssertFalse(coordinator.responseDraft.isEmpty)

        coordinator.clearTransientState()
        XCTAssertEqual(coordinator.responseDraft, "")
        XCTAssertTrue(coordinator.currentCitations.isEmpty)
        XCTAssertNil(coordinator.notice)
        XCTAssertNil(coordinator.errorMessage)
    }
}
