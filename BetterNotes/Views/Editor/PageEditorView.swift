import SwiftUI
import PhotosUI
import PencilKit
import SwiftData
import AVFAudio
import VisionKit
import UIKit

private enum FingerElementControl: Equatable {
    case move
    case resizeLeading
    case resizeTrailing
    case rotate
    /// The play button of an audio recording, which has no drag of its own.
    case audioPlay
}

private struct FingerDragSession {
    let pageID: PersistentIdentifier
    let elementID: PersistentIdentifier
    let control: FingerElementControl
    let start: CGPoint
    let baseX: Double
    let baseY: Double
    let baseWidth: Double
    let baseHeight: Double
    let baseRotation: Double
    var didRecordMutation = false
}

/// Reference box for the drawing `setCanvasDrawing` has queued but not yet
/// applied. A class so recording it never invalidates the view.
private final class PendingCanvasDrawing {
    var drawing: PKDrawing?
    var generation = 0
}

struct PageEditorView: View {
    private static let selectionPasteboardType = "com.betternotes.selection.v1"
    private static let selectionPasteboardName = UIPasteboard.Name("com.betternotes.selection")

    @Bindable var page: Page
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
    /// True on the last page of an editable notebook in single-page mode.
    var canPullToAddPage = false
    // Vertical scroll mode zooms the whole multi-page document as one unit
    // (see NotebookView.verticalScrollContent) instead of letting each page
    // run its own independent pinch-to-zoom UIScrollView -- that per-page
    // zoom was the bug: pinching one page turned it into its own isolated
    // zoomable island rather than scaling the coherent document. When false,
    // this view renders its content at a fixed size and leaves zooming
    // (and the page-swipe/blank-canvas-paste gestures that live on
    // ZoomablePageView) to the caller.
    var usesOwnZoomContainer = true

    @Environment(\.modelContext) private var context
    @EnvironmentObject private var inkAnswers: InkAnswerCoordinator
    @EnvironmentObject private var aiSettings: AISettingsStore
    @AppStorage(AppPreferenceKey.allowsFingerDrawing) private var allowsFingerDrawing = false
    @AppStorage(AppPreferenceKey.assistantEnabled) private var assistantEnabled = true
    @AppStorage(AppPreferenceKey.inkQuestionsEnabled) private var inkQuestionsEnabled = true

    @State private var canvas: PKCanvasView = PencilInputCanvasView()

    @State private var selectedElementID: PersistentIdentifier?
    @State private var fingerDragSession: FingerDragSession?
    @State private var fingerElementDraft: FingerElementDraft?
    @StateObject private var history = PageHistory()

    /// Shared selection for ink strokes and page elements.
    @State private var selectionState = SelectionState()
    @State private var lockedExcludedElementIDs: Set<PersistentIdentifier> = []

    /// The element currently being written into by the assistant.
    @State private var answeringElementID: PersistentIdentifier?
    @State private var isPreparingInkQuestion = false
    /// A handwritten question the OCR pass spotted, waiting to be accepted.
    @State private var detectedInkQuestion: InkQuestion?
    @State private var editingAssistantQuestion: PageElement?
    @State private var assistantQuestionDraft = ""
    /// Questions already offered or answered, so the 1 s OCR debounce cannot
    /// keep re-offering the same sentence every time a stroke lands near it.
    @State private var handledQuestionFingerprints: Set<Int> = []

    @State private var showingImagePicker = false
    @State private var showingDocumentScanner = false
    @State private var photoItem: PhotosPickerItem?
    @State private var editingTextElement: PageElement?
    @State private var editingTapeElement: PageElement?
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
    @State private var handwritingOCRTask: Task<Void, Never>?
    @State private var lastRecognizedInkData: Data?
    @State private var loadedPage: Page?
    @State private var saveError: String?
    @State private var hasSaveFailure = false
    @State private var noticeTask: Task<Void, Never>?
    @State private var isSwitchingPages = false
    /// Guards against re-entry into onDrawingChanged when we programmatically
    /// set canvas.drawing (undo/redo apply, paste, delete, transform).
    /// Without this, each programmatic assignment triggers canvasViewDrawingDidChange
    /// → onDrawingChanged, causing double history entries, redundant OCR, and
    /// selection flicker.
    @State private var isApplyingProgrammaticChange = false
    @State private var pendingCanvasDrawing = PendingCanvasDrawing()
    @State private var pageSlideOffset: CGFloat = 0
    /// Points the finger has pulled the last page to the left.
    @State private var addPagePull: CGFloat = 0
    @State private var pageAreaWidth: CGFloat = 0
    @State private var isUsingInkTool = false
    @State private var heldShapePreview: PKDrawing?
    @State private var isTransformingInkSelection = false

    /// Ink lifted out of the PencilKit canvas for the duration of a drag.
    ///
    /// Routing a live transform through PencilKit means the ink is repainted
    /// asynchronously, a frame or two after the SwiftUI selection outline has
    /// already moved -- measured at only 0.36ms of work per frame, so this is
    /// presentation latency, not cost, and shaving the per-frame work cannot
    /// close it. Instead the selected strokes leave the canvas once when the
    /// drag starts and are drawn in an overlay, which the same SwiftUI
    /// transaction that moves the outline also transforms. Ink and outline are
    /// then updated together by construction. Real stroke geometry is written
    /// back once, on release.
    @State private var liftedInk: LiftedInk?

    struct LiftedInk {
        /// The lifted strokes, still in their pre-gesture geometry.
        let drawing: PKDrawing
        /// Where each lifted stroke sat in the canvas. Ascending, so committing
        /// can reinsert them in place and preserve stacking order.
        let indices: [Int]
        /// Bumped only when the lifted set changes, so the overlay can skip
        /// re-assigning (and so re-rendering) an unchanged drawing every frame.
        let generation: Int
        /// Accumulated transform for this gesture.
        var transform: CGAffineTransform = .identity
    }

    @State private var liftedInkGeneration = 0
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

