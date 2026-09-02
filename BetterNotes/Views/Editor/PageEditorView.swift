import SwiftUI
import PhotosUI
import PencilKit
import SwiftData
import AVFAudio
import VisionKit
import UIKit

private enum EditorSaveStatus: Equatable {
    case saving
    case failed(String)
}

struct PageEditorView: View {
    private static let selectionPasteboardType = "com.betternotes.selection.v1"
    private static let selectionPasteboardName = UIPasteboard.Name("com.betternotes.selection")

    @Bindable var page: Page
    let pageNumber: Int
    let pageCount: Int
    let isReadOnly: Bool
    let toolbarObstruction: ToolbarObstruction
    @Binding var zoomScale: CGFloat
    @Binding var zoomRatio: CGFloat
    @Binding var zoomCommand: PageZoomCommand?
    @Binding var canUndo: Bool
    @Binding var canRedo: Bool
    @Binding var canReplaceSelectedText: Bool
    @Binding var tool: DrawingTool
    @ObservedObject var toolSettings: ToolSettings
    @Binding var command: EditorCommand?
    let pageTurnDirection: PageTurnDirection
    var onPageSwipe: (PageSwipeDirection) -> Void = { _ in }

    @Environment(\.modelContext) private var context
    @AppStorage(AppPreferenceKey.allowsFingerDrawing) private var allowsFingerDrawing = true

    @State private var canvas: PKCanvasView = PencilInputCanvasView()

    @State private var selectedElementID: PersistentIdentifier?
    @StateObject private var history = PageHistory()

    /// Shared selection for ink strokes and page elements.
    @State private var selectionState = SelectionState()
    @State private var lockedExcludedElementIDs: Set<PersistentIdentifier> = []

    @State private var showingImagePicker = false
    @State private var showingDocumentScanner = false
    @State private var photoItem: PhotosPickerItem?
    @State private var editingTextElement: PageElement?
    @State private var isImportingImage = false
    @State private var imageImportError: String?

    @State private var showingPageStyle = false
    @State private var showingPageShare = false
    @State private var pdfURL: URL?

    @StateObject private var audio = AudioRecorder()
    @State private var recordingElement: PageElement?
    @State private var transcribingAudioElementID: PersistentIdentifier?
    @State private var transcriptionTask: Task<Void, Never>?
    @State private var transcriptionRequestID: UUID?
    @State private var lastRecordedStrokeCount: Int = 0
    @State private var editorNotice: String?
    @State private var showingSourceText = false
    @State private var isRecognizingHandwriting = false
    @State private var handwritingOCRTask: Task<Void, Never>?
    @State private var loadedPage: Page?
    @State private var saveError: String?
    @State private var saveStatus: EditorSaveStatus?
    @State private var saveStatusTask: Task<Void, Never>?
    @State private var noticeTask: Task<Void, Never>?
    @State private var isSwitchingPages = false
    /// Guards against re-entry into onDrawingChanged when we programmatically
    /// set canvas.drawing (beautify, undo/redo apply, paste, delete, transform).
    /// Without this, each programmatic assignment triggers canvasViewDrawingDidChange
    /// → onDrawingChanged, causing double history entries, redundant OCR, and
    /// selection flicker.
    @State private var isApplyingProgrammaticChange = false
    @State private var pageSlideOffset: CGFloat = 0
    @State private var pageAreaWidth: CGFloat = 0
    @State private var isUsingInkTool = false
    @State private var heldShapePreview: PKDrawing?
    @State private var isTransformingInkSelection = false
    @State private var visiblePageCenter: CGPoint = .zero
    @State private var cachedSelectionPayload: SelectionPayload?

    @State private var canvasCoordinator = PaperCanvas.CoordinatorHolder()
    /// Whether the high-resolution VectorInkOverlay is shown.
    ///
    /// The overlay is a CATiledLayer that renders crisp ink when zoomed in.
    /// While the user is actively drawing, the overlay must be hidden so the
    /// live PKCanvasView strokes (which render in real time under the user's
    /// pen) are visible — otherwise the static overlay sits on top and the
    /// in-progress stroke only appears after lift.
    ///
    /// The canvas remains fully opaque during ordinary drawing. It is dimmed
    /// only while a held-shape preview is visible, with settled ink redrawn at
    /// full opacity by ShapePreviewOverlay.
    private var highResolutionInkOverlayActive: Bool {
        zoomRatio > 1.15 && !isUsingInkTool && heldShapePreview == nil
    }

    /// Finger touches inside these regions go to the SwiftUI elements beneath
    /// PencilKit. Apple Pencil input still reaches the canvas everywhere.
    private var elementInteractionRects: [CGRect] {
        page.elements.map { element in
            let angle = CGFloat(element.rotation * .pi / 180)
            let width = CGFloat(element.width)
            let height = CGFloat(element.height)
            let rotatedWidth = abs(cos(angle)) * width + abs(sin(angle)) * height
            let rotatedHeight = abs(sin(angle)) * width + abs(cos(angle)) * height
            return CGRect(
                x: CGFloat(element.posX) - rotatedWidth / 2,
                y: CGFloat(element.posY) - rotatedHeight / 2,
                width: rotatedWidth,
                height: rotatedHeight
            ).insetBy(dx: -28, dy: -28)
        }
    }

