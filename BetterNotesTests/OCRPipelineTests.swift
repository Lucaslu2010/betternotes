import Combine
import Darwin
import ImageIO
import PencilKit
import SwiftData
import UIKit
import XCTest
@testable import BetterNotes

@MainActor
final class OCRPipelineTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var settings: OCRSettingsStore!

    override func setUp() {
        super.setUp()
        suite = "OCRPipelineTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        settings = OCRSettingsStore(defaults: defaults, tokenService: suite)
    }

    override func tearDown() {
        try? settings.removeToken()
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testLocalIsTheDefaultAndCustomRequiresCredentials() throws {
        XCTAssertEqual(settings.provider, .local)
        XCTAssertNil(settings.configuration)
        XCTAssertThrowsError(try settings.save(provider: .custom, endpoint: "https://example.com/layout-parsing", token: nil, format: .paddleOCR, model: ""))
        XCTAssertEqual(settings.provider, .local)
    }

    func testOCRCredentialsPersistSeparatelyAndNeverEnterDefaults() throws {
        try settings.save(provider: .custom, endpoint: "https://example.com/layout-parsing", token: "ocr-secret", format: .paddleOCR, model: "")
        let restored = OCRSettingsStore(defaults: defaults, tokenService: suite)
        XCTAssertEqual(restored.configuration?.token, "ocr-secret")
        XCTAssertEqual(restored.provider, .custom)
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { ($0 as? String) == "ocr-secret" })
        XCTAssertEqual(restored.identity, settings.identity)
        let identity = restored.identity
        try restored.save(provider: .custom, endpoint: "https://example.com/ocr", token: nil, format: .paddleOCR, model: "")
        XCTAssertNotEqual(restored.identity, identity)
        XCTAssertEqual(restored.configuration?.token, "ocr-secret")
    }

    func testTestingDraftConfigurationDoesNotSwitchTheProvider() throws {
        let draft = try settings.testConfiguration(endpoint: "https://example.com/ocr", token: "draft-token", format: .paddleOCR, model: "")
        XCTAssertEqual(draft.token, "draft-token")
        XCTAssertEqual(settings.provider, .local)
        XCTAssertFalse(settings.hasToken)
    }

    func testOnlyHTTPSAndExactLocalhostAreAccepted() {
        XCTAssertTrue(OCRSettingsStore.isAllowedEndpoint("https://example.com/layout-parsing"))
        XCTAssertTrue(OCRSettingsStore.isAllowedEndpoint("http://localhost:8080/ocr"))
        for value in ["http://example.com/ocr", "http://localhost.evil.com/ocr", "https://user:secret@example.com/ocr", "https://example.com/ocr#secret", "file:///tmp/ocr"] {
            XCTAssertFalse(OCRSettingsStore.isAllowedEndpoint(value), value)
        }
    }

    func testPaddleDocumentAndTextResponsesAreParsedWithoutImages() throws {
        let layout = Data(##"{"errorCode":0,"result":{"layoutParsingResults":[{"markdown":{"text":"# Notes\nEnergy: $E=mc^2$","images":{"diagram":"https://example.com/never-download"}}}]}}"##.utf8)
        XCTAssertEqual(try OCRClient.transcription(from: layout, format: .paddleOCR), "# Notes\nEnergy: $E=mc^2$")
        let text = Data(#"{"result":{"ocrResults":[{"prunedResult":{"rec_texts":["?? Explain entropy","Entropy measures disorder"]}}]}}"#.utf8)
        XCTAssertEqual(try OCRClient.transcription(from: text, format: .paddleOCR), "?? Explain entropy\nEntropy measures disorder")
        XCTAssertThrowsError(try OCRClient.transcription(from: Data(#"{"errorCode":429}"#.utf8), format: .paddleOCR))
        XCTAssertThrowsError(try OCRClient.transcription(from: Data(#"{"result":{"jobId":"async-job"}}"#.utf8), format: .paddleOCR))
    }

    func testVisionResponsesPreserveFormulasAndRejectTruncation() throws {
        let response = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"?? What is $x^2$?"}}]}"#.utf8)
        XCTAssertEqual(try OCRClient.transcription(from: response, format: .visionChat), "?? What is $x^2$?")
        let truncated = Data(#"{"choices":[{"finish_reason":"length","message":{"content":"partial"}}]}"#.utf8)
        XCTAssertThrowsError(try OCRClient.transcription(from: truncated, format: .visionChat))
    }

    func testQuestionMarkerCanStartOrEndALine() {
        XCTAssertEqual(HandwrittenQuestion.question(in: "Lecture\n?? Why does entropy increase?"), "Why does entropy increase?")
        XCTAssertEqual(HandwrittenQuestion.question(in: "# ？？ 什么是熵？"), "什么是熵？")
        XCTAssertEqual(HandwrittenQuestion.question(in: "? ? Explain this"), "Explain this")
        XCTAssertEqual(HandwrittenQuestion.question(in: "??"), "")
        XCTAssertEqual(HandwrittenQuestion.question(in: "Is this right??"), "Is this right")
        XCTAssertEqual(HandwrittenQuestion.question(in: "什么是熵 ？ ？"), "什么是熵")
        XCTAssertEqual(HandwrittenQuestion.question(in: "Explain this ??"), "Explain this")
        XCTAssertNil(HandwrittenQuestion.question(in: "? Explain this"))
        XCTAssertNil(HandwrittenQuestion.question(in: "Is this right?"))
        XCTAssertNil(HandwrittenQuestion.question(in: "Words ?? inside a sentence"))
    }

    func testQuestionDetectionJoinsSplitPunctuationOnTheSameRow() throws {
        let lines: [HandwritingOCR.Line] = [
            .init(text: "Explain entropy", bounds: CGRect(x: 30, y: 100, width: 200, height: 30)),
            .init(text: "?", bounds: CGRect(x: 250, y: 100, width: 15, height: 30)),
            .init(text: "?", bounds: CGRect(x: 275, y: 102, width: 15, height: 28)),
            .init(text: "Unrelated row", bounds: CGRect(x: 30, y: 160, width: 200, height: 30))
        ]
        let line = try XCTUnwrap(HandwritingOCR.questionLine(in: lines))
        XCTAssertEqual(HandwrittenQuestion.question(in: line.text), "Explain entropy")
        XCTAssertEqual(line.bounds, CGRect(x: 30, y: 100, width: 260, height: 30))
    }

    func testQuestionCropIncludesWordsToTheLeftOfASuffixMarker() {
        let line = HandwritingOCR.Line(text: "??", bounds: CGRect(x: 500, y: 100, width: 40, height: 30))
        let region = HandwritingOCR.questionRegion(for: line, pageSize: CGSize(width: 600, height: 800))
        XCTAssertEqual(region.minX, 0)
        XCTAssertEqual(region.maxX, 600)
        XCTAssertTrue(region.contains(CGRect(x: 30, y: 100, width: 500, height: 30)))
    }

    func testPaddleRequestUsesTokenAuthenticationAndBase64Image() async throws {
        MockAIURLProtocol.install([.init(body: #"{"result":{"layoutParsingResults":[{"markdown":{"text":"recognized notes"}}]}}"#)])
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [MockAIURLProtocol.self]
        let client = OCRClient(session: URLSession(configuration: session))
        let config = OCRConfiguration(endpoint: URL(string: "https://example.com/layout-parsing")!, token: "ocr-token", format: .paddleOCR, model: "", identity: "test")
        let image = Data([1, 2, 3])
        let text = try await client.recognize(imageData: image, configuration: config)
        XCTAssertEqual(text, "recognized notes")
        let request = try XCTUnwrap(MockAIURLProtocol.recordedRequests().first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token ocr-token")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["file"] as? String, image.base64EncodedString())
        XCTAssertEqual(body["fileType"] as? Int, 1)
        XCTAssertEqual(body["visualize"] as? Bool, false)
        XCTAssertEqual(body["returnMarkdownImages"] as? Bool, false)
        XCTAssertEqual(MockAIURLProtocol.recordedRequests().count, 1)
    }

    func testOversizedOCRResponseFailsBeforeJSONParsing() async throws {
        MockAIURLProtocol.install([.init(body: String(repeating: "x", count: 1024))])
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [MockAIURLProtocol.self]
        let client = OCRClient(session: URLSession(configuration: session), maximumResponseBytes: 128)
        let config = OCRConfiguration(endpoint: URL(string: "https://example.com/ocr")!, token: "test", format: .paddleOCR, model: "", identity: "test")
        do {
            _ = try await client.recognize(imageData: Data([1]), configuration: config)
            XCTFail("Oversized OCR responses must not be loaded into a JSON object")
        } catch OCRError.responseTooLarge { }
    }

    func testLargeHandwrittenPageRendersWithinBitmapBudget() async throws {
        let rendered = await HandwritingOCR.imageData(
            from: drawing().dataRepresentation(), pageSize: CGSize(width: 4000, height: 3000),
            region: CGRect(x: 0, y: 0, width: 4000, height: 3000)
        )
        let data = try XCTUnwrap(rendered)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        XCTAssertLessThanOrEqual(max(width, height), Int(OCRImageBudget.maximumEdge))
        XCTAssertLessThanOrEqual(width * height, Int(OCRImageBudget.maximumPixels) + width + height)
    }

    func testAlreadyCancelledLocalOCRDoesNotStartRecognition() async {
        let ink = drawing().dataRepresentation()
        let task = Task {
            await HandwritingOCR.scan(from: ink, pageSize: CGSize(width: 4000, height: 3000))
        }
        task.cancel()
        let lines = await task.value
        XCTAssertTrue(lines.isEmpty)
    }

    func testImageOCRDownsamplesBeforeDecodingFullResolution() async throws {
        let image = largeNoteImage()
        let thumbnail = try XCTUnwrap(OCRImageBudget.thumbnail(from: image))
        XCTAssertLessThanOrEqual(thumbnail.width * thumbnail.height, Int(OCRImageBudget.maximumPixels) + thumbnail.width + thumbnail.height)
        let text = await HandwritingOCR.recognizeImage(from: image)
        XCTAssertTrue(text.contains("ENERGY"), text)
    }

    func testRepeatedLocalOCRAndProviderRequestsKeepMemoryBounded() async throws {
        let image = largeNoteImage()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockAIURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let ocr = OCRClient(session: session)
        let ai = AIClient(session: session)
        let ocrConfig = OCRConfiguration(endpoint: URL(string: "https://example.com/ocr")!, token: "test", format: .paddleOCR, model: "", identity: "test")
        let aiConfig = AIProviderConfiguration(apiKey: "test", baseURL: "https://example.com/v1", model: "test")
        var peak = memoryFootprint()
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                peak = max(peak, memoryFootprint())
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { monitor.cancel() }
        var settled: [UInt64] = []
        for round in 0..<6 {
            let text = await HandwritingOCR.recognizeImage(from: image)
            XCTAssertTrue(text.contains("ENERGY"))
            let prepared = await HandwritingOCR.preparedImageData(from: image)
            let png = try XCTUnwrap(prepared)
            MockAIURLProtocol.install([
                .init(body: #"{"result":{"ocrResults":[{"prunedResult":{"rec_texts":["Energy notes"]}}]}}"#),
                .init(body: #"{"choices":[{"message":{"content":"Energy is conserved."}}]}"#)
            ])
            let recognized = try await ocr.recognize(imageData: png, configuration: ocrConfig)
            let answer = try await ai.complete(AIRequest(systemInstructions: "Answer from notes.", conversationMessages: [AIConversationMessage(role: .user, content: recognized)], retrievedSources: [], outputLimit: 100, featureOrigin: .assistant), configuration: aiConfig)
            XCTAssertEqual(answer, "Energy is conserved.")
            try await Task.sleep(for: .milliseconds(100))
            settled.append(memoryFootprint())
            print("[OCR memory] round=\(round + 1) footprintMiB=\(settled.last! / 1_048_576) peakMiB=\(peak / 1_048_576)")
        }
        // Warm-up loads the Vision model. Repeated requests must release their
        // working images rather than retaining another bitmap every round.
        XCTAssertLessThan(settled.last!, settled[0] + 64 * 1_048_576)
    }

    private func memoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private func largeNoteImage() -> Data {
        autoreleasepool {
            let size = CGSize(width: 4000, height: 3000)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                ("ENERGY NOTES" as NSString).draw(at: CGPoint(x: 250, y: 250), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 180), .foregroundColor: UIColor.black
                ])
            }.jpegData(compressionQuality: 0.8)!
        }
    }

    func testRefreshingBlankInkKeepsLegacyPDFText() async throws {
        let context = try makeContext()
        let page = Page()
        page.ocrText = "Original PDF source text"
        let size = page.pageOrientation.size
        let image = PageElement(type: .image, x: size.width / 2, y: size.height / 2, width: size.width, height: size.height)
        image.isLocked = true
        page.appendElement(image)
        context.insert(page)
        try await OCRService(settings: settings).refresh(pages: [page])
        XCTAssertEqual(page.pdfText, "Original PDF source text")
        XCTAssertEqual(page.ocrText, "")
        XCTAssertEqual(page.searchableOCRText, "Original PDF source text")
    }

    func testFailedCustomRecognitionPreservesExistingText() async throws {
        let context = try makeContext()
        let page = Page()
        page.ocrText = "previous recognition"
        page.inkData = drawing().dataRepresentation()
        page.ocrStorageVersion = 1
        context.insert(page)
        try settings.save(provider: .custom, endpoint: "https://example.com/ocr", token: "token", format: .paddleOCR, model: "")
        MockAIURLProtocol.install([.init(statusCode: 429)])
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [MockAIURLProtocol.self]
        let service = OCRService(settings: settings, client: OCRClient(session: URLSession(configuration: session)))
        do {
            try await service.refresh(pages: [page])
            XCTFail("The failed request should be reported")
        } catch { }
        XCTAssertEqual(page.ocrText, "previous recognition")
        XCTAssertNil(page.ocrInkFingerprint)
    }

    func testUnchangedInkIsNotUploadedTwice() async throws {
        let context = try makeContext()
        let page = Page()
        page.inkData = drawing().dataRepresentation()
        page.ocrStorageVersion = 1
        context.insert(page)
        try settings.save(provider: .custom, endpoint: "https://example.com/ocr", token: "token", format: .paddleOCR, model: "")
        MockAIURLProtocol.install([.init(body: #"{"result":{"ocrResults":[{"prunedResult":{"rec_texts":["Accurate note text"]}}]}}"#)])
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [MockAIURLProtocol.self]
        let service = OCRService(settings: settings, client: OCRClient(session: URLSession(configuration: session)))
        try await service.refresh(pages: [page])
        try await service.refresh(pages: [page])
        XCTAssertEqual(page.ocrText, "Accurate note text")
        XCTAssertEqual(MockAIURLProtocol.recordedRequests().count, 1)
    }

    func testLateOCRDoesNotOverwriteNewInk() async throws {
        let context = try makeContext()
        let page = Page()
        page.inkData = drawing().dataRepresentation()
        page.ocrText = "previous text"
        page.ocrStorageVersion = 1
        context.insert(page)
        try settings.save(provider: .custom, endpoint: "https://example.com/ocr", token: "token", format: .paddleOCR, model: "")
        MockAIURLProtocol.install([.init(body: #"{"result":{"ocrResults":[{"prunedResult":{"rec_texts":["stale result"]}}]}}"#, delay: 0.2)])
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [MockAIURLProtocol.self]
        let service = OCRService(settings: settings, client: OCRClient(session: URLSession(configuration: session)))
        let task = Task { try await service.refresh(pages: [page]) }
        try await Task.sleep(for: .milliseconds(50))
        page.inkData = PKDrawing().dataRepresentation()
        do { try await task.value; XCTFail("Stale OCR should be rejected") } catch is CancellationError { }
        XCTAssertEqual(page.ocrText, "previous text")
    }

    func testPDFTextSurvivesPageCopiesAndBackups() throws {
        let context = try makeContext()
        let notebook = Notebook(title: "PDF notes")
        let page = Page()
        page.pdfText = "Imported source text"
        page.ocrText = "Handwritten annotations"
        page.ocrStorageVersion = 1
        page.notebook = notebook
        notebook.pages = [page]
        context.insert(notebook)
        let copy = PageOperations.clone(page, newIndex: 1, notebook: notebook)
        XCTAssertEqual(copy.searchableOCRText, page.searchableOCRText)
        let url = try CloudTranslator.writeArchive(for: notebook)
        defer { try? FileManager.default.removeItem(at: url) }
        let restored = try CloudTranslator.importArchive(from: url, into: try makeContext())
        XCTAssertEqual(restored.pages.first?.pdfText, page.pdfText)
        XCTAssertEqual(restored.pages.first?.ocrText, page.ocrText)
    }

    func testCachedPassagesRefreshBookmarkAndArchiveFilters() async {
        let notebook = UUID()
        let page = UUID()
        let indexer = NoteCorpusIndexer(persistenceURL: nil)
        func source(bookmarked: Bool, archived: Bool) -> NoteCorpusSource {
            NoteCorpusSource(notebookID: notebook, pageID: page, notebookTitle: "Notes", pageTitle: "Entropy", sourceKind: .ocr, label: "Notes - OCR", text: "Entropy increases", modifiedAt: .now, isBookmarked: bookmarked, isArchived: archived, sourceOrdinal: 0)
        }
        await indexer.rebuild(from: [source(bookmarked: false, archived: false)])
        await indexer.rebuild(from: [source(bookmarked: true, archived: true)])
        let bookmarked = await indexer.search(SearchQuery(text: "entropy", filters: SearchFilters(bookmarkedOnly: true)))
        XCTAssertEqual(bookmarked.count, 1)
        let unarchived = await indexer.search(SearchQuery(text: "entropy", filters: SearchFilters(includeArchived: false)))
        XCTAssertTrue(unarchived.isEmpty)
    }

    func testInlineQuestionAppearsBeforeOCRAndRequiresConfirmationToOpenAssistant() async throws {
        let context = try makeContext()
        let page = Page()
        page.inkData = drawing().dataRepresentation()
        context.insert(page)
        let service = try questionService(stub: .init(body: #"{"result":{"ocrResults":[{"prunedResult":{"rec_texts":["?? Why does entropy increase?"]}}]}}"#, delay: 0.1))
        let editor = EditorActionState()
        let completed = expectation(description: "Question transcription completed")
        let observer = editor.$handwrittenQuestion.compactMap { $0 }.sink { draft in
            if case .ready = draft.phase { completed.fulfill() }
        }
        defer { observer.cancel() }
        editor.recognizeQuestion(questionRequest(page), using: service, context: context)
        let pendingID = editor.handwrittenQuestion?.id
        XCTAssertFalse(editor.isAssistantPresented)
        XCTAssertNotNil(editor.questionAnchor(for: page.persistentModelID))
        XCTAssertFalse(editor.shouldSubmitQuestion)
        editor.confirmQuestion()
        XCTAssertFalse(editor.isAssistantPresented, "Recognition must finish before Answer is enabled")
        XCTAssertEqual(editor.handwrittenQuestion?.phase, .recognizing)
        XCTAssertTrue(editor.handwrittenQuestion?.isRecognizing == true)
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(editor.handwrittenQuestion?.id, pendingID)
        XCTAssertEqual(editor.handwrittenQuestion?.text, "Why does entropy increase?")
        XCTAssertFalse(editor.isAssistantPresented, "OCR completion must not interrupt writing")
        XCTAssertEqual(MockAIURLProtocol.recordedRequests().count, 1, "The draft should not wait for full-note OCR")
        editor.confirmQuestion()
        XCTAssertTrue(editor.isAssistantPresented)
        XCTAssertTrue(editor.shouldSubmitQuestion)
        XCTAssertNil(editor.questionAnchor(for: page.persistentModelID))
    }

    func testQuestionRecognitionFailureStaysInTheInlineLabel() async throws {
        let context = try makeContext()
        let page = Page()
        page.inkData = drawing().dataRepresentation()
        context.insert(page)
        let service = try questionService(stub: .init(statusCode: 429))
        let editor = EditorActionState()
        let failed = expectation(description: "OCR failure shown in inline label")
        let observer = editor.$handwrittenQuestion.compactMap { $0 }.sink { draft in
            if case .failed = draft.phase { failed.fulfill() }
        }
        defer { observer.cancel() }
        editor.recognizeQuestion(questionRequest(page), using: service, context: context)
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertFalse(editor.isAssistantPresented)
        XCTAssertNotNil(editor.questionAnchor(for: page.persistentModelID))
        XCTAssertFalse(editor.handwrittenQuestion?.isRecognizing ?? true)
        XCTAssertEqual(editor.handwrittenQuestion?.text, "")
    }

    func testWritingOnAnotherRowDoesNotInvalidateTheInlineQuestion() async throws {
        let context = try makeContext()
        let page = Page()
        let original = drawing()
        page.inkData = original.dataRepresentation()
        context.insert(page)
        let service = try questionService(stub: .init(body: #"{"result":{"ocrResults":[{"prunedResult":{"rec_texts":["?? Explain entropy"]}}]}}"#, delay: 0.1))
        let editor = EditorActionState()
        let completed = expectation(description: "Question ready while writing continues elsewhere")
        let observer = editor.$handwrittenQuestion.compactMap { $0 }.sink { draft in
            if case .ready = draft.phase { completed.fulfill() }
        }
        defer { observer.cancel() }
        let region = CGRect(x: 0, y: 0, width: 300, height: 100)
        editor.recognizeQuestion(HandwrittenQuestionRequest(
            page: page, inkData: page.inkData!, pageSize: page.pageOrientation.size,
            region: region, fingerprint: "marker"
        ), using: service, context: context)
        let otherRow = original.transformed(using: CGAffineTransform(translationX: 0, y: 300))
        page.inkData = PKDrawing(strokes: original.strokes + otherRow.strokes).dataRepresentation()
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(editor.handwrittenQuestion?.text, "Explain entropy")
        XCTAssertFalse(editor.isAssistantPresented)
    }

    func testQuestionFingerprintUsesStrokeContentInsteadOfDrawingArchiveIdentity() throws {
        let original = drawing()
        let region = CGRect(x: 0, y: 0, width: 300, height: 100)
        let expected = QuestionInkFingerprint.make(in: original, region: region)
        let decoded = try PKDrawing(data: original.dataRepresentation())
        let rebuilt = PKDrawing(strokes: decoded.strokes)
        XCTAssertEqual(QuestionInkFingerprint.make(in: rebuilt, region: region), expected)
        let otherRow = original.transformed(using: CGAffineTransform(translationX: 0, y: 300))
        let withMoreWriting = PKDrawing(strokes: original.strokes + otherRow.strokes)
        XCTAssertEqual(QuestionInkFingerprint.make(in: withMoreWriting, region: region), expected)
        let moved = original.transformed(using: CGAffineTransform(translationX: 10, y: 0))
        XCTAssertNotEqual(QuestionInkFingerprint.make(in: moved, region: region), expected)
        var erased = original.strokes[0]
        erased.mask = UIBezierPath(rect: CGRect(x: 20, y: 20, width: 60, height: 40))
        XCTAssertNotEqual(QuestionInkFingerprint.make(in: PKDrawing(strokes: [erased]), region: region), expected)
    }

    func testRetryReadsUpdatedQuestionInkInsteadOfRepeatingAStaleSnapshot() async throws {
        let context = try makeContext()
        let page = Page()
        let original = drawing()
        page.inkData = original.dataRepresentation()
        context.insert(page)
        let response = #"{"result":{"ocrResults":[{"prunedResult":{"rec_texts":["?? Updated question"]}}]}}"#
        let service = try questionService(stub: .init(body: response, delay: 0.1))
        MockAIURLProtocol.install([.init(body: response, delay: 0.1), .init(body: response, delay: 0.1)])
        let editor = EditorActionState()
        let rejected = expectation(description: "Actual change is detected")
        let completed = expectation(description: "Retry uses the changed ink")
        let observer = editor.$handwrittenQuestion.compactMap { $0 }.sink { draft in
            if case .failed = draft.phase { rejected.fulfill() }
            if case .ready = draft.phase { completed.fulfill() }
        }
        defer { observer.cancel() }
        editor.recognizeQuestion(questionRequest(page), using: service, context: context)
        page.inkData = original.transformed(using: CGAffineTransform(translationX: 10, y: 0)).dataRepresentation()
        await fulfillment(of: [rejected], timeout: 3)
        editor.retryQuestion(using: service, context: context)
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(editor.handwrittenQuestion?.text, "Updated question")
        XCTAssertEqual(MockAIURLProtocol.recordedRequests().count, 2)
        XCTAssertFalse(editor.isAssistantPresented)
    }

    func testDismissalPreventsLateOCRFromReopeningTheQuestionWindow() async throws {
        let context = try makeContext()
        let page = Page()
        page.inkData = drawing().dataRepresentation()
        context.insert(page)
        let service = try questionService(stub: .init(body: #"{"result":{"ocrResults":[{"prunedResult":{"rec_texts":["?? Late question"]}}]}}"#, delay: 0.1))
        let editor = EditorActionState()
        editor.recognizeQuestion(questionRequest(page), using: service, context: context)
        await Task.yield()
        editor.dismissQuestion()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(editor.isAssistantPresented)
        XCTAssertNil(editor.handwrittenQuestion)
    }

    private func questionService(stub: MockAIURLProtocol.Stub) throws -> OCRService {
        try settings.save(provider: .custom, endpoint: "https://example.com/ocr", token: "token", format: .paddleOCR, model: "")
        MockAIURLProtocol.install([stub])
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [MockAIURLProtocol.self]
        return OCRService(settings: settings, client: OCRClient(session: URLSession(configuration: session)))
    }

    private func questionRequest(_ page: Page) -> HandwrittenQuestionRequest {
        let size = page.pageOrientation.size
        return HandwrittenQuestionRequest(page: page, inkData: page.inkData!, pageSize: size,
                                          region: CGRect(origin: .zero, size: size), fingerprint: "marker")
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Notebook.self, Page.self, PageElement.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    private func drawing() -> PKDrawing {
        let points = [CGPoint(x: 30, y: 30), CGPoint(x: 130, y: 60)].enumerated().map { offset, point in
            PKStrokePoint(location: point, timeOffset: Double(offset) * 0.1, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: .now))])
    }
}
