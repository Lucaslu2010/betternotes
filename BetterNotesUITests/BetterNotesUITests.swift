import XCTest

final class BetterNotesUITests: XCTestCase {
    private var app: XCUIApplication!
    private var fingerDrawingDisabledForPageSwipes = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        fingerDrawingDisabledForPageSwipes = false
        app = XCUIApplication()
        app.launchArguments.append("-ui-testing")
        app.launchArguments.append(contentsOf: ["-ui-testing-store-id", UUID().uuidString])
        app.launch()
    }

    func testCreateNotebookAndReachPrimaryEditorControls() {
        let title = "UI Automation Notebook"
        createNotebook(named: title)

        let notebook = app.buttons[title].firstMatch
        XCTAssertTrue(notebook.waitForExistence(timeout: 5))
        attachScreenshot(named: "iPad Library")
        notebook.tap()

        let editorTitle = app.descendants(matching: .any)["notebook-title"]
        XCTAssertTrue(editorTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(editorTitle.label, title)
        XCTAssertTrue(editorTitle.isHittable)
        XCTAssertTrue(app.buttons["Back"].isHittable)
        let addTab = app.buttons["editor-add-tab"]
        XCTAssertTrue(addTab.isHittable)

        for label in ["Pen", "Pencil", "Highlighter", "Eraser", "Lasso"] {
            let button = app.buttons[label]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing primary tool: \(label)")
            XCTAssertTrue(button.isHittable, "Primary tool is not reachable: \(label)")
            // XCTest reports 44-point SwiftUI frames a few ulps below 44.
            XCTAssertGreaterThanOrEqual(button.frame.width, 43.9)
            XCTAssertGreaterThanOrEqual(button.frame.height, 43.9)
            XCTAssertGreaterThanOrEqual(button.frame.minY, addTab.frame.maxY - 1,
                                        "\(label) is covered by the notebook tab strip")
        }
        XCTAssertTrue(app.buttons["Undo"].exists)
        XCTAssertTrue(app.buttons["Redo"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Zoom,'")).firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["floating-page-controls"].exists)
        XCTAssertFalse(app.buttons["Add Page"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Page 1 of'")).firstMatch.exists)
        attachScreenshot(named: "iPad Editor")
    }

    func testPageControlsStayInBottomRightCornerInBothOrientations() {
        app.terminate()
        app.launchArguments.append("-ui-testing-bottom-toolbar")
        app.launch()
        _ = openNotebook(named: uniqueTitle("Page Controls"))

        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let controls = app.descendants(matching: .any)["floating-page-controls"].firstMatch
            let toolbar = app.descendants(matching: .any)["floating-editor-toolbar"].firstMatch
            let pen = app.buttons["Pen"]
            let redo = app.buttons["Redo"].firstMatch
            XCTAssertTrue(controls.waitForExistence(timeout: 5))
            XCTAssertTrue(controls.isHittable)
            XCTAssertTrue(pen.isHittable)
            XCTAssertTrue(redo.exists)
            let bottomGap = XCUIScreen.main.screenshot().image.size.height - controls.frame.maxY
            XCTAssertGreaterThanOrEqual(bottomGap, 0, "Page controls extend off the bottom edge")
            XCTAssertLessThanOrEqual(bottomGap, 6, "Page controls sit too high above the bottom edge")
            XCTAssertLessThanOrEqual(abs(toolbar.frame.maxY - controls.frame.maxY), 3,
                                     "Bottom toolbar and page controls should share a bottom edge: toolbar \(toolbar.frame), controls \(controls.frame)")
            XCTAssertGreaterThan(controls.frame.minX, redo.frame.maxX + 6,
                                 "Page controls overlap the bottom drawing toolbar")
            attachScreenshot(named: orientation == .portrait ? "Page Controls Portrait" : "Page Controls Landscape")
        }
        XCUIDevice.shared.orientation = .portrait
    }

    func testToolbarDocksVerticallyAtEitherSide() {
        _ = openNotebook(named: uniqueTitle("Side Toolbar"))
        let toolbar = app.descendants(matching: .any)["floating-editor-toolbar"].firstMatch
        let handle = app.descendants(matching: .any)["Move Toolbar"].firstMatch
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5))
        XCTAssertTrue(handle.isHittable)
        let penWidth = toolbar.frame.width
        app.buttons["Lasso"].tap()
        XCTAssertLessThan(toolbar.frame.width, penWidth - 30,
                          "Horizontal toolbar should shrink when fewer controls are visible")
        app.buttons["Pen"].tap()
        let screen = app.windows.firstMatch.frame

        for x in [screen.minX + 28, screen.maxX - 28] {
            let target = app.coordinate(withNormalizedOffset: CGVector(
                dx: x / screen.width, dy: screen.midY / screen.height
            ))
            handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.1)
            XCTAssertLessThan(toolbar.frame.width, 80, "Side-docked toolbar should be vertical")
            XCTAssertGreaterThan(toolbar.frame.height, 300)
            XCTAssertTrue(app.buttons["Pen"].isHittable)
            XCTAssertTrue(app.buttons["Insert"].isHittable)
            let penHeight = toolbar.frame.height
            app.buttons["Lasso"].tap()
            XCTAssertLessThan(toolbar.frame.height, penHeight - 30,
                              "Vertical toolbar should shrink when fewer controls are visible")
            app.buttons["Pen"].tap()
            if x < screen.midX {
                XCTAssertLessThan(toolbar.frame.midX, screen.midX / 2)
            } else {
                XCTAssertGreaterThan(toolbar.frame.midX, screen.midX * 1.5)
            }
        }
    }

    func testInsertingTextBoxAndStickyNoteOpensEditableSheet() {
        _ = openNotebook(named: uniqueTitle("Text Elements"))
        for (item, title) in [("Text Box", "Text"), ("Sticky Note", "Sticky Note")] {
            app.buttons["Insert"].tap()
            app.buttons[item].tap()
            let editor = app.navigationBars[title]
            XCTAssertTrue(editor.waitForExistence(timeout: 5), "\(item) editor did not open")
            let textView = app.textViews.firstMatch
            XCTAssertTrue(textView.waitForExistence(timeout: 5))
            textView.typeText("Study note")
            textView.typeText(" for tomorrow.")
            XCTAssertEqual(textView.value as? String, "Study note for tomorrow.",
                           "Typing must not move the insertion point or reorder text")
            editor.buttons["Done"].tap()
            XCTAssertFalse(editor.exists)
        }
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "page-element").count, 2)
    }

    func testLandscapeNotebookAndExplicitPortraitPage() {
        openNewNotebookSheet()
        let name = uniqueTitle("Landscape Notebook")
        let field = app.textFields["Untitled Notebook"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(focus(field))
        field.typeText(name)
        let hideKeyboard = app.buttons["Hide keyboard"]
        if hideKeyboard.exists { hideKeyboard.tap() }
        let landscape = app.buttons["Landscape"].firstMatch
        XCTAssertTrue(landscape.waitForExistence(timeout: 5))
        landscape.tap()
        app.navigationBars["New Notebook"].buttons["Create"].tap()
        app.buttons[name].firstMatch.tap()

        openToolbarMenu(named: "More")
        app.buttons["Page Style"].tap()
        XCTAssertTrue(app.buttons["Landscape"].isSelected)
        app.buttons["Done"].tap()

        openToolbarMenu(named: "More")
        app.buttons["Insert Page"].tap()
        app.buttons["Portrait Page"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Page 2 of 2'")).firstMatch.waitForExistence(timeout: 5))
        openToolbarMenu(named: "More")
        app.buttons["Page Style"].tap()
        XCTAssertTrue(app.buttons["Portrait"].isSelected)
    }

    func testSinglePageAddsOnlyWithLeftSwipeAtEnd() {
        _ = openNotebook(named: uniqueTitle("Swipe to Add Page"))
        let canvas = app.scrollViews["page-canvas"]
        let pageOne = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Page 1 of 1'"))
        XCTAssertTrue(pageOne.firstMatch.exists)

        let verticalStart = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
        let verticalEnd = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
        verticalStart.press(forDuration: 0.1, thenDragTo: verticalEnd, withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(pageOne.firstMatch.exists, "vertical scrolling created a page in single-page mode")

        let pageTwo = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Page 2 of 2'"))
        swipeCanvasLeft()
        XCTAssertTrue(pageTwo.firstMatch.waitForExistence(timeout: 5), "swiping left on the last page did not add one")
        attachScreenshot(named: "Page Added by Swipe")
    }

    func testNotebookPersistsAcrossRelaunch() {
        let title = uniqueTitle("Relaunch Persistence")
        createNotebook(named: title)
        XCTAssertTrue(app.buttons[title].firstMatch.waitForExistence(timeout: 5))

        app.terminate()
        app.launch()

        XCTAssertTrue(app.buttons[title].firstMatch.waitForExistence(timeout: 5))
    }

    func testLanguagePickerSwitchesBetweenEnglishAndChinese() {
        app.buttons["More"].tap()
        app.buttons["Settings"].tap()

        let languagePicker = app.descendants(matching: .any)["app-language-picker"].firstMatch
        XCTAssertTrue(languagePicker.waitForExistence(timeout: 5))
        languagePicker.tap()
        app.buttons["简体中文"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))

        languagePicker.tap()
        app.buttons["繁體中文"].tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 5))

        languagePicker.tap()
        app.buttons["English"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    func testAssistantCreatesAndReopensConversation() {
        app.terminate()
        app.launchArguments.append("-ui-testing-ai-stub")
        app.launch()
        let notebookTitle = openNotebook(named: uniqueTitle("Assistant"))

        // The assistant is a dedicated toolbar button now, not a More-menu item.
        let assistant = app.buttons["editor-assistant"]
        XCTAssertTrue(assistant.waitForExistence(timeout: 4))
        assistant.tap()
        XCTAssertTrue(app.segmentedControls.buttons["All Notes"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["Summary"].exists)

        app.buttons["Explain a concept"].tap()
        XCTAssertTrue(app.staticTexts["Because it kept the French stress on the second syllable."].waitForExistence(timeout: 10))
        dismissAssistant()

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons[notebookTitle].firstMatch.waitForExistence(timeout: 5))
        app.buttons[notebookTitle].firstMatch.tap()
        app.buttons["editor-assistant"].tap()
        XCTAssertTrue(app.staticTexts["Explain the most important concept in these notes in simple terms."].waitForExistence(timeout: 4))
        let conversations = app.descendants(matching: .any)["assistant-conversations-menu"]
        XCTAssertTrue(conversations.waitForExistence(timeout: 4))
        conversations.tap()
        app.buttons["New Conversation"].tap()
        XCTAssertFalse(app.staticTexts["Explain the most important concept in these notes in simple terms."].exists)
        conversations.tap()
        app.buttons["Explain the most important concept in"].tap()
        XCTAssertTrue(app.staticTexts["Explain the most important concept in these notes in simple terms."].exists)
        dismissAssistant()
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
        XCTAssertTrue(app.buttons["Draw with Finger"].waitForExistence(timeout: 3), "Missing handwriting action: Draw with Finger")

        app.buttons["Draw with Finger"].tap()
        let insert = app.buttons["Insert"]
        insert.tap()
        XCTAssertTrue(app.buttons["Shape"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Text Box"].exists)
        XCTAssertTrue(app.buttons["Sticky Note"].exists)
        XCTAssertFalse(app.buttons["Draw with Finger"].exists)
    }

    func testExportNotebookPDFInVerticalScrollModeShowsShareSheet() {
        openNotebook(named: uniqueTitle("Vertical Export"))

        openToolbarMenu(named: "More")
        let verticalOption = app.buttons["Vertical Scroll"]
        XCTAssertTrue(verticalOption.waitForExistence(timeout: 3))
        verticalOption.tap()

        drawStroke(from: CGVector(dx: 0.2, dy: 0.3), to: CGVector(dx: 0.5, dy: 0.3))

        openToolbarMenu(named: "More")
        let export = app.buttons["Export Notebook as PDF"]
        XCTAssertTrue(export.waitForExistence(timeout: 3))
        export.tap()

        // A blank/stuck share sheet still presents (it's a real UIKit sheet),
        // it just never draws anything inside -- so check for actual content,
        // not merely that something was presented.
        let activityContent = app.otherElements["ActivityListView"].firstMatch
        let anyActivityButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Copy' OR label CONTAINS 'Save'")).firstMatch
        let appeared = activityContent.waitForExistence(timeout: 6) || anyActivityButton.waitForExistence(timeout: 6)
        XCTAssertTrue(appeared, "exporting the notebook in vertical scroll mode produced no visible share sheet content")
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
        app.buttons["Selection Shape"].tap()
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
        app.buttons["Selection Shape"].tap()
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
        for _ in 0..<4 { swipeCanvasLeft() }

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
        swipeCanvasLeft()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Page 5 of 5'")).firstMatch.exists)

        openToolbarMenu(named: "More")
        app.buttons["Page Info"].tap()
        XCTAssertTrue(app.navigationBars["Page Info"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.textFields["Page title"].isEnabled)
        XCTAssertFalse(app.switches["Bookmark"].isEnabled)
        app.navigationBars["Page Info"].buttons["Done"].tap()
    }

    func testDeletionTimeoutRestoreAndPermanentDeleteConfirmation() {
        openNotebook(named: uniqueTitle("Page Trash"))
        swipeCanvasLeft()
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
        swipeCanvasLeft()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Page 2 of 2'")).firstMatch.exists)

        // Add the second notebook from the visible tab strip.
        let addTab = app.buttons["editor-add-tab"]
        XCTAssertTrue(addTab.waitForExistence(timeout: 5))
        addTab.tap()
        app.buttons[secondTitle].tap()
        XCTAssertEqual(app.buttons["notebook-title"].label, secondTitle)

        // Switching tabs keeps both notebooks open.
        app.buttons[firstTitle].tap()
        XCTAssertEqual(app.buttons["notebook-title"].label, firstTitle)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Page 2 of 2'")).firstMatch.exists,
                      "Switching tabs should retain the page position")
        app.buttons[secondTitle].tap()
        attachScreenshot(named: "Two Notebook Tabs Portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        let activeTab = app.buttons["notebook-title"]
        let drawingTool = app.buttons["Pen"]
        XCTAssertTrue(activeTab.waitForExistence(timeout: 5))
        XCTAssertTrue(drawingTool.isHittable)
        XCTAssertLessThan(activeTab.frame.maxY, drawingTool.frame.minY,
                          "Notebook tabs must stay above the drawing toolbar")
        XCTAssertTrue(app.buttons["editor-add-tab"].isHittable)
        XCTAssertTrue(app.buttons["editor-assistant"].isHittable)
        attachScreenshot(named: "Two Notebook Tabs Landscape")
        XCUIDevice.shared.orientation = .portrait

        // The second notebook is now the active tab; close it again.
        let closeTab = app.buttons["Close \(secondTitle) Tab"]
        XCTAssertTrue(closeTab.waitForExistence(timeout: 3))
        closeTab.tap()

        attachScreenshot(named: "iPad Workspace")

        app.buttons["Back"].tap()
        XCTAssertTrue(app.buttons[secondTitle].firstMatch.waitForExistence(timeout: 5))
    }

    func testAddTabCanCreateAndOpenNotebook() {
        openNotebook(named: uniqueTitle("First Tab"))
        app.buttons["editor-add-tab"].tap()
        app.buttons["New Notebook"].tap()

        let title = uniqueTitle("Created Tab")
        let field = app.textFields["Untitled Notebook"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(focus(field))
        field.typeText(title)
        app.navigationBars["New Notebook"].buttons["Create"].tap()

        let selectedTab = app.buttons["notebook-title"]
        XCTAssertTrue(selectedTab.waitForExistence(timeout: 5))
        XCTAssertEqual(selectedTab.label, title)
        XCTAssertTrue(app.buttons["Close \(title) Tab"].exists)
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

    func testNestedFolderFiltersIncludeChildNotebooks() {
        let algebra = uniqueTitle("Algebra")
        let history = uniqueTitle("History")
        createNotebook(named: algebra)
        createNotebook(named: history)
        organize(notebook: algebra, folder: "School/Math", tags: "study")

        let parent = app.buttons["library-folder-School"]
        let child = app.buttons["library-folder-School/Math"]
        XCTAssertTrue(parent.waitForExistence(timeout: 5))
        XCTAssertTrue(child.exists)
        parent.tap()
        XCTAssertTrue(app.buttons[algebra].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[history].firstMatch.exists)
        child.tap()
        XCTAssertTrue(app.buttons[algebra].firstMatch.exists)
        XCTAssertFalse(app.buttons[history].firstMatch.exists)
        attachScreenshot(named: "Nested Folders")
    }

    func testSettingsSidebarChangesDetailPane() {
        app.buttons["More"].tap()
        app.buttons["Settings"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["settings-section-language"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["app-language-picker"].firstMatch.exists)
        app.descendants(matching: .any)["settings-section-input"].firstMatch.tap()
        XCTAssertTrue(app.switches["Draw with Finger"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["settings-section-sync"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Nearby Sync"].waitForExistence(timeout: 5))
        attachScreenshot(named: "Settings Sidebar")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Nearby Sync"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["settings-section-language"].firstMatch.isHittable)
        attachScreenshot(named: "Settings Sidebar Landscape")
        XCUIDevice.shared.orientation = .portrait
    }

    func testEmptyFolderSurvivesRelaunch() {
        let name = uniqueTitle("Courses")
        app.buttons["library-new-folder"].tap()
        let field = app.textFields["new-folder-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(focus(field))
        field.typeText(name)
        app.navigationBars["New Folder"].buttons["Create"].tap()
        XCTAssertTrue(app.buttons["library-folder-\(name)"].waitForExistence(timeout: 5))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["library-folder-\(name)"].waitForExistence(timeout: 5))
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

    /// Draw, lasso, then resize by a handle.
    ///
    /// Every other UI test builds its content from the Insert menu, so the
    /// PencilKit path -- the thing this app is for -- had no coverage at all,
    /// and the bug this covers went unnoticed through a full device run: the
    /// resize handles were 12-16pt against a 44pt guideline, so a drag aimed
    /// at one usually missed, fell through to the lasso overlay that covers
    /// the whole page, and was read as the start of a new selection. The
    /// selection you were trying to stretch was discarded instead.
    /// Draw, lasso, and reach the Ask action.
    ///
    /// Covers the half of asking-in-ink that only a device can vouch for: that
    /// a synthesised drag really lays down PencilKit strokes, that the lasso
    /// finds them, and that the Ask control is reachable and its tap is not
    /// swallowed by `UnifiedLassoOverlay` -- which covers the whole page and
    /// reads any miss as the start of a new selection. That last risk is real
    /// here because the selection bar now carries nine controls, not eight.
    ///
    /// It deliberately stops at "the tap was acted on". Vision cannot read the
    /// two straight lines a synthesised drag produces as text, so the question
    /// is empty and the editor says so; asserting an answer card instead would
    /// mean typing real words through the keyboard, and driving the rich-text
    /// sheet on device hung the run for four minutes without finishing. What
    /// the assistant then does with a question -- streaming, citations,
    /// fallbacks, where the card lands -- is covered by `InkQuestionTests` and
    /// `AssistantCoordinatorTests`, which need no device at all.
    func testAskAboutLassoedInkIsReachableFromTheSelectionBar() {
        app.terminate()
        app.launchArguments.append("-ui-testing-ai-stub")
        app.launch()

        openNotebook(named: uniqueTitle("Ask In Ink"))

        app.buttons["Pen"].tap()
        drawStroke(from: CGVector(dx: 0.30, dy: 0.26), to: CGVector(dx: 0.64, dy: 0.30))
        drawStroke(from: CGVector(dx: 0.30, dy: 0.36), to: CGVector(dx: 0.64, dy: 0.40))

        app.buttons["Lasso"].tap()
        let canvas = app.scrollViews["page-canvas"]
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.18))
            .press(
                forDuration: 0.2,
                thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.76, dy: 0.50)),
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )

        // The selection bar existing at all is the proof that ink committed:
        // there is nothing else on this page for the lasso to have found.
        let bar = app.descendants(matching: .any)["selection-context-bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "the lasso did not select the hand-drawn strokes")

        let ask = bar.descendants(matching: .button)["Ask"].firstMatch
        XCTAssertTrue(ask.waitForExistence(timeout: 3), "the selection bar has no Ask action")
        // The bar gained a ninth control, and the risk is that it lands past
        // the end of the layout: such a button still exists in the
        // accessibility tree and reports a frame, but cannot be tapped.
        //
        // Not a size assertion. These buttons publish the frame of their
        // glyph, not the 44pt target around it, and SF Symbols differ in
        // width -- "sparkles" measures 14.5 next to "doc.on.doc" at 16, so
        // any threshold here would be measuring the icon, not the reach.
        XCTAssertTrue(ask.isHittable, "the Ask button is present but unreachable")
        XCTAssertTrue(bar.frame.contains(ask.frame), "the ninth action fell outside the selection bar")
        attachScreenshot(named: "selection-bar-with-ask")
        ask.tap()

        // Either outcome proves the tap reached the editor rather than being
        // read as the start of a new lasso: an answer card for readable ink,
        // or the editor saying it found nothing to ask about.
        let answer = app.descendants(matching: .any)["assistant-note"]
        let nothingReadable = app.staticTexts["Nothing readable in that selection"]
        let deadline = Date().addingTimeInterval(20)
        var acted = false
        while Date() < deadline {
            if answer.exists || nothingReadable.exists {
                acted = true
                break
            }
            _ = answer.waitForExistence(timeout: 0.2)
        }
        XCTAssertTrue(acted, "tapping Ask did nothing at all -- the tap was swallowed")
        attachScreenshot(named: "after-ask")
    }

    /// Undo must actually remove a stroke for good. A prior bug (PencilKit
    /// resurrecting the undone stroke the moment a new one committed) would
    /// only show up once a new stroke is drawn *after* the undo, not at the
    /// moment of the undo itself -- so this draws, undoes, draws again, then
    /// lassoes exactly the row the undone stroke occupied and nothing else.
    func testUndoneStrokeDoesNotReappearAfterDrawingAgain() {
        openNotebook(named: uniqueTitle("Undo Resurrection"))

        app.buttons["Pen"].tap()
        drawStroke(from: CGVector(dx: 0.2, dy: 0.25), to: CGVector(dx: 0.5, dy: 0.25))
        drawStroke(from: CGVector(dx: 0.2, dy: 0.45), to: CGVector(dx: 0.5, dy: 0.45))

        hittableButton("Undo").tap()

        drawStroke(from: CGVector(dx: 0.2, dy: 0.65), to: CGVector(dx: 0.5, dy: 0.65))

        app.buttons["Lasso"].tap()
        let canvas = app.scrollViews["page-canvas"]
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.40))
            .press(
                forDuration: 0.2,
                thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.50)),
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )

        let outline = app.descendants(matching: .any)["selection-outline"]
        _ = outline.waitForExistence(timeout: 2)
        XCTAssertFalse(
            outline.exists,
            "the undone stroke reappeared: lassoing only its row still found a selection"
        )
    }

    /// Same bug, but the way it was actually reported: undo pressed *twice*
    /// in a row (removing two separate strokes) before drawing again, not
    /// just once.
    func testTwoUndoneStrokesDoNotReappearAfterDrawingAgain() {
        openNotebook(named: uniqueTitle("Double Undo Resurrection"))

        app.buttons["Pen"].tap()
        drawStroke(from: CGVector(dx: 0.2, dy: 0.20), to: CGVector(dx: 0.5, dy: 0.20))
        drawStroke(from: CGVector(dx: 0.2, dy: 0.40), to: CGVector(dx: 0.5, dy: 0.40))
        drawStroke(from: CGVector(dx: 0.2, dy: 0.60), to: CGVector(dx: 0.5, dy: 0.60))

        let undo = hittableButton("Undo")
        undo.tap()
        undo.tap()

        drawStroke(from: CGVector(dx: 0.2, dy: 0.80), to: CGVector(dx: 0.5, dy: 0.80))

        app.buttons["Lasso"].tap()
        let canvas = app.scrollViews["page-canvas"]
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.35))
            .press(
                forDuration: 0.2,
                thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.65)),
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )

        let outline = app.descendants(matching: .any)["selection-outline"]
        _ = outline.waitForExistence(timeout: 2)
        XCTAssertFalse(
            outline.exists,
            "the two undone strokes reappeared after drawing again following a double undo"
        )
    }

    /// The specific gap the first two undo-resurrection tests didn't cover:
    /// undoing all the way back to an *empty* page. There the target drawing
    /// is `PKDrawing()`, identical to the empty intermediate `setCanvasDrawing`
    /// used to flush PencilKit's stale baseline -- making that second
    /// assignment a no-op and leaving the stale (pre-undo, non-empty)
    /// baseline in place for the next stroke to resurrect everything onto.
    func testStrokeDoesNotReappearAfterUndoingBackToAnEmptyPage() {
        openNotebook(named: uniqueTitle("Empty Page Undo Resurrection"))

        app.buttons["Pen"].tap()
        drawStroke(from: CGVector(dx: 0.2, dy: 0.30), to: CGVector(dx: 0.5, dy: 0.30))

        hittableButton("Undo").tap()

        drawStroke(from: CGVector(dx: 0.2, dy: 0.60), to: CGVector(dx: 0.5, dy: 0.60))

        app.buttons["Lasso"].tap()
        let canvas = app.scrollViews["page-canvas"]
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.20))
            .press(
                forDuration: 0.2,
                thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.40)),
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )

        let outline = app.descendants(matching: .any)["selection-outline"]
        _ = outline.waitForExistence(timeout: 2)
        XCTAssertFalse(
            outline.exists,
            "the stroke undone back to an empty page reappeared once a new stroke was drawn"
        )
    }

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

    /// The whole-element drag used `.highPriorityGesture`, which wins over
    /// any gesture nested inside it -- including the corner ResizeHandle's
    /// own drag, overlaid inside the same view. That made resize (and, for
    /// rotatable types, rotation) completely unusable: touching the handle
    /// just fed the element-level drag, which no-ops there by design
    /// (`canStartDrag` excludes the handle regions) and nothing happened.
    func testInsertedElementCanBeResizedByItsHandle() {
        openNotebook(named: uniqueTitle("Element Resize"))

        insertFromMenu("Tape")
        let element = app.descendants(matching: .any)["page-element"].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), "insert produced no element")

        // Select it with a short drag rather than a tap: Tape's own content
        // view has a `.onTapGesture` (reveal/cover) nested inside it, which
        // wins over the outer selection tap and would leave nothing selected
        // for a reason that has nothing to do with resizing. The drag
        // gesture's onChanged sets selection too, and a few points of travel
        // land well clear of the corner handle regions `canStartDrag` excludes.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.1,
                thenDragTo: element.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
            )
        let before = element.frame

        let handle = app.descendants(matching: .any)["element-resize-handle-br"].firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 4), "no bottom-right resize handle appeared after selecting the element")

        // Drag relative to the stable page canvas, not the small element
        // itself -- extrapolating a target from the element's own (moving)
        // frame is exactly the kind of imprecision that made an earlier
        // version of this test inconclusive.
        let canvas = app.scrollViews["page-canvas"]
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.2,
                thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.9)),
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )

        let after = element.frame
        XCTAssertNotEqual(
            before.size, after.size,
            "dragging the resize handle did not resize the element -- the whole-element drag gesture is stealing the touch"
        )
    }

    /// Reported on a real iPad: draw, lasso, move, Undo, Redo -- and the page
    /// went blank. Ink is built from real strokes here, not the Insert menu,
    /// and "ink survived" is proved by the lasso finding a selection.
    func testRedoOfALassoMoveKeepsTheInk() {
        openNotebook(named: uniqueTitle("Redo Lasso Move"))

        app.buttons["Pen"].tap()
        // Diagonal on purpose: a flat stroke has a selection box only a few
        // points tall, and its 44pt top/bottom resize handles overlap the
        // centre, so a drag from the centre resizes instead of moving.
        drawStroke(from: CGVector(dx: 0.2, dy: 0.25), to: CGVector(dx: 0.5, dy: 0.45))

        app.buttons["Lasso"].tap()
        let canvas = app.scrollViews["page-canvas"]
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.47))
            .press(
                forDuration: 0.2,
                thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.23)),
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )
        let outline = app.descendants(matching: .any)["selection-outline"]
        XCTAssertTrue(outline.waitForExistence(timeout: 5), "lasso did not select the drawn stroke")
        let originalBounds = outline.value as? String

        outline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.2,
                thenDragTo: outline.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.5)),
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )
        let moved = app.descendants(matching: .any)["selection-outline"]
        XCTAssertTrue(moved.waitForExistence(timeout: 3))
        XCTAssertNotEqual(moved.value as? String, originalBounds, "the drag did not move the selection")

        // `buttons["Undo"].firstMatch` is a hidden 1pt keyboard-shortcut
        // button that is never hittable; the toolbar button is the hittable one.
        let undo = hittableButton("Undo")
        let redo = hittableButton("Redo")
        XCTAssertTrue(undo.isEnabled, "no usable Undo button")
        XCTAssertFalse(redo.isEnabled, "Redo should be unavailable before anything is undone")
        undo.tap()
        let redoEnabled = NSPredicate(format: "isEnabled == true")
        expectation(for: redoEnabled, evaluatedWith: redo)
        waitForExpectations(timeout: 4)
        XCTAssertTrue(redo.isEnabled, "nothing to redo after undoing the move")
        redo.tap()

        // Clear any selection, then cross the whole band the stroke can be in.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.80)).tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.55))
            .press(
                forDuration: 0.2,
                thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.15)),
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )
        XCTAssertTrue(
            app.descendants(matching: .any)["selection-outline"].waitForExistence(timeout: 5),
            "the page is blank after redoing a lasso move: the ink was lost"
        )
    }

    func testInsertedElementMovesWithFingerDrag() {
        assertInsertedElementMovesWithFingerDrag()
    }

    func testFingerDragWorksWhenCanvasReceivesTouch() {
        app.terminate()
        app.launchArguments.append("-ui-testing-force-canvas-finger")
        app.launch()
        assertInsertedElementMovesWithFingerDrag()
    }

    func testResizeHandleWorksWhenCanvasReceivesFingerTouch() {
        app.terminate()
        app.launchArguments.append("-ui-testing-force-canvas-finger")
        app.launch()
        _ = openNotebook(named: uniqueTitle("Canvas Resize"))
        insertFromMenu("Tape")
        let element = app.descendants(matching: .any)["page-element"].firstMatch
        let handle = app.descendants(matching: .any)["element-resize-handle-br"].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        let before = element.frame
        let canvas = app.scrollViews["page-canvas"]
        let target = canvas.coordinate(withNormalizedOffset: CGVector(
            dx: (handle.frame.midX + 90 - canvas.frame.minX) / canvas.frame.width,
            dy: (handle.frame.midY + 70 - canvas.frame.minY) / canvas.frame.height
        ))
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.1)
        let after = element.frame
        XCTAssertGreaterThan(after.width - before.width, 40, "finger resize did not enlarge the element")
        XCTAssertGreaterThan(after.height - before.height, 30, "finger resize did not increase element height")
    }

    func testRotationHandleWorksWhenCanvasReceivesFingerTouch() {
        app.terminate()
        app.launchArguments.append("-ui-testing-force-canvas-finger")
        app.launchArguments.append("-ui-testing-seed-image")
        app.launch()
        _ = openNotebook(named: uniqueTitle("Image Rotation"))
        let element = app.descendants(matching: .any)["page-element"].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), "test image did not appear")
        let handle = app.descendants(matching: .any)["element-rotate-handle"].firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "image has no rotation handle")
        let before = element.value as? String
        let canvas = app.scrollViews["page-canvas"]
        let target = canvas.coordinate(withNormalizedOffset: CGVector(
            dx: (handle.frame.midX + 70 - canvas.frame.minX) / canvas.frame.width,
            dy: (handle.frame.midY + 55 - canvas.frame.minY) / canvas.frame.height
        ))
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertNotEqual(element.value as? String, before, "finger rotation did not change the image angle")
    }

    func testTextAndStickyNoteResizeWithFinger() {
        app.terminate()
        app.launchArguments.append("-ui-testing-force-canvas-finger")
        app.launch()
        _ = openNotebook(named: uniqueTitle("Text Control Resize"))
        for (item, title) in [("Text Box", "Text"), ("Sticky Note", "Sticky Note")] {
            app.buttons["Insert"].tap()
            app.buttons[item].tap()
            let editor = app.navigationBars[title]
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            app.textViews.firstMatch.typeText("Study")
            editor.buttons["Done"].tap()
            let kind = item == "Text Box" ? "Text box" : "Sticky note"
            let element = app.descendants(matching: .any)
                .matching(identifier: "page-element")
                .matching(NSPredicate(format: "label BEGINSWITH %@", kind))
                .firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 5))
            let handle = app.descendants(matching: .any)["element-resize-handle-br"].firstMatch
            XCTAssertTrue(handle.waitForExistence(timeout: 5), "\(item) has no resize handle")
            let before = element.frame
            let canvas = app.scrollViews["page-canvas"]
            let target = canvas.coordinate(withNormalizedOffset: CGVector(
                dx: (handle.frame.midX + 65 - canvas.frame.minX) / canvas.frame.width,
                dy: (handle.frame.midY + 55 - canvas.frame.minY) / canvas.frame.height
            ))
            handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.1)
            XCTAssertGreaterThan(element.frame.width - before.width, 25, "\(item) did not resize with a finger")
        }
    }

    private func assertInsertedElementMovesWithFingerDrag() {
        _ = openNotebook(named: uniqueTitle("Element Drag"))
        insertFromMenu("Tape")
        let element = app.descendants(matching: .any)["page-element"].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let before = element.frame
        let canvas = app.scrollViews["page-canvas"]
        let target = canvas.coordinate(withNormalizedOffset: CGVector(
            dx: (before.midX + 80 - canvas.frame.minX) / canvas.frame.width,
            dy: (before.midY + 70 - canvas.frame.minY) / canvas.frame.height
        ))
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.1)
        let after = element.frame
        XCTAssertGreaterThan(after.midX - before.midX, 40, "element did not follow the finger horizontally")
        XCTAssertGreaterThan(after.midY - before.midY, 30, "element did not follow the finger vertically")
    }

    func testTapeOptionsChangeColorLengthAndHeight() {
        openNotebook(named: uniqueTitle("Tape Options"))
        app.buttons["Insert"].tap()
        app.buttons["Tape"].tap()

        let options = app.navigationBars["Tape Options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        let color = app.buttons["tape-color-F2B8BC"]
        XCTAssertTrue(color.exists)
        color.tap()
        app.sliders["tape-length-slider"].adjust(toNormalizedSliderPosition: 0.7)
        app.sliders["tape-height-slider"].adjust(toNormalizedSliderPosition: 0.65)
        options.buttons["Save"].tap()

        let tape = app.descendants(matching: .any)["page-element"].firstMatch
        XCTAssertTrue(tape.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Saving"].exists)
        XCTAssertGreaterThan(tape.frame.width, 200)
        XCTAssertGreaterThan(tape.frame.height, 60)
        attachScreenshot(named: "Opaque Tape on Page")

        app.buttons["Tape Options"].tap()
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["tape-color-F2B8BC"].isSelected)
        attachScreenshot(named: "Opaque Tape Options")
    }

    /// Reported on a real iPad: tapping a tape does not reveal what is under
    /// it. "Tap to reveal" is drawn on a covered tape and replaced by an eye
    /// icon once revealed, so its disappearance is the observable effect.
    func testTappingTapeRevealsWhatIsUnderIt() {
        assertTappingTapeReveals()
    }

    /// Real fingers often reach the canvas without a known touch type, so the
    /// canvas -- not the SwiftUI element -- receives the tap.
    func testTappingTapeRevealsWhenCanvasReceivesFingerTouch() {
        app.terminate()
        app.launchArguments.append("-ui-testing-force-canvas-finger")
        app.launch()
        assertTappingTapeReveals()
    }

    private func assertTappingTapeReveals() {
        openNotebook(named: uniqueTitle("Tape Reveal"))
        insertFromMenu("Tape")

        let tape = app.descendants(matching: .any)["page-element"].firstMatch
        XCTAssertTrue(tape.waitForExistence(timeout: 5), "no tape was inserted")
        XCTAssertTrue(app.staticTexts["Tap to reveal"].firstMatch.waitForExistence(timeout: 3),
                      "a new tape should start covered")

        tape.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let revealed = NSPredicate(format: "exists == false")
        expectation(for: revealed, evaluatedWith: app.staticTexts["Tap to reveal"].firstMatch)
        waitForExpectations(timeout: 4)
        XCTAssertFalse(app.staticTexts["Tap to reveal"].firstMatch.exists,
                       "tapping the tape did not reveal it")
    }

    /// The editable backup was only reachable from a notebook's long-press
    /// menu in the library, so it was effectively invisible from the editor.
    func testEditableBackupCanBeExportedFromTheEditor() {
        openNotebook(named: uniqueTitle("Editor Backup"))
        openToolbarMenu(named: "More")

        let backup = app.buttons["Export Editable Backup"].firstMatch
        XCTAssertTrue(backup.waitForExistence(timeout: 3), "no Export Editable Backup in the editor's More menu")
        backup.tap()

        let share = app.otherElements["ActivityListView"]
        XCTAssertTrue(share.waitForExistence(timeout: 6), "the share sheet did not open for the backup")
        XCTAssertFalse(app.alerts["Export Failed"].exists)
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
        if label == "Tape" {
            let options = app.navigationBars["Tape Options"]
            XCTAssertTrue(options.waitForExistence(timeout: 5), "new tape did not open its options")
            options.buttons["Save"].tap()
        }
    }

    private func openNotebook(named title: String) -> String {
        createNotebook(named: title)
        let notebook = app.buttons[title].firstMatch
        XCTAssertTrue(notebook.waitForExistence(timeout: 5))
        notebook.tap()
        XCTAssertTrue(app.scrollViews["page-canvas"].waitForExistence(timeout: 8))
        return title
    }

    private func swipeCanvasLeft() {
        if !fingerDrawingDisabledForPageSwipes {
            // UI testing enables finger drawing to exercise PencilKit. Turn
            // it off for the one-finger page-turn gesture under test.
            openToolbarMenu(named: "More")
            app.buttons["Draw with Finger"].tap()
            fingerDrawingDisabledForPageSwipes = true
        }
        let canvas = app.scrollViews["page-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.5))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
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