    private var pagePanRequiresTwoFingers: Bool {
        guard !isReadOnly else { return false }
        return allowsFingerDrawing
            || (tool == .lasso && toolSettings.lassoMode == .rectangle)
            || selectedElementID != nil
            || !selectionState.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                        ZoomablePageView(
                            pageSize: page.pageOrientation.size,
                            // When finger drawing is off, one finger can pan
                            // blank page areas. If finger drawing is on, or
                            // the rectangular lasso is active, two fingers are
                            // reserved for page panning.
                            panRequiresTwoFingers: pagePanRequiresTwoFingers,
                    onPageSwipe: onPageSwipe,
                    zoomCommand: $zoomCommand,
                    zoomScale: $zoomScale,
                    zoomRatio: $zoomRatio,
                    visiblePageCenter: $visiblePageCenter,
                    canShowBlankCanvasMenu: { point in canShowBlankCanvasPasteMenu(at: point) },
                    onBlankCanvasMenuWillShow: {
                        canvasCoordinator.coordinator?.cancelTentativeFingerMark()
                    },
                    onBlankCanvasPaste: pasteSelection
                ) {
                    ZStack {
                        PageBackground(
                            backgroundHex: page.backgroundHex,
                            lineStyle: page.lines,
                            orientation: page.pageOrientation
                        )
                        .id(page.backgroundHex + page.lineStyle + page.orientation)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Tapping blank page must dismiss a lasso
                            // selection too, not just an element one. The
                            // selection context bar -- Copy, Delete, the rest
                            // -- is gated on `selectionState`, so clearing
                            // only `selectedElementID` left the bar on screen
                            // over a selection the user had visibly tapped
                            // away from, with no way to dismiss it but to
                            // start drawing. Whether a tap landed here or on
                            // the canvas below depended on the page's aspect
                            // ratio, which is why it reproduced on an iPad Air
                            // and not in a larger simulator.
                            DispatchQueue.main.async {
                                clearSelection()
                            }
                        }

                        // ElementOverlay goes BELOW the canvas so ink strokes
                        // are always drawn on top of elements (including PDF
                        // page images). This lets users write on imported PDFs.
                        // Finger touches over element regions pass through the
                        // canvas for dragging/tapping; open areas still draw.
                        ElementOverlay(
                            elements: $page.elements,
                            selectedID: $selectedElementID,
                            isInteractive: !isReadOnly,
                            allowsDirectImageManipulation: !isReadOnly,
                            // Allow tap-to-deselect when tapping blank page
                            // areas. The ElementOverlay's background
                            // color.clear only activates when no element is
                            // under the tap point, so element taps still work.
                            backgroundClearsSelection: false,
                            playingAudioElementID: audio.playingElementID,
                            audioIsPlaying: audio.isPlaying,
                            audioPlaybackProgress: audio.playbackProgress,
                            onTextEdit: openTextEditor,
                            onAudioToggle: toggleAudio,
                            onAudioSeek: { element, progress in
                                audio.seek(to: progress)
                            },
                            onAudioTranscribe: transcribeAudio,
                            onDelete: { element in
                                deleteElement(element)
                            },
                            onDuplicate: { element in
                                duplicateElement(element)
                            },
                            onMutationBegan: beginElementMutation,
                            onMutationEnded: finishElementMutation
                        )

                        PaperCanvas(
                            canvasView: $canvas,
                            tool: tool,
                            // Use a fixed (non-dynamic) UIColor so ink colors
                            // don't flip in dark mode. The page is always white,
                            // so black ink must stay black regardless of system
                            // appearance.
                            color: toolSettings.fixedUIColor(for: tool),
                            lineWidth: toolSettings.width(for: tool),
                            generatedShapeStyle: toolSettings.generatedShapeStyle(for: tool),
                            eraserWidth: toolSettings.eraserWidth,
                            eraserStyle: toolSettings.eraserStyle,
                            lassoMode: toolSettings.lassoMode,
                            isReadOnly: isReadOnly,
                            allowsFingerDrawing: allowsFingerDrawing,
                            elementInteractionRects: elementInteractionRects,
                            inkData: page.inkData,
                            beautifiesHandwriting: toolSettings.beautifyHandwriting,
                            canvasInkOpacity: heldShapePreview == nil ? 1 : 0.22,
                            onDrawingChange: { _ in onDrawingChanged() },
                            onToolUseChange: { isUsing in
                                isUsingInkTool = isUsing
                                // Starting to draw/erase clears element
                                // selection so resize handles disappear.
                                if isUsing {
                                    clearSelection()
                                } else {
                                    persistInk()
                                }
                            },
                            onShapePreviewChange: { preview in
                                heldShapePreview = preview
                            },
                            coordinatorHolder: canvasCoordinator
                        )
                        .ignoresSafeArea(.keyboard)

                        VectorInkOverlay(
                            drawingData: page.inkData,
                            pageSize: page.pageOrientation.size,
                            zoomScale: zoomScale,
                            isEnabled: highResolutionInkOverlayActive
                        )
                        .frame(width: page.pageOrientation.size.width, height: page.pageOrientation.size.height)
                        .allowsHitTesting(false)

                        if let heldShapePreview {
                            ShapePreviewOverlay(drawing: heldShapePreview)
                                .frame(
                                    width: page.pageOrientation.size.width,
                                    height: page.pageOrientation.size.height
                                )
                                .allowsHitTesting(false)
                        }

                        // Tape display layer: tape elements are re-rendered
                        // ABOVE the ink canvas so they can cover/hide ink
                        // strokes as intended. This is display-only; the
                        // interactive tape elements remain in ElementOverlay
                        // below for tap/drag handling.
                        TapeDisplayLayer(elements: page.elements)
                            .frame(
                                width: page.pageOrientation.size.width,
                                height: page.pageOrientation.size.height
                            )
                            .allowsHitTesting(false)

                        if !isReadOnly && tool == .lasso {
                            UnifiedLassoOverlay(
                                mode: toolSettings.lassoMode,
                                selectionBounds: selectionState.bounds,
                                onRectangle: selectContent(in:),
                                onFreeform: selectContent(in:),
                                onClear: clearSelection
                            )
                        }

                        if !isReadOnly, !selectionState.bounds.isNull, tool == .lasso {
                            SelectionHandles(
                                bounds: selectionState.bounds,
                                pageSize: page.pageOrientation.size,
                                onResize: { scaleX, scaleY, anchor in
                                    transformSelection(
                                        scaleX: scaleX,
                                        scaleY: scaleY,
                                        rotation: 0,
                                        anchor: anchor
                                    )
                                },
                                onRotate: { rotationDelta in
                                    transformSelection(
                                        rotation: rotationDelta,
                                        anchor: CGPoint(x: selectionState.bounds.midX, y: selectionState.bounds.midY)
                                    )
                                },
                                onMove: { translationDelta in
                                    transformSelection(
                                        translation: translationDelta
                                    )
                                },
                                onMutationBegan: beginInkSelectionMutation,
                                onMutationEnded: finishInkSelectionMutation,
                                onClear: clearSelection
                            )
                        }
                        LockedSelectionMarkers(elements: page.elements.filter { lockedExcludedElementIDs.contains($0.id) })
                    }
                    .frame(width: page.pageOrientation.size.width, height: page.pageOrientation.size.height)
                    .clipShape(Rectangle())
                    .overlay(
                        Rectangle()
                            .stroke(Color.black.opacity(0.16), lineWidth: 1)
                    )
                }
                .offset(x: pageSlideOffset)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { pageAreaWidth = geo.size.width }
                            .onChange(of: geo.size.width) { _, newWidth in
                                pageAreaWidth = newWidth
                            }
                    }
                )

                if audio.isRecording {
                    VStack {
                        Spacer()
                        RecordingBar(
                            elapsed: audio.elapsed,
                            onStop: { finishRecording(save: true) },
                            onCancel: { finishRecording(save: false) }
                        )
                        .padding(.bottom, 12)
                    }
                    .allowsHitTesting(true)
                    .zIndex(50)
                }

                if let editorNotice {
                    VStack {
                        Spacer()
                        Text(editorNotice)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(.regularMaterial, in: Capsule())
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                            .padding(.bottom, 74)
                    }
                    .allowsHitTesting(false)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(70)
                }

                if isRecognizingHandwriting {
                    VStack {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Recognizing handwriting")
                                .font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(.regularMaterial, in: Capsule())
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("handwriting-recognition-progress")
                        Spacer()
                    }
                    .padding(12)
                    .zIndex(73)
                }

                if let displayedSaveStatus {
                    VStack {
                        HStack {
                            Spacer()
                            AutosaveStatusView(
                                status: displayedSaveStatus,
                                onRetry: saveChanges
                            )
                        }
                        Spacer()
                    }
                    .padding(12)
                    .zIndex(72)
                }

            }
            .clipped()
            .background(Color(.systemGroupedBackground))
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .overlay(alignment: .bottom) {
            if !selectionState.isEmpty, !isReadOnly {
                SelectionContextBar(
                    canPaste: clipboardPayload() != nil,
                    canLock: !selectionState.elementIDs.isEmpty,
                    canBringForward: canMoveSelectionElements(forward: true),
                    canSendBackward: canMoveSelectionElements(forward: false),
                    onCut: cutSelection,
                    onCopy: copySelection,
                    onPaste: pasteSelection,
                    onDuplicate: duplicateSelection,
                    onDelete: deleteSelection,
                    onLock: lockSelection,
                    onBringForward: { moveSelectionElements(forward: true) },
                    onSendBackward: { moveSelectionElements(forward: false) }
                )
                .padding(.bottom, 16 + toolbarObstruction.bottomClearance)
                .zIndex(61)
            } else if let selectedElement, !isReadOnly {
                SelectedElementControls(
                    elementType: selectedElement.type,
                    isLocked: selectedElement.isLocked,
                    canSendBackward: canSendSelectedElementBackward,
                    canBringForward: canBringSelectedElementForward,
                    onEdit: { openTextEditor(selectedElement) },
                    onDuplicate: { duplicateElement(selectedElement) },
                    onTranscribe: { transcribeAudio(selectedElement) },
                    isTranscribing: transcribingAudioElementID == selectedElement.id,
                    onToggleLock: toggleSelectedElementLock,
                    onSendBackward: { moveSelectedElement(by: -1) },
                    onBringForward: { moveSelectedElement(by: 1) },
                    onDelete: deleteSelected
                )
                .padding(.bottom, 16 + toolbarObstruction.bottomClearance)
                .zIndex(60)
            }
        }
        .onAppear {
            canUndo = history.canUndo
            canRedo = history.canRedo
            // The array's order is the canvas stacking order, and SwiftData
            // does not preserve it. Restore it before anything reads it.
            page.restoreElementOrder()
            if canvas.drawing.strokes.isEmpty {
                loadInk(from: page)
            }
            loadedPage = page
            visiblePageCenter = CGPoint(x: page.pageOrientation.size.width / 2, y: page.pageOrientation.size.height / 2)
            lastRecordedStrokeCount = canvas.drawing.strokes.count
            if !canvas.drawing.strokes.isEmpty && page.ocrText.isEmpty {
                scheduleHandwritingOCR()
            }
        }
        .task {
            await refreshSelectionClipboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            Task {
                await refreshSelectionClipboard()
            }
        }
        .onChange(of: page.id) { _, _ in
            switchLoadedPage()
        }
        .onChange(of: page.orientation) { _, _ in
            visiblePageCenter = CGPoint(x: page.pageOrientation.size.width / 2, y: page.pageOrientation.size.height / 2)
            refreshSelectionBounds()
        }
        .onChange(of: tool) { _, _ in
            // Switching tools clears all selections.
            canvasCoordinator.coordinator?.cancelShapeRecognition()
            heldShapePreview = nil
            clearSelection()
        }
        .onChange(of: isReadOnly) { _, readOnly in if readOnly { clearSelection() } }
        .onChange(of: selectedElementID) { _, id in
            canReplaceSelectedText = id.flatMap { selectedID in
                page.elements.first(where: { $0.id == selectedID })
            }.map { $0.modelContext != nil && ($0.type == .textBox || $0.type == .stickyNote) } ?? false
            guard let id, tool == .lasso, !selectionState.elementIDs.contains(id),
                  let element = page.elements.first(where: { $0.id == id }),
                  element.modelContext != nil, !element.isLocked else { return }
            selectionState = SelectionState(strokeIndices: [], elementIDs: [id], bounds: elementSelectionBounds(element))
        }
        .onChange(of: command) { _, newCommand in
            execute(newCommand)
        }
        .onReceive(history.$revision) { _ in
            canUndo = history.canUndo
            canRedo = history.canRedo
        }
        .onDisappear {
            canReplaceSelectedText = false
            canvasCoordinator.coordinator?.cancelShapeRecognition()
            heldShapePreview = nil
            handwritingOCRTask?.cancel()
            transcriptionTask?.cancel()
            transcriptionRequestID = nil
            audio.cancelTranscription()
            if recordingElement != nil {
                finishRecording(save: audio.isRecording)
            }
            audio.stopPlayback()
            persistInk()
            // Cancel any pending save-status clear task and reset so the
            // "Saving..." indicator doesn't persist after leaving the page.
            saveStatusTask?.cancel()
            saveStatus = nil
        }
        .sheet(item: $editingTextElement) { elem in
            TextEditSheet(element: elem) {
                selectedElementID = elem.id
                markPageModified()
                saveChanges()
            }
        }
        .sheet(isPresented: $showingPageStyle) {
            PageStyleSheet(page: page) {
                markPageModified()
                saveChanges()
            }
            .presentationDetents([.medium])
        }
        .photosPicker(isPresented: $showingImagePicker, selection: $photoItem, matching: .images)
        .sheet(isPresented: $showingDocumentScanner) {
            DocumentScannerView { images in
                importScannedImages(images)
                showingDocumentScanner = false
            } onCancel: {
                showingDocumentScanner = false
            }
        }
        .onChange(of: photoItem) { _, newItem in
            Task {
                await loadImage(from: newItem)
            }
        }
        .overlay {
            if isImportingImage {
                SmartImportProgressOverlay()
            }
        }
        .sheet(isPresented: $showingPageShare) {
            if let url = pdfURL { ShareSheet(items: [url]) }
        }
        .sheet(isPresented: $showingSourceText) {
            SourceTextSheet(sources: pageTextSources(), ocrUpdatedAt: page.ocrUpdatedAt)
        }
        .alert("Audio Error", isPresented: Binding(
            get: { audio.lastError != nil },
            set: { if !$0 { audio.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { audio.lastError = nil }
        } message: {
            Text(audio.lastError ?? "")
        }
        .alert("Image Import Failed", isPresented: Binding(
            get: { imageImportError != nil },
            set: { if !$0 { imageImportError = nil } }
        )) {
            Button("OK", role: .cancel) { imageImportError = nil }
        } message: {
            Text(imageImportError ?? "")
        }
        .alert("Couldn’t Save Changes", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("Try Again") { saveChanges() }
            Button("Dismiss", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private var displayedSaveStatus: EditorSaveStatus? { saveStatus }

    private func execute(_ command: EditorCommand?) {
        guard let command, command.targetPageID == page.persistentModelID else { return }
        switch command.action {
        case .undo:
            undo()
        case .redo:
            redo()
        case .insert(let kind):
            handleInsert(kind)
        case .insertShape(let kind):
            insertShape(kind)
        case .beautifyInk:
            beautifyCurrentPageInk()
        case .copy:
            copySelection()
        case .cut:
            cutSelection()
        case .paste:
            pasteSelection()
        case .deleteSelection:
            deleteSelection()
        case .insertAssistantText(let text):
            insertAssistantResult(text)
        case .replaceSelectedText(let text):
            replaceSelectedText(with: text)
        case .showPageStyle:
            showingPageStyle = true
        case .showSourceText:
            showingSourceText = true
        case .exportPage:
            exportCurrentPage()
        case .scanDocument:
            if VNDocumentCameraViewController.isSupported, !isReadOnly {
                showingDocumentScanner = true
            }
        case .recognizeHandwriting:
            recognizeCurrentHandwriting()
        case .resetLearnedHandwriting:
            HandwritingBeautifier.resetProfile()
        }
        self.command = nil
    }

    // MARK: - Ink save

    private func saveInk() {
        guard !isReadOnly else { return }
        saveInk(to: loadedPage ?? page)
    }

    private func persistInk() {
        saveInk()
        saveChanges()
    }

    private func markPageModified() {
        page.modifiedAt = .now
        page.notebook?.modifiedAt = .now
    }

    private func saveChanges() {
        do {
            page.stampElementOrder()
            try context.save()
            NotificationCenter.default.post(name: .noteCorpusDidChange, object: nil)
            saveError = nil
            // Set .saving AFTER the save succeeds, so a blocking save()
            // doesn't leave a stale .saving indicator.
            saveStatus = .saving
            saveStatusTask?.cancel()
            saveStatusTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                if saveStatus == .saving { saveStatus = nil }
            }
        } catch {
            saveError = error.localizedDescription
            saveStatus = .failed(error.localizedDescription)
        }
    }

    private func saveInk(to targetPage: Page?) {
        guard !isReadOnly else { return }
        // Guard against the page being deleted during teardown.
        // Accessing any property on a deleted SwiftData model can crash,
        // so check modelContext first (it becomes nil when deleted).
        guard let targetPage, targetPage.modelContext != nil else { return }
        targetPage.inkData = canvas.drawing.dataRepresentation()
    }

    private func loadInk(from sourcePage: Page) {
        if let data = sourcePage.inkData {
            canvas.drawing = (try? PKDrawing(data: data)) ?? PKDrawing()
        } else {
            canvas.drawing = PKDrawing()
        }
        lastRecordedStrokeCount = canvas.drawing.strokes.count
    }

    private func switchLoadedPage() {
        // `page` is already the incoming page by the time this runs, and the
        // saveChanges() below stamps its array order into zIndex. Restore that
        // order from the store first, or the save would overwrite the user's
        // layering with whatever order SwiftData happened to hand back.
        page.restoreElementOrder()
        canvasCoordinator.coordinator?.cancelShapeRecognition()
        heldShapePreview = nil

        // Finish any in-flight recording before switching pages. Without this,
        // the recording is orphaned: audio.isRecording stays true, the
        // RecordingBar renders on the new page, but recordingElement points
        // at the old page's element — tapping Stop silently does nothing.
        if audio.isRecording {
            finishRecording(save: true)
        }
        // Cancel any in-flight transcription to prevent writes to the old page.
        transcriptionTask?.cancel()
        transcribingAudioElementID = nil
        isUsingInkTool = false
        isTransformingInkSelection = false

        // Save the OLD page's ink BEFORE doing anything else. This must happen
        // before the canvas is touched, before loadedPage is reassigned, and
        // before SwiftUI can re-render PaperCanvas with new parameters.
        saveInk(to: loadedPage)
        // Persist immediately so a SwiftData refault can't lose the save.
        saveChanges()

        handwritingOCRTask?.cancel()
        selectedElementID = nil
        clearSelection()
        history.clearAll()
        // Eagerly fault the incoming page's inkData BEFORE reassigning
        // loadedPage. SwiftData faults Data properties lazily; without this,
        // a swipe can momentarily expose `page.inkData == nil` to SwiftUI
        // (driving VectorInkOverlay blank) until the row is fetched. Reading
        // it here forces the fault now, on the main thread, synchronously.
        let incomingInk = page.inkData
        loadedPage = page
        // Prevent onDrawingChanged from firing while we swap the canvas content.
        // Without this, setting canvas.drawing below triggers
        // canvasViewDrawingDidChange → onDrawingChanged, which writes the NEW
        // page's ink to page.inkData — but with lastRecordedStrokeCount still
        // holding the OLD page's value, the guard may pass and corrupt state.
        isSwitchingPages = true
        if let incomingInk {
            canvas.drawing = (try? PKDrawing(data: incomingInk)) ?? PKDrawing()
        } else {
            canvas.drawing = PKDrawing()
        }
        isSwitchingPages = false
        lastRecordedStrokeCount = canvas.drawing.strokes.count
        if !canvas.drawing.strokes.isEmpty && page.ocrText.isEmpty {
            scheduleHandwritingOCR()
        }
        animatePageSurfaceIn()
    }

    private func animatePageSurfaceIn() {
        let width = max(pageAreaWidth, UITraitCollection.current.horizontalSizeClass == .compact ? 375 : 1024)
        let startOffset = width * pageTurnDirection.incomingOffsetMultiplier
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pageSlideOffset = startOffset
        }
        withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.88, blendDuration: 0.08)) {
            pageSlideOffset = 0
        }
    }

    // MARK: - Export

    private func exportCurrentPage() {
        if !isReadOnly { saveInk() }
        saveChanges()
        let data = PDFExport.renderPage(page)
        pdfURL = PDFExport.writePDF(data, name: "Page-\(pageNumber)")
        showingPageShare = true
    }

    // MARK: - AI

    private func pageTextSources() -> [NoteTextSource] {
        var sources: [NoteTextSource] = []
        var textBoxCount = 0
        var stickyCount = 0

        for element in page.elements {
            guard let text = element.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                continue
            }
            switch element.type {
            case .textBox:
                textBoxCount += 1
                sources.append(NoteTextSource(title: "Text Box \(textBoxCount)", text: text))
            case .stickyNote:
                stickyCount += 1
                sources.append(NoteTextSource(title: "Sticky Note \(stickyCount)", text: text))
            case .audioRecording:
                if let transcript = element.transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !transcript.isEmpty {
                    sources.append(NoteTextSource(title: "Audio Transcript", text: transcript))
                }
            case .image:
                // Smart-imported images carry OCR-extracted text in `element.text`
                // so the page stays searchable without a visible text box.
                sources.append(NoteTextSource(title: "Image Text", text: text))
            default:
                break
            }
        }

        let extractedText = page.ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extractedText.isEmpty {
            sources.append(NoteTextSource(title: "OCR and PDF Text", text: extractedText))
        }
        return sources
    }

    private func insertAssistantResult(_ text: String) {
        guard !isReadOnly, !text.isEmpty else { return }
        recordBeforeMutation()
        let pageSize = page.pageOrientation.size
        let element = PageElement(
            type: .textBox,
            x: pageSize.width / 2,
            y: min(pageSize.height / 2, 360),
            width: min(pageSize.width - 96, 480),
            height: 260
        )
        element.text = text
        element.fontSize = 15
        element.page = page
        context.insert(element)
        page.appendElement(element)
        selectedElementID = element.id
        markPageModified()
        saveChanges()
        showNotice("AI result added to the page")
    }

    private func replaceSelectedText(with text: String) {
        guard !isReadOnly, !text.isEmpty,
              let selectedElementID,
              let element = page.elements.first(where: { $0.id == selectedElementID }),
              element.modelContext != nil,
              element.type == .textBox || element.type == .stickyNote else { return }
        recordBeforeMutation()
        let original = element.resolvedRichText
        let suggestion = WritingSuggestion(
            id: UUID(),
            sourceRange: NSRange(location: 0, length: original.length),
            originalText: original.string,
            replacementText: text,
            mode: .improveClarity,
            requestRevision: 0
        )
        let replacement = WritingSuggestionCoordinator.replacingText(in: original, with: suggestion)
        element.text = replacement.string
        element.richTextData = PageElement.encodeRichText(replacement)
        markPageModified()
        saveChanges()
        showNotice("Selected text replaced")
    }

    // MARK: - Undo / Redo

    /// Programmatically sets canvas.drawing while suppressing the re-entry
    /// into onDrawingChanged that would otherwise cause double history/OCR/clear.
    private func setCanvasDrawing(_ drawing: PKDrawing) {
        isApplyingProgrammaticChange = true
        canvas.drawing = drawing
        isApplyingProgrammaticChange = false
        lastRecordedStrokeCount = canvas.drawing.strokes.count
    }

    private func onDrawingChanged() {
        guard !isReadOnly else { return }
        guard !isSwitchingPages else { return }
        guard !isApplyingProgrammaticChange else { return }
        let currentCount = canvas.drawing.strokes.count
        // A live move/resize rebuilds the drawing on every drag frame, and
        // PencilKit calls back here for each one. Archiving the whole page's
        // ink at touch rate is pure waste: the snapshot is overwritten by the
        // next frame and never read. finishInkSelectionMutation() writes
        // page.inkData once when the drag ends, and switchLoadedPage() saves
        // the ink if the page changes first, so nothing here is load-bearing.
        // Take no snapshot; just keep the stroke count in step.
        if isTransformingInkSelection {
            lastRecordedStrokeCount = currentCount
            return
        }
        let currentInkData = canvas.drawing.dataRepresentation()
        if currentCount != lastRecordedStrokeCount || page.inkData != currentInkData {
            history.record(ink: page.inkData, elements: page.elements, coalesce: true)
            page.inkData = currentInkData
            markPageModified()
            lastRecordedStrokeCount = currentCount
            history.clearRedoStack()
            // New strokes invalidate the ink selection (indices may have shifted).
            clearSelection()
            scheduleHandwritingOCR()
        }
    }

    private func recognizeCurrentHandwriting() {
        let data = canvas.drawing.dataRepresentation()
        if !isReadOnly {
            page.inkData = data
        }
        let targetPageID = page.persistentModelID
        handwritingOCRTask?.cancel()
        handwritingOCRTask = Task { @MainActor in
            await updateHandwritingOCR(
                from: data,
                pageSize: page.pageOrientation.size,
                showProgress: true,
                targetPageID: targetPageID
            )
        }
    }

    private func beautifyCurrentPageInk() {
        guard !isReadOnly else { return }
        let strokes = canvas.drawing.strokes
        guard !strokes.isEmpty else {
            showNotice("No ink on this page")
            return
        }

        let before = canvas.drawing.dataRepresentation()
        recordBeforeMutation()
        HandwritingBeautifier.learn(from: strokes)
        setCanvasDrawing(HandwritingBeautifier.beautified(drawing: canvas.drawing))
        let after = canvas.drawing.dataRepresentation()
        page.inkData = after
        lastRecordedStrokeCount = canvas.drawing.strokes.count
        history.clearRedoStack()
        scheduleHandwritingOCR()
        markPageModified()
        saveChanges()
        showNotice(before == after ? "These strokes are already smooth" : "Handwriting smoothed")
    }

    private func showNotice(_ message: String) {
        withAnimation(.snappy(duration: 0.2)) { editorNotice = message }
        // Use a single cancellable task to prevent unbounded Task creation.
        noticeTask?.cancel()
        noticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            guard editorNotice == message else { return }
            withAnimation(.easeOut(duration: 0.2)) { editorNotice = nil }
        }
    }

    private func scheduleHandwritingOCR() {
        let data = canvas.drawing.dataRepresentation()
        let pageSize = page.pageOrientation.size
        // Capture the page id so a late OCR result that completes AFTER a
        // page swipe can detect it's stale and bail out, instead of writing
        // the previous page's recognized text onto the current page and
        // triggering a SwiftData save/refault that blanks the live ink.
        let targetPageID = page.persistentModelID
        handwritingOCRTask?.cancel()
        handwritingOCRTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await updateHandwritingOCR(
                from: data,
                pageSize: pageSize,
                showProgress: false,
                targetPageID: targetPageID
            )
        }
    }

    @MainActor
    private func updateHandwritingOCR(
        from data: Data?,
        pageSize: CGSize,
        showProgress: Bool,
        targetPageID: PersistentIdentifier? = nil
    ) async {
        if showProgress {
            isRecognizingHandwriting = true
        }
        let recognized = await HandwritingOCR.recognizeText(from: data, pageSize: pageSize)
        guard !Task.isCancelled else {
            if showProgress { isRecognizingHandwriting = false }
            return
        }
        // Reject stale results from a previous page. Without this, a slow
        // Vision call started on page N can finish after the user has swiped
        // to page N+1; writing `recognized` onto the new page corrupts its
        // ocrText, and the `context.save()` below can refault the new page's
        // inkData — visibly blanking the page for up to ~30s.
        if let targetPageID, page.persistentModelID != targetPageID {
            if showProgress { isRecognizingHandwriting = false }
            return
        }
        page.ocrText = recognized
        page.ocrUpdatedAt = .now
        saveChanges()
        if showProgress {
            isRecognizingHandwriting = false
            // Explicit user-triggered recognition previously gave no feedback
            // at all — it looked like nothing had happened.
            let trimmed = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                showNotice("No handwriting recognized on this page")
            } else {
                let words = trimmed.split(whereSeparator: \.isWhitespace).count
                showNotice("Recognized \(words) word\(words == 1 ? "" : "s")")
            }
        }
    }

    private func undo() {
        guard !isReadOnly else { return }
        guard let snapshot = history.undo(ink: page.inkData, elements: page.elements) else { return }
        apply(snapshot)
    }

    private func redo() {
        guard !isReadOnly else { return }
        guard let snapshot = history.redo(ink: page.inkData, elements: page.elements) else { return }
        apply(snapshot)
    }

    private func apply(_ snapshot: PageHistory.Snapshot) {
        page.inkData = snapshot.ink
        setCanvasDrawing(snapshot.ink.flatMap { try? PKDrawing(data: $0) } ?? PKDrawing())
        let existingIDs = Dictionary(uniqueKeysWithValues: page.elements.map { ($0.id, $0) })
        let snapshotIDs = Set(snapshot.elements.map { $0.id })
        var restored: [PageElement] = []
        for snap in snapshot.elements {
            if let existing = existingIDs[snap.id] {
                snap.apply(to: existing)
                restored.append(existing)
            } else {
                // Reborn elements get new PersistentIdentifiers. To keep
                // undo/redo cycles consistent, we create the element from
                // the snapshot data. Subsequent snapshots will capture the
                // new ID.
                let type = ElementType(rawValue: snap.type) ?? .textBox
                let reborn = PageElement(type: type, x: snap.posX, y: snap.posY, width: snap.width, height: snap.height)
                snap.apply(to: reborn)
                reborn.page = page
                context.insert(reborn)
                restored.append(reborn)
            }
        }
        for e in page.elements where !snapshotIDs.contains(e.id) {
            context.delete(e)
        }
        page.elements = restored
        refreshSelectionBounds()
        saveChanges()
    }

    private func recordBeforeMutation() {
        history.record(ink: canvas.drawing.dataRepresentation(), elements: page.elements, coalesce: false)
    }

    // MARK: - Insert

    private func handleInsert(_ kind: InsertKind) {
        guard !isReadOnly else { return }
        switch kind {
        case .textBox:        insertElement(.textBox)
        case .stickyNote:     insertElement(.stickyNote)
        case .image:          showingImagePicker = true
        case .audioRecording: startRecording()
        case .tape:           insertElement(.tape, size: CGSize(width: 200, height: 60))
        }
    }

    private func openTextEditor(_ element: PageElement) {
        guard !isReadOnly, element.modelContext != nil, !element.isLocked else { return }
        guard element.type == .textBox || element.type == .stickyNote else { return }
        recordBeforeMutation()
        // Defer state mutation to the next runloop to avoid "Publishing
        // changes from within view updates" — onTapGesture closures can
        // fire synchronously during a SwiftUI re-render.
        DispatchQueue.main.async {
            selectedElementID = element.id
            editingTextElement = element
        }
    }

    private func beginElementMutation() {
        history.record(
            ink: canvas.drawing.dataRepresentation(),
            elements: page.elements,
            coalesce: true
        )
    }

    private func finishElementMutation() {
        markPageModified()
        saveChanges()
    }

    private func insertElement(_ type: ElementType, size: CGSize = CGSize(width: 200, height: 120)) {
        guard !isReadOnly else { return }
        recordBeforeMutation()
        let centre = insertionCentre(for: size)
        let elem = PageElement(type: type, x: centre.x, y: centre.y, width: size.width, height: size.height)
        if type == .stickyNote { elem.colorHex = "FFE066" }
        elem.page = page
        context.insert(elem)
        page.appendElement(elem)
        selectedElementID = elem.id
        markPageModified()
        saveChanges()
        if type == .textBox || type == .stickyNote {
            editingTextElement = elem
        }
    }

    private func insertShape(_ kind: ShapeKind) {
        guard !isReadOnly else { return }
        recordBeforeMutation()
        let pageSize = page.pageOrientation.size
        let size = defaultShapeSize(for: kind, pageSize: pageSize)
        let position = defaultInsertionPosition(for: size, pageSize: pageSize)
        let origin = CGPoint(x: position.x - size.width / 2, y: position.y - size.height / 2)
        let newStrokeIndices = canvasCoordinator.coordinator?.addShape(
            kind,
            style: toolSettings.generatedShapeStyle(for: tool),
            at: origin,
            size: size
        ) ?? []
        page.inkData = canvas.drawing.dataRepresentation()
        lastRecordedStrokeCount = canvas.drawing.strokes.count
        selectionState = SelectionState(
            strokeIndices: newStrokeIndices,
            elementIDs: [],
            bounds: combinedBounds(strokes: newStrokeIndices, elements: [])
        )
        selectedElementID = nil
        markPageModified()
        saveChanges()
        showNotice("\(kind.label) inserted")
    }

    private func defaultShapeSize(for kind: ShapeKind, pageSize: CGSize) -> CGSize {
        let maxWidth = max(120, min(pageSize.width - 96, 240))
        switch kind {
        case .circle, .star:
            let side = min(maxWidth, 170)
            return CGSize(width: side, height: side)
        case .line, .arrow:
            return CGSize(width: maxWidth, height: 90)
        case .rectangle:
            return CGSize(width: min(maxWidth, 220), height: 140)
        }
    }

    /// Where a newly inserted element's centre belongs.
    ///
    /// Every image, recording, sticky note and text box used to be created at
    /// a hardcoded (200, 300). Insert one while scrolled or zoomed anywhere
    /// but the top of the page and it landed out of sight, which reads as the
    /// button having done nothing; insert two and they stacked exactly on top
    /// of each other. Shapes never had the problem because `insertShape` asks
    /// `defaultInsertionPosition` -- this routes the other four the same way,
    /// preferring the part of the page actually on screen.
    ///
    /// `SelectionPasteGeometry.origin` is the clamp paste already uses, so an
    /// inserted element and a pasted one land in the same place and neither
    /// can be pushed off the page.
    private func insertionCentre(for size: CGSize) -> CGPoint {
        let pageSize = page.pageOrientation.size
        // `visiblePageCenter` is zero until the page reports its viewport.
        // Treating that as a real centre would pin the element to the page's
        // top-left corner, so fall back to the static placement.
        guard visiblePageCenter != .zero else {
            return cascaded(defaultInsertionPosition(for: size, pageSize: pageSize), size: size, pageSize: pageSize)
        }
        let origin = SelectionPasteGeometry.origin(
            for: CGRect(origin: .zero, size: size),
            visibleCenter: visiblePageCenter,
            pageSize: pageSize
        )
        let centre = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        return cascaded(centre, size: size, pageSize: pageSize)
    }

    /// Nudge off any element already sitting at this exact spot.
    ///
    /// Without this, inserting twice without moving the first puts the second
    /// perfectly on top of it, and the page looks like it only took one.
    private func cascaded(_ centre: CGPoint, size: CGSize, pageSize: CGSize) -> CGPoint {
        let step: CGFloat = 24
        var candidate = centre
        for _ in 0..<8 {
            let occupied = page.elements.contains { element in
                element.modelContext != nil
                    && abs(CGFloat(element.posX) - candidate.x) < 1
                    && abs(CGFloat(element.posY) - candidate.y) < 1
            }
            if !occupied { return candidate }
            candidate = CGPoint(x: candidate.x + step, y: candidate.y + step)
            // Once the cascade would run off the page, stop rather than
            // place the element somewhere it cannot be seen.
            guard candidate.x + size.width / 2 <= pageSize.width,
                  candidate.y + size.height / 2 <= pageSize.height else { return centre }
        }
        return candidate
    }

    private func defaultInsertionPosition(for size: CGSize, pageSize: CGSize) -> CGPoint {
        let margin: CGFloat = 24
        let x = min(max(pageSize.width / 2, size.width / 2 + margin), pageSize.width - size.width / 2 - margin)
        let preferredY = min(pageSize.height / 2, 320)
        let y = min(max(preferredY, size.height / 2 + margin), pageSize.height - size.height / 2 - margin)
        return CGPoint(x: x, y: y)
    }

    private func deleteSelected() {
        guard !isReadOnly else { return }
        guard let id = selectedElementID else { return }
        deleteElementByID(id)
    }

    private func deleteElement(_ element: PageElement) {
        guard !isReadOnly else { return }
        deleteElementByID(element.id)
    }

    private func deleteElementByID(_ id: PersistentIdentifier) {
        if let idx = page.elements.firstIndex(where: { $0.id == id }) {
            guard !page.elements[idx].isLocked else { return }
            recordBeforeMutation()
            context.delete(page.elements[idx])
            page.elements.remove(at: idx)
        }
        // Not `selectedElementID = nil`: a lasso selection can hold this
        // element alongside others, and clearing only the id left its id in
        // `selectionState.elementIDs` and its area in the selection bounds --
        // an outline stretched around something no longer on the page.
        // Refreshing drops the dead id, reflows the bounds, and still clears
        // the selection outright when nothing is left, which is the single
        // -element case this line used to handle.
        refreshSelectionBounds()
        markPageModified()
        saveChanges()
    }

    private func duplicateElement(_ element: PageElement) {
        guard !isReadOnly, element.modelContext != nil, !element.isLocked else { return }
        recordBeforeMutation()
        let copy = PageElement.copy(of: element)
        copy.posX += 30
        copy.posY += 30
        copy.page = page
        context.insert(copy)
        page.appendElement(copy)
        selectedElementID = copy.id
        markPageModified()
        saveChanges()
    }

    private var selectedElementIndex: Int? {
        guard let id = selectedElementID else { return nil }
        return page.elements.firstIndex(where: { $0.id == id })
    }

    private var selectedElement: PageElement? {
        guard let idx = selectedElementIndex else { return nil }
        return page.elements[idx]
    }

    private var canSendSelectedElementBackward: Bool {
        guard let idx = selectedElementIndex, let selectedElement else { return false }
        return !selectedElement.isLocked && idx > 0
    }

    private var canBringSelectedElementForward: Bool {
        guard let idx = selectedElementIndex, let selectedElement else { return false }
        return !selectedElement.isLocked && idx < page.elements.count - 1
    }

    private func toggleSelectedElementLock() {
        guard !isReadOnly, let idx = selectedElementIndex else { return }
        recordBeforeMutation()
        page.elements[idx].isLocked.toggle()
        markPageModified()
        saveChanges()
    }

    private func moveSelectedElement(by offset: Int) {
        guard !isReadOnly, let idx = selectedElementIndex else { return }
        guard !page.elements[idx].isLocked else { return }
        let target = idx + offset
        guard page.elements.indices.contains(target) else { return }
        recordBeforeMutation()
        page.elements.swapAt(idx, target)
        markPageModified()
        saveChanges()
    }

    private func selectContent(in rect: CGRect) {
        guard rect.width >= 8, rect.height >= 8 else { clearSelection(); return }
        let strokeIndices = StrokeSelectionGeometry.indices(in: canvas.drawing, rect: rect)
        let candidates = page.elements.filter { elementSelectionBounds($0).intersects(rect) }
        let unlocked = candidates.filter { !$0.isLocked }
        lockedExcludedElementIDs = Set(candidates.filter(\.isLocked).map(\.id))
        let elementIDs = Set(unlocked.map(\.id))
        selectedElementID = unlocked.last?.id
        let state = SelectionState(strokeIndices: strokeIndices, elementIDs: elementIDs, bounds: combinedBounds(strokes: strokeIndices, elements: elementIDs))
        selectionState = state
    }

    private func selectContent(in polygon: [CGPoint]) {
        guard polygon.count >= 3 else { clearSelection(); return }
        let strokeIndices = StrokeSelectionGeometry.indices(in: canvas.drawing, polygon: polygon)
        let candidates = page.elements.filter { element in
            let bounds = elementSelectionBounds(element)
            return StrokeSelectionGeometry.pointInPolygon(CGPoint(x: bounds.midX, y: bounds.midY), polygon: polygon)
                || polygon.contains(where: { point in bounds.contains(point) })
        }
        let unlocked = candidates.filter { !$0.isLocked }
        lockedExcludedElementIDs = Set(candidates.filter(\.isLocked).map(\.id))
        let elementIDs = Set(unlocked.map(\.id))
        selectedElementID = unlocked.last?.id
        selectionState = SelectionState(strokeIndices: strokeIndices, elementIDs: elementIDs, bounds: combinedBounds(strokes: strokeIndices, elements: elementIDs))
    }

    private func clearSelection() {
        selectionState.clear()
        lockedExcludedElementIDs.removeAll()
        selectedElementID = nil
    }

    private func refreshSelectionBounds() {
        selectionState.strokeIndices = Set(selectionState.strokeIndices.filter { canvas.drawing.strokes.indices.contains($0) })
        let validElementIDs = Set(page.elements.filter { !$0.isLocked }.map(\.id))
        selectionState.elementIDs.formIntersection(validElementIDs)
        selectionState.bounds = combinedBounds(
            strokes: selectionState.strokeIndices,
            elements: selectionState.elementIDs
        )
        if selectionState.isEmpty {
            clearSelection()
        } else if let selectedElementID, !selectionState.elementIDs.contains(selectedElementID) {
            self.selectedElementID = page.elements.last(where: { selectionState.elementIDs.contains($0.id) })?.id
        }
    }

    private func elementSelectionBounds(_ element: PageElement) -> CGRect {
        guard element.modelContext != nil else { return .null }
        let angle = CGFloat(element.rotation * .pi / 180)
        let width = CGFloat(element.width), height = CGFloat(element.height)
        let rotatedWidth = abs(cos(angle)) * width + abs(sin(angle)) * height
        let rotatedHeight = abs(sin(angle)) * width + abs(cos(angle)) * height
        return CGRect(x: CGFloat(element.posX) - rotatedWidth / 2, y: CGFloat(element.posY) - rotatedHeight / 2, width: rotatedWidth, height: rotatedHeight)
    }

    private func combinedBounds(strokes: Set<Int>, elements: Set<PersistentIdentifier>) -> CGRect {
        var result = CGRect.null
        for index in strokes where canvas.drawing.strokes.indices.contains(index) { result = result.union(canvas.drawing.strokes[index].renderBounds) }
        for element in page.elements where elements.contains(element.id) { result = result.union(elementSelectionBounds(element)) }
        // Guard against NaN/Infinity from corrupt element data — NaN
        // comparisons always return false, so .isNull wouldn't catch it.
        guard result.width.isFinite, result.height.isFinite else { return .null }
        return result.isNull ? .null : result.insetBy(dx: -2, dy: -2)
    }

    // MARK: - Mixed selection transforms

    private func transformSelection(scaleX: CGFloat = 1, scaleY: CGFloat = 1,
                                    rotation: CGFloat = 0, translation: CGSize = .zero,
                                    anchor: CGPoint = .zero) {
        guard !selectionState.isEmpty else { return }
        let transform = SelectionTransform.affine(scaleX: scaleX, scaleY: scaleY, rotation: rotation, translation: translation, anchor: anchor)
        var strokes = canvas.drawing.strokes
        for index in selectionState.strokeIndices where strokes.indices.contains(index) {
            let stroke = strokes[index]
            let combined = stroke.transform.concatenating(transform)
            strokes[index] = PKStroke(ink: stroke.ink, path: stroke.path, transform: combined, mask: stroke.mask, randomSeed: stroke.randomSeed)
        }
        setCanvasDrawing(PKDrawing(strokes: strokes))
        for element in page.elements where selectionState.elementIDs.contains(element.id) && !element.isLocked {
            let center = CGPoint(x: element.posX, y: element.posY).applying(transform)
            element.posX = Double(center.x)
            element.posY = Double(center.y)
            element.width = Double(max(SelectionTransform.minimumDimension, abs(scaleX) * CGFloat(element.width)))
            element.height = Double(max(SelectionTransform.minimumDimension, abs(scaleY) * CGFloat(element.height)))
            element.rotation += Double(rotation * 180 / .pi)
        }
        var newBounds = combinedBounds(strokes: selectionState.strokeIndices, elements: selectionState.elementIDs)
        let recovery = SelectionTransform.recoveryTranslation(for: newBounds, pageSize: page.pageOrientation.size)
        if recovery != .zero {
            let correction = CGAffineTransform(translationX: recovery.width, y: recovery.height)
            strokes = canvas.drawing.strokes
            for index in selectionState.strokeIndices where strokes.indices.contains(index) {
                let stroke = strokes[index]
                strokes[index] = PKStroke(ink: stroke.ink, path: stroke.path, transform: stroke.transform.concatenating(correction), mask: stroke.mask, randomSeed: stroke.randomSeed)
            }
            setCanvasDrawing(PKDrawing(strokes: strokes))
            for element in page.elements where selectionState.elementIDs.contains(element.id) && !element.isLocked {
                element.posX += recovery.width
                element.posY += recovery.height
            }
            newBounds = combinedBounds(strokes: selectionState.strokeIndices, elements: selectionState.elementIDs)
        }
        selectionState.bounds = newBounds
        markPageModified()
    }

    // MARK: - Selection commands

    private func makeSelectionPayload() -> SelectionPayload? {
        guard !selectionState.isEmpty, !selectionState.bounds.isNull else { return nil }
        let strokeData = selectionState.strokeIndices.sorted().compactMap { index -> Data? in
            guard canvas.drawing.strokes.indices.contains(index) else { return nil }
            return PKDrawing(strokes: [canvas.drawing.strokes[index]]).dataRepresentation()
        }
        let origin = selectionState.bounds.origin
        let elements = page.elements.filter { selectionState.elementIDs.contains($0.id) }.map { SelectionPayload.ElementSnapshot($0, relativeTo: origin) }
        return SelectionPayload(strokes: strokeData, elements: elements, bounds: selectionState.bounds)
    }

    private func clipboardPayload() -> SelectionPayload? {
        cachedSelectionPayload
    }

    private func refreshSelectionClipboard() async {
        let pasteboardType = Self.selectionPasteboardType
        let pasteboardName = Self.selectionPasteboardName
        let data = await Task.detached(priority: .utility) {
            UIPasteboard(name: pasteboardName, create: true)?.data(forPasteboardType: pasteboardType)
        }.value
        guard !Task.isCancelled else { return }
        cachedSelectionPayload = Self.decodeSelectionPayload(from: data)
    }

    private static func decodeSelectionPayload(from data: Data?) -> SelectionPayload? {
        guard let data,
              let payload = try? JSONDecoder().decode(SelectionPayload.self, from: data),
              payload.version == SelectionPayload.currentVersion else { return nil }
        return payload
    }

    private func copySelection() {
        guard let payload = makeSelectionPayload(), let data = try? JSONEncoder().encode(payload) else { return }
        cachedSelectionPayload = payload
        UIPasteboard(name: Self.selectionPasteboardName, create: true)?
            .setData(data, forPasteboardType: Self.selectionPasteboardType)
        showNotice("Selection copied")
    }

    private func cutSelection() {
        guard !isReadOnly, !selectionState.isEmpty else { return }
        copySelection()
        deleteSelection()
    }

    private func pasteSelection() {
        guard !isReadOnly, let payload = clipboardPayload(), !payload.isEmpty else { return }
        recordBeforeMutation()
        let pageSize = page.pageOrientation.size
        let pasteOrigin = SelectionPasteGeometry.origin(
            for: payload.bounds,
            visibleCenter: visiblePageCenter,
            pageSize: pageSize
        )
        let translation = CGAffineTransform(
            translationX: pasteOrigin.x - payload.bounds.minX,
            y: pasteOrigin.y - payload.bounds.minY
        )
        var strokes = canvas.drawing.strokes
        let firstNewStroke = strokes.count
        for data in payload.strokes {
            guard let drawing = try? PKDrawing(data: data) else { continue }
            for stroke in drawing.strokes {
                strokes.append(PKStroke(ink: stroke.ink, path: stroke.path, transform: stroke.transform.concatenating(translation), mask: stroke.mask, randomSeed: stroke.randomSeed))
            }
        }
        setCanvasDrawing(PKDrawing(strokes: strokes))
        var newElementIDs: Set<PersistentIdentifier> = []
        for snapshot in payload.elements {
            let element = snapshot.makeElement(at: pasteOrigin, page: page)
            context.insert(element)
            page.appendElement(element)
            newElementIDs.insert(element.id)
        }
        let newStrokeIndices = Set(firstNewStroke..<strokes.count)
        selectionState = SelectionState(
            strokeIndices: newStrokeIndices,
            elementIDs: newElementIDs,
            bounds: combinedBounds(strokes: newStrokeIndices, elements: newElementIDs)
        )
        selectedElementID = page.elements.last(where: { newElementIDs.contains($0.id) })?.id
        let recovery = selectionState.bounds.isNull ? .zero : SelectionTransform.recoveryTranslation(
            for: selectionState.bounds,
            pageSize: pageSize
        )
        if recovery != CGSize.zero {
            // Keep edge recovery inside the same undo transaction as paste.
            isTransformingInkSelection = true
            transformSelection(translation: recovery)
            isTransformingInkSelection = false
        }
        page.inkData = canvas.drawing.dataRepresentation()
        lastRecordedStrokeCount = strokes.count
        markPageModified()
        saveChanges()
        showNotice("Selection pasted")
    }

    private func canShowBlankCanvasPasteMenu(at point: CGPoint) -> Bool {
        guard !isReadOnly, clipboardPayload()?.isEmpty == false else { return false }
        if canvas.drawing.strokes.contains(where: { $0.renderBounds.insetBy(dx: -12, dy: -12).contains(point) }) {
            return false
        }
        if page.elements.contains(where: { elementSelectionBounds($0).insetBy(dx: -12, dy: -12).contains(point) }) {
            return false
        }
        if !selectionState.bounds.isNull, selectionState.bounds.insetBy(dx: -36, dy: -36).contains(point) {
            return false
        }
        return true
    }

    private func duplicateSelection() {
        guard !selectionState.isEmpty else { return }
        copySelection()
        pasteSelection()
    }

    private func deleteSelection() {
        guard !isReadOnly, !selectionState.isEmpty else { return }
        recordBeforeMutation()
        let retainedStrokes = canvas.drawing.strokes.enumerated().compactMap { selectionState.strokeIndices.contains($0.offset) ? nil : $0.element }
        setCanvasDrawing(PKDrawing(strokes: retainedStrokes))
        let removed = page.elements.filter { selectionState.elementIDs.contains($0.id) && !$0.isLocked }
        page.elements.removeAll { element in removed.contains(where: { $0.id == element.id }) }
        removed.forEach(context.delete)
        page.inkData = canvas.drawing.dataRepresentation()
        lastRecordedStrokeCount = retainedStrokes.count
        clearSelection()
        markPageModified()
        saveChanges()
    }

    private func lockSelection() {
        guard !isReadOnly, !selectionState.elementIDs.isEmpty else { return }
        recordBeforeMutation()
        for element in page.elements where selectionState.elementIDs.contains(element.id) { element.isLocked = true }
        selectionState.elementIDs.removeAll()
        selectedElementID = nil
        selectionState.bounds = combinedBounds(strokes: selectionState.strokeIndices, elements: [])
        if selectionState.strokeIndices.isEmpty { clearSelection() }
        markPageModified()
        saveChanges()
    }

    private func moveSelectionElements(forward: Bool) {
        guard !isReadOnly, canMoveSelectionElements(forward: forward) else { return }
        recordBeforeMutation()
        let byID = Dictionary(uniqueKeysWithValues: page.elements.map { ($0.id, $0) })
        let order = ElementLayering.moving(
            page.elements.map(\.id),
            selected: selectionState.elementIDs,
            forward: forward
        )
        page.elements = order.compactMap { byID[$0] }
        markPageModified()
        saveChanges()
    }

    private func canMoveSelectionElements(forward: Bool) -> Bool {
        let unlockedSelected = Set(page.elements.filter {
            selectionState.elementIDs.contains($0.id) && !$0.isLocked
        }.map(\.id))
        return ElementLayering.canMove(page.elements.map(\.id), selected: unlockedSelected, forward: forward)
    }

    private func beginInkSelectionMutation() {
        guard !isTransformingInkSelection else { return }
        recordBeforeMutation()
        isTransformingInkSelection = true
    }

    private func finishInkSelectionMutation() {
        guard isTransformingInkSelection else { return }
        isTransformingInkSelection = false
        page.inkData = canvas.drawing.dataRepresentation()
        lastRecordedStrokeCount = canvas.drawing.strokes.count
        markPageModified()
        saveChanges()
    }

    private func startRecording() {
        guard !isReadOnly, recordingElement == nil else { return }
        // Create the recording element synchronously so it appears on the page
        // immediately and recordingElement is non-nil before the popup can be
        // dismissed. Previously the element was created inside an async Task
        // after awaiting mic permission, which raced with the popup's Stop
        // button — if the user tapped Stop before the Task completed,
        // finishRecording bailed on `recordingElement == nil` and the element
        // was never properly finalized.
        let elem = PageElement(type: .audioRecording, x: 200, y: 300, width: 220, height: 56)
        elem.colorHex = "F18F01"
        elem.text = "Recording..."
        elem.page = page
        context.insert(elem)
        page.appendElement(elem)
        selectedElementID = elem.id
        recordingElement = elem
        markPageModified()
        saveChanges()

        Task { @MainActor in
            guard await audio.startRecording() else {
                // Permission denied or recorder init failed — remove the
                // placeholder element we created above. Don't record history
                // since we're reverting to the pre-insertion state.
                if let idx = page.elements.firstIndex(where: { $0.id == elem.id }) {
                    context.delete(page.elements[idx])
                    page.elements.remove(at: idx)
                }
                if selectedElementID == elem.id { selectedElementID = nil }
                recordingElement = nil
                markPageModified()
                saveChanges()
                return
            }
            // Permission granted — now record the undo snapshot
            recordBeforeMutation()
        }
    }

    private func toggleAudio(_ element: PageElement) {
        guard element.modelContext != nil else { return }
        if audio.isRecording, let rec = recordingElement, rec.id == element.id {
            finishRecording(save: true)
            return
        }
        if audio.playingElementID == element.id {
            if audio.isPlaying {
                audio.pausePlayback()
            } else {
                audio.resumePlayback()
            }
        } else if let data = element.audioData {
            audio.play(data: data, elementID: element.id)
        } else {
            audio.lastError = "This recording does not contain playable audio."
        }
    }

    private func transcribeAudio(_ element: PageElement) {
        guard !isReadOnly, element.modelContext != nil, !element.isLocked else { return }
        guard let data = element.audioData, !data.isEmpty else {
            audio.lastError = "This recording does not contain audio to transcribe."
            return
        }
        transcriptionTask?.cancel()
        audio.cancelTranscription()
        let requestID = UUID()
        transcriptionRequestID = requestID
        transcribingAudioElementID = element.id
        transcriptionTask = Task { @MainActor in
            defer {
                if transcriptionRequestID == requestID {
                    transcriptionRequestID = nil
                    transcribingAudioElementID = nil
                }
            }
            do {
                let transcript = try await audio.transcribe(data: data)
                guard !Task.isCancelled,
                      transcriptionRequestID == requestID,
                      element.modelContext != nil else { return }
                recordBeforeMutation()
                element.transcript = transcript
                element.text = "Recording (\(formatDuration(element.audioDuration ?? 0)))"
                markPageModified()
                saveChanges()
                showNotice("Recording transcribed")
            } catch {
                guard !Task.isCancelled, transcriptionRequestID == requestID else { return }
                audio.lastError = error.localizedDescription
            }
        }
    }

    private func finishRecording(save: Bool) {
        // Guard on recordingElement (not audio.isRecording) because the
        // element is now created synchronously and audio.startRecording()
        // may still be awaiting permission when the user taps Stop.
        audio.cancelPendingRecording()
        guard let element = recordingElement else { return }
        let duration = audio.elapsed
        let data = audio.isRecording ? audio.stopRecording() : nil
        if let idx = page.elements.firstIndex(where: { $0.id == element.id }) {
            if save, let data, !data.isEmpty {
                page.elements[idx].audioData = data
                page.elements[idx].audioDuration = duration
                page.elements[idx].text = "Recording (\(formatDuration(duration)))"
            } else {
                context.delete(page.elements[idx])
                page.elements.remove(at: idx)
                if selectedElementID == element.id {
                    selectedElementID = nil
                }
            }
        }
        recordingElement = nil
        markPageModified()
        saveChanges()
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func loadImage(from item: PhotosPickerItem?) async {
        guard !isReadOnly else { return }
        guard let item else { return }
        isImportingImage = true
        defer {
            isImportingImage = false
            photoItem = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), !data.isEmpty else {
                throw ImageImportError.unreadableImage
            }
            let extraction = await SmartImageExtractor.extract(from: data)

            recordBeforeMutation()
            insertSmartImageImport(extraction, fallbackImageData: data)
            markPageModified()
            saveChanges()
        } catch {
            imageImportError = error.localizedDescription
        }
    }

    private func importScannedImages(_ images: [UIImage]) {
        guard !images.isEmpty, !isReadOnly else { return }
        isImportingImage = true
        Task { @MainActor in
            defer { isImportingImage = false }
            recordBeforeMutation()
            let pageSize = page.pageOrientation.size
            for (index, image) in images.prefix(4).enumerated() {
                guard let data = image.jpegData(compressionQuality: 0.9) else { continue }
                let extraction = await SmartImageExtractor.extract(from: data)
                insertSmartImageImport(extraction, fallbackImageData: data)
                if let selectedElementID,
                   let element = page.elements.first(where: { $0.id == selectedElementID }),
                   element.modelContext != nil {
                    element.posY = min(220 + Double(index) * 220, pageSize.height - element.height / 2 - 24)
                }
            }
            markPageModified()
            saveChanges()
            showNotice(images.count > 4 ? "Added the first 4 scanned pages" : "Scan added")
        }
    }

    private func insertSmartImageImport(_ extraction: SmartImageExtractor.Extraction, fallbackImageData: Data) {
        let pageSize = page.pageOrientation.size
        let pageCenterX = pageSize.width / 2

        let imageData = extraction.croppedImageData ?? fallbackImageData
        let sourceImageSize = extraction.croppedImageSize == .zero
            ? imageSize(from: fallbackImageData)
            : extraction.croppedImageSize
        let fittedSize = fittedElementSize(
            for: sourceImageSize,
            maxSize: CGSize(
                width: min(pageSize.width - 96, 440),
                height: 320
            )
        )

        let imageElement = PageElement(
            type: .image,
            x: pageCenterX,
            y: 240,
            width: fittedSize.width,
            height: fittedSize.height
        )
        imageElement.imageData = imageData
        // Store the OCR-extracted text on the image element (invisible, but
        // indexed by pageTextSources so the page stays searchable without
        // cluttering it with a separate text box).
        let extracted = extraction.extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extracted.isEmpty {
            imageElement.text = extracted
        }
        imageElement.page = page
        context.insert(imageElement)
        page.appendElement(imageElement)

        selectedElementID = imageElement.id
    }

    private func fittedElementSize(for sourceSize: CGSize, maxSize: CGSize) -> CGSize {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return CGSize(width: min(maxSize.width, 240), height: min(maxSize.height, 240))
        }
        let scale = min(maxSize.width / sourceSize.width, maxSize.height / sourceSize.height, 1)
        let fitted = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return CGSize(width: max(fitted.width, 80), height: max(fitted.height, 60))
    }

    private func imageSize(from data: Data) -> CGSize {
        guard let image = UIImage(data: data) else {
            return CGSize(width: 240, height: 240)
        }
        return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }
}

