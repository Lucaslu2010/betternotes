import XCTest
import UIKit

final class BetterNotesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("-ui-testing")
        app.launchArguments.append(contentsOf: ["-ui-testing-store-id", UUID().uuidString])
        app.launch()
    }

    func testAddFolderButtonCreatesPersistentEmptyFolderAndContainsNewNotebook() {
        let name = uniqueTitle("School Folder")
        let folderButton = app.buttons["library-add-folder"]
        let notebookButton = app.buttons["library-new-notebook"]
        XCTAssertTrue(folderButton.waitForExistence(timeout: 5))
        XCTAssertLessThan(folderButton.frame.midX, notebookButton.frame.midX)
        folderButton.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText(name)
        app.alerts.buttons["Create"].tap()
        let folderTile = app.buttons["library-folder-tile-\(name)"]
        XCTAssertTrue(folderTile.waitForExistence(timeout: 4))
        folderTile.tap()
        XCTAssertTrue(app.staticTexts["This Folder Is Empty"].waitForExistence(timeout: 4))
        app.terminate()
        app.launch()
        let folder = app.buttons["library-folder-tile-\(name)"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5), "The empty folder disappeared after relaunch")
        folder.tap()
        let notebookName = uniqueTitle("Folder Notebook")
        createNotebook(named: notebookName)
        XCTAssertTrue(app.buttons[notebookName].firstMatch.waitForExistence(timeout: 4))
        app.terminate()
        app.launch()
        app.buttons["library-folder-tile-\(name)"].tap()
        XCTAssertTrue(app.buttons[notebookName].firstMatch.waitForExistence(timeout: 4),
                      "A notebook created inside the folder lost its membership")
        attachScreenshot(named: "Library folder and add buttons")
    }

    func testOpeningPDFDocumentURLCreatesAndOpensANotebook() throws {
        let title = uniqueTitle("Open In PDF")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(title).appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { context in
            context.beginPage()
            ("Shared document" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
        }
        try data.write(to: url)
        app.open(url)
        let confirm = app.buttons["document-import-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "The import did not ask where to save")
        XCTAssertTrue(app.buttons["document-import-location-root"].isSelected)
        confirm.tap()
        let editor = app.descendants(matching: .any)["notebook-title"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual(editor.label, title)
        XCTAssertTrue(app.scrollViews["page-canvas"].exists)
        attachScreenshot(named: "PDF received through document URL")
    }

    func testDraggingNotebookIntoFolderHidesItFromRootAndPersistsMembership() {
        let folderName = uniqueTitle("Drag Folder")
        app.buttons["library-add-folder"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText(folderName)
        app.alerts.buttons["Create"].tap()
        let notebookName = uniqueTitle("Move This Notebook")
        createNotebook(named: notebookName)
        let notebook = app.buttons[notebookName].firstMatch
        let folder = app.buttons["library-folder-tile-\(folderName)"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 4))
        XCTAssertTrue(folder.waitForExistence(timeout: 4))
        notebook.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.8,
                   thenDragTo: folder.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)),
                   withVelocity: .slow, thenHoldForDuration: 0.25)
        let disappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: notebook)
        XCTAssertEqual(XCTWaiter.wait(for: [disappeared], timeout: 5), .completed)
        folder.tap()
        XCTAssertTrue(app.buttons[notebookName].firstMatch.waitForExistence(timeout: 4))
        app.buttons["library-location-root"].tap()
        XCTAssertFalse(app.buttons[notebookName].exists)
        app.terminate()
        app.launch()
        app.buttons["library-folder-tile-\(folderName)"].tap()
        XCTAssertTrue(app.buttons[notebookName].firstMatch.waitForExistence(timeout: 4))
    }

    func testCancellingImportDestinationDoesNotCreateNotebook() throws {
        let title = uniqueTitle("Cancelled Import")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(title).appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600))
            .pdfData { $0.beginPage() }.write(to: url)
        app.open(url)
        XCTAssertTrue(app.buttons["document-import-confirm"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["library-new-notebook"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons[title].exists)
        app.terminate()
        app.launch()
        XCTAssertFalse(app.buttons[title].exists)
    }

    func testCreateNotebookAndReachPrimaryEditorControls() {
        let title = "UI Automation Notebook"
        createNotebook(named: title)

        let notebook = app.buttons[title].firstMatch
        XCTAssertTrue(notebook.waitForExistence(timeout: 5))
        attachScreenshot(named: "iPhone Library")
        notebook.tap()

        let editorTitle = app.descendants(matching: .any)["notebook-title"]
        XCTAssertTrue(editorTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(editorTitle.label, title)
        XCTAssertTrue(editorTitle.isHittable)
        XCTAssertTrue(app.buttons["Back"].isHittable)

        for label in ["Pen", "Pencil", "Highlighter", "Eraser", "Lasso"] {
            let button = app.buttons[label]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing primary tool: \(label)")
            XCTAssertTrue(button.isHittable, "Primary tool is not reachable: \(label)")
            // XCTest reports 44-point SwiftUI frames a few ulps below 44.
            XCTAssertGreaterThanOrEqual(button.frame.width, 43.9)
            XCTAssertGreaterThanOrEqual(button.frame.height, 43.9)
        }
        XCTAssertTrue(app.buttons["Undo"].exists)
        XCTAssertTrue(app.buttons["Redo"].exists)
        XCTAssertTrue(app.buttons["Add Page"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Page 1 of'")).firstMatch.exists)
        attachScreenshot(named: "iPhone Editor")
    }

    func testNotebookPersistsAcrossRelaunch() {
        let title = uniqueTitle("Relaunch Persistence")
        createNotebook(named: title)
        XCTAssertTrue(app.buttons[title].firstMatch.waitForExistence(timeout: 5))

        app.terminate()
        app.launch()

        XCTAssertTrue(app.buttons[title].firstMatch.waitForExistence(timeout: 5))
    }

    func testVerticalPinchScalesThePageBoxWithTheWritingArea() {
        app.terminate()
        app.launchArguments.append("-ui-testing-vertical-scroll")
        app.launch()
        openNotebook(named: uniqueTitle("Vertical Zoom"))
        let writingArea = app.scrollViews["notebook-canvas"]
        XCTAssertTrue(writingArea.waitForExistence(timeout: 5))
        let page = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'vertical-page-'")).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        let pageBefore = page.frame
        let viewportBefore = writingArea.frame
        writingArea.pinch(withScale: 1.6, velocity: 1)
        let expanded = NSPredicate { _, _ in page.frame.width > pageBefore.width * 1.3 }
        expectation(for: expanded, evaluatedWith: page)
        waitForExpectations(timeout: 5)
        XCTAssertGreaterThan(page.frame.height, pageBefore.height * 1.3)
        XCTAssertEqual(writingArea.frame.width, viewportBefore.width, accuracy: 1)
        XCTAssertEqual(writingArea.frame.height, viewportBefore.height, accuracy: 1)
        attachScreenshot(named: "Vertical Notebook Zoom")
    }

    func testAssistantCreatesAndReopensConversation() {
        openNotebook(named: uniqueTitle("Assistant"))

        // The assistant is a dedicated toolbar button now, not a More-menu item.
        let assistant = app.buttons["editor-assistant"]
        XCTAssertTrue(assistant.waitForExistence(timeout: 4))
        assistant.tap()
        XCTAssertTrue(app.segmentedControls.buttons["All Notes"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["Summary"].exists)

        app.buttons["Explain a concept"].tap()
        // Wait for any on-device answer. Which of the two local outcomes you
        // get ("no evidence" vs. "here are the passages") depends on whether
        // the corpus index and the NLEmbedding sentence model have finished
        // loading, so asserting one specific string made this test depend on a
        // race. This test covers conversation creation and reopening; the
        // ranking behaviour itself is covered by the corpus unit tests.
        let answered = NSPredicate(format:
            "label CONTAINS 'could not find enough evidence' OR label CONTAINS 'most relevant passages'"
        )
        let response = app.staticTexts.containing(answered).firstMatch
        XCTAssertTrue(response.waitForExistence(timeout: 10), "Assistant produced no on-device answer")
        dismissAssistant()

        app.buttons["editor-assistant"].tap()
        XCTAssertTrue(app.staticTexts["Explain the most important concept in these notes in simple terms."].waitForExistence(timeout: 4))
        dismissAssistant()
    }

    func testAutomaticWritingSuggestionsAreOptIn() {
        app.buttons["More"].tap()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 4))
        settings.tap()

        let toggle = app.switches["Automatic Writing Suggestions"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 4))
        XCTAssertEqual(toggle.value as? String, "Off")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let enabled = NSPredicate(format: "value == 'On'")
        expectation(for: enabled, evaluatedWith: toggle)
        waitForExpectations(timeout: 3)
        app.buttons["Done"].tap()
    }

    func testProviderDraftStaysOpenWhenSwitchingAppsAndCanBeCancelled() {
        let title = uniqueTitle("Settings Return")
        openNotebook(named: title)
        openEditorSettings()
        openAIProviderSettings()
        let model = app.textFields["ai-provider-model"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        model.tap()
        model.typeText("-unsaved-draft")
        let draftModel = model.value as? String
        let key = app.secureTextFields["ai-provider-key"]
        key.tap()
        key.typeText("test-unsaved-key")
        let draftKey = key.value as? String
        XCUIDevice.shared.press(.home)
        XCUIApplication(bundleIdentifier: "com.apple.mobilesafari").activate()
        app.activate()
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        XCTAssertEqual(model.value as? String, draftModel)
        XCTAssertEqual(key.value as? String, draftKey)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["AI Provider Settings"].waitForExistence(timeout: 4))
        app.buttons["Done"].tap()
        XCTAssertEqual(app.descendants(matching: .any)["notebook-title"].label, title)
        openEditorSettings()
        openAIProviderSettings()
        XCTAssertTrue(model.waitForExistence(timeout: 4))
        XCTAssertNotEqual(model.value as? String, draftModel, "Cancel saved an unsaved draft")
        app.buttons["Cancel"].tap()
        app.buttons["Done"].tap()
    }

    func testDrawingPanelsCanCloseAndReopen() {
        openNotebook(named: uniqueTitle("Dismiss Panels"))
        for _ in 0..<2 {
            app.buttons["Ink Color"].tap()
            let colorDone = app.buttons["ink-color-done"]
            XCTAssertTrue(colorDone.waitForExistence(timeout: 4))
            colorDone.tap()
            XCTAssertTrue(app.buttons["Stroke Thickness"].waitForExistence(timeout: 4))
            app.buttons["Stroke Thickness"].tap()
            let sizeDone = app.buttons["stroke-size-done"]
            XCTAssertTrue(sizeDone.waitForExistence(timeout: 4))
            sizeDone.tap()
        }
        openToolbarMenu(named: "More")
        app.buttons["Page Info"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 4))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Ink Color"].waitForExistence(timeout: 4))
    }

    func testOCRDraftSurvivesSwitchingAppsAndReturningFromSetupGuide() {
        let title = uniqueTitle("OCR Settings Return")
        openNotebook(named: title)
        openEditorSettings()
        app.buttons["OCR Settings"].tap()
        let provider = app.buttons["ocr-provider-picker"]
        XCTAssertTrue(provider.waitForExistence(timeout: 5))
        provider.tap()
        app.buttons["Custom OCR"].tap()
        let endpoint = app.textFields["ocr-endpoint"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 5))
        endpoint.tap()
        endpoint.typeText("https://example.invalid/unsaved-ocr")
        let draftEndpoint = endpoint.value as? String
        let token = app.secureTextFields["ocr-token"]
        token.tap()
        token.typeText("test-unsaved-ocr-token")
        let draftToken = token.value as? String
        XCUIDevice.shared.press(.home)
        XCUIApplication(bundleIdentifier: "com.apple.mobilesafari").activate()
        app.activate()
        XCTAssertTrue(endpoint.waitForExistence(timeout: 5))
        XCTAssertEqual(endpoint.value as? String, draftEndpoint)
        XCTAssertEqual(token.value as? String, draftToken)
        app.buttons["Set Up a Free PaddleOCR API Token"].tap()
        let back = app.navigationBars.buttons["OCR Settings"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(endpoint.waitForExistence(timeout: 5))
        XCTAssertEqual(endpoint.value as? String, draftEndpoint)
        XCTAssertEqual(token.value as? String, draftToken)
        app.buttons["Cancel"].tap()
        app.buttons["Done"].tap()
        XCTAssertEqual(app.descendants(matching: .any)["notebook-title"].label, title)
    }

    func testNotebookCanOpenAndReopenWithoutReturningToLibrary() {
        let title = uniqueTitle("Open Regression")
        createNotebook(named: title)
        createNotebook(named: uniqueTitle("More Recent Notebook"))
        for _ in 0..<3 {
            let notebook = app.buttons[title].firstMatch
            XCTAssertTrue(notebook.waitForExistence(timeout: 5))
            notebook.tap()
            let heading = app.descendants(matching: .any)["notebook-title"]
            XCTAssertTrue(heading.waitForExistence(timeout: 5))
            XCTAssertEqual(heading.label, title)
            XCTAssertTrue(app.buttons["Pen"].waitForExistence(timeout: 5))
            app.buttons["Back"].tap()
        }
    }

    func testPencilProSettingsOfferEveryToolAndPersistChoice() {
        openToolbarMenu(named: "More")
        app.buttons["Settings"].tap()
        let picker = app.buttons["pencil-double-tap-tool"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Apple Pencil Pro only.'")).firstMatch.exists)
        picker.tap()
        for tool in ["pen", "pencil", "marker", "eraser", "lasso"] {
            XCTAssertTrue(app.buttons["pencil-double-tap-option-\(tool)"].waitForExistence(timeout: 3))
        }
        app.buttons["pencil-double-tap-option-lasso"].tap()
        app.buttons["Done"].tap()
        openToolbarMenu(named: "More")
        app.buttons["Settings"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.label.contains("Lasso") || (picker.value as? String)?.contains("Lasso") == true)
        // Restore the default after verifying persistence.
        picker.tap()
        app.buttons["pencil-double-tap-option-eraser"].tap()
        app.buttons["Done"].tap()
    }

    func testTemplatePreviewsAndConsolidatedHandwritingMenu() {
        openNewNotebookSheet()

        let blankTemplate = app.buttons["template-choice-blank"]
        let ruledTemplate = app.buttons["template-choice-ruled"]
        XCTAssertTrue(blankTemplate.waitForExistence(timeout: 5))
        XCTAssertTrue(ruledTemplate.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(blankTemplate.frame.height, 44)
        XCTAssertGreaterThanOrEqual(ruledTemplate.frame.height, 44)
        ruledTemplate.tap()
        XCTAssertTrue(ruledTemplate.isSelected)
        app.navigationBars["New Notebook"].buttons["Cancel"].tap()

        openNotebook(named: uniqueTitle("Handwriting Menu"))
        openToolbarMenu(named: "More")
        for label in ["Beautify Handwriting", "Draw with Finger", "Beautify Existing Ink", "Reset Learned Style"] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 3), "Missing handwriting action: \(label)")
        }

        app.buttons["Draw with Finger"].tap()
        let insert = app.buttons["Insert"]
        insert.tap()
        XCTAssertTrue(app.buttons["Shape"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Text Box"].exists)
        XCTAssertTrue(app.buttons["Sticky Note"].exists)
        XCTAssertFalse(app.buttons["Draw with Finger"].exists)
        XCTAssertFalse(app.buttons["Beautify Existing Ink"].exists)
    }

    func testSelectionOutlineReportsItsOwnFrameNotTheWholePage() {
        // The outline's accessibility frame is not cosmetic. It is what
        // VoiceOver and Switch Control offer as "Selection outline", and it is
        // the hit area of the drag-to-move button underneath. When the
        // accessibility modifiers sat after `.position`, they attached to the
        // view `.position` returns -- which fills the page -- so a selection
        // an inch across published (12, 86, 1000, 1333) on a 13-inch iPad Air,
        // and the whole page became an invisible button that swallowed every
        // tap while a selection was live. Tapping blank page to dismiss did
        // nothing at all.
        openNotebook(named: uniqueTitle("Outline Frame"))
        app.buttons["Lasso"].tap()
        app.buttons["Lasso"].tap() // Tap the active tool again to choose its mode.
        app.buttons["Rect"].tap()
        insertShape(named: "Rectangle")

        let outline = app.descendants(matching: .any)["selection-outline"]
        XCTAssertTrue(outline.waitForExistence(timeout: 5))
        let pageCanvas = app.scrollViews["page-canvas"]
        XCTAssertTrue(pageCanvas.exists)

        // A selection of one inserted shape is a fraction of the page. Half is
        // generous, and still fails by a mile on the whole-page frame.
        XCTAssertLessThan(
            outline.frame.width, pageCanvas.frame.width * 0.5,
            "outline claims \(outline.frame) of a page \(pageCanvas.frame)")
        XCTAssertLessThan(
            outline.frame.height, pageCanvas.frame.height * 0.5,
            "outline claims \(outline.frame) of a page \(pageCanvas.frame)")

        // And it must agree with the bounds the outline reports for itself,
        // so a test driving it by coordinate aims where the ink actually is.
        let reported = (outline.value as? String ?? "").split(separator: ",").compactMap { Double($0) }
        XCTAssertEqual(reported.count, 4, "expected x,y,w,h — got \(outline.value ?? "nil")")
        if reported.count == 4 {
            let ratio = outline.frame.width / CGFloat(reported[2])
            XCTAssertEqual(ratio, outline.frame.height / CGFloat(reported[3]), accuracy: 0.05,
                           "frame and reported bounds disagree on aspect")
        }
    }

    func testInsertedInkCanMoveAndPasteFromBlankCanvas() {
        openNotebook(named: uniqueTitle("Selection Paste"))
        app.buttons["Lasso"].tap()
        app.buttons["Lasso"].tap() // Tap the active tool again to choose its mode.
        app.buttons["Rect"].tap()
        insertShape(named: "Rectangle")

        let insertedOutline = app.descendants(matching: .any)["selection-outline"]
        XCTAssertTrue(insertedOutline.waitForExistence(timeout: 4))
        let pageCanvas = app.scrollViews["page-canvas"]
        // Stay above the fixed toolbar and away from system-edge gestures.
        // Menu-inserted shapes are centered in this page-relative region.
        let lassoStart = pageCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.25))
        let lassoEnd = pageCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.60))

        app.buttons["Pen"].tap()
        app.buttons["Lasso"].tap()
        XCTAssertTrue(insertedOutline.waitForNonExistence(timeout: 3))
        lassoStart
            .press(
                forDuration: 0.2,
                thenDragTo: lassoEnd,
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )

        let outline = app.descendants(matching: .any)["selection-outline"]
        XCTAssertTrue(outline.waitForExistence(timeout: 5))
        let originalBoundsValue = outline.value as? String
        outline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.2,
                thenDragTo: outline.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.5)),
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )

        let movedOutline = app.descendants(matching: .any)["selection-outline"]
        XCTAssertTrue(movedOutline.waitForExistence(timeout: 3))
        XCTAssertNotEqual(movedOutline.value as? String, originalBoundsValue)

        let copy = hittableButton("Copy")
        XCTAssertTrue(copy.waitForExistence(timeout: 4))
        copy.tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.58)).tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 3))

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.58)).press(forDuration: 1.2)
        let paste = hittableButton("Paste")
        XCTAssertTrue(paste.waitForExistence(timeout: 4))
        paste.tap()
        XCTAssertTrue(hittableButton("Copy").waitForExistence(timeout: 4))
        XCTAssertTrue(app.descendants(matching: .any)["selection-outline"].exists)
    }

    func testFixedBottomToolbarKeepsSelectionActionsReachable() throws {
        try requireCompactWidth()
        openNotebook(named: uniqueTitle("Bottom Toolbar"))

        let pen = app.buttons["Pen"]
        XCTAssertTrue(pen.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(pen.frame.midY, app.frame.midY)
        XCTAssertFalse(app.descendants(matching: .any)["Move Toolbar"].exists)

        insertShape(named: "Circle")
        let selectionBar = app.descendants(matching: .any)["selection-context-bar"]
        XCTAssertTrue(selectionBar.waitForExistence(timeout: 5))
        let copy = selectionBar.descendants(matching: .button)["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(copy.frame.maxY + 8, pen.frame.minY)
        XCTAssertTrue(copy.isHittable)
        XCTAssertTrue(selectionBar.descendants(matching: .button)["Delete"].firstMatch.isHittable)
    }

    func testAdaptiveOverviewAndReadOnlyMode() {
        openNotebook(named: uniqueTitle("Overview Read Only"))
        for _ in 0..<4 { app.buttons["Add Page"].firstMatch.tap() }

        openOverview()
        let firstThumbnail = app.descendants(matching: .any)["page-thumbnail-1"]
        XCTAssertTrue(firstThumbnail.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(firstThumbnail.frame.width, 139)
        app.buttons["overview-done"].firstMatch.tap()

        openToolbarMenu(named: "More")
        app.buttons["Enter View-Only Mode"].tap()
        let editorHeading = app.descendants(matching: .any)["notebook-title"]
        XCTAssertTrue(editorHeading.waitForExistence(timeout: 3))
        XCTAssertTrue(editorHeading.label.contains("View Only"))
        XCTAssertFalse(app.buttons["Pen"].isEnabled)
        XCTAssertFalse(app.buttons["Add Page"].firstMatch.isEnabled)

        openToolbarMenu(named: "More")
        app.buttons["Page Info"].tap()
        XCTAssertTrue(app.navigationBars["Page Info"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.textFields["Page title"].isEnabled)
        XCTAssertFalse(app.switches["Bookmark"].isEnabled)
        app.navigationBars["Page Info"].buttons["Done"].tap()
    }

    func testDeletionTimeoutRestoreAndPermanentDeleteConfirmation() {
        openNotebook(named: uniqueTitle("Page Trash"))
        app.buttons["Add Page"].firstMatch.tap()
        deleteCurrentPage()

        let banner = app.descendants(matching: .any)["page-deletion-undo-banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 4))
        XCTAssertTrue(banner.waitForNonExistence(timeout: 6.5))

        openOverview()
        app.segmentedControls.buttons["Trash"].tap()
        XCTAssertTrue(app.buttons["Restore"].waitForExistence(timeout: 4))
        app.buttons["Restore"].tap()
        XCTAssertTrue(app.staticTexts["Page Trash Is Empty"].waitForExistence(timeout: 4))

        app.segmentedControls.buttons["Pages"].tap()
        let secondThumbnail = app.descendants(matching: .any)["page-thumbnail-2"]
        XCTAssertTrue(secondThumbnail.waitForExistence(timeout: 4))
        secondThumbnail.tap()
        deleteCurrentPage()

        openOverview()
        app.segmentedControls.buttons["Trash"].tap()
        let delete = hittableButton("Delete")
        XCTAssertTrue(delete.waitForExistence(timeout: 4))
        delete.tap()
        XCTAssertTrue(app.staticTexts["Delete \"Page 2\" permanently?"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Restore"].exists)

        delete.tap()
        app.buttons["Delete Permanently"].tap()
        XCTAssertTrue(app.staticTexts["Page Trash Is Empty"].waitForExistence(timeout: 4))
    }

    func testSearchAnswersRunOnlyAfterAskNotesIsTapped() {
        let title = uniqueTitle("Search Target")
        createNotebook(named: title)

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(focus(search), "the search field never took keyboard focus")
        search.typeText(title)

        let askNotes = app.buttons["Ask Notes"]
        XCTAssertTrue(askNotes.waitForExistence(timeout: 10))
        let localFallback = app.staticTexts["I could not find enough evidence in the selected notes to answer that question."]
        XCTAssertFalse(localFallback.exists)

        search.typeText("\n")
        XCTAssertTrue(askNotes.waitForExistence(timeout: 5))
        XCTAssertFalse(localFallback.exists)

        askNotes.tap()
        XCTAssertTrue(app.descendants(matching: .any)["search-ai-answer"].waitForExistence(timeout: 10))
    }

    func testRegularWidthWorkspaceSwitchingAndRemovalPreservesNotebook() throws {
        guard app.frame.width >= 700 else {
            throw XCTSkip("Regular-width workspace requires an iPad destination")
        }
        attachScreenshot(named: "iPad Library")

        let firstTitle = uniqueTitle("Workspace One")
        let secondTitle = uniqueTitle("Workspace Two")
        createNotebook(named: firstTitle)
        createNotebook(named: secondTitle)
        app.buttons[firstTitle].firstMatch.tap()

        // Open the second notebook as an additional tab via the toolbar's
        // tab switcher menu.
        let tabSwitcher = app.buttons["Switch Notebook"]
        XCTAssertTrue(tabSwitcher.waitForExistence(timeout: 5))
        tabSwitcher.tap()
        let openNotebook = app.buttons["Open Notebook"]
        XCTAssertTrue(openNotebook.waitForExistence(timeout: 3))
        openNotebook.tap()
        app.buttons[secondTitle].tap()

        // The second notebook is now the active tab; close it again.
        tabSwitcher.tap()
        let closeTab = app.buttons["Close Current Tab"]
        XCTAssertTrue(closeTab.waitForExistence(timeout: 3))
        closeTab.tap()

        attachScreenshot(named: "iPad Workspace")

        app.buttons["Back"].tap()
        XCTAssertTrue(app.buttons[secondTitle].firstMatch.waitForExistence(timeout: 5))
    }

    func testFolderAndTagFiltersNarrowTheLibrary() throws {
        let physics = uniqueTitle("Physics")
        let history = uniqueTitle("History")
        createNotebook(named: physics)
        createNotebook(named: history)

        // Put only the first notebook in a folder and give it a tag.
        organize(notebook: physics, folder: "Science", tags: "exam")

        // The tag chip filters the grid down to the tagged notebook.
        let tagChip = app.buttons["library-tag-exam"]
        XCTAssertTrue(tagChip.waitForExistence(timeout: 5), "Tag chip did not appear")
        tagChip.tap()

        XCTAssertTrue(app.buttons[physics].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[history].firstMatch.exists, "Untagged notebook should be filtered out")

        // Clearing restores the full list.
        let clear = app.buttons["library-clear-filters"]
        XCTAssertTrue(clear.waitForExistence(timeout: 3))
        clear.tap()
        XCTAssertTrue(app.buttons[history].firstMatch.waitForExistence(timeout: 5))

        // On iPad the folder also appears in the sidebar and filters.
        if app.frame.width >= 700 {
            let folder = app.buttons["library-folder-Science"]
            if folder.waitForExistence(timeout: 3) {
                folder.tap()
                XCTAssertTrue(app.buttons[physics].firstMatch.waitForExistence(timeout: 5))
                XCTAssertFalse(app.buttons[history].firstMatch.exists, "Notebook outside the folder should be filtered out")
                folder.tap()
            }
        }
    }

    /// Sets a folder and tags on a notebook through its Rename sheet.
    private func organize(notebook title: String, folder: String, tags: String) {
        let actions = app.buttons["More actions for \(title)"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()

        let rename = app.buttons["Rename"]
        XCTAssertTrue(rename.waitForExistence(timeout: 3))
        rename.tap()

        let folderField = app.textFields["Folder"]
        XCTAssertTrue(folderField.waitForExistence(timeout: 5))
        XCTAssertTrue(focus(folderField), "the folder field never took keyboard focus")
        folderField.typeText(folder)

        let tagsField = app.textFields["Tags, separated by commas"]
        XCTAssertTrue(tagsField.waitForExistence(timeout: 3))
        XCTAssertTrue(focus(tagsField), "the tags field never took keyboard focus")
        tagsField.typeText(tags)

        app.navigationBars["Rename"].buttons["Save"].tap()
    }

    /// Taps a text field and waits until it actually holds keyboard focus
    /// before returning. A bare `tap()` followed by `typeText` is a race on a
    /// real device: the tap lands while the sheet is still animating, focus
    /// arrives a frame or two later, and typeText fails with "Neither element
    /// nor any descendant has keyboard focus". Retries the tap once, which is
    /// enough whenever the first one was swallowed by the presentation.
    @discardableResult
    private func focus(_ field: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        func hasFocus() -> Bool { (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false }

        for attempt in 0..<2 {
            field.tap()
            let deadline = Date().addingTimeInterval(attempt == 0 ? timeout / 2 : timeout)
            while Date() < deadline {
                if hasFocus() { return true }
                _ = field.waitForExistence(timeout: 0.1)
            }
        }
        return hasFocus()
    }

    private func createNotebook(named title: String) {
        openNewNotebookSheet()
        let titleField = app.textFields.firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 8))
        XCTAssertTrue(focus(titleField), "the new-notebook title field never took keyboard focus")
        titleField.typeText(title)
        app.navigationBars["New Notebook"].buttons["Create"].tap()
    }

    private func openNewNotebookSheet() {
        let newNotebook = app.buttons["library-new-notebook"]
        XCTAssertTrue(newNotebook.waitForExistence(timeout: 5))
        if app.frame.width >= 700 {
            newNotebook.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            newNotebook.tap()
        }

        XCTAssertTrue(app.navigationBars["New Notebook"].waitForExistence(timeout: 8))
    }

    @discardableResult
    // MARK: - Handwriting

    func testLassoSelectsInkOnFirstTapInBothModes() {
        checkFirstTapLasso(vertical: false)
    }

    func testVerticalLassoSelectsInkOnFirstTapInBothModes() {
        checkFirstTapLasso(vertical: true)
    }

    private func checkFirstTapLasso(vertical: Bool) {
        if vertical { app.launchArguments.append("-ui-testing-vertical-scroll") }
        for mode in ["freeform", "rectangle"] {
            app.terminate()
            app.launchArguments.append(contentsOf: ["-lassoMode", mode])
            app.launch()
            openNotebook(named: uniqueTitle("First Tap Lasso \(mode)"))
            let canvas = app.scrollViews[vertical ? "notebook-canvas" : "page-canvas"]
            let visibleInk = inkCanvas.frame.intersection(canvas.frame)
            func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
                canvas.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                    dx: visibleInk.minX - canvas.frame.minX + visibleInk.width * x,
                    dy: visibleInk.minY - canvas.frame.minY + visibleInk.height * y))
            }
            point(0.32, 0.30).press(forDuration: 0.01, thenDragTo: point(0.62, 0.34),
                                    withVelocity: .slow, thenHoldForDuration: 0)

            let lasso = app.buttons["drawing-tool-lasso"]
            lasso.tap()
            XCTAssertTrue(lasso.isSelected, "The first tap did not activate Lasso")
            // A line crossing the ink also intersects the freeform polygon's
            // edges, so this checks routing without choosing a mode again.
            point(0.22, 0.20)
                .press(forDuration: 0.01,
                       thenDragTo: point(0.74, 0.56),
                       withVelocity: .slow, thenHoldForDuration: 0)
            XCTAssertTrue(app.descendants(matching: .any)["selection-outline"].waitForExistence(timeout: 5),
                          "First-tap \(mode) lasso did not select the drawn stroke")
            attachScreenshot(named: "First-tap \(mode) selection")

            // Pencil users commonly turn finger drawing off. Lasso must still
            // own one-finger selection rather than letting the page pan.
            openToolbarMenu(named: "More")
            app.buttons["Draw with Finger"].tap()
            app.buttons["Pen"].tap()
            lasso.tap()
            point(0.22, 0.20)
                .press(forDuration: 0.01,
                       thenDragTo: point(0.74, 0.56),
                       withVelocity: .slow, thenHoldForDuration: 0)
            XCTAssertTrue(app.descendants(matching: .any)["selection-outline"].waitForExistence(timeout: 5),
                          "First-tap \(mode) lasso failed with finger drawing disabled")
            app.launchArguments.removeLast(2)
        }
    }

    /// Draw, lasso, then resize by a handle.
    ///
    /// Every other UI test builds its content from the Insert menu, so the
    /// PencilKit path -- the thing this app is for -- had no coverage at all,
    /// and the bug this covers went unnoticed through a full device run: the
    /// resize handles were 12-16pt against a 44pt guideline, so a drag aimed
    /// at one usually missed, fell through to the lasso overlay that covers
    /// the whole page, and was read as the start of a new selection. The
    /// selection you were trying to stretch was discarded instead.
    func testDrawnStrokesCanBeResizedByTheirHandlesWithoutLosingSelection() {
        openNotebook(named: uniqueTitle("Stroke Resize"))

        app.buttons["Pen"].tap()
        drawStroke(from: CGVector(dx: 0.32, dy: 0.30), to: CGVector(dx: 0.62, dy: 0.34))
        drawStroke(from: CGVector(dx: 0.32, dy: 0.42), to: CGVector(dx: 0.62, dy: 0.46))

        // Proof the ink committed is the lasso assertion below: it can only
        // find a selection if there are strokes to select. An earlier version
        // checked the Undo button instead, but its activation point is
        // invalid on a real iPad, so `isHittable` threw before the test could
        // reach anything it was actually about.
        attachScreenshot(named: "after-drawing")

        app.buttons["Lasso"].tap()
        app.buttons["Lasso"].tap()
        app.buttons["Rect"].tap()
        let canvas = app.scrollViews["page-canvas"]
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.20))
            .press(
                forDuration: 0.2,
                thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.74, dy: 0.56)),
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )

        let outline = app.descendants(matching: .any)["selection-outline"]
        XCTAssertTrue(
            outline.waitForExistence(timeout: 5),
            "the lasso did not select hand-drawn strokes"
        )
        let boundsBeforeResize = outline.value as? String

        // Drive the handle itself rather than a screen coordinate near it.
        let handle = app.descendants(matching: .any)["selection-handle-br"].firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 4), "no bottom-right resize handle on the selection")
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.3,
                thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.72)),
                withVelocity: .slow,
                thenHoldForDuration: 0.3
            )

        XCTAssertTrue(
            outline.waitForExistence(timeout: 3),
            "dragging a resize handle cleared the selection instead of scaling it"
        )
        XCTAssertNotEqual(
            outline.value as? String,
            boundsBeforeResize,
            "the selection survived but did not resize"
        )
    }

    /// Inserted elements must land where the page is actually showing, and
    /// two of them must not occupy the same point. Both were broken: every
    /// image, recording, note and tape was created at a hardcoded (200, 300).
    func testInsertedElementsLandOnThePageAndDoNotStack() {
        openNotebook(named: uniqueTitle("Insertion Placement"))

        insertFromMenu("Tape")
        let first = app.descendants(matching: .any)["page-element"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5), "the first insert produced no element")
        let firstFrame = first.frame

        insertFromMenu("Tape")
        let elements = app.descendants(matching: .any).matching(identifier: "page-element")
        XCTAssertEqual(elements.count, 2, "the second insert produced no second element")

        let frames = elements.allElementsBoundByIndex.map(\.frame)
        XCTAssertFalse(
            frames.contains(where: { $0 == firstFrame }) && frames.allSatisfy({ $0 == firstFrame }),
            "both inserted elements landed on exactly the same spot"
        )

        let page = app.scrollViews["page-canvas"].frame
        for frame in frames {
            XCTAssertTrue(
                page.intersects(frame),
                "an inserted element landed outside the visible page at \(frame)"
            )
        }
    }

    /// Draw one stroke on the page with a finger.
    ///
    /// `allowsFingerDrawing` defaults on, and PaperCanvas observes `.direct`
    /// touches when it is, so a synthesised drag reaches PencilKit exactly as
    /// a fingertip would.
    /// The PencilKit surface itself, not the zoomable scroll view around it.
    private var inkCanvas: XCUIElement {
        app.descendants(matching: .any)["ink-canvas"].firstMatch
    }

    private func drawStroke(from start: CGVector, to end: CGVector) {
        let canvas = inkCanvas
        XCTAssertTrue(canvas.waitForExistence(timeout: 5), "the ink canvas is not in the accessibility tree")
        // No initial press and no trailing hold: the canvas runs a
        // press-and-hold shape recogniser, and dwelling at either end of the
        // drag feeds that instead of laying down an ordinary stroke.
        canvas.coordinate(withNormalizedOffset: start)
            .press(
                forDuration: 0.01,
                thenDragTo: canvas.coordinate(withNormalizedOffset: end),
                withVelocity: .slow,
                thenHoldForDuration: 0.0
            )
    }

    private func insertFromMenu(_ label: String) {
        app.buttons["Insert"].tap()
        let item = app.buttons[label]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "no \(label) item in the Insert menu")
        item.tap()
    }

    private func openNotebook(named title: String) -> String {
        createNotebook(named: title)
        let notebook = app.buttons[title].firstMatch
        XCTAssertTrue(notebook.waitForExistence(timeout: 5))
        notebook.tap()
        let canvasID = app.launchArguments.contains("-ui-testing-vertical-scroll") ? "notebook-canvas" : "page-canvas"
        XCTAssertTrue(app.scrollViews[canvasID].waitForExistence(timeout: 8))
        return title
    }

    private func insertShape(named name: String) {
        app.buttons["Insert"].tap()
        let shape = app.buttons["Shape"]
        XCTAssertTrue(shape.waitForExistence(timeout: 3))
        shape.tap()
        XCTAssertTrue(app.navigationBars["Insert Shape"].waitForExistence(timeout: 4))
        app.buttons[name].tap()
        XCTAssertTrue(hittableButton("Copy").waitForExistence(timeout: 4))
    }

    private func openOverview() {
        let indicator = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Page ' AND label CONTAINS 'open overview'")).firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 4))
        indicator.tap()
        XCTAssertTrue(app.segmentedControls.firstMatch.waitForExistence(timeout: 4))
    }

    private func deleteCurrentPage() {
        openToolbarMenu(named: "More")
        let deletePage = app.buttons["Delete Page"]
        XCTAssertTrue(deletePage.waitForExistence(timeout: 3))
        XCTAssertTrue(deletePage.isEnabled)
        deletePage.tap()
    }

    private func openToolbarMenu(named label: String) {
        let menu = app.buttons[label]
        if menu.waitForExistence(timeout: 1), menu.isHittable {
            menu.tap()
            return
        }

        let overflow = app.buttons["OverflowBarButtonItem"]
        XCTAssertTrue(overflow.waitForExistence(timeout: 3), "Missing toolbar overflow for \(label)")
        overflow.tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 3), "Missing overflowed toolbar menu: \(label)")
        XCTAssertTrue(menu.isHittable, "Overflowed toolbar menu is not reachable: \(label)")
        menu.tap()
    }

    private func openEditorSettings() {
        openToolbarMenu(named: "More")
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 4))
        settings.tap()
    }

    private func openAIProviderSettings() {
        let form = app.descendants(matching: .any)["app-settings-form"].firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 4))
        let provider = app.buttons["AI Provider Settings"]
        for _ in 0..<3 {
            if provider.exists && provider.isHittable { break }
            form.swipeUp()
        }
        XCTAssertTrue(provider.waitForExistence(timeout: 4))
        provider.tap()
    }

    private func uniqueTitle(_ prefix: String) -> String {
        "\(prefix) \(UUID().uuidString.prefix(8))"
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func hittableButton(_ label: String, timeout: TimeInterval = 4) -> XCUIElement {
        let query = app.buttons.matching(identifier: label)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let element = query.allElementsBoundByIndex.first(where: {
                $0.frame.width > 0 && $0.frame.height > 0 && $0.isHittable
            }) {
                return element
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return query.firstMatch
    }

    private func dismissAssistant() {
        let button = app.buttons["assistant-dismiss"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 4))
        XCTAssertEqual(button.label, "Close Assistant")
        button.tap()
    }

    private func requireCompactWidth() throws {
        guard app.frame.width < 700 else {
            throw XCTSkip("Compact-width behavior requires an iPhone destination")
        }
    }
}