    /// Known finger touches inside these regions go to the SwiftUI elements
    /// beneath PencilKit. A canvas-level finger pan handles touches for which
    /// UIKit did not supply a touch type during hit testing.
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
        editorAlerts
    }

    private var editorSurface: some View {
        VStack(spacing: 0) {
            ZStack {
                Group {
                    if usesOwnZoomContainer {
                        ZoomablePageView(
                            pageSize: page.pageOrientation.size,
                            // When finger drawing is off, one finger can pan
                            // blank page areas. If finger drawing is on, or
                            // the rectangular lasso is active, two fingers are
                            // reserved for page panning.
                            panRequiresTwoFingers: pagePanRequiresTwoFingers,
                            onPageSwipe: onPageSwipe,
                            canPullToAddPage: canPullToAddPage,
                            onPullToAddPage: handleAddPagePull,
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
                            pageContent
                        }
                    } else {
                        pageContent
                    }
                }
                .offset(x: pageSlideOffset - Self.rubberBand(addPagePull))
                // Drawn behind the page, which slides aside to reveal it.
                .background(alignment: .trailing) {
                    if addPagePull > 0 {
                        AddPagePullIndicator(
                            progress: addPagePull / Self.addPageThreshold,
                            revealedWidth: Self.rubberBand(addPagePull)
                        )
                    }
                }
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
                        HStack {
                            RecordingBar(
                                elapsed: audio.elapsed,
                                onStop: { finishRecording(save: true) },
                                onCancel: { finishRecording(save: false) }
                            )
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 16)
                        .padding(.bottom, recordingBottomInset)
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

                if hasSaveFailure {
                    VStack {
                        HStack {
                            Spacer()
                            SaveFailureView(onRetry: { _ = saveChanges() })
                        }
                        Spacer()
                    }
                    .padding(12)
                    .zIndex(72)
                }

            }
            .background(Color(.systemGroupedBackground))
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .overlay(alignment: .bottom) {
            if !selectionState.isEmpty, !isReadOnly {
                SelectionContextBar(
                    canAsk: canAskAboutSelection,
                    onAsk: askAboutSelection,
                    canPaste: clipboardPayload() != nil,
                    canLock: !selectionState.elementIDs.isEmpty,
                    canBringForward: canMoveSelectionElements(forward: true),
                    canSendBackward: canMoveSelectionElements(forward: false),
                    canCustomizeTape: customizableSelectedTape != nil,
                    onCut: cutSelection,
                    onCopy: copySelection,
                    onPaste: pasteSelection,
                    onDuplicate: duplicateSelection,
                    onDelete: deleteSelection,
                    onLock: lockSelection,
                    onBringForward: { moveSelectionElements(forward: true) },
                    onSendBackward: { moveSelectionElements(forward: false) },
                    onCustomizeTape: { editingTapeElement = customizableSelectedTape }
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
                    onCustomizeTape: { editingTapeElement = selectedElement },
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
    }

    private var editorLifecycle: some View {
        editorSurface
        .onAppear {
            canUndo = history.canUndo
            canRedo = history.canRedo
            // The array's order is the canvas stacking order, and SwiftData
            // does not preserve it. Restore it before anything reads it.
            page.restoreElementOrder()
            #if DEBUG
            seedImageForControlTestIfRequested()
            #endif
            settleInterruptedAnswers()
            if canvas.drawing.strokes.isEmpty {
                loadInk(from: page)
            }
            loadedPage = page
            lastRecognizedInkData = page.ocrUpdatedAt == nil ? nil : page.inkData
            visiblePageCenter = CGPoint(x: page.pageOrientation.size.width / 2, y: page.pageOrientation.size.height / 2)
            lastRecordedStrokeCount = canvas.drawing.strokes.count
            if !canvas.drawing.strokes.isEmpty && page.ocrText.isEmpty {
                scheduleHandwritingOCR(offersQuestions: false)
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
            updateSelectedElement(id)
        }
        .onChange(of: command) { _, newCommand in
            execute(newCommand)
        }
        .onReceive(history.$revision) { _ in
            canUndo = history.canUndo
            canRedo = history.canRedo
        }
        .onDisappear {
            fingerDragSession = nil
            fingerElementDraft = nil
            canReplaceSelectedText = false
            commitLiftedInk()
            canvasCoordinator.coordinator?.cancelShapeRecognition()
            heldShapePreview = nil
            handwritingOCRTask?.cancel()
            stopStreamingAnswer()
            detectedInkQuestion = nil
            transcriptionTask?.cancel()
            transcriptionRequestID = nil
            audio.cancelTranscription()
            if recordingElement != nil {
                finishRecording(save: audio.isRecording)
            }
            audio.stopPlayback()
            persistInk()
            hasSaveFailure = false
        }
    }

    private var editorSheets: some View {
        editorLifecycle
        .sheet(item: $editingTextElement) { elem in
            TextEditSheet(element: elem) {
                selectedElementID = elem.id
                markPageModified()
                saveChanges()
            }
        }
        .sheet(item: $editingTapeElement) { element in
            TapeSettingsSheet(
                element: element,
                maxLength: min(600, page.pageOrientation.size.width - 48)
            ) { colorHex, length, height in
                saveTapeSettings(element, colorHex: colorHex, length: length, height: height)
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
        .sheet(item: $editingAssistantQuestion) { element in
            assistantQuestionSheet(for: element)
        }
    }

    private var editorAlerts: some View {
        editorSheets
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

    @ViewBuilder
    private var pageContent: some View {
        ZStack {
            PageBackground(
                backgroundHex: page.backgroundHex,
                lineStyle: page.lines,
                orientation: page.pageOrientation,
                lineThickness: page.effectiveLineThickness,
                lineOpacity: page.effectiveLineOpacity
            )
            .id("\(page.backgroundHex)-\(page.lineStyle)-\(page.orientation)-\(page.lineThickness)-\(page.lineOpacity)")
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
                onTapeEdit: { editingTapeElement = $0 },
                onDelete: { element in
                    deleteElement(element)
                },
                onDuplicate: { element in
                    duplicateElement(element)
                },
                onMutationBegan: beginElementMutation,
                onMutationEnded: finishElementMutation,
                onAssistantEdit: { element in
                    assistantQuestionDraft = element.assistantPayload?.question ?? ""
                    editingAssistantQuestion = element
                },
                fingerDraft: fingerElementDraft
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
                canBeginFingerElementDrag: { point in
                    fingerControl(at: point) != nil
                },
                onFingerElementDrag: handleFingerElementDrag,
                canPencilTapElement: { point in tape(at: point) != nil },
                onPencilTapElement: toggleTape(at:),
                inkData: page.inkData,
                canvasInkOpacity: heldShapePreview == nil ? 1 : 0.22,
                onDrawingChange: { _ in onDrawingChanged() },
                onToolUseChange: { isUsing in
                    isUsingInkTool = isUsing
                    // Starting to draw/erase clears element
                    // selection so resize handles disappear.
                    if isUsing {
                        if fingerDragSession == nil { clearSelection() }
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

            if let liftedInk {
                // `.transformEffect` is a geometry effect, so this
                // moves in the same SwiftUI transaction as the
                // selection outline -- the two cannot desync.
                LiftedInkOverlay(
                    drawing: liftedInk.drawing,
                    generation: liftedInk.generation
                )
                .frame(
                    width: page.pageOrientation.size.width,
                    height: page.pageOrientation.size.height
                )
                .transformEffect(liftedInk.transform)
                .allowsHitTesting(false)
            }

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

            if let question = detectedInkQuestion, !isReadOnly {
                InkQuestionPrompt(
                    question: question,
                    pageSize: page.pageOrientation.size,
                    onAccept: { beginInkAnswer(to: question) },
                    onDismiss: {
                        handledQuestionFingerprints.insert(question.fingerprint)
                        detectedInkQuestion = nil
                    }
                )
            }
        }
        .frame(width: page.pageOrientation.size.width, height: page.pageOrientation.size.height)
        .clipShape(Rectangle())
        .overlay(
            Rectangle()
                .stroke(Color.black.opacity(0.16), lineWidth: 1)
        )
    }

    private var recordingBottomInset: CGFloat {
        if horizontalSizeClass == .compact { return 108 }
        let spaceBesideToolbar = max((pageAreaWidth - toolbarObstruction.size.width) / 2, 0)
        return spaceBesideToolbar >= 290 ? 12 : 24 + toolbarObstruction.bottomClearance
    }

    private func updateSelectedElement(_ id: PersistentIdentifier?) {
        guard let id, let element = page.elements.first(where: { $0.id == id }) else {
            canReplaceSelectedText = false
            return
        }
        canReplaceSelectedText = element.modelContext != nil
            && (element.type == .textBox || element.type == .stickyNote)
        guard tool == .lasso, !selectionState.elementIDs.contains(id),
              element.modelContext != nil, !element.isLocked else { return }
        selectionState = SelectionState(strokeIndices: [], elementIDs: [id], bounds: elementSelectionBounds(element))
    }

    private func assistantQuestionSheet(for element: PageElement) -> some View {
        NavigationStack {
            Form {
                TextField("Question", text: $assistantQuestionDraft, axis: .vertical)
                    .lineLimit(2...5)
                Text("Check the recognized question before sending it again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Retry answer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { editingAssistantQuestion = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Retry") {
                        retryInkAnswer(element, question: assistantQuestionDraft)
                        editingAssistantQuestion = nil
                    }
                    .disabled(assistantQuestionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

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

    @discardableResult
    private func saveChanges() -> Bool {
        do {
            page.stampElementOrder()
            try context.save()
            NotificationCenter.default.post(name: .noteCorpusDidChange, object: nil)
            saveError = nil
            hasSaveFailure = false
            return true
        } catch {
            saveError = error.localizedDescription
            hasSaveFailure = true
            return false
        }
    }

    private func saveInk(to targetPage: Page?) {
        guard !isReadOnly else { return }
        // Guard against the page being deleted during teardown.
        // Accessing any property on a deleted SwiftData model can crash,
        // so check modelContext first (it becomes nil when deleted).
        guard let targetPage, targetPage.modelContext != nil else { return }
        targetPage.inkData = currentDrawing.dataRepresentation()
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
        fingerDragSession = nil
        fingerElementDraft = nil
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
        // Before saveInk below: lifted strokes are not in the canvas, so
        // saving without committing would write the page without them.
        commitLiftedInk()
        isTransformingInkSelection = false

        // Save the OLD page's ink BEFORE doing anything else. This must happen
        // before the canvas is touched, before loadedPage is reassigned, and
        // before SwiftUI can re-render PaperCanvas with new parameters.
        saveInk(to: loadedPage)
        // Persist immediately so a SwiftData refault can't lose the save.
        saveChanges()

        handwritingOCRTask?.cancel()
        // An answer still streaming belongs to the page being left. Let it
        // finish writing into the outgoing page and it lands on the incoming
        // one instead, which is the same failure `updateHandwritingOCR` guards.
        stopStreamingAnswer()
        detectedInkQuestion = nil
        handledQuestionFingerprints.removeAll()
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
        settleInterruptedAnswers()
        lastRecognizedInkData = page.ocrUpdatedAt == nil ? nil : incomingInk
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
            scheduleHandwritingOCR(offersQuestions: false)
        }
        animatePageSurfaceIn()
    }

    /// Finger travel needed to add a page, and the flick that counts as enough.
    private static let addPageThreshold: CGFloat = 140
    private static let addPageMinimumFlickDistance: CGFloat = 60

    /// The page follows the finger with resistance, and stops short of
    /// leaving the screen.
    private static func rubberBand(_ distance: CGFloat) -> CGFloat {
        min(max(distance, 0) * 0.6, 220)
    }

    private func handleAddPagePull(_ event: PageEdgePull) {
        guard canPullToAddPage, !isReadOnly else { return }
        switch event {
        case .changed(let distance):
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { addPagePull = distance }
        case .ended(let distance, let flick):
            let commits = distance >= Self.addPageThreshold
                || (flick && distance >= Self.addPageMinimumFlickDistance)
            if commits {
                // The page slides out with its current offset while the new
                // one slides in; this editor is replaced, so nothing resets.
                onPageSwipe(.next)
            } else {
                withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.8)) { addPagePull = 0 }
            }
        case .cancelled:
            withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.8)) { addPagePull = 0 }
        }
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
        guard saveChanges() else { return }
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
                    sources.append(NoteTextSource(title: AppLocalization.text("Audio Transcript"), text: transcript))
                }
            case .image:
                // Smart-imported images carry OCR-extracted text in `element.text`
                // so the page stays searchable without a visible text box.
                sources.append(NoteTextSource(title: AppLocalization.text("Image Text"), text: text))
            default:
                break
            }
        }

        let extractedText = page.ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extractedText.isEmpty {
            sources.append(NoteTextSource(title: AppLocalization.text("OCR and PDF Text"), text: extractedText))
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
        showNotice(AppLocalization.text("AI result added to the page"))
    }

    // MARK: Ask on the page

    /// Anything with words in it can be asked about: ink, or the text of a
    /// selected box, sticky note or smart-imported image.
    private var canAskAboutSelection: Bool {
        guard assistantEnabled, !isReadOnly, !isPreparingInkQuestion else { return false }
        if !selectionState.strokeIndices.isEmpty { return true }
        return page.elements.contains { element in
            selectionState.elementIDs.contains(element.id)
                && !(element.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Read the lassoed content as a question and answer it on the page.
    private func askAboutSelection() {
        guard canAskAboutSelection else { return }
        let bounds = selectionState.bounds
        let strokes = selectionState.strokeIndices.sorted().compactMap { index -> PKStroke? in
            guard canvas.drawing.strokes.indices.contains(index) else { return nil }
            return canvas.drawing.strokes[index]
        }
        let selectedText = page.elements
            .filter { selectionState.elementIDs.contains($0.id) && $0.type != .assistantNote }
            .compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let pageSize = page.pageOrientation.size
        let targetPageID = page.persistentModelID

        isPreparingInkQuestion = true
        Task { @MainActor in
            let recognized = strokes.isEmpty
                ? ""
                : await HandwritingOCR.recognizeText(from: PKDrawing(strokes: strokes), pageSize: pageSize)
            // The user can swipe pages while Vision is working; writing the
            // answer onto whatever page arrived next is the same class of bug
            // `updateHandwritingOCR` guards against.
            guard page.persistentModelID == targetPageID else {
                isPreparingInkQuestion = false
                return
            }
            isPreparingInkQuestion = false

            let question = ([recognized] + selectedText)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            guard !question.isEmpty else {
                showNotice(AppLocalization.text("Nothing readable in that selection"))
                return
            }
            beginInkAnswer(to: InkQuestion(text: question, bounds: bounds))
        }
    }

    /// Put an empty answer card on the page and start writing into it.
    ///
    /// The card appears before the first token arrives on purpose: the whole
    /// appeal of asking in ink is watching the reply land next to what you
    /// wrote, and a spinner somewhere else on screen is not that.
    private func beginInkAnswer(to question: InkQuestion) {
        guard !isReadOnly, assistantEnabled else { return }
        handledQuestionFingerprints.insert(question.fingerprint)
        detectedInkQuestion = nil
        clearSelection()

        let pageSize = page.pageOrientation.size
        let size = CGSize(
            width: min(max(pageSize.width * 0.42, 220), pageSize.width - AnswerPlacement.margin * 2),
            height: 150
        )
        let frame = AnswerPlacement.frame(
            for: size,
            near: question.bounds,
            avoiding: occupiedPageRects(),
            pageSize: pageSize
        )

        recordBeforeMutation()
        let element = PageElement(
            type: .assistantNote,
            x: frame.midX,
            y: frame.midY,
            width: frame.width,
            height: frame.height
        )
        element.text = ""
        element.fontSize = 16
        element.colorHex = "3C4A6B"
        element.assistantPayload = AssistantNotePayload(
            question: question.text,
            anchor: question.bounds.isNull ? frame.origin : CGPoint(x: question.bounds.midX, y: question.bounds.maxY),
            isStreaming: true
        )
        element.page = page
        context.insert(element)
        page.appendElement(element)
        selectedElementID = element.id
        answeringElementID = element.id
        // Elements were just added; without this the selection bounds can keep
        // ids that no longer describe what is on the page.
        refreshSelectionBounds()
        markPageModified()
        guard saveChanges() else {
            var payload = element.assistantPayload ?? AssistantNotePayload(question: question.text)
            payload.isStreaming = false
            payload.notice = "Couldn’t save this question. Retry after resolving the save error."
            payload.didFail = true
            element.assistantPayload = payload
            answeringElementID = nil
            return
        }

        let elementID = element.id
        // SwiftData can replace a newly inserted element's temporary ID when
        // save() assigns its permanent ID. The response callback and the
        // active-card guard must both use the post-save ID.
        selectedElementID = elementID
        answeringElementID = elementID
        inkAnswers.answer(
            question: question.text,
            notebookID: page.notebook?.stableID,
            pageID: page.stableID,
            pageContext: pageContextText(excluding: elementID),
            history: pageAnswerHistory(excluding: elementID),
            pageImage: aiSettings.sendsPageImages ? PDFExport.renderPageImage(page) : nil
        ) { update in
            applyInkAnswer(update, to: element)
        }
    }

    private func applyInkAnswer(_ update: InkAnswerCoordinator.Update, to element: PageElement) {
        guard answeringElementID == element.id else { return }
        let answerPage = loadedPage ?? page
        guard element.modelContext != nil, element.page?.id == answerPage.id else { return }
        element.text = update.text
        // Saving per token would hammer SwiftData for every few characters,
        // and re-encoding the payload per token would re-serialise JSON just
        // as often. The draft lives in memory until the answer is finished.
        guard !update.isStreaming else { return }

        var payload = element.assistantPayload ?? AssistantNotePayload(question: "")
        payload.isStreaming = false
        payload.citations = update.citations
        payload.notice = update.error ?? update.notice
        payload.didFail = update.error != nil
        element.assistantPayload = payload
        answeringElementID = nil
        growInkAnswer(element)
        answerPage.modifiedAt = .now
        answerPage.notebook?.modifiedAt = .now
        saveChanges()
        if let error = update.error, update.text.isEmpty {
            showNotice(error)
        }
    }

    /// Stop an answer mid-sentence and leave the card in a settled state.
    ///
    /// Without clearing the flag, a card abandoned by a page swipe keeps
    /// saying "writing…" forever -- there is no longer anything running that
    /// could ever turn it off.
    private func stopStreamingAnswer() {
        inkAnswers.cancel()
        guard let elementID = answeringElementID else { return }
        answeringElementID = nil
        let answerPage = loadedPage ?? page
        guard let element = answerPage.elements.first(where: { $0.id == elementID }),
              element.modelContext != nil else { return }
        var payload = element.assistantPayload ?? AssistantNotePayload(question: "")
        payload.isStreaming = false
        payload.notice = "Stopped before the answer finished."
        payload.didFail = true
        element.assistantPayload = payload
        growInkAnswer(element)
        answerPage.modifiedAt = .now
        answerPage.notebook?.modifiedAt = .now
        saveChanges()
    }

    /// A force-close can leave the persisted card marked as streaming even
    /// though its task no longer exists. Make the saved card retryable on the
    /// next open instead of leaving “writing…” on the page indefinitely.
    private func settleInterruptedAnswers() {
        var changed = false
        for element in page.elements where element.id != answeringElementID {
            guard var payload = element.assistantPayload, payload.isStreaming else { continue }
            payload.isStreaming = false
            payload.notice = "The answer was interrupted. Tap Retry to try again."
            payload.didFail = true
            element.assistantPayload = payload
            changed = true
        }
        if changed { saveChanges() }
    }

    private func retryInkAnswer(_ element: PageElement, question rawQuestion: String) {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isReadOnly, element.modelContext != nil,
              page.elements.contains(where: { $0.id == element.id }) else { return }
        inkAnswers.cancel()
        var payload = element.assistantPayload ?? AssistantNotePayload(question: question)
        payload.question = question
        payload.isStreaming = true
        payload.notice = nil
        payload.didFail = nil
        payload.citations = []
        element.assistantPayload = payload
        element.text = ""
        answeringElementID = element.id
        markPageModified()
        guard saveChanges() else {
            payload.isStreaming = false
            payload.notice = "Couldn’t save this question. Retry after resolving the save error."
            payload.didFail = true
            element.assistantPayload = payload
            answeringElementID = nil
            return
        }
        let elementID = element.id
        inkAnswers.answer(
            question: question,
            notebookID: page.notebook?.stableID,
            pageID: page.stableID,
            pageContext: pageContextText(excluding: elementID),
            history: pageAnswerHistory(excluding: elementID),
            pageImage: aiSettings.sendsPageImages ? PDFExport.renderPageImage(page) : nil
        ) { update in
            applyInkAnswer(update, to: element)
        }
    }

    /// Size the card to the answer it ended up holding.
    private func growInkAnswer(_ element: PageElement) {
        let text = element.text ?? ""
        guard !text.isEmpty else { return }
        let width = CGFloat(element.width)
        let font = UIFont(name: "Bradley Hand", size: max(13, CGFloat(element.fontSize)))
            ?? UIFont.systemFont(ofSize: max(13, CGFloat(element.fontSize)))
        let bounding = (text as NSString).boundingRect(
            with: CGSize(width: width - 24, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        let pageSize = page.pageOrientation.size
        let height = min(max(ceil(bounding.height) + 100, 150), pageSize.height - AnswerPlacement.margin * 2)
        element.height = Double(height)
        let centre = AnswerPlacement.clampedCentre(
            CGPoint(x: element.posX, y: element.posY),
            size: CGSize(width: width, height: height),
            pageSize: pageSize
        )
        element.posX = Double(centre.x)
        element.posY = Double(centre.y)
    }

    /// Everything already taking up room on the page, so an answer can be put
    /// somewhere that is not on top of it.
    private func occupiedPageRects() -> [CGRect] {
        var rects = page.elements
            .filter { $0.modelContext != nil }
            .map { element in
                CGRect(
                    x: element.posX - element.width / 2,
                    y: element.posY - element.height / 2,
                    width: element.width,
                    height: element.height
                )
            }
        rects.append(contentsOf: canvas.drawing.strokes.map(\.renderBounds).filter { !$0.isNull && !$0.isEmpty })
        return rects
    }

    /// The page as text, for context -- minus the card being written into, so
    /// the assistant is never fed its own half-finished sentence.
    private func pageContextText(excluding elementID: PersistentIdentifier?) -> String {
        var parts = page.elements
            .filter { $0.id != elementID && $0.type != .assistantNote }
            .compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let ocr = page.ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ocr.isEmpty { parts.append(ocr) }
        return parts.joined(separator: "\n")
    }

    /// Completed answer cards on this page provide conversational continuity
    /// for another handwritten question. They never enter the note evidence
    /// list or receive a source citation.
    private func pageAnswerHistory(excluding elementID: PersistentIdentifier?) -> [AIConversationMessage] {
        page.elements
            .filter { $0.id != elementID && $0.type == .assistantNote }
            .sorted { $0.createdAt < $1.createdAt }
            .compactMap { element -> [AIConversationMessage]? in
                guard let payload = element.assistantPayload,
                      !payload.isStreaming,
                      payload.didFail != true,
                      let answer = element.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !answer.isEmpty,
                      !answer.hasPrefix("The request failed:") else { return nil }
                return [
                    AIConversationMessage(role: .user, content: payload.question),
                    AIConversationMessage(role: .assistant, content: answer)
                ]
            }
            .suffix(3)
            .flatMap { $0 }
    }

    private func replaceSelectedText(with text: String) {
        guard !isReadOnly, !text.isEmpty,
              let selectedElementID,
              let element = page.elements.first(where: { $0.id == selectedElementID }),
              element.modelContext != nil,
              element.type == .textBox || element.type == .stickyNote else { return }
        recordBeforeMutation()
        let original = element.resolvedRichText
        let attributes: [NSAttributedString.Key: Any] = original.length > 0
            ? original.attributes(at: 0, effectiveRange: nil) : [:]
        let replacement = NSAttributedString(string: text, attributes: attributes)
        element.text = replacement.string
        element.richTextData = PageElement.encodeRichText(replacement)
        markPageModified()
        saveChanges()
        showNotice(AppLocalization.text("Selected text replaced"))
    }

    // MARK: - Undo / Redo

    /// Programmatically sets canvas.drawing while suppressing the re-entry
    /// into onDrawingChanged that would otherwise cause double history/OCR/clear.
    ///
    /// PKCanvasView keeps an internal baseline it composites the *next* live
    /// stroke against, and that baseline is only invalidated by a real
    /// drawing/erasing gesture — not by assigning `.drawing` directly. Undo
    /// used to do exactly that single assignment, so after removing strokes
    /// the very next pencil stroke was composited on top of PencilKit's
    /// stale pre-undo baseline, resurrecting everything just undone (erasing
    /// never showed this because it always goes through the live gesture
    /// path). Routing the reduced drawing through an intermediate empty
    /// drawing forces PencilKit to actually observe the change and drop that
    /// stale baseline before the target drawing is applied.
    ///
    /// The empty-drawing round-trip above was verified against synthesized
    /// touch input, which is all UI-test automation can drive — XCTest has no
    /// way to originate a real Apple Pencil event. PencilKit runs a separate,
    /// lower-latency prediction/compositing path exclusively for genuine
    /// Pencil strokes, so a stale baseline could still survive there even
    /// though the touch path is proven clean. Cycling the canvas's own
    /// drawingGestureRecognizer forces PencilKit to fully tear down and
    /// rebuild whatever in-flight stroke state it's holding — for either
    /// input type — as a second, belt-and-suspenders reset.
    ///
    /// One more gap: undoing all the way back to an empty page makes `drawing`
    /// itself `PKDrawing()` — identical to the intermediate value above — so
    /// that second assignment is a no-op PencilKit can (and does) optimize
    /// away as "setting the same value again," and the stale baseline from
    /// before the undo survives after all. `Self.transientResetDrawing` is an
    /// off-page, invisible, throwaway stroke that can never equal a real
    /// target, so the intermediate step is a genuine change every time.
    ///
    /// Still-reported gap: on a real device with actual Apple Pencil input
    /// (which XCUITest cannot originate -- see above), the resurrection kept
    /// happening even with both resets in place. The two assignments above
    /// land in the same run-loop turn, and UIKit view property writes within
    /// one turn are commonly coalesced into a single commit at the next
    /// display pass -- so PencilKit may only ever have observed the *second*
    /// value, never actually seeing the intermediate reset as a discrete
    /// frame. Forcing a layout pass after the reset, then deferring the real
    /// target to the *next* run loop turn, guarantees PencilKit processes them
    /// as two separate frames. Reassigning `canvas.tool` afterwards is a
    /// further reset: PencilKit ties some of its internal compositing state to
    /// tool changes, so touching it is one more way to force that state to be
    /// rebuilt against the drawing that's actually current.
    ///
    /// Tried and reverted: replacing `canvas` with a brand-new PKCanvasView
    /// instance (plus an `.id()` bump to force PaperCanvas to rebuild around
    /// it) on the theory that only a never-touched view is guaranteed free of
    /// stale internal state. That regressed even the synthesized-touch tests
    /// that had been reliably green: `canvas = fresh` and the `.id()` bump are
    /// both @State writes SwiftUI coalesces into one render pass, but that
    /// pass happens on the *next* run-loop turn, not synchronously here --
    /// leaving a window where the old (still fully interactive) PKCanvasView
    /// is what a touch immediately after undo actually lands on. Its internal
    /// state was never touched, so this reintroduced the exact bug it was
    /// meant to fix.
    /// The drawing the canvas holds, or is about to hold.
    ///
    /// `setCanvasDrawing` parks a placeholder on `canvas.drawing` straight
    /// away and only assigns the real drawing on the next run-loop turn, so
    /// reading `canvas.drawing` in between returns the placeholder: a single
    /// invisible stroke off the page. Anything that persists ink or reads
    /// strokes right after a programmatic change must read this instead --
    /// reading the canvas there saved a blank page after every lasso move, and
    /// Undo then Redo restored it.
    private var currentDrawing: PKDrawing { pendingCanvasDrawing.drawing ?? canvas.drawing }

    private func setCanvasDrawing(_ drawing: PKDrawing) {
        isApplyingProgrammaticChange = true
        let pending = pendingCanvasDrawing
        pending.generation &+= 1
        let generation = pending.generation
        pending.drawing = drawing
        let gesture = canvas.drawingGestureRecognizer
        gesture.isEnabled = false
        canvas.drawing = Self.transientResetDrawing
        canvas.setNeedsDisplay()
        canvas.layoutIfNeeded()
        DispatchQueue.main.async { [canvas] in
            canvas.drawing = drawing
            let tool = canvas.tool
            canvas.tool = tool
            gesture.isEnabled = true
            self.isApplyingProgrammaticChange = false
            self.lastRecordedStrokeCount = canvas.drawing.strokes.count
            // A later call in the same turn has its own drawing queued.
            if pending.generation == generation { pending.drawing = nil }
        }
    }

    private static let transientResetDrawing: PKDrawing = {
        let point = PKStrokePoint(
            location: CGPoint(x: -10_000, y: -10_000),
            timeOffset: 0,
            size: CGSize(width: 1, height: 1),
            opacity: 0,
            force: 1,
            azimuth: 0,
            altitude: .pi / 2
        )
        let path = PKStrokePath(controlPoints: [point], creationDate: .now)
        let stroke = PKStroke(ink: PKInk(.pen, color: .clear), path: path)
        return PKDrawing(strokes: [stroke])
    }()

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

    /// `offersQuestions` is false for the passes that run just because a page
    /// was opened. Recognition there is catching up on ink written earlier, and
    /// prompting to answer a question from a previous session every time the
    /// page is turned to is nagging, not help.
    private func scheduleHandwritingOCR(offersQuestions: Bool = true) {
        let data = canvas.drawing.dataRepresentation()
        guard data != lastRecognizedInkData else { return }
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
                targetPageID: targetPageID,
                offersQuestions: offersQuestions
            )
        }
    }

    /// Runs silently, the same way autosave does — there is no manual
    /// "Recognize Handwriting" trigger to give this a user-visible moment;
    /// anyone who wants to confirm it ran can open "Show Source Text".
    @MainActor
    private func updateHandwritingOCR(
        from data: Data?,
        pageSize: CGSize,
        targetPageID: PersistentIdentifier? = nil,
        offersQuestions: Bool = true
    ) async {
        let lines = await HandwritingOCR.recognizeLines(from: data, pageSize: pageSize)
        let recognized = lines.map(\.text).joined(separator: "\n")
        guard !Task.isCancelled else { return }
        // Reject stale results from a previous page. Without this, a slow
        // Vision call started on page N can finish after the user has swiped
        // to page N+1; writing `recognized` onto the new page corrupts its
        // ocrText, and the `context.save()` below can refault the new page's
        // inkData — visibly blanking the page for up to ~30s.
        if let targetPageID, page.persistentModelID != targetPageID { return }
        guard canvas.drawing.dataRepresentation() == data else { return }
        page.ocrText = recognized
        page.ocrUpdatedAt = .now
        if saveChanges() { lastRecognizedInkData = data }
        if offersQuestions { detectInkQuestion(in: lines) }
    }

    /// Spot a handwritten question and offer to answer it.
    ///
    /// Offer, never answer: OCR runs a second after every stroke, and a Vision
    /// misread that fired a request on its own would spend the user's own
    /// provider key without them asking. The trigger is a doubled question
    /// mark for the same reason -- a single `?` is ordinary punctuation.
    private func detectInkQuestion(in lines: [HandwritingOCR.RecognizedLine]) {
        guard inkQuestionsEnabled, assistantEnabled, !isReadOnly else {
            detectedInkQuestion = nil
            return
        }
        guard answeringElementID == nil else { return }

        for line in lines.reversed() where InkQuestionDetector.isQuestion(line.text) {
            let text = InkQuestionDetector.stripped(line.text)
            guard !text.isEmpty else { continue }
            let fingerprint = InkQuestion.fingerprint(of: text)
            guard !handledQuestionFingerprints.contains(fingerprint) else { continue }
            detectedInkQuestion = InkQuestion(text: text, bounds: line.bounds)
            return
        }
        // The question was erased or rewritten; take the prompt away with it.
        if let pending = detectedInkQuestion,
           !lines.contains(where: { InkQuestion.fingerprint(of: InkQuestionDetector.stripped($0.text)) == pending.fingerprint }) {
            detectedInkQuestion = nil
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

    private func fingerControl(at point: CGPoint) -> (PageElement, FingerElementControl)? {
        guard !isReadOnly else { return nil }
        let topFirst = page.elements.reversed().filter { $0.type == .tape }
            + page.elements.reversed().filter { $0.type != .tape }
        // PencilKit may clear selectedElementID on touch-down before the
        // finger observer runs. Check the actual handle geometry even then;
        // otherwise the visible control silently turns into a move gesture.
        let selected = page.elements.first(where: { $0.id == selectedElementID })
        let handleTargets = selected.map { [$0] } ?? topFirst
        for element in handleTargets where !element.isLocked {
            let width = CGFloat(element.width)
            let height = CGFloat(element.height)
            let left = CGFloat(element.posX) - width / 2
            let top = CGFloat(element.posY) - height / 2
            if element.type.isRotatable {
                let rotationHandle = CGRect(x: CGFloat(element.posX) - 22, y: top - 46, width: 44, height: 44)
                if rotationHandle.contains(point) { return (element, .rotate) }
            }
            if element.type.isResizable {
                let leadingHandle = CGRect(x: left, y: top + height - 44, width: 44, height: 44)
                let trailingHandle = CGRect(x: left + width - 44, y: top + height - 44, width: 44, height: 44)
                if leadingHandle.contains(point) { return (element, .resizeLeading) }
                if trailingHandle.contains(point) { return (element, .resizeTrailing) }
            }
        }
        for element in topFirst where !element.isLocked {
            let angle = CGFloat(element.rotation * .pi / 180)
            let width = CGFloat(element.width)
            let height = CGFloat(element.height)
            let hitWidth = abs(cos(angle)) * width + abs(sin(angle)) * height
            let hitHeight = abs(sin(angle)) * width + abs(cos(angle)) * height
            let rect = CGRect(
                x: CGFloat(element.posX) - hitWidth / 2,
                y: CGFloat(element.posY) - hitHeight / 2,
                width: hitWidth,
                height: hitHeight
            )
            guard rect.contains(point) else { continue }
            let localX = point.x - CGFloat(element.posX) + width / 2
            if element.type == .audioRecording {
                // The grip at the leading edge moves the element; the play
                // button just after it plays. The rest of the card (title,
                // slider) belongs to its own controls.
                if localX >= 40 && localX < 80 { return (element, .audioPlay) }
                if localX >= 80 { continue }
            }
            return (element, .move)
        }
        return nil
    }

    /// The unlocked tape under `point`, topmost first.
    private func tape(at point: CGPoint) -> PageElement? {
        guard !isReadOnly else { return nil }
        return page.elements.reversed().first { element in
            guard element.type == .tape, !element.isLocked else { return false }
            let angle = CGFloat(element.rotation * .pi / 180)
            let width = CGFloat(element.width)
            let height = CGFloat(element.height)
            let hitWidth = abs(cos(angle)) * width + abs(sin(angle)) * height
            let hitHeight = abs(sin(angle)) * width + abs(cos(angle)) * height
            return CGRect(
                x: CGFloat(element.posX) - hitWidth / 2,
                y: CGFloat(element.posY) - hitHeight / 2,
                width: hitWidth,
                height: hitHeight
            ).contains(point)
        }
    }

    /// A tap with Apple Pencil, which PencilKit owns, so the SwiftUI tape
    /// never sees it.
    private func toggleTape(at point: CGPoint) {
        guard let tape = tape(at: point) else { return }
        beginElementMutation()
        tape.isRevealed.toggle()
        finishElementMutation()
    }

    private func handleFingerElementDrag(_ event: FingerElementDragEvent) {
        switch event {
        case .began(let point):
            guard let (element, control) = fingerControl(at: point) else { return }
            fingerDragSession = FingerDragSession(
                pageID: page.id,
                elementID: element.id,
                control: control,
                start: point,
                baseX: element.posX,
                baseY: element.posY,
                baseWidth: element.width,
                baseHeight: element.height,
                baseRotation: element.rotation
            )
            selectedElementID = element.id
        case .changed(let point):
            guard var session = fingerDragSession, session.pageID == page.id,
                  session.control != .audioPlay else { return }
            let deltaX = Double(point.x - session.start.x)
            let deltaY = Double(point.y - session.start.y)
            if !session.didRecordMutation && abs(deltaX) + abs(deltaY) > 1 {
                beginElementMutation()
                session.didRecordMutation = true
                fingerDragSession = session
            }
            var posX = session.baseX
            var posY = session.baseY
            var width = session.baseWidth
            var height = session.baseHeight
            var rotation = session.baseRotation
            switch session.control {
            case .move:
                posX += deltaX
                posY += deltaY
            case .resizeLeading, .resizeTrailing:
                let widthDelta = session.control == .resizeLeading ? -deltaX : deltaX
                width = max(40, session.baseWidth + widthDelta)
                height = max(40, session.baseHeight + deltaY)
                let widthGrowth = width - session.baseWidth
                let heightGrowth = height - session.baseHeight
                posX += (session.control == .resizeLeading ? -1 : 1) * widthGrowth / 2
                posY += heightGrowth / 2
            case .rotate:
                let startAngle = atan2(
                    Double(session.start.y) - session.baseY,
                    Double(session.start.x) - session.baseX
                )
                let currentAngle = atan2(
                    Double(point.y) - session.baseY,
                    Double(point.x) - session.baseX
                )
                var angleDelta = currentAngle - startAngle
                if angleDelta > .pi { angleDelta -= 2 * .pi }
                if angleDelta < -.pi { angleDelta += 2 * .pi }
                rotation += angleDelta * 180 / .pi
            case .audioPlay:
                break  // returned above; a play button never drags
            }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                fingerElementDraft = FingerElementDraft(
                    id: session.elementID,
                    posX: posX,
                    posY: posY,
                    width: width,
                    height: height,
                    rotation: rotation
                )
            }
        case .ended(let point):
            handleFingerElementDrag(.changed(point))
            // A tap that never moved: tape is revealed and covered by tapping
            // it. The SwiftUI element handles that for touches that pass
            // through the canvas, but real fingers often reach the canvas
            // instead, and this path previously only selected the element.
            if let session = fingerDragSession,
               session.pageID == page.id,
               session.control == .move,
               !session.didRecordMutation,
               let tape = page.elements.first(where: { $0.id == session.elementID }),
               tape.type == .tape, !tape.isLocked {
                fingerDragSession = nil
                fingerElementDraft = nil
                beginElementMutation()
                tape.isRevealed.toggle()
                finishElementMutation()
                return
            }
            // The same for the play button of a recording: a real finger can
            // reach the canvas instead of the SwiftUI button, which then did
            // nothing and, held, raised the canvas's Select All menu.
            if let session = fingerDragSession,
               session.pageID == page.id,
               session.control == .audioPlay,
               hypot(point.x - session.start.x, point.y - session.start.y) < 20,
               let audioElement = page.elements.first(where: { $0.id == session.elementID }),
               audioElement.type == .audioRecording {
                fingerDragSession = nil
                fingerElementDraft = nil
                toggleAudio(audioElement)
                return
            }
            guard let session = fingerDragSession,
                  session.pageID == page.id,
                  session.didRecordMutation,
                  let element = page.elements.first(where: { $0.id == session.elementID }),
                  let draft = fingerElementDraft else {
                fingerDragSession = nil
                fingerElementDraft = nil
                return
            }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                element.posX = draft.posX
                element.posY = draft.posY
                element.width = draft.width
                element.height = draft.height
                element.rotation = draft.rotation
                fingerElementDraft = nil
                fingerDragSession = nil
            }
            finishElementMutation()
        case .cancelled:
            fingerElementDraft = nil
            fingerDragSession = nil
        }
    }

    private func insertElement(_ type: ElementType, size: CGSize = CGSize(width: 200, height: 120)) {
        guard !isReadOnly else { return }
        recordBeforeMutation()
        let centre = insertionCentre(for: size)
        let elem = PageElement(type: type, x: centre.x, y: centre.y, width: size.width, height: size.height)
        if type == .stickyNote { elem.colorHex = "FFE066" }
        if type == .tape { elem.colorHex = TapeStyle.defaultColorHex }
        elem.page = page
        context.insert(elem)
        page.appendElement(elem)
        selectedElementID = elem.id
        markPageModified()
        guard saveChanges() else { return }
        // The first save replaces the temporary SwiftData identifier.
        selectedElementID = elem.id
        if type == .textBox || type == .stickyNote {
            editingTextElement = elem
        } else if type == .tape {
            editingTapeElement = elem
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

    private var customizableSelectedTape: PageElement? {
        guard let selectedElement, selectedElement.type == .tape, !selectedElement.isLocked else { return nil }
        if !selectionState.isEmpty {
            guard selectionState.elementIDs.count == 1,
                  selectionState.elementIDs.contains(selectedElement.id) else { return nil }
        }
        return selectedElement
    }

    private func saveTapeSettings(_ element: PageElement, colorHex: String, length: Double, height: Double) -> String? {
        guard !isReadOnly, element.modelContext != nil, !element.isLocked else {
            return AppLocalization.text("This tape is no longer available for editing.")
        }
        let oldColor = element.colorHex
        let oldWidth = element.width
        let oldHeight = element.height
        if TapeStyle.colorHex(for: element) == colorHex && oldWidth == length && oldHeight == height {
            selectedElementID = element.id
            return nil
        }
        let oldPageModified = page.modifiedAt
        let oldNotebookModified = page.notebook?.modifiedAt
        recordBeforeMutation()
        element.colorHex = colorHex
        element.width = length
        element.height = height
        markPageModified()
        if !selectionState.isEmpty { refreshSelectionBounds() }
        if saveChanges() {
            selectedElementID = element.id
            return nil
        }

        element.colorHex = oldColor
        element.width = oldWidth
        element.height = oldHeight
        page.modifiedAt = oldPageModified
        page.notebook?.modifiedAt = oldNotebookModified ?? oldPageModified
        if !selectionState.isEmpty { refreshSelectionBounds() }
        let message = saveError ?? AppLocalization.text("Couldn’t save tape changes.")
        saveError = nil
        hasSaveFailure = false
        return message
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
        selectionState.strokeIndices = Set(selectionState.strokeIndices.filter { currentDrawing.strokes.indices.contains($0) })
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

    /// Selection bounds that stay correct while ink is lifted out of the
    /// canvas, where `combinedBounds` would find no strokes to measure.
    private func liveSelectionBounds() -> CGRect {
        guard let lifted = liftedInk else {
            return combinedBounds(strokes: selectionState.strokeIndices, elements: selectionState.elementIDs)
        }
        var result = lifted.drawing.bounds.isNull ? .null : lifted.drawing.bounds.applying(lifted.transform)
        for element in page.elements where selectionState.elementIDs.contains(element.id) {
            result = result.union(elementSelectionBounds(element))
        }
        guard result.width.isFinite, result.height.isFinite else { return .null }
        return result.isNull ? .null : result.insetBy(dx: -2, dy: -2)
    }

    private func combinedBounds(strokes: Set<Int>, elements: Set<PersistentIdentifier>) -> CGRect {
        var result = CGRect.null
        let drawing = currentDrawing
        for index in strokes where drawing.strokes.indices.contains(index) { result = result.union(drawing.strokes[index].renderBounds) }
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
        if liftedInk != nil {
            // Ink is out of the canvas for the duration of the drag: just
            // accumulate. commitLiftedInk() applies this to the real strokes.
            liftedInk?.transform = liftedInk!.transform.concatenating(transform)
        } else {
            var strokes = currentDrawing.strokes
            for index in selectionState.strokeIndices where strokes.indices.contains(index) {
                let stroke = strokes[index]
                let combined = stroke.transform.concatenating(transform)
                strokes[index] = PKStroke(ink: stroke.ink, path: stroke.path, transform: combined, mask: stroke.mask, randomSeed: stroke.randomSeed)
            }
            setCanvasDrawing(PKDrawing(strokes: strokes))
        }
        for element in page.elements where selectionState.elementIDs.contains(element.id) && !element.isLocked {
            let center = CGPoint(x: element.posX, y: element.posY).applying(transform)
            element.posX = Double(center.x)
            element.posY = Double(center.y)
            element.width = Double(max(SelectionTransform.minimumDimension, abs(scaleX) * CGFloat(element.width)))
            element.height = Double(max(SelectionTransform.minimumDimension, abs(scaleY) * CGFloat(element.height)))
            element.rotation += Double(rotation * 180 / .pi)
        }
        var newBounds = liveSelectionBounds()
        let recovery = SelectionTransform.recoveryTranslation(for: newBounds, pageSize: page.pageOrientation.size)
        if recovery != .zero {
            let correction = CGAffineTransform(translationX: recovery.width, y: recovery.height)
            if liftedInk != nil {
                liftedInk?.transform = liftedInk!.transform.concatenating(correction)
            } else {
                var strokes = currentDrawing.strokes
                for index in selectionState.strokeIndices where strokes.indices.contains(index) {
                    let stroke = strokes[index]
                    strokes[index] = PKStroke(ink: stroke.ink, path: stroke.path, transform: stroke.transform.concatenating(correction), mask: stroke.mask, randomSeed: stroke.randomSeed)
                }
                setCanvasDrawing(PKDrawing(strokes: strokes))
            }
            for element in page.elements where selectionState.elementIDs.contains(element.id) && !element.isLocked {
                element.posX += recovery.width
                element.posY += recovery.height
            }
            newBounds = liveSelectionBounds()
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
        showNotice(AppLocalization.text("Selection copied"))
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
        var strokes = currentDrawing.strokes
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
        page.inkData = currentDrawing.dataRepresentation()
        lastRecordedStrokeCount = strokes.count
        markPageModified()
        saveChanges()
        showNotice(AppLocalization.text("Selection pasted"))
    }

    private func canShowBlankCanvasPasteMenu(at point: CGPoint) -> Bool {
        // A resting hand while actively drawing/erasing is exactly the kind
        // of touch that shouldn't pop the paste menu.
        guard !isUsingInkTool else { return false }
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
        let retainedStrokes = currentDrawing.strokes.enumerated().compactMap { selectionState.strokeIndices.contains($0.offset) ? nil : $0.element }
        setCanvasDrawing(PKDrawing(strokes: retainedStrokes))
        let removed = page.elements.filter { selectionState.elementIDs.contains($0.id) && !$0.isLocked }
        page.elements.removeAll { element in removed.contains(where: { $0.id == element.id }) }
        removed.forEach(context.delete)
        page.inkData = currentDrawing.dataRepresentation()
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
        liftSelectedInk()
    }

    /// Moves the selected strokes out of the canvas and into `liftedInk`.
    private func liftSelectedInk() {
        let indices = selectionState.strokeIndices.sorted()
        let all = currentDrawing.strokes
        guard !indices.isEmpty, indices.allSatisfy({ all.indices.contains($0) }) else { return }
        liftedInkGeneration += 1
        liftedInk = LiftedInk(
            drawing: PKDrawing(strokes: indices.map { all[$0] }),
            indices: indices,
            generation: liftedInkGeneration
        )
        setCanvasDrawing(PKDrawing(strokes: all.enumerated()
            .filter { !selectionState.strokeIndices.contains($0.offset) }
            .map(\.element)))
    }

    /// Writes the gesture's accumulated transform into the real strokes and
    /// returns them to the canvas.
    ///
    /// Every path that can end a drag must call this -- releasing the finger,
    /// switching pages, leaving the editor. While ink is lifted it exists only
    /// in `liftedInk`, so a path that skips this drops the strokes entirely.
    private func commitLiftedInk() {
        guard let lifted = liftedInk else { return }
        liftedInk = nil
        var strokes = currentDrawing.strokes
        let transformed = lifted.drawing.strokes.map {
            PKStroke(ink: $0.ink, path: $0.path,
                     transform: $0.transform.concatenating(lifted.transform),
                     mask: $0.mask, randomSeed: $0.randomSeed)
        }
        // `indices` ascends and the strokes were removed from the same array,
        // so reinserting in order puts each one back where it came from.
        for (offset, index) in lifted.indices.enumerated() {
            strokes.insert(transformed[offset], at: min(index, strokes.count))
        }
        setCanvasDrawing(PKDrawing(strokes: strokes))
        selectionState.strokeIndices = Set(lifted.indices)
        selectionState.bounds = combinedBounds(
            strokes: selectionState.strokeIndices,
            elements: selectionState.elementIDs
        )
    }

    private func finishInkSelectionMutation() {
        guard isTransformingInkSelection else { return }
        commitLiftedInk()
        isTransformingInkSelection = false
        page.inkData = currentDrawing.dataRepresentation()
        lastRecordedStrokeCount = currentDrawing.strokes.count
        markPageModified()
        saveChanges()
    }

    /// The simulator has no microphone, so a UI test cannot record. With this
    /// launch argument the Recording item adds a finished recording of a quiet
    /// tone instead, which is enough to exercise playback and its touch routing.
    private func insertSyntheticRecording() {
        recordBeforeMutation()
        let elem = PageElement(type: .audioRecording, x: 200, y: 300, width: 220, height: 56)
        elem.colorHex = "F18F01"
        elem.audioData = Self.syntheticWAV(seconds: 3)
        elem.audioDuration = 3
        elem.text = "Recording (\(formatDuration(3)))"
        elem.page = page
        context.insert(elem)
        page.appendElement(elem)
        selectedElementID = elem.id
        markPageModified()
        saveChanges()
    }

    private static func syntheticWAV(seconds: Double, sampleRate: Int = 44_100) -> Data {
        var pcm = Data()
        for i in 0..<Int(seconds * Double(sampleRate)) {
            var sample = Int16(1_500 * sin(2 * Double.pi * 440 * Double(i) / Double(sampleRate)))
            pcm.append(Data(bytes: &sample, count: 2))
        }
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var wav = Data("RIFF".utf8)
        wav += le(UInt32(36 + pcm.count)) + Data("WAVEfmt ".utf8) + le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1))
        wav += le(UInt32(sampleRate)) + le(UInt32(sampleRate * 2)) + le(UInt16(2)) + le(UInt16(16))
        wav += Data("data".utf8) + le(UInt32(pcm.count)) + pcm
        return wav
    }

    private func startRecording() {
        guard !isReadOnly, recordingElement == nil else { return }
        if ProcessInfo.processInfo.arguments.contains("-ui-testing"),
           ProcessInfo.processInfo.arguments.contains("-ui-testing-synthetic-recording") {
            insertSyntheticRecording()
            return
        }
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
            audio.lastError = AppLocalization.text("This recording does not contain playable audio.")
        }
    }

    private func transcribeAudio(_ element: PageElement) {
        guard !isReadOnly, element.modelContext != nil, !element.isLocked else { return }
        guard let data = element.audioData, !data.isEmpty else {
            audio.lastError = AppLocalization.text("This recording does not contain audio to transcribe.")
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
            let imageElement = insertSmartImageImport(extraction)
            markPageModified()
            if saveChanges() { selectedElementID = imageElement.id }
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
            var lastInsertedImage: PageElement?
            for (index, image) in images.prefix(4).enumerated() {
                guard let data = image.jpegData(compressionQuality: 0.9) else { continue }
                let extraction = await SmartImageExtractor.extract(from: data)
                let element = insertSmartImageImport(extraction)
                lastInsertedImage = element
                if element.modelContext != nil {
                    element.posY = min(220 + Double(index) * 220, pageSize.height - element.height / 2 - 24)
                }
            }
            markPageModified()
            if saveChanges(), let lastInsertedImage { selectedElementID = lastInsertedImage.id }
            showNotice(images.count > 4 ? "Added the first 4 scanned pages" : "Scan added")
        }
    }

    @discardableResult
    private func insertSmartImageImport(_ extraction: SmartImageExtractor.Extraction) -> PageElement {
        let pageSize = page.pageOrientation.size
        let pageCenterX = pageSize.width / 2

        // The whole source frame is part of the note. Vision may focus on a
        // text region for recognition, but must never replace the image.
        let imageData = extraction.originalImageData
        let sourceImageSize = extraction.originalImageSize == .zero
            ? imageSize(from: imageData) : extraction.originalImageSize
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
        return imageElement
    }

    #if DEBUG
    private func seedImageForControlTestIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-ui-testing-seed-image"),
              page.elements.isEmpty else { return }
        let imageSize = CGSize(width: 160, height: 100)
        let data = UIGraphicsImageRenderer(size: imageSize).pngData { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(origin: .zero, size: imageSize))
        }
        let element = PageElement(
            type: .image,
            x: page.pageOrientation.size.width / 2,
            y: 240,
            width: imageSize.width,
            height: imageSize.height
        )
        element.imageData = data
        element.page = page
        context.insert(element)
        page.appendElement(element)
        if saveChanges() { selectedElementID = element.id }
    }
    #endif

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

/// A compact, non-blocking recording bar pinned to the bottom of the screen.
/// Unlike a full-screen popup, this lets the user continue writing while
/// recording. Shows elapsed time, a pulsing indicator, and Stop/Cancel buttons.
private struct RecordingBar: View {
    let elapsed: TimeInterval
    var onStop: () -> Void
    var onCancel: () -> Void

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
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
    var onCustomizeTape: () -> Void
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
            if elementType == .tape {
                iconButton("slider.horizontal.3", "Tape Options", action: onCustomizeTape)
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

private struct SaveFailureView: View {
    var onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text("Save failed")
            Button("Retry", action: onRetry).bold()
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

    @State private var drag = IncrementalDrag()
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
                            let delta = drag.consume(value.translation)
                            if delta != .zero {
                                onMove(delta)
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
                                let delta = drag.consume(value.translation)
                                if delta != .zero {
                                    handleCornerResize(anchor: anchor, translation: delta)
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
                                let delta = drag.consume(value.translation)
                                if delta != .zero {
                                    handleEdgeResize(anchor: anchor, translation: delta)
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
                            let delta = drag.consume(value.translation)
                            if delta.width != 0 {
                                onRotate(delta.width * 0.01)
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
        drag.reset()
        guard gestureActive else { return }
        gestureActive = false
        onMutationEnded()
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

/// Shown behind the last page while it is pulled aside: a ring that fills as
/// the pull nears the threshold, and what releasing will do. It is sized to
/// the strip the page has uncovered so none of it hides behind the page.
private struct AddPagePullIndicator: View {
    let progress: CGFloat
    let revealedWidth: CGFloat

    var body: some View {
        let ready = progress >= 1
        let tint: Color = ready ? .green : .blue
        let caption = AppLocalization.text(ready ? "Release to Add Page" : "Pull to Add Page")
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: ready ? "doc.badge.plus" : "arrow.left")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(tint)
            }
            .frame(width: 48, height: 48)
            Text(caption)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(width: max(revealedWidth, 0))
        .opacity(min(1, revealedWidth / 56))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("pull-to-add-page")
        .accessibilityLabel(caption)
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
                    .fill(Color(hex: TapeStyle.colorHex(for: element)) ?? .gray)
                    .overlay {
                        VStack(spacing: 4) {
                            Image(systemName: "bandage.fill")
                                .font(.title3)
                            Text("Tap to reveal")
                                .font(.caption2)
                        }
                        .foregroundStyle(TapeStyle.usesDarkForeground(TapeStyle.colorHex(for: element)) ? .black : .white)
                    }
            }
        }
        .frame(width: element.width, height: element.height)
        .rotationEffect(.degrees(element.rotation))
    }
}

private struct TapeSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let maxLength: Double
    let onSave: (String, Double, Double) -> String?
    @State private var colorHex: String
    @State private var length: Double
    @State private var height: Double
    @State private var saveError: String?

    init(element: PageElement, maxLength: Double,
         onSave: @escaping (String, Double, Double) -> String?) {
        self.maxLength = max(80, max(maxLength, element.width))
        self.onSave = onSave
        _colorHex = State(initialValue: TapeStyle.colorHex(for: element))
        _length = State(initialValue: element.width)
        _height = State(initialValue: element.height)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Color") {
                    ZStack {
                        Color.white
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(hex: colorHex) ?? .gray)
                            .overlay {
                                Image(systemName: "bandage.fill")
                                    .foregroundStyle(TapeStyle.usesDarkForeground(colorHex) ? .black : .white)
                            }
                            .frame(width: min(length, 300), height: min(height, 44))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 8) {
                        ForEach(TapeStyle.palette, id: \.self) { hex in
                            Button {
                                colorHex = hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: hex) ?? .gray)
                                    .frame(width: 36, height: 36)
                                    .overlay(Circle().stroke(colorHex == hex ? Color.accentColor : .clear, lineWidth: 3))
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Tape color \(hex)")
                            .accessibilityIdentifier("tape-color-\(hex)")
                            .accessibilityAddTraits(colorHex == hex ? .isSelected : [])
                        }
                    }
                    ColorPicker("Custom Color", selection: Binding(
                        get: { Color(hex: colorHex) ?? .gray },
                        set: { colorHex = $0.hexString }
                    ), supportsOpacity: false)
                }

                Section("Size") {
                    VStack(alignment: .leading) {
                        LabeledContent("Length", value: "\(Int(length)) pt")
                        Slider(value: $length, in: 40...maxLength, step: 10)
                            .accessibilityIdentifier("tape-length-slider")
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("Height", value: "\(Int(height)) pt")
                        Slider(value: $height, in: 20...max(160, height), step: 4)
                            .accessibilityIdentifier("tape-height-slider")
                    }
                }
            }
            .navigationTitle("Tape Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        if let error = onSave(colorHex, length, height) {
                            saveError = error
                        } else {
                            dismiss()
                        }
                    }
                    .bold()
                }
            }
            .alert("Couldn’t Save Tape", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
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

/// "Answer this?" beside a handwritten question.
///
/// It lives in the topmost page-space layer on purpose. `UnifiedLassoOverlay`
/// covers the whole page and reads any touch that misses a control above it as
/// the start of a new selection, so a prompt placed lower would be unreachable
/// with the lasso in hand. Positioned with `.position`, never `.offset`: the
/// accessibility system publishes the layout frame, and `.offset` leaves that
/// behind where nothing can find it.
private struct InkQuestionPrompt: View {
    let question: InkQuestion
    let pageSize: CGSize
    var onAccept: () -> Void
    var onDismiss: () -> Void

    private static let size = CGSize(width: 242, height: 72)

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onAccept) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(question.text)
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .accessibilityIdentifier("ink-question-recognized-text")
                    Label("Answer this?", systemImage: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                .padding(.leading, 10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Answer this question")

            Divider().frame(height: 44)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 44, height: 72)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss question prompt")
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        .position(centre)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ink-question-prompt")
        .transition(.opacity)
    }

    /// Just past the end of the question, clamped onto the page.
    private var centre: CGPoint {
        let anchor = question.bounds.isNull || question.bounds.isEmpty
            ? CGRect(x: pageSize.width / 2, y: pageSize.height / 3, width: 0, height: 0)
            : question.bounds
        let rightX = anchor.maxX + 12 + Self.size.width / 2
        let proposed: CGPoint
        if rightX + Self.size.width / 2 <= pageSize.width - AnswerPlacement.margin {
            proposed = CGPoint(x: rightX, y: anchor.midY)
        } else if anchor.maxY + 12 + Self.size.height <= pageSize.height - AnswerPlacement.margin {
            proposed = CGPoint(x: anchor.midX, y: anchor.maxY + 12 + Self.size.height / 2)
        } else {
            proposed = CGPoint(x: anchor.midX, y: anchor.minY - 12 - Self.size.height / 2)
        }
        return AnswerPlacement.clampedCentre(
            proposed,
            size: Self.size,
            pageSize: pageSize
        )
    }
}

private struct SelectionContextBar: View {
    let canAsk: Bool
    var onAsk: () -> Void
    let canPaste: Bool
    let canLock: Bool
    let canBringForward: Bool
    let canSendBackward: Bool
    let canCustomizeTape: Bool
    var onCut: () -> Void
    var onCopy: () -> Void
    var onPaste: () -> Void
    var onDuplicate: () -> Void
    var onDelete: () -> Void
    var onLock: () -> Void
    var onBringForward: () -> Void
    var onSendBackward: () -> Void
    var onCustomizeTape: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) { clipboardActions; selectionActions; assistantActions }
            VStack(spacing: 0) {
                HStack(spacing: 0) { clipboardActions; assistantActions }
                selectionActions
            }
            VStack(spacing: 0) {
                clipboardActions
                selectionActions
                assistantActions
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

    /// The ink-first route into the assistant: circle what you wrote, tap this,
    /// and the answer is written onto the page beside it -- no chat box, no
    /// leaving the page.
    private var assistantActions: some View {
        HStack(spacing: 0) {
            action("sparkles", "Ask", onAsk).disabled(!canAsk)
        }
    }

    private var selectionActions: some View {
        HStack(spacing: 0) {
            if canCustomizeTape {
                action("slider.horizontal.3", "Tape Options", onCustomizeTape)
            }
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
    @StateObject private var editorController = RichTextEditingController()
    @State private var editorAttributedText: NSAttributedString
    @State private var didFinish = false

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
                    onActivity: { _, _, _ in }
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
                // UITextView can finish laying out after this sheet appears.
                // Refresh formatting state on the next run loop, outside
                // UIViewRepresentable's make/update cycle.
                DispatchQueue.main.async {
                    editorController.configure(
                        defaultAttributes: element.defaultTextAttributes,
                        fallbackAlignment: element.alignment
                    )
                    editorController.refreshSelectionState()
                }
            }
            .onDisappear {
                finish()
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
        guard self.textView !== textView else { return }
        self.textView = textView
        if textView.typingAttributes.isEmpty {
            textView.typingAttributes = defaultAttributes
        }
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
        controller.attach(textView)
        installControllerCallback(context.coordinator)
        focusIfNeeded(textView, coordinator: context.coordinator)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        controller.attach(uiView)
        installControllerCallback(context.coordinator)
        // UITextView owns the live edit. Echoing the SwiftUI binding back into
        // it during a render replaces its text storage while the keyboard is
        // typing, which resets or moves the insertion point (especially with
        // marked text). This binding is only a snapshot for saving the sheet.
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

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichTextEditorView
        var didFocus = false

        init(parent: RichTextEditorView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                let text = textView.attributedText ?? NSAttributedString()
                let selection = textView.selectedRange
                let isComposing = textView.markedTextRange != nil
                self.parent.attributedText = text
                self.parent.controller.refreshSelectionState(from: textView)
                self.parent.onActivity(text, selection, isComposing)
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.parent.controller.refreshSelectionState(from: textView)
            }
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
                Section("Orientation") {
                    Picker("Orientation", selection: Binding(
                        get: { page.pageOrientation },
                        set: { page.orientation = $0.rawValue }
                    )) {
                        ForEach(PageOrientation.allCases, id: \.self) { orientation in
                            Label(orientation.label, systemImage: orientation.icon).tag(orientation)
                        }
                    }
                    .pickerStyle(.segmented)
                }
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
                        orientation: page.pageOrientation,
                        lineThickness: page.effectiveLineThickness,
                        lineOpacity: page.effectiveLineOpacity
                    )
                }
                Section("Line Appearance") {
                    LineAppearanceControls(thickness: $page.lineThickness, opacity: $page.lineOpacity)
                }
                if let notebook = page.notebook {
                    Section("Notebook Default") {
                        Button("Use \(page.lines.label) as notebook default", systemImage: "bookmark") {
                            notebook.defaultLineStyle = page.lineStyle
                            notebook.defaultLineThickness = page.effectiveLineThickness
                            notebook.defaultLineOpacity = page.effectiveLineOpacity
                            notebook.defaultBackgroundHex = page.backgroundHex
                            notebook.defaultOrientation = page.orientation
                        }
                    }
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

                if service.isRemoteConfigured {
                    Section {
                        Toggle(isOn: Binding(
                            get: { service.sendsPageImages },
                            set: { service.setSendsPageImages($0) }
                        )) {
                            Label("Send Page Images (Vision)", systemImage: "photo")
                        }
                    } footer: {
                        Text("Only for models that accept image input (e.g. GPT-4o, Claude 3+, Gemini). Increases request size and cost.")
                    }
                }

                Section {
                    Label(
                        service.isRemoteConfigured ? "Remote AI enabled" : "No AI provider configured",
                        systemImage: service.isRemoteConfigured ? "checkmark.shield" : "exclamationmark.triangle"
                    )
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                    if let connectionStatus {
                        Text(connectionStatus).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Only passages selected for an explicit assistant or search request are sent (plus page images, when Send Page Images is on). The key is stored in this device's Keychain.")
                }

                if service.isRemoteConfigured {
                    Section {
                        Button("Remove AI Provider", role: .destructive) {
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