// MARK: - Audio Recording Controls

/// A Voice-Memos-style centered recording popup. Stays on screen above the
/// toolbar until the user taps Stop or Cancel, so the recording state is always
/// visible (the previous top-pinned pill was hidden behind the floating toolbar).
/// A compact, non-blocking recording bar pinned to the bottom of the screen.
/// Unlike a full-screen popup, this lets the user continue writing while
/// recording. Shows elapsed time, a pulsing indicator, and Stop/Cancel buttons.
private struct RecordingBar: View {
    let elapsed: TimeInterval
    var onStop: () -> Void
    var onCancel: () -> Void

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            // Pulsing red dot
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .scaleEffect(pulse ? 1.3 : 1.0)
                .opacity(pulse ? 0.5 : 1.0)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)

            Text("Recording")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(formattedElapsed)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
                .frame(minWidth: 44, alignment: .leading)

            Spacer(minLength: 0)

            Button(action: onCancel) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.red.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel Recording")

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.red))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop Recording")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        )
        .padding(.horizontal, 40)
        .onAppear { pulse = true }
    }

    private var formattedElapsed: String {
        let total = Int(elapsed.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Selected Element Controls

private struct SelectedElementControls: View {
    let elementType: ElementType
    let isLocked: Bool
    let canSendBackward: Bool
    let canBringForward: Bool
    var onEdit: () -> Void
    var onDuplicate: () -> Void
    var onTranscribe: () -> Void
    let isTranscribing: Bool
    var onToggleLock: () -> Void
    var onSendBackward: () -> Void
    var onBringForward: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if elementType == .textBox || elementType == .stickyNote {
                iconButton("pencil", "Edit Text", action: onEdit)
                    .disabled(isLocked)
            }
            iconButton("plus.square.on.square", "Duplicate", action: onDuplicate)
                .disabled(isLocked)
            if elementType == .audioRecording {
                Button(action: onTranscribe) {
                    if isTranscribing {
                        ProgressView().frame(width: 30, height: 28)
                    } else {
                        Image(systemName: "captions.bubble")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 30, height: 28)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isLocked || isTranscribing)
                .accessibilityLabel("Transcribe Recording")
            }
            Divider().frame(height: 22)
            iconButton(isLocked ? "lock.open" : "lock", isLocked ? "Unlock" : "Lock", action: onToggleLock)
            Divider().frame(height: 22)
            iconButton("arrow.down", "Send Backward", action: onSendBackward)
                .disabled(!canSendBackward)
            iconButton("arrow.up", "Bring Forward", action: onBringForward)
                .disabled(!canBringForward)
            Divider().frame(height: 22)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(isLocked)
            .accessibilityLabel("Delete")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(Color.black.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    private func iconButton(_ systemName: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Source Text Sheet

private struct NoteTextSource {
    let title: String
    let text: String
}

private struct SmartImportProgressOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("Reading image…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .transition(.opacity)
    }
}

private struct AutosaveStatusView: View {
    let status: EditorSaveStatus
    var onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch status {
            case .saving:
                ProgressView().controlSize(.small)
                Text("Saving")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text("Save failed")
                Button("Retry", action: onRetry).bold()
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

private struct SourceTextSheet: View {
    let sources: [NoteTextSource]
    let ocrUpdatedAt: Date?
    @Environment(\.dismiss) private var dismiss

    private var combinedText: String {
        sources.map { "[\($0.title)]\n\($0.text)" }.joined(separator: "\n\n")
    }

    var body: some View {
        NavigationStack {
            Group {
                if sources.isEmpty {
                    ContentUnavailableView(
                        "No Source Text",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Add text, import a searchable PDF, or recognize handwriting on this page.")
                    )
                } else {
                    List {
                        if let ocrUpdatedAt {
                            Section {
                                Label("Updated \(ocrUpdatedAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "text.viewfinder")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                            Section(source.title) {
                                Text(source.text)
                                    .font(.body)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Source Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = combinedText
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(sources.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Rectangular Lasso

/// Resize and rotate handles rendered around an ink stroke selection produced
/// by the rectangular lasso. The user drags the corner handles to scale and
/// the top handle to rotate. A tap on the selection clears it.
/// Resize box for ink selection results. Provides corner handles for
/// proportional scaling, edge handles for single-axis stretching, a body
/// drag for moving, and a top handle for rotation.
private struct SelectionHandles: View {
    /// Fixed reference frame for all handle drags. See `.coordinateSpace` below.
    fileprivate static let dragSpace = "selection-handles"
    let bounds: CGRect
    let pageSize: CGSize
    var onResize: (CGFloat, CGFloat, CGPoint) -> Void
    var onRotate: (CGFloat) -> Void
    var onMove: (CGSize) -> Void
    var onMutationBegan: () -> Void
    var onMutationEnded: () -> Void
    var onClear: () -> Void

    @State private var dragStart: CGSize = .zero
    @State private var gestureActive = false

    /// The touch target for one handle.
    ///
    /// Full 44pt wherever there is room. On a small selection eight handles
    /// at that size would blanket the whole thing and leave nowhere to grab
    /// for a move, so the target shrinks with the selection rather than
    /// trading the resize bug for a move one.
    private var handleTouchTarget: CGFloat {
        let room = min(bounds.width, bounds.height) / 2
        guard room.isFinite else { return selectionHandleTouchTarget }
        return min(selectionHandleTouchTarget, max(24, room))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Selection box outline.
            Rectangle()
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .frame(width: bounds.width, height: bounds.height)
                .offset(x: bounds.minX, y: bounds.minY)
                .accessibilityHidden(true)

            // Drag-to-move body (tap to clear, drag to move).
            //
            // Positioned rather than offset. `.offset` is a rendering
            // transform: it moves what you see and what a finger hits, but
            // leaves the layout frame at the ZStack's top-leading corner, and
            // that stale frame is what the accessibility system publishes. A
            // person dragging the outline was always fine; XCUITest, which
            // derives its touch points from the accessibility frame, aimed at
            // the page's top-left instead of at the selection -- landing
            // outside it, so the lasso layer below took the touch, cleared the
            // selection and began drawing a new one. `.position` places the
            // view's centre, so the layout frame and the visible outline agree.
            Button(action: onClear) {
                Rectangle()
                    .fill(Color.black.opacity(0.001))
                    .frame(width: bounds.width, height: bounds.height)
            }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.dragSpace))
                        .onChanged { value in
                            beginGestureIfNeeded()
                            let delta = incrementalDelta(for: value.translation)
                            if delta != .zero {
                                onMove(delta)
                                dragStart = value.translation
                            }
                        }
                        .onEnded { _ in endGesture() }
                )
                // Accessibility BEFORE `.position`, not after.
                //
                // Using `.position` instead of `.offset` fixed where the view
                // is drawn, but the view `.position` returns fills all the
                // space its parent offers -- that is how it can place a child
                // anywhere in it. Attaching the accessibility modifiers to
                // *that* view published the whole page as the outline's frame:
                // a lasso selection an inch across reported (12, 86, 1000,
                // 1333) on a 13-inch iPad Air.
                //
                // So VoiceOver and Switch Control offered the entire page as
                // one "Selection outline" element, and XCUITest -- which
                // derives touch points from the accessibility frame -- read
                // "the middle of the outline" as the middle of the page. On
                // these modifiers the element is the button itself, and its
                // frame is the selection.
                .accessibilityLabel("Selection outline")
                .accessibilityValue(selectionBoundsAccessibilityValue)
                .accessibilityIdentifier("selection-outline")
                .position(x: bounds.midX, y: bounds.midY)

            // Corner resize handles — scale proportionally from the opposite corner.
            ForEach(cornerAnchors, id: \.id) { anchor in
                ResizeDot(touchTarget: handleTouchTarget)
                    .offset(x: anchor.point.x - handleTouchTarget / 2,
                            y: anchor.point.y - handleTouchTarget / 2)
                    // Addressable so a test can drive the handle itself
                    // rather than guess at a screen coordinate, and so
                    // VoiceOver has something to announce.
                    .accessibilityElement()
                    .accessibilityIdentifier("selection-handle-\(anchor.id)")
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.dragSpace))
                            .onChanged { value in
                                beginGestureIfNeeded()
                                let delta = incrementalDelta(for: value.translation)
                                if delta != .zero {
                                    handleCornerResize(anchor: anchor, translation: delta)
                                    dragStart = value.translation
                                }
                            }
                            .onEnded { _ in endGesture() }
                    )
            }

            // Edge handles for single-axis stretch.
            ForEach(edgeAnchors, id: \.id) { anchor in
                ResizeDot(size: 12, touchTarget: handleTouchTarget)
                    .offset(x: anchor.point.x - handleTouchTarget / 2,
                            y: anchor.point.y - handleTouchTarget / 2)
                    .accessibilityElement()
                    .accessibilityIdentifier("selection-handle-\(anchor.id)")
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.dragSpace))
                            .onChanged { value in
                                beginGestureIfNeeded()
                                let delta = incrementalDelta(for: value.translation)
                                if delta != .zero {
                                    handleEdgeResize(anchor: anchor, translation: delta)
                                    dragStart = value.translation
                                }
                            }
                            .onEnded { _ in endGesture() }
                    )
            }

            // Top rotate handle.
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 1.5, height: 24)
                .offset(x: bounds.midX - 0.75, y: bounds.minY - 24)
            Circle()
                .fill(Color.white)
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                .frame(width: 18, height: 18)
                .frame(width: handleTouchTarget, height: handleTouchTarget)
                .contentShape(Rectangle())
                .offset(x: bounds.midX - handleTouchTarget / 2,
                        y: bounds.minY - 23 - handleTouchTarget / 2)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.dragSpace))
                        .onChanged { value in
                            beginGestureIfNeeded()
                            let delta = incrementalDelta(for: value.translation)
                            if delta.width != 0 {
                                onRotate(delta.width * 0.01)
                                dragStart = value.translation
                            }
                        }
                        .onEnded { _ in endGesture() }
                )
        }
        .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
        // Every drag below is measured against THIS space, not each control's
        // own. The controls are positioned from `bounds`, which the drags
        // mutate -- so in the default `.local` space a gesture measures itself
        // against a view its own output is moving, and oscillates. This root
        // is page-sized and stationary, so it is a fixed reference.
        .coordinateSpace(name: Self.dragSpace)
        .allowsHitTesting(true)
    }

    // MARK: - Resize logic

    private func beginGestureIfNeeded() {
        guard !gestureActive else { return }
        gestureActive = true
        onMutationBegan()
    }

    private func endGesture() {
        dragStart = .zero
        guard gestureActive else { return }
        gestureActive = false
        onMutationEnded()
    }

    private func incrementalDelta(for translation: CGSize) -> CGSize {
        CGSize(
            width: translation.width - dragStart.width,
            height: translation.height - dragStart.height
        )
    }

    /// Computes a proportional scale from dragging a corner handle.
    /// The opposite corner stays fixed as the anchor.
    private func handleCornerResize(anchor: CornerAnchor, translation: CGSize) {
        let opposite = CGPoint(x: bounds.maxX - (anchor.point.x - bounds.minX), y: bounds.maxY - (anchor.point.y - bounds.minY))
        let originalDist = distance(from: opposite, to: anchor.point)
        guard originalDist > 1 else { return }

        let newPoint = CGPoint(x: anchor.point.x + translation.width, y: anchor.point.y + translation.height)
        let newDist = distance(from: opposite, to: newPoint)
        let minimumScale = max(SelectionTransform.minimumDimension / max(bounds.width, 1), SelectionTransform.minimumDimension / max(bounds.height, 1))
        let scale = min(max(newDist / originalDist, minimumScale), 6)
        onResize(scale, scale, opposite)
    }

    /// Computes a single-axis scale from dragging an edge handle.
    private func handleEdgeResize(anchor: EdgeAnchor, translation: CGSize) {
        let isHorizontal = anchor.axis == .horizontal
        let opposite: CGPoint
        if isHorizontal {
            opposite = CGPoint(x: bounds.maxX - (anchor.point.x - bounds.minX), y: bounds.midY)
        } else {
            opposite = CGPoint(x: bounds.midX, y: bounds.maxY - (anchor.point.y - bounds.minY))
        }
        let originalDist: CGFloat
        let newDist: CGFloat
        if isHorizontal {
            originalDist = abs(anchor.point.x - opposite.x)
            newDist = abs(anchor.point.x + translation.width - opposite.x)
        } else {
            originalDist = abs(anchor.point.y - opposite.y)
            newDist = abs(anchor.point.y + translation.height - opposite.y)
        }
        guard originalDist > 1 else { return }
        let minimumScale = SelectionTransform.minimumDimension / max(isHorizontal ? bounds.width : bounds.height, 1)
        let scale = min(max(newDist / originalDist, minimumScale), 6)
        if isHorizontal {
            onResize(scale, 1, opposite)
        } else {
            onResize(1, scale, opposite)
        }
    }

    private func distance(from a: CGPoint, to b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    private var selectionBoundsAccessibilityValue: String {
        [bounds.minX, bounds.minY, bounds.width, bounds.height]
            .map { String(Int($0.rounded())) }
            .joined(separator: ",")
    }

    // MARK: - Anchors

    private struct CornerAnchor: Identifiable {
        let id: String
        let point: CGPoint
    }

    private struct EdgeAnchor: Identifiable {
        let id: String
        let point: CGPoint
        let axis: Axis
    }

    private enum Axis { case horizontal, vertical }

    private var cornerAnchors: [CornerAnchor] {
        [
            CornerAnchor(id: "tl", point: CGPoint(x: bounds.minX, y: bounds.minY)),
            CornerAnchor(id: "tr", point: CGPoint(x: bounds.maxX, y: bounds.minY)),
            CornerAnchor(id: "bl", point: CGPoint(x: bounds.minX, y: bounds.maxY)),
            CornerAnchor(id: "br", point: CGPoint(x: bounds.maxX, y: bounds.maxY))
        ]
    }

    private var edgeAnchors: [EdgeAnchor] {
        [
            EdgeAnchor(id: "t", point: CGPoint(x: bounds.midX, y: bounds.minY), axis: .vertical),
            EdgeAnchor(id: "b", point: CGPoint(x: bounds.midX, y: bounds.maxY), axis: .vertical),
            EdgeAnchor(id: "l", point: CGPoint(x: bounds.minX, y: bounds.midY), axis: .horizontal),
            EdgeAnchor(id: "r", point: CGPoint(x: bounds.maxX, y: bounds.midY), axis: .horizontal)
        ]
    }
}

/// Display-only layer that re-renders tape elements above the ink canvas.
/// The interactive tape elements remain in ElementOverlay for gesture handling;
/// this overlay purely shows the visual "covering" effect on top of ink.
private struct TapeDisplayLayer: View {
    let elements: [PageElement]

    var body: some View {
        ZStack {
            ForEach(elements.filter { $0.type == .tape }) { element in
                TapeVisual(element: element)
                    .position(x: element.posX, y: element.posY)
            }
        }
    }
}

private struct TapeVisual: View {
    let element: PageElement

    var body: some View {
        Group {
            if element.isRevealed {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.gray.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4]))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        LinearGradient(
                            colors: [Color.gray.opacity(0.85), Color.gray.opacity(0.7)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            }
        }
        .frame(width: element.width, height: element.height)
        .rotationEffect(.degrees(element.rotation))
    }
}

private struct UnifiedLassoOverlay: View {
    let mode: LassoMode
    let selectionBounds: CGRect
    var onRectangle: (CGRect) -> Void
    var onFreeform: ([CGPoint]) -> Void
    var onClear: () -> Void
    @State private var points: [CGPoint] = []
    @State private var currentRect: CGRect?

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            if points.isEmpty { points = [value.startLocation] }
                            points.append(value.location)
                            currentRect = normalizedRect(from: points[0], to: value.location)
                        }
                        .onEnded { value in
                            defer { points.removeAll(); currentRect = nil }
                            if mode == .rectangle {
                                let rect = normalizedRect(from: points.first ?? value.startLocation, to: value.location)
                                if rect.width >= 8 && rect.height >= 8 { onRectangle(rect) }
                                else if !selectionBounds.contains(value.location) { onClear() }
                            } else if points.count >= 3 {
                                onFreeform(points)
                            } else if !selectionBounds.contains(value.location) {
                                onClear()
                            }
                        })
                    .simultaneousGesture(SpatialTapGesture().onEnded { value in
                        if !selectionBounds.contains(value.location) { onClear() }
                    })

                if mode == .rectangle, let rect = currentRect {
                    selectionPath(rect: rect)
                } else if mode == .freeform, points.count > 1 {
                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                }
            }
        }
    }

    private func selectionPath(rect: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.accentColor.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

}

private struct LockedSelectionMarkers: View {
    let elements: [PageElement]

    var body: some View {
        ForEach(elements, id: \.id) { element in
            let width = CGFloat(element.width), height = CGFloat(element.height)
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.orange, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .frame(width: width, height: height)
                .overlay(Image(systemName: "lock.fill").font(.caption).foregroundStyle(.orange).padding(4), alignment: .topTrailing)
                .rotationEffect(.degrees(element.rotation))
                .position(x: CGFloat(element.posX), y: CGFloat(element.posY))
                .allowsHitTesting(false)
        }
    }
}

private struct SelectionContextBar: View {
    let canPaste: Bool
    let canLock: Bool
    let canBringForward: Bool
    let canSendBackward: Bool
    var onCut: () -> Void
    var onCopy: () -> Void
    var onPaste: () -> Void
    var onDuplicate: () -> Void
    var onDelete: () -> Void
    var onLock: () -> Void
    var onBringForward: () -> Void
    var onSendBackward: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) { clipboardActions; selectionActions }
            VStack(spacing: 0) {
                clipboardActions
                selectionActions
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("selection-context-bar")
    }

    private var clipboardActions: some View {
        HStack(spacing: 0) {
            action("scissors", "Cut", onCut)
            action("doc.on.doc", "Copy", onCopy)
            action("doc.on.clipboard", "Paste", onPaste).disabled(!canPaste)
            action("plus.square.on.square", "Duplicate", onDuplicate)
        }
    }

    private var selectionActions: some View {
        HStack(spacing: 0) {
            action("trash", "Delete", onDelete)
            action("lock", "Lock", onLock).disabled(!canLock)
            action("arrow.up", "Bring Forward", onBringForward).disabled(!canBringForward)
            action("arrow.down", "Send Backward", onSendBackward).disabled(!canSendBackward)
        }
    }

    private func action(_ icon: String, _ label: String, _ handler: @escaping () -> Void) -> some View {
        Button(action: handler) { Image(systemName: icon).frame(width: 44, height: 44) }
            .buttonStyle(.plain).accessibilityLabel(label)
    }
}

/// A circular resize handle dot.
/// The minimum comfortable touch target, per Apple's human interface
/// guidelines. The handles are drawn much smaller than this on purpose -- a
/// 44pt dot would hide the very selection it sits on -- so the gap is made up
/// in hit area instead of pixels.
let selectionHandleTouchTarget: CGFloat = 44

private struct ResizeDot: View {
    var size: CGFloat = 16
    var touchTarget: CGFloat = selectionHandleTouchTarget

    var body: some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            // A 12pt edge handle is a thirteenth of the recommended touch
            // area, and a touch that misses it lands on the lasso overlay
            // below -- which covers the whole page and reads the miss as the
            // start of a new selection, discarding the selection the user was
            // trying to resize.
            //
            // The frame has to grow, not just the content shape: SwiftUI
            // clips hit-testing to a view's own frame, so a `contentShape`
            // inset outwards is silently ignored. The dot keeps its drawn
            // size inside a larger, invisible touch target.
            .frame(width: touchTarget, height: touchTarget)
            .contentShape(Rectangle())
    }
}

// MARK: - Text Edit Sheet

private struct TextEditSheet: View {
    @Bindable var element: PageElement
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var aiSettings: AISettingsStore
    @EnvironmentObject private var suggestionCoordinator: WritingSuggestionCoordinator
    @StateObject private var editorController = RichTextEditingController()
    @State private var editorAttributedText: NSAttributedString
    @State private var didFinish = false
    @State private var showingSuggestionReview = false
    @State private var opensReviewWhenReady = false
    @State private var undoAttributedText: NSAttributedString?

    init(element: PageElement, onDone: @escaping () -> Void) {
        self.element = element
        self.onDone = onDone
        _editorAttributedText = State(initialValue: element.resolvedRichText(forFallbackText: element.text ?? ""))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                formattingToolbar

                RichTextEditorView(
                    attributedText: $editorAttributedText,
                    controller: editorController,
                    defaultAttributes: element.defaultTextAttributes,
                    fallbackAlignment: element.alignment,
                    autoFocus: true,
                    onActivity: handleEditorActivity
                )
                .frame(maxHeight: .infinity)
                .background(Color(.secondarySystemBackground))
            }
            .navigationTitle(element.type == .stickyNote ? "Sticky Note" : "Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        finish()
                        dismiss()
                    }.bold()
                }
            }
            .onAppear {
                suggestionCoordinator.dismiss()
                editorController.configure(
                    defaultAttributes: element.defaultTextAttributes,
                    fallbackAlignment: element.alignment
                )
            }
            .onDisappear {
                suggestionCoordinator.dismiss()
                finish()
            }
            .onChange(of: suggestionCoordinator.suggestion) { _, suggestion in
                if suggestion != nil, opensReviewWhenReady {
                    showingSuggestionReview = true
                    opensReviewWhenReady = false
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if suggestionCoordinator.isLoading || suggestionCoordinator.suggestion != nil || undoAttributedText != nil {
                    Button {
                        showingSuggestionReview = suggestionCoordinator.suggestion != nil || undoAttributedText != nil
                    } label: {
                        if suggestionCoordinator.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: suggestionCoordinator.suggestion == nil ? "arrow.uturn.backward" : "sparkles")
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor, in: Circle())
                    .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
                    .padding(16)
                    .accessibilityLabel(suggestionCoordinator.isLoading ? "Checking writing" : "Review writing suggestion")
                }
            }
            .popover(isPresented: $showingSuggestionReview) {
                suggestionReview
                    .frame(idealWidth: 380)
                    .presentationCompactAdaptation(.sheet)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private var formattingToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Stepper(value: Binding(
                    get: { Double(editorController.currentFontSize) },
                    set: { editorController.setFontSize(CGFloat($0)) }
                ), in: 8...72, step: 1) {
                    Text("\(Int(editorController.currentFontSize.rounded()))pt")
                        .font(.caption.monospacedDigit())
                }

                Divider().frame(height: 24)

                formatButton("bold", isActive: editorController.isBoldActive) {
                    editorController.toggleBold()
                }
                formatButton("italic", isActive: editorController.isItalicActive) {
                    editorController.toggleItalic()
                }
                formatButton("underline", isActive: editorController.isUnderlineActive) {
                    editorController.toggleUnderline()
                }

                Divider().frame(height: 24)

                ForEach(TextAlign.allCases, id: \.self) { align in
                    formatButton(align.icon, isActive: editorController.alignment == align) {
                        editorController.setAlignment(align)
                    }
                }

                Divider().frame(height: 24)

                Menu {
                    ForEach(WritingSuggestionMode.allCases, id: \.self) { mode in
                        Button(mode.label, systemImage: writingModeIcon(mode)) {
                            requestSuggestion(mode: mode, automatic: false)
                        }
                    }
                } label: {
                    Image(systemName: "sparkles")
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel("Writing actions")

                if element.type == .stickyNote {
                    Divider().frame(height: 24)
                    ForEach(["FFE066", "FF9999", "99FF99", "9999FF", "FF99FF", "FFFFFF"], id: \.self) { hex in
                        Button { element.colorHex = hex } label: {
                            Circle()
                                .fill(Color(hex: hex) ?? .white)
                                .frame(width: 24, height: 24)
                                .overlay(Circle().stroke(element.colorHex == hex ? Color.accentColor : .clear, lineWidth: 2))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Sticky color \(hex)")
                        .accessibilityAddTraits(element.colorHex == hex ? .isSelected : [])
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private func formatButton(_ systemName: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 30, height: 30)
                .foregroundStyle(isActive ? .white : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? Color.accentColor : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private var suggestionReview: some View {
        NavigationStack {
            ScrollView {
                if let suggestion = suggestionCoordinator.suggestion {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Original").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(suggestion.originalText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Proposed").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(suggestion.replacementText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let notice = suggestionCoordinator.notice {
                            Label(notice, systemImage: "iphone")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle(suggestionCoordinator.suggestion?.mode.label ?? "Writing Suggestion")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button("Replace Paragraph", systemImage: "arrow.triangle.2.circlepath") {
                        applySuggestion(insertBelow: false)
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    Button("Insert Below", systemImage: "arrow.down.to.line") {
                        applySuggestion(insertBelow: true)
                    }
                    .buttonStyle(.bordered)
                    HStack {
                        Button("Dismiss") {
                            suggestionCoordinator.dismiss()
                            showingSuggestionReview = false
                        }
                        Spacer()
                        Button("Undo", systemImage: "arrow.uturn.backward") { undoSuggestion() }
                            .disabled(undoAttributedText == nil)
                    }
                }
                .padding(12)
                .background(.bar)
            }
        }
    }

    private func handleEditorActivity(_ text: NSAttributedString, _ selectedRange: NSRange, _ hasMarkedText: Bool) {
        guard aiSettings.automaticWritingSuggestions, !hasMarkedText else {
            if hasMarkedText { suggestionCoordinator.dismiss() }
            return
        }
        guard let paragraph = paragraph(in: text, around: selectedRange), paragraph.text.count >= 40 else {
            suggestionCoordinator.dismiss()
            return
        }
        suggestionCoordinator.request(
            text: paragraph.text,
            range: paragraph.range,
            mode: .improveClarity,
            automatic: true
        )
    }

    private func requestSuggestion(mode: WritingSuggestionMode, automatic: Bool) {
        let current = editorController.currentAttributedText ?? editorAttributedText
        guard let paragraph = paragraph(in: current, around: editorController.selectedRange) else { return }
        opensReviewWhenReady = !automatic
        suggestionCoordinator.request(
            text: paragraph.text,
            range: paragraph.range,
            mode: mode,
            automatic: automatic,
            debounce: automatic ? .seconds(1.5) : .zero
        )
    }

    private func paragraph(in text: NSAttributedString, around selectedRange: NSRange) -> (range: NSRange, text: String)? {
        let string = text.string as NSString
        guard string.length > 0 else { return nil }
        let location = min(max(selectedRange.location, 0), string.length - 1)
        let paragraphRange = string.paragraphRange(for: NSRange(location: location, length: min(selectedRange.length, string.length - location)))
        let raw = string.substring(with: paragraphRange) as NSString
        let value = (raw as String).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let contentRange = raw.range(of: value)
        let range = NSRange(location: paragraphRange.location + contentRange.location, length: contentRange.length)
        return (range, value)
    }

    private func applySuggestion(insertBelow: Bool) {
        guard let suggestion = suggestionCoordinator.suggestion else { return }
        let current = editorController.currentAttributedText ?? editorAttributedText
        undoAttributedText = current
        if insertBelow {
            let mutable = NSMutableAttributedString(attributedString: current)
            let insertionLocation = min(NSMaxRange(suggestion.sourceRange), mutable.length)
            let attributes = mutable.length > 0
                ? mutable.attributes(at: min(max(0, insertionLocation - 1), mutable.length - 1), effectiveRange: nil)
                : element.defaultTextAttributes
            mutable.insert(NSAttributedString(string: "\n\(suggestion.replacementText)", attributes: attributes), at: insertionLocation)
            editorAttributedText = mutable
        } else {
            editorAttributedText = WritingSuggestionCoordinator.replacingText(in: current, with: suggestion)
        }
        suggestionCoordinator.dismiss()
        showingSuggestionReview = false
    }

    private func undoSuggestion() {
        guard let undoAttributedText else { return }
        editorAttributedText = undoAttributedText
        self.undoAttributedText = nil
        showingSuggestionReview = false
    }

    private func writingModeIcon(_ mode: WritingSuggestionMode) -> String {
        switch mode {
        case .improveClarity: return "text.badge.checkmark"
        case .makeConcise: return "text.redaction"
        case .explain: return "lightbulb"
        case .outline: return "list.bullet.indent"
        case .continueWriting: return "text.append"
        }
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        commitRichText()
        onDone()
    }

    private func commitRichText() {
        let finalText = editorController.currentAttributedText ?? editorAttributedText
        let normalized = NSMutableAttributedString(attributedString: finalText)
        element.text = normalized.string
        element.richTextData = normalized.length == 0 ? nil : PageElement.encodeRichText(normalized)
        updateElementFallbackFormatting(from: normalized)
    }

    private func updateElementFallbackFormatting(from attributedText: NSAttributedString) {
        guard attributedText.length > 0 else {
            element.fontSize = Double(editorController.currentFontSize)
            element.isBold = editorController.isBoldActive
            element.isItalic = editorController.isItalicActive
            element.isUnderline = editorController.isUnderlineActive
            element.textAlignment = editorController.alignment.rawValue
            return
        }

        let attrs = attributedText.attributes(at: 0, effectiveRange: nil)
        if let font = attrs[.font] as? UIFont {
            element.fontSize = Double(font.pointSize)
            let traits = font.fontDescriptor.symbolicTraits
            element.isBold = traits.contains(.traitBold)
            element.isItalic = traits.contains(.traitItalic)
        }
        element.isUnderline = RichTextEditingController.hasUnderline(attrs[.underlineStyle])
        if let paragraph = attrs[.paragraphStyle] as? NSParagraphStyle {
            element.textAlignment = TextAlign(nsTextAlignment: paragraph.alignment).rawValue
        }
    }
}

@MainActor
private final class RichTextEditingController: ObservableObject {
    @Published var currentFontSize: CGFloat = 16
    @Published var isBoldActive = false
    @Published var isItalicActive = false
    @Published var isUnderlineActive = false
    @Published var alignment: TextAlign = .leading

    weak var textView: UITextView?
    var onTextChange: ((NSAttributedString) -> Void)?

    private var defaultAttributes: [NSAttributedString.Key: Any] = [:]
    private var isConfigured = false

    var currentAttributedText: NSAttributedString? {
        textView?.attributedText
    }

    var selectedRange: NSRange {
        textView?.selectedRange ?? NSRange(location: 0, length: 0)
    }

    func configure(defaultAttributes: [NSAttributedString.Key: Any], fallbackAlignment: TextAlign) {
        self.defaultAttributes = defaultAttributes
        guard !isConfigured else { return }
        isConfigured = true
        alignment = fallbackAlignment
        if let font = defaultAttributes[.font] as? UIFont {
            currentFontSize = font.pointSize
            let traits = font.fontDescriptor.symbolicTraits
            isBoldActive = traits.contains(.traitBold)
            isItalicActive = traits.contains(.traitItalic)
        }
        isUnderlineActive = Self.hasUnderline(defaultAttributes[.underlineStyle])
    }

    func attach(_ textView: UITextView) {
        self.textView = textView
        if textView.typingAttributes.isEmpty {
            textView.typingAttributes = defaultAttributes
        }
        refreshSelectionState(from: textView)
    }

    func refreshSelectionState(from textView: UITextView? = nil) {
        guard let textView = textView ?? self.textView else { return }
        let attrs = effectiveAttributes(in: textView)
        let font = font(from: attrs)
        assignIfChanged(&currentFontSize, font.pointSize)
        let traits = font.fontDescriptor.symbolicTraits
        assignIfChanged(&isBoldActive, traits.contains(.traitBold))
        assignIfChanged(&isItalicActive, traits.contains(.traitItalic))
        assignIfChanged(&isUnderlineActive, Self.hasUnderline(attrs[.underlineStyle]))

        if let paragraph = attrs[.paragraphStyle] as? NSParagraphStyle {
            assignIfChanged(&alignment, TextAlign(nsTextAlignment: paragraph.alignment))
        }
    }

    func setFontSize(_ size: CGFloat) {
        let clamped = min(max(size, 8), 72)
        applyFontTransform { font in
            UIFont(descriptor: font.fontDescriptor, size: clamped)
        }
        assignIfChanged(&currentFontSize, clamped)
    }

    func toggleBold() {
        let enabled = !isBoldActive
        applyFontTransform { [weak self] font in
            self?.font(font, setting: .traitBold, enabled: enabled) ?? font
        }
        assignIfChanged(&isBoldActive, enabled)
    }

    func toggleItalic() {
        let enabled = !isItalicActive
        applyFontTransform { [weak self] font in
            self?.font(font, setting: .traitItalic, enabled: enabled) ?? font
        }
        assignIfChanged(&isItalicActive, enabled)
    }

    func toggleUnderline() {
        let enabled = !isUnderlineActive
        applyAttributeToSelectedText { attrs in
            if enabled {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            } else {
                attrs.removeValue(forKey: .underlineStyle)
            }
        }
        assignIfChanged(&isUnderlineActive, enabled)
    }

    func setAlignment(_ align: TextAlign) {
        guard let textView else { return }
        let source = textView.attributedText ?? NSAttributedString()
        let selected = clampedRange(textView.selectedRange, length: source.length)
        let target = paragraphRange(for: selected, in: source.string as NSString)

        guard target.length > 0 else {
            updateTypingAttributes { attrs in
                let paragraph = paragraphStyle(from: attrs)
                paragraph.alignment = align.nsTextAlignment
                attrs[.paragraphStyle] = paragraph
            }
            assignIfChanged(&alignment, align)
            return
        }

        let mutable = NSMutableAttributedString(attributedString: source)
        mutable.enumerateAttribute(.paragraphStyle, in: target, options: []) { value, range, _ in
            let paragraph = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? paragraphStyle(from: defaultAttributes)
            paragraph.alignment = align.nsTextAlignment
            mutable.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
        replaceText(in: textView, with: mutable, selectedRange: selected)
        assignIfChanged(&alignment, align)
    }

    static func hasUnderline(_ value: Any?) -> Bool {
        if let value = value as? Int { return value != 0 }
        if let value = value as? NSNumber { return value.intValue != 0 }
        return false
    }

    private func applyFontTransform(_ transform: (UIFont) -> UIFont) {
        applyAttributeToSelectedText { attrs in
            attrs[.font] = transform(font(from: attrs))
        }
    }

    private func applyAttributeToSelectedText(_ mutate: (inout [NSAttributedString.Key: Any]) -> Void) {
        guard let textView else { return }
        let source = textView.attributedText ?? NSAttributedString()
        let selected = clampedRange(textView.selectedRange, length: source.length)

        guard selected.length > 0 else {
            updateTypingAttributes { attrs in
                mutate(&attrs)
            }
            return
        }

        let mutable = NSMutableAttributedString(attributedString: source)
        mutable.enumerateAttributes(in: selected, options: []) { attrs, range, _ in
            var updated = mergedAttributes(attrs)
            mutate(&updated)
            mutable.setAttributes(updated, range: range)
        }
        replaceText(in: textView, with: mutable, selectedRange: selected)
    }

    private func updateTypingAttributes(_ mutate: (inout [NSAttributedString.Key: Any]) -> Void) {
        guard let textView else { return }
        var attrs = mergedAttributes(textView.typingAttributes)
        mutate(&attrs)
        textView.typingAttributes = attrs
        refreshSelectionState(from: textView)
    }

    private func replaceText(in textView: UITextView, with attributedText: NSAttributedString, selectedRange: NSRange) {
        textView.attributedText = attributedText
        textView.selectedRange = clampedRange(selectedRange, length: attributedText.length)
        textView.typingAttributes = mergedAttributes(effectiveAttributes(in: textView))
        publishChange(from: textView)
    }

    private func publishChange(from textView: UITextView) {
        onTextChange?(textView.attributedText ?? NSAttributedString())
        refreshSelectionState(from: textView)
    }

    private func effectiveAttributes(in textView: UITextView) -> [NSAttributedString.Key: Any] {
        let attributedText = textView.attributedText ?? NSAttributedString()
        var attrs = mergedAttributes(textView.typingAttributes)
        guard attributedText.length > 0 else { return attrs }

        let selected = clampedRange(textView.selectedRange, length: attributedText.length)
        let location: Int
        if selected.length > 0 {
            location = min(selected.location, attributedText.length - 1)
        } else if selected.location > 0 {
            location = min(selected.location - 1, attributedText.length - 1)
        } else {
            location = 0
        }

        for (key, value) in attributedText.attributes(at: location, effectiveRange: nil) {
            attrs[key] = value
        }
        return attrs
    }

    private func mergedAttributes(_ attrs: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var merged = defaultAttributes
        for (key, value) in attrs {
            merged[key] = value
        }
        return merged
    }

    private func font(from attrs: [NSAttributedString.Key: Any]) -> UIFont {
        attrs[.font] as? UIFont
            ?? defaultAttributes[.font] as? UIFont
            ?? UIFont.systemFont(ofSize: currentFontSize)
    }

    private func font(_ font: UIFont, setting trait: UIFontDescriptor.SymbolicTraits, enabled: Bool) -> UIFont {
        var traits = font.fontDescriptor.symbolicTraits
        if enabled {
            traits.insert(trait)
        } else {
            traits.remove(trait)
        }
        if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
            return UIFont(descriptor: descriptor, size: font.pointSize)
        }

        var fallback = UIFont.systemFont(ofSize: font.pointSize, weight: traits.contains(.traitBold) ? .bold : .regular)
        if traits.contains(.traitItalic) {
            var fallbackTraits = fallback.fontDescriptor.symbolicTraits
            fallbackTraits.insert(.traitItalic)
            if let descriptor = fallback.fontDescriptor.withSymbolicTraits(fallbackTraits) {
                fallback = UIFont(descriptor: descriptor, size: font.pointSize)
            }
        }
        return fallback
    }

    private func paragraphStyle(from attrs: [NSAttributedString.Key: Any]) -> NSMutableParagraphStyle {
        (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
            ?? (defaultAttributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
            ?? NSMutableParagraphStyle()
    }

    private func paragraphRange(for selectedRange: NSRange, in string: NSString) -> NSRange {
        guard string.length > 0 else { return NSRange(location: 0, length: 0) }
        let selected = clampedRange(selectedRange, length: string.length)
        if selected.length == 0 {
            return string.paragraphRange(for: NSRange(location: min(selected.location, string.length - 1), length: 0))
        }
        return string.paragraphRange(for: selected)
    }

    private func clampedRange(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        let availableLength = max(0, length - location)
        return NSRange(location: location, length: min(max(range.length, 0), availableLength))
    }

    private func assignIfChanged<T: Equatable>(_ value: inout T, _ newValue: T) {
        if value != newValue {
            value = newValue
        }
    }
}

private struct RichTextEditorView: UIViewRepresentable {
    @Binding var attributedText: NSAttributedString
    @ObservedObject var controller: RichTextEditingController
    let defaultAttributes: [NSAttributedString.Key: Any]
    let fallbackAlignment: TextAlign
    let autoFocus: Bool
    let onActivity: (NSAttributedString, NSRange, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.alwaysBounceVertical = true
        textView.isScrollEnabled = true
        textView.keyboardDismissMode = .interactive
        textView.allowsEditingTextAttributes = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        textView.attributedText = attributedText
        textView.typingAttributes = defaultAttributes
        controller.configure(defaultAttributes: defaultAttributes, fallbackAlignment: fallbackAlignment)
        controller.attach(textView)
        installControllerCallback(context.coordinator)
        focusIfNeeded(textView, coordinator: context.coordinator)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        controller.configure(defaultAttributes: defaultAttributes, fallbackAlignment: fallbackAlignment)
        controller.attach(uiView)
        installControllerCallback(context.coordinator)
        if !uiView.attributedText.isEqual(attributedText) {
            let selected = uiView.selectedRange
            uiView.attributedText = attributedText
            uiView.selectedRange = clampedRange(selected, length: attributedText.length)
        }
        focusIfNeeded(uiView, coordinator: context.coordinator)
    }

    private func installControllerCallback(_ coordinator: Coordinator) {
        controller.onTextChange = { [weak coordinator] attributedText in
            coordinator?.applyControllerChange(attributedText)
        }
    }

    private func focusIfNeeded(_ textView: UITextView, coordinator: Coordinator) {
        guard autoFocus, !coordinator.didFocus else { return }
        DispatchQueue.main.async {
            guard !coordinator.didFocus else { return }
            textView.becomeFirstResponder()
            coordinator.didFocus = true
        }
    }

    private func clampedRange(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        let availableLength = max(0, length - location)
        return NSRange(location: location, length: min(max(range.length, 0), availableLength))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichTextEditorView
        var didFocus = false

        init(parent: RichTextEditorView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.attributedText = textView.attributedText ?? NSAttributedString()
            parent.controller.refreshSelectionState(from: textView)
            parent.onActivity(
                textView.attributedText ?? NSAttributedString(),
                textView.selectedRange,
                textView.markedTextRange != nil
            )
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.controller.refreshSelectionState(from: textView)
        }

        func applyControllerChange(_ attributedText: NSAttributedString) {
            parent.attributedText = attributedText
        }
    }
}

// MARK: - Page Style Sheet

struct PageStyleSheet: View {
    @Bindable var page: Page
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var didFinish = false

    private let bgColors: [String] = [
        "FFFFFF", "F7F4E9", "E8F0FE", "FDE8F0", "E8F8E8", "FFF3E0", "F0E8FD", "1C1C1E"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Background Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        ForEach(bgColors, id: \.self) { hex in
                            Button { page.backgroundHex = hex } label: {
                                Circle()
                                    .fill(Color(hex: hex) ?? .white)
                                    .frame(width: 40, height: 40)
                                    .overlay(Circle().stroke(.white.opacity(page.backgroundHex == hex ? 0.9 : 0.2), lineWidth: page.backgroundHex == hex ? 4 : 1))
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Page background \(hex)")
                            .accessibilityAddTraits(page.backgroundHex == hex ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 6)
                    ColorPicker("Custom Color", selection: Binding(
                        get: { Color(hex: page.backgroundHex) ?? .white },
                        set: { page.backgroundHex = $0.hexString }
                    ), supportsOpacity: false)

                    // Ink colors are deliberately fixed (non-dynamic) so they
                    // never flip in dark mode, which means dark paper hides
                    // dark ink. Warn instead of silently producing a page the
                    // user cannot write on.
                    if ColorLuminance.isDarkPaper(page.backgroundHex) {
                        Label(
                            "Dark paper hides dark ink. Pick a light ink color from the toolbar before writing.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("dark-paper-warning")
                    }
                }
                Section("Line Style") {
                    PageTemplatePicker(
                        selection: Binding(
                            get: { page.lines },
                            set: { page.lineStyle = $0.rawValue }
                        ),
                        backgroundHex: page.backgroundHex,
                        orientation: page.pageOrientation
                    )
                }
                if let notebook = page.notebook {
                    Section("Notebook Default") {
                        Button("Use \(page.lines.label) as notebook default", systemImage: "bookmark") {
                            notebook.defaultLineStyle = page.lineStyle
                            notebook.defaultBackgroundHex = page.backgroundHex
                            notebook.defaultOrientation = page.orientation
                        }
                    }
                }
                Section("Orientation") {
                    Picker("Orientation", selection: Binding(
                        get: { page.pageOrientation },
                        set: { page.orientation = $0.rawValue }
                    )) {
                        ForEach(PageOrientation.allCases, id: \.self) { o in
                            Label(o.label, systemImage: o.icon).tag(o)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Page Style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        finish()
                        dismiss()
                    }
                    .bold()
                }
            }
            .onDisappear { finish() }
        }
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        onDone()
    }
}

private enum ImageImportError: LocalizedError {
    case unreadableImage

    var errorDescription: String? {
        "The selected image could not be read."
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct DocumentScannerView: UIViewControllerRepresentable {
    var onComplete: ([UIImage]) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onComplete: ([UIImage]) -> Void
        let onCancel: () -> Void

        init(onComplete: @escaping ([UIImage]) -> Void, onCancel: @escaping () -> Void) {
            self.onComplete = onComplete
            self.onCancel = onCancel
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onComplete((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onCancel()
        }
    }
}

struct AIProviderSettingsSheet: View {
    @ObservedObject var service: AIService
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var model = ""
    @State private var errorMessage: String?
    @State private var connectionStatus: String?
    @State private var isTestingConnection = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    TextField("Base URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Model", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(service.isRemoteConfigured ? "API key saved - enter to replace" : "API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        testConnection()
                    } label: {
                        if isTestingConnection {
                            HStack { ProgressView(); Text("Testing Connection") }
                        } else {
                            Label("Test Connection", systemImage: "network")
                        }
                    }
                    .disabled(isTestingConnection)
                }

                Section {
                    Label(
                        service.isRemoteConfigured ? "Remote AI enabled" : "On-device assistance enabled",
                        systemImage: service.isRemoteConfigured ? "checkmark.shield" : "iphone"
                    )
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                    if let connectionStatus {
                        Text(connectionStatus).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Only passages selected for an explicit assistant or search request are sent. Automatic suggestions send only the active paragraph after you opt in. The key is stored in this device's Keychain.")
                }

                if service.isRemoteConfigured {
                    Section {
                        Button("Use On-Device Assistance Only", role: .destructive) {
                            service.clearConfiguration()
                            apiKey = ""
                        }
                    }
                }
            }
            .navigationTitle("AI Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }.bold()
                }
            }
            .onAppear {
                baseURL = service.configuredBaseURL
                model = service.configuredModel
            }
        }
    }

    private func save() {
        do {
            try service.updateConfiguration(
                apiKey: apiKey.isEmpty ? nil : apiKey,
                baseURL: baseURL,
                model: model
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func testConnection() {
        do {
            try service.updateConfiguration(
                apiKey: apiKey.isEmpty ? nil : apiKey,
                baseURL: baseURL,
                model: model
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard let configuration = service.settingsStore.configuration else {
            errorMessage = "Enter and save an API key before testing."
            return
        }
        errorMessage = nil
        connectionStatus = nil
        isTestingConnection = true
        Task {
            do {
                try await service.client.testConnection(configuration: configuration)
                connectionStatus = "Connection succeeded."
            } catch {
                errorMessage = error.localizedDescription
            }
            isTestingConnection = false
        }
    }
}
