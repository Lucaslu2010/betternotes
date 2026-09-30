import SwiftUI
import SwiftData
import PencilKit
import UniformTypeIdentifiers

private enum EditorHint { case toolbar, pan, finger, lasso }

enum EditorPresentedPanel: String, Identifiable {
    case overview
    case pageInfo
    case shapePicker
    case settings

    var id: String { rawValue }
}

@MainActor
final class EditorActionState: ObservableObject {
    @Published var currentPageIndex: Int
    @Published var isViewOnly = false
    @Published var presentedPanel: EditorPresentedPanel?
    @Published var isAssistantPresented = false

    init(currentPageIndex: Int = 0) {
        self.currentPageIndex = currentPageIndex
    }
}

struct EditorCommand: Identifiable, Equatable {
    enum Action: Equatable {
        case undo
        case redo
        case insert(InsertKind)
        case insertShape(ShapeKind)
        case copy
        case cut
        case paste
        case deleteSelection
        case insertAssistantText(String)
        case replaceSelectedText(String)
        case showPageStyle
        case showSourceText
        case exportPage
        case scanDocument
    }

    let id = UUID()
    let targetPageID: PersistentIdentifier
    let action: Action
}

struct NotebookView: View {
    @Bindable var notebook: Notebook
    @ObservedObject var editorState: EditorActionState
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var corpusStore: NoteCorpusStore
    @Query(sort: \Notebook.modifiedAt, order: .reverse) private var allNotebooks: [Notebook]
    @AppStorage(AppPreferenceKey.allowsFingerDrawing) private var allowsFingerDrawing = false
    @AppStorage(AppPreferenceKey.toolbarDock) private var toolbarDockRaw = ToolbarDock.top.rawValue
    @AppStorage(AppPreferenceKey.toolbarHintSeen) private var toolbarHintSeen = false
    @AppStorage(AppPreferenceKey.panHintSeen) private var panHintSeen = false
    @AppStorage(AppPreferenceKey.fingerHintSeen) private var fingerHintSeen = false
    @AppStorage(AppPreferenceKey.lassoHintSeen) private var lassoHintSeen = false
    @AppStorage(AppPreferenceKey.assistantEnabled) private var assistantEnabled = true
    @AppStorage(AppPreferenceKey.scrollMode) private var scrollModeRaw = ScrollMode.singlePage.rawValue

    private var scrollMode: ScrollMode {
        ScrollMode(rawValue: scrollModeRaw) ?? .singlePage
    }
    @State private var notebookPDFURL: URL?
    @State private var showingNotebookShare = false
    @State private var showingPDFImporter = false
    @State private var recentlyDeletedPage: Page?
    @State private var pdfImportError: String?
    @State private var saveError: String?
    @State private var isImportingPDF = false
    @State private var pdfImportTask: Task<Void, Never>?
    @State private var pageZoomScale: CGFloat = 1
    @State private var pageZoomRatio: CGFloat = 1
    @State private var pageZoomCommand: PageZoomCommand?
    // Gesture-relative: MagnificationGesture reports a multiplier off its own
    // start, not an absolute scale, so this pins down what pageZoomScale was
    // when the current pinch began.
    @State private var verticalZoomBaseScale: CGFloat = 1
    @State private var editorCanUndo = false
    @State private var editorCanRedo = false
    @State private var editorCanReplaceSelectedText = false
    @State private var pageTurnDirection: PageTurnDirection = .forward
    @State private var editorTool: DrawingTool = .pen
    @State private var editorToolbarOffset = CGSize(width: 0, height: 8)
    @State private var editorCommand: EditorCommand?
    @State private var toolbarSize: CGSize = .zero
    @GestureState private var toolbarDragTranslation: CGSize = .zero
    @GestureState private var isDraggingToolbar = false
    @StateObject private var toolSettings = ToolSettings()
    @StateObject private var deletionBanner = DeletionUndoBannerModel()
    private let onOpenAssistantSource: (UUID, UUID?) -> Void

    init(
        notebook: Notebook,
        editorState: EditorActionState,
        onOpenAssistantSource: @escaping (UUID, UUID?) -> Void = { _, _ in }
    ) {
        self.notebook = notebook
        self.editorState = editorState
        self.onOpenAssistantSource = onOpenAssistantSource
    }

    private var isReadOnly: Bool { editorState.isViewOnly }
    // The page pill and bottom-docked toolbar share this visual bottom edge.
    private let floatingControlBottomOverflow: CGFloat = 18

    private var currentPageIndex: Int {
        get { editorState.currentPageIndex }
        nonmutating set { editorState.currentPageIndex = newValue }
    }

    var body: some View {
        ZStack {
            if sortedPages.isEmpty {
                ContentUnavailableView(
                    "This notebook has no pages",
                    systemImage: "doc.text",
                    description: Text("Add a page to start writing.")
                )
            } else if !sortedPages.isEmpty {
                if scrollMode == .verticalScroll {
                    verticalScrollContent
                } else {
                    let currentPage = sortedPages[safePageIndex]
                    PageEditorView(
                        page: currentPage,
                        pageNumber: safePageIndex + 1,
                        pageCount: sortedPages.count,
                        isReadOnly: isReadOnly,
                        toolbarObstruction: horizontalSizeClass == .compact ? .none : ToolbarObstruction(
                            dock: ToolbarDock(rawValue: toolbarDockRaw) ?? .top,
                            size: toolbarSize
                        ),
                        zoomScale: $pageZoomScale,
                        zoomRatio: $pageZoomRatio,
                        zoomCommand: $pageZoomCommand,
                        canUndo: $editorCanUndo,
                        canRedo: $editorCanRedo,
                        canReplaceSelectedText: $editorCanReplaceSelectedText,
                        tool: $editorTool,
                        toolSettings: toolSettings,
                        command: $editorCommand,
                        pageTurnDirection: pageTurnDirection,
                        onPageSwipe: handlePageSwipe
                    )
                    // PKCanvasView is stateful UIKit content. Scoping the editor to
                    // one page prevents a canvas from being rebound to another page
                    // before the outgoing drawing has finished saving.
                    .id(currentPage.persistentModelID)
                    .transition(pageTransition)
                }
            }

            if horizontalSizeClass != .compact {
                GeometryReader { geo in
                    ZStack(alignment: .top) {
                        floatingToolbar(in: geo.size)
                            .background(
                                GeometryReader { toolbarGeo in
                                    Color.clear.preference(key: ToolbarSizePreferenceKey.self, value: toolbarGeo.size)
                                }
                            )
                            .onPreferenceChange(ToolbarSizePreferenceKey.self) { size in
                                guard toolbarSize != size else { return }
                                toolbarSize = size
                                if !isDraggingToolbar {
                                    setToolbarOffset(dockedToolbarOffset(in: geo.size), animated: false)
                                }
                            }
                            .transaction { transaction in
                                if isDraggingToolbar {
                                    transaction.disablesAnimations = true
                                    transaction.animation = nil
                                }
                            }
                            .offset(displayedToolbarOffset(in: geo.size))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .onChange(of: geo.size) { _, newSize in
                        setToolbarOffset(dockedToolbarOffset(in: newSize), animated: false)
                    }
                    .onChange(of: dynamicTypeSize) { _, _ in
                        setToolbarOffset(dockedToolbarOffset(in: geo.size), animated: false)
                    }
                    .onChange(of: toolbarDockRaw) { _, _ in
                        setToolbarOffset(dockedToolbarOffset(in: geo.size), animated: false)
                    }
                    .onAppear { setToolbarOffset(dockedToolbarOffset(in: geo.size), animated: false) }
                }
                .zIndex(100)
            }

            editorTopActions
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 10)
                .padding(.trailing, 16)
                .zIndex(110)

            editorPageBar
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 18)
                .padding(.bottom, 4)
                .offset(y: horizontalSizeClass == .compact ? 0 : floatingControlBottomOverflow + 4)
                .zIndex(110)

            if let recentlyDeletedPage, deletionBanner.isPresented {
                VStack {
                    Spacer()
                    UndoBanner(message: AppLocalization.text("Page moved to trash")) {
                        guard PageOperations.restore(recentlyDeletedPage, in: notebook, isReadOnly: isReadOnly) else { return }
                        if saveChanges() {
                            deletionBanner.clear()
                            self.recentlyDeletedPage = nil
                        }
                    }
                    .padding(.bottom, 18)
                }
                .zIndex(200)
            }

            if let hint = activeHint {
                FirstUseHintBanner(text: hintText(hint), onDismiss: { dismissHint(hint) })
                    .padding(.top, max(toolbarSize.height, 52) + 18)
                    .padding(.horizontal, 16)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .zIndex(150)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if horizontalSizeClass == .compact {
                editorBottomBar
            }
        }
        .overlay {
            if isImportingPDF {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Importing PDF…")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .transition(.opacity)
            }
        }
        .sheet(item: $editorState.presentedPanel) { panel in
            editorPanel(panel)
        }
        .sheet(isPresented: $showingNotebookShare) {
            if let url = notebookPDFURL {
                ShareSheet(items: [url])
            }
        }
        .assistantPresentation(
            isCompact: horizontalSizeClass == .compact,
            isPresented: $editorState.isAssistantPresented
        ) {
            assistantContent
        }
        .fileImporter(
            isPresented: $showingPDFImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            importPDF(result)
        }
        .alert("PDF Import Failed", isPresented: Binding(
            get: { pdfImportError != nil },
            set: { if !$0 { pdfImportError = nil } }
        )) {
            Button("OK", role: .cancel) { pdfImportError = nil }
        } message: {
            Text(pdfImportError ?? "")
        }
        .alert("Couldn’t Save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("Try Again") { _ = saveChanges() }
            Button("Dismiss", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .onChange(of: editorState.isAssistantPresented) { _, isShowing in
            guard isShowing else { return }
            Task { await corpusStore.rebuild(notebooks: allNotebooks) }
        }
        .onDisappear {
            pdfImportTask?.cancel()
        }
        .background { keyboardShortcutButtons }
    }

    // MARK: - Vertical scroll mode

    private var verticalScrollContent: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                ForEach(Array(sortedPages.enumerated()), id: \.element.persistentModelID) { index, page in
                    PageEditorView(
                        page: page,
                        pageNumber: index + 1,
                        pageCount: sortedPages.count,
                        isReadOnly: isReadOnly,
                        toolbarObstruction: .none,
                        zoomScale: $pageZoomScale,
                        zoomRatio: $pageZoomRatio,
                        zoomCommand: .constant(nil),
                        canUndo: $editorCanUndo,
                        canRedo: $editorCanRedo,
                        canReplaceSelectedText: $editorCanReplaceSelectedText,
                        tool: $editorTool,
                        toolSettings: toolSettings,
                        command: $editorCommand,
                        pageTurnDirection: pageTurnDirection,
                        onPageSwipe: { _ in },
                        // The whole vertical document zooms as one unit (see
                        // PageEditorView.usesOwnZoomContainer) instead of each
                        // page running its own independent pinch-to-zoom
                        // UIScrollView -- that per-page zoom was the bug: it
                        // turned every page into its own isolated zoomable
                        // island rather than scaling the coherent document
                        // when pinched. The shared pinch gesture below drives
                        // pageZoomScale for every page at once.
                        usesOwnZoomContainer: false
                    )
                    .id(page.persistentModelID)
                    .frame(width: page.pageOrientation.size.width, height: page.pageOrientation.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                    .scaleEffect(pageZoomScale, anchor: .top)
                    // The frame must grow with the visual scale too, or
                    // ScrollView keeps laying the stack out at the unscaled
                    // size -- the same contentSize-vs-zoomScale mismatch that
                    // once clamped single-page zoom short of the page bottom,
                    // here it would clip/overlap neighboring pages instead.
                    .frame(
                        width: page.pageOrientation.size.width * pageZoomScale,
                        height: page.pageOrientation.size.height * pageZoomScale
                    )
                    .onAppear {
                        // Track the current page for the page counter.
                        editorState.currentPageIndex = index
                    }
                }

                // Vertical scroll keeps its explicit end-of-document action.
                // Single-page mode uses a horizontal page-turn gesture.
                if !isReadOnly {
                    Button(action: addNewPage) {
                        Label("Add Page", systemImage: "plus.square")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 24)
                    .accessibilityIdentifier("vertical-scroll-add-page")
                }
            }
            .padding(.vertical, 24)
        }
        .background(Color(.systemGroupedBackground))
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    let target = verticalZoomBaseScale * value
                    pageZoomScale = min(max(target, 0.5), 4.0)
                }
                .onEnded { _ in
                    verticalZoomBaseScale = pageZoomScale
                }
        )
    }

    // MARK: - Navigation

    private var editorBottomBar: some View {
        GeometryReader { geometry in
                    EditorToolbar(
                        tool: $editorTool,
                        color: activeColor,
                        lineWidth: activeLineWidth,
                        eraserWidth: eraserWidth,
                        eraserStyle: eraserStyle,
                        lassoMode: lassoMode,
                        toolSettings: toolSettings,
                        availableWidth: geometry.size.width,
                        dock: .bottom,
                        isReadOnly: isReadOnly,
                        canUndo: editorCanUndo,
                        canRedo: editorCanRedo,
                        onUndo: { sendEditorCommand(.undo) },
                        onRedo: { sendEditorCommand(.redo) },
                        onInsert: { sendEditorCommand(.insert($0)) },
                        onInsertShape: { editorState.presentedPanel = .shapePicker }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 98)
        .background(.bar)
    }

    private var editorPageBar: some View {
        HStack(spacing: 0) {
            Button(action: prevPage) {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
            }
            .disabled(safePageIndex == 0)
            .accessibilityLabel("Previous Page")

            Button {
                editorState.presentedPanel = .overview
            } label: {
                Text("\(safePageIndex + 1)/\(sortedPages.count)")
                    .font(.subheadline.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(minWidth: 52, minHeight: 44)
            }
            .accessibilityLabel("Page \(safePageIndex + 1) of \(sortedPages.count), open overview")

            Button(action: nextPage) {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
            }
            .disabled(safePageIndex >= sortedPages.count - 1)
            .accessibilityLabel("Next Page")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(uiColor: .separator).opacity(0.35)))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("floating-page-controls")
    }

    private var editorTopActions: some View {
        HStack(spacing: 2) {
            if assistantEnabled {
                Button {
                    editorState.isAssistantPresented = true
                } label: {
                    Image(systemName: "sparkles")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Assistant")
                .accessibilityIdentifier("editor-assistant")
            }

            editorMoreMenu
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(uiColor: .separator).opacity(0.35)))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }

    private var editorMoreMenu: some View {
        Menu {
            Section("Mode") {
                Button(
                    isReadOnly ? "Enable Editing" : "Enter View-Only Mode",
                    systemImage: isReadOnly ? "pencil" : "eye.slash"
                ) {
                    editorState.isViewOnly.toggle()
                }
            }

            Section("Page") {
                Menu("Insert Page", systemImage: "plus.square") {
                    Button("Portrait Page", systemImage: PageOrientation.portrait.icon) {
                        addNewPage(orientation: .portrait)
                    }
                    Button("Landscape Page", systemImage: PageOrientation.landscape.icon) {
                        addNewPage(orientation: .landscape)
                    }
                }
                .disabled(isReadOnly)
                Button("Page Info", systemImage: "info.circle") {
                    editorState.presentedPanel = .pageInfo
                }
                Button("Page Style", systemImage: "paintbrush") {
                    sendEditorCommand(.showPageStyle)
                }
                .disabled(isReadOnly)
                Button("Show Source Text", systemImage: "doc.text.magnifyingglass") {
                    sendEditorCommand(.showSourceText)
                }
                Button("Duplicate Page", systemImage: "plus.square.on.square", action: duplicateCurrentPage)
                    .disabled(isReadOnly)
                Button("Export Page as PDF", systemImage: "square.and.arrow.up") {
                    sendEditorCommand(.exportPage)
                }
                Button("Scan Document", systemImage: "doc.viewfinder") {
                    sendEditorCommand(.scanDocument)
                }
                .disabled(isReadOnly)
                Button("Delete Page", systemImage: "trash", role: .destructive, action: deleteCurrentPage)
                    .disabled(isReadOnly || sortedPages.isEmpty)
            }

            Section("Handwriting") {
                Toggle("Draw with Finger", systemImage: "hand.draw", isOn: $allowsFingerDrawing)
                    .disabled(isReadOnly)
            }

            Section("Display") {
                Picker("Scroll Mode", selection: $scrollModeRaw) {
                    ForEach(ScrollMode.allCases, id: \.self) { mode in
                        Label(mode.label, systemImage: mode.icon).tag(mode.rawValue)
                    }
                }
            }

            Section("Notebook") {
                Picker("New Page Orientation", selection: Binding(
                    get: { PageOrientation(rawValue: notebook.defaultOrientation) ?? .portrait },
                    set: { orientation in
                        let previous = notebook.defaultOrientation
                        notebook.defaultOrientation = orientation.rawValue
                        if !saveChanges() { notebook.defaultOrientation = previous }
                    }
                )) {
                    ForEach(PageOrientation.allCases, id: \.self) { orientation in
                        Label(orientation.label, systemImage: orientation.icon).tag(orientation)
                    }
                }
                .disabled(isReadOnly)
                Button("Import PDF", systemImage: "doc.badge.plus") {
                    showingPDFImporter = true
                }
                .disabled(isReadOnly)
                Button("Export Notebook as PDF", systemImage: "square.and.arrow.up.on.square", action: exportNotebook)
            }

            Section("App") {
                Button("Settings", systemImage: "gearshape") {
                    editorState.presentedPanel = .settings
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More")
    }

    @ViewBuilder
    private func editorPanel(_ panel: EditorPresentedPanel) -> some View {
        switch panel {
        case .overview:
            NotebookOverviewGrid(
                notebook: notebook,
                selectedIndex: overviewSelectedIndex,
                isReadOnly: isReadOnly
            )
        case .pageInfo:
            if !sortedPages.isEmpty {
                PageInfoSheet(page: sortedPages[safePageIndex], notebook: notebook, isReadOnly: isReadOnly)
            }
        case .shapePicker:
            ShapePickerSheet { kind in
                sendEditorCommand(.insertShape(kind))
            }
        case .settings:
            BetterNotesSettingsSheet()
        }
    }

    private var keyboardShortcutButtons: some View {
        Group {
            Button("Undo") { sendEditorCommand(.undo) }.keyboardShortcut("z", modifiers: .command)
            Button("Redo") { sendEditorCommand(.redo) }.keyboardShortcut("z", modifiers: [.command, .shift])
            Button("Copy") { sendEditorCommand(.copy) }.keyboardShortcut("c", modifiers: .command)
            Button("Cut") { sendEditorCommand(.cut) }.keyboardShortcut("x", modifiers: .command)
            Button("Paste") { sendEditorCommand(.paste) }.keyboardShortcut("v", modifiers: .command)
            // Delete is bound with a modifier. A bare .delete shortcut is
            // global and swallowed the Delete key inside every text field in
            // the app (text boxes, assistant composer, rename, search).
            Button("Delete Selection") { sendEditorCommand(.deleteSelection) }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("New Page") { addNewPage() }.keyboardShortcut("n", modifiers: .command)
            Button("Previous Page") { prevPage() }.keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Next Page") { nextPage() }.keyboardShortcut(.rightArrow, modifiers: .command)
            // Labeled for what it actually does — it opens the page overview,
            // which is where page search lives.
            Button("Page Overview") { editorState.presentedPanel = .overview }
                .keyboardShortcut("f", modifiers: .command)
        }
        .frame(width: 1, height: 1)
        .opacity(0.001)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var assistantContent: some View {
        if !sortedPages.isEmpty {
            AssistantView(
                notebook: notebook,
                page: sortedPages[safePageIndex],
                isReadOnly: isReadOnly,
                canReplaceSelection: editorCanReplaceSelectedText,
                onOpenCitation: openAssistantCitation,
                onInsert: { sendEditorCommand(.insertAssistantText($0)) },
                onReplaceSelection: { sendEditorCommand(.replaceSelectedText($0)) },
                onCreateNote: createNoteFromAssistant,
                onDismiss: { editorState.isAssistantPresented = false }
            )
        }
    }

    private func openAssistantCitation(_ citation: SourceCitation) {
        editorState.isAssistantPresented = false
        if citation.notebookID == notebook.stableID,
           let pageID = citation.pageID,
           let index = sortedPages.firstIndex(where: { $0.stableID == pageID }) {
            setPageIndex(index)
        } else {
            onOpenAssistantSource(citation.notebookID, citation.pageID)
        }
    }

    private func createNoteFromAssistant(_ text: String) {
        guard !isReadOnly, !text.isEmpty else { return }
        let page = Page(index: sortedPages.count)
        page.title = "Assistant Note"
        page.backgroundHex = notebook.defaultBackgroundHex
        page.lineStyle = notebook.defaultLineStyle
        page.lineThickness = notebook.defaultLineThickness
        page.lineOpacity = notebook.defaultLineOpacity
        page.orientation = notebook.defaultOrientation
        page.notebook = notebook
        let pageSize = page.pageOrientation.size
        let element = PageElement(
            type: .textBox,
            x: pageSize.width / 2,
            y: min(pageSize.height / 2, 360),
            width: min(pageSize.width - 96, 480),
            height: 300
        )
        element.text = text
        element.fontSize = 15
        element.page = page
        page.appendElement(element)
        notebook.pages.append(page)
        context.insert(page)
        context.insert(element)
        notebook.modifiedAt = .now
        if saveChanges() { setPageIndex(sortedPages.count - 1, saveBeforeChange: false) }
    }

    private var activeHint: EditorHint? {
        if horizontalSizeClass == .compact {
            return allowsFingerDrawing && !panHintSeen ? .pan : nil
        }
        if !toolbarHintSeen { return .toolbar }
        if allowsFingerDrawing && !panHintSeen { return .pan }
        // Only worth mentioning when finger drawing is off and the user might
        // be wondering why their finger doesn't draw. It used to fire for
        // everyone, unprompted.
        if !allowsFingerDrawing && !fingerHintSeen { return .finger }
        if editorTool == .lasso && !lassoHintSeen { return .lasso }
        return nil
    }

    private func hintText(_ hint: EditorHint) -> String {
        switch hint {
        case .toolbar: return AppLocalization.text("Drag the toolbar handle to dock it at any edge.")
        case .pan: return AppLocalization.text("Use two fingers to move the page while finger drawing is on.")
        case .finger: return AppLocalization.text("Finger drawing is off, so your finger scrolls. Turn it on from the More menu.")
        case .lasso: return AppLocalization.text("Drag inside the selection to move it; use edge, corner, and rotation handles to transform it.")
        }
    }

    private func dismissHint(_ hint: EditorHint) {
        switch hint {
        case .toolbar: toolbarHintSeen = true
        case .pan: panHintSeen = true
        case .finger: fingerHintSeen = true
        case .lasso: lassoHintSeen = true
        }
    }

    private func nextPage() {
        guard safePageIndex < sortedPages.count - 1 else { return }
        setPageIndex(safePageIndex + 1)
    }

    private func prevPage() {
        guard safePageIndex > 0 else { return }
        setPageIndex(safePageIndex - 1)
    }

    private func handlePageSwipe(_ direction: PageSwipeDirection) {
        switch direction {
        case .previous:
            prevPage()
        case .next:
            // GoodNotes-style: swiping right-to-left on the last page creates
            // a new blank page and navigates to it automatically.
            if safePageIndex >= sortedPages.count - 1 {
                if !isReadOnly {
                    addNewPage()
                }
            } else {
                nextPage()
            }
        }
    }

    private func addNewPage() {
        addNewPage(orientation: PageOrientation(rawValue: notebook.defaultOrientation) ?? .portrait)
    }

    private func addNewPage(orientation: PageOrientation) {
        guard !isReadOnly else { return }
        let newIndex = sortedPages.count
        let page = Page(index: newIndex)
        page.lineStyle = notebook.defaultLineStyle
        page.lineThickness = notebook.defaultLineThickness
        page.lineOpacity = notebook.defaultLineOpacity
        page.backgroundHex = notebook.defaultBackgroundHex
        page.orientation = orientation.rawValue
        page.notebook = notebook
        notebook.pages.append(page)
        notebook.modifiedAt = .now
        _ = saveChanges()
        setPageIndex(newIndex, saveBeforeChange: false)
    }

    // MARK: - Notebook-level actions

    private func exportNotebook() {
        _ = saveChanges()
        // Same deferral as LibraryView.exportNotebook: this fires from the
        // "..." Menu's action closure while it's still dismissing, and
        // presenting the share sheet in that same run-loop turn races the
        // menu's own transition — UIKit can leave the sheet showing with
        // nothing drawn inside it. Waiting a turn lets the menu finish first.
        DispatchQueue.main.async {
            let data = PDFExport.renderNotebook(notebook)
            notebookPDFURL = PDFExport.writePDF(data, name: notebook.title)
            showingNotebookShare = true
        }
    }

    private func importPDF(_ result: Result<[URL], Error>) {
        guard !isReadOnly else { return }
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            try context.save()
            let startIndex = sortedPages.count

            // Run PDF import off the main thread to avoid blocking the UI on
            // large PDFs. Show a progress overlay while importing.
            isImportingPDF = true
            pdfImportTask?.cancel()
            pdfImportTask = Task { @MainActor in
                do {
                    let importedPages = try await Task.detached(priority: .userInitiated) {
                        try PDFImporter.pages(from: url)
                    }.value

                    guard !Task.isCancelled else {
                        isImportingPDF = false
                        return
                    }

                    guard !importedPages.isEmpty else {
                        throw PDFImportError.unreadableDocument
                    }
                    for (offset, importedPage) in importedPages.enumerated() {
                        let page = makePage(from: importedPage, index: startIndex + offset)
                        page.notebook = notebook
                        notebook.pages.append(page)
                    }
                    notebook.modifiedAt = .now
                    try context.save()
                    setPageIndex(startIndex, saveBeforeChange: false)
                } catch {
                    pdfImportError = error.localizedDescription
                }
                isImportingPDF = false
                pdfImportTask = nil
            }
        } catch {
            pdfImportError = error.localizedDescription
        }
    }

    private func makePage(from importedPage: PDFImporter.ImportedPage, index: Int) -> Page {
        let page = Page(index: index)
        page.orientation = importedPage.orientation
        page.lineStyle = PageLineStyle.blank.rawValue
        page.backgroundHex = "FFFFFF"
        page.ocrText = importedPage.extractedText
        page.ocrUpdatedAt = importedPage.extractedText.isEmpty ? nil : Date.now

        if let imageData = importedPage.imageData {
            let frame = importedPage.imageFrame
            let element = PageElement(
                type: .image,
                x: frame.midX,
                y: frame.midY,
                width: frame.width,
                height: frame.height
            )
            element.imageData = imageData
            element.isLocked = true
            element.page = page
            page.appendElement(element)
        }
        return page
    }

    // MARK: - Page-level actions

    private func duplicateCurrentPage() {
        guard !isReadOnly else { return }
        let pages = sortedPages
        guard safePageIndex < pages.count else { return }
        let src = pages[safePageIndex]
        let copy = PageOperations.clone(src, newIndex: pages.count, notebook: notebook)
        notebook.pages.append(copy)
        notebook.modifiedAt = .now
        _ = saveChanges()
        setPageIndex(sortedPages.count - 1, saveBeforeChange: false)
    }

    private func deleteCurrentPage() {
        guard !isReadOnly else { return }
        let pages = sortedPages
        guard !pages.isEmpty else { return }
        guard safePageIndex < pages.count else { return }

        let page = pages[safePageIndex]

        // Adjust index BEFORE deleting.
        let remaining = pages.count - 1
        let targetIndex: Int
        if currentPageIndex >= remaining {
            targetIndex = max(0, remaining - 1)
        } else {
            // Stay on the same index (which now points to the next page).
            targetIndex = safePageIndex
        }

        guard PageOperations.trash(page, in: notebook, isReadOnly: isReadOnly) else { return }
        recentlyDeletedPage = page
        deletionBanner.show(for: pageDeletionKey(page))
        _ = saveChanges()
        setPageIndex(targetIndex, saveBeforeChange: false)
    }

    private var sortedPages: [Page] {
        PageOperations.visiblePages(in: notebook)
    }

    private func pageDeletionKey(_ page: Page) -> String {
        String(describing: page.persistentModelID)
    }

    private var safePageIndex: Int {
        let count = sortedPages.count
        guard count > 0 else { return 0 }
        return min(max(0, currentPageIndex), count - 1)
    }

    private var pageTurnAnimation: Animation {
        .interactiveSpring(response: 0.28, dampingFraction: 0.88, blendDuration: 0.08)
    }

    private var pageTransition: AnyTransition {
        switch pageTurnDirection {
        case .forward:
            return .asymmetric(
                insertion: .move(edge: .trailing),
                removal: .move(edge: .leading)
            )
        case .backward:
            return .asymmetric(
                insertion: .move(edge: .leading),
                removal: .move(edge: .trailing)
            )
        }
    }

    private func floatingToolbar(in size: CGSize) -> some View {
        let dock = ToolbarDock(rawValue: toolbarDockRaw) ?? .top
        let isVertical = dock == .left || dock == .right
        return Group {
            if isVertical {
                VStack(spacing: 0) {
                    toolbarDragHandle(in: size)
                    Divider().frame(width: 30)
                    ScrollView(.vertical) { toolbarContent(in: size) }
                        .scrollIndicators(.hidden)
                }
            } else {
                HStack(spacing: 0) {
                    toolbarDragHandle(in: size)
                    Divider().frame(height: 30)
                    toolbarContent(in: size)
                }
            }
        }
        .frame(width: toolbarFrameWidth(in: size),
               height: isVertical ? min(max(size.height - 16, 1), verticalToolbarHeight) : nil,
               alignment: isVertical ? .top : .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("floating-editor-toolbar")
    }

    private func toolbarContent(in size: CGSize) -> some View {
        EditorToolbar(
                tool: $editorTool,
                color: activeColor,
                lineWidth: activeLineWidth,
                eraserWidth: eraserWidth,
                eraserStyle: eraserStyle,
                lassoMode: lassoMode,
                toolSettings: toolSettings,
                availableWidth: max(toolbarFrameWidth(in: size) - EditorToolbarLayout.toolbarChromeWidth, 1),
                preferredLayout: toolbarLayout(in: size),
                dock: ToolbarDock(rawValue: toolbarDockRaw) ?? .top,
                isReadOnly: isReadOnly,
                canUndo: editorCanUndo,
                canRedo: editorCanRedo,
                onUndo: { sendEditorCommand(.undo) },
                onRedo: { sendEditorCommand(.redo) },
                onInsert: { sendEditorCommand(.insert($0)) },
                onInsertShape: { if !sortedPages.isEmpty { editorState.presentedPanel = .shapePicker } }
            )
    }

    private var activeColor: Binding<Color> {
        Binding(
            get: { toolSettings.color(for: editorTool) },
            set: { toolSettings.setColor($0, for: editorTool) }
        )
    }

    private func sendEditorCommand(_ action: EditorCommand.Action) {
        guard !sortedPages.isEmpty else { return }
        editorCommand = EditorCommand(
            targetPageID: sortedPages[safePageIndex].persistentModelID,
            action: action
        )
    }

    private var activeLineWidth: Binding<CGFloat> {
        Binding(
            get: { toolSettings.width(for: editorTool) },
            set: { toolSettings.setWidth($0, for: editorTool) }
        )
    }

    private var eraserWidth: Binding<CGFloat> {
        Binding(
            get: { toolSettings.eraserWidth },
            set: { toolSettings.setEraserWidth($0) }
        )
    }

    private var eraserStyle: Binding<EraserStyle> {
        Binding(
            get: { toolSettings.eraserStyle },
            set: { toolSettings.setEraserStyle($0) }
        )
    }

    private var lassoMode: Binding<LassoMode> {
        Binding(
            get: { toolSettings.lassoMode },
            set: { toolSettings.setLassoMode($0) }
        )
    }

    private func toolbarDragHandle(in size: CGSize) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 38, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Move Toolbar")
            .highPriorityGesture(toolbarDragGesture(in: size))
    }

    private func toolbarDragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .updating($toolbarDragTranslation) { value, translation, _ in
                translation = value.translation
            }
            .updating($isDraggingToolbar) { _, isDragging, transaction in
                transaction.disablesAnimations = true
                isDragging = true
            }
            .onEnded { value in
                let proposed = CGSize(
                    width: editorToolbarOffset.width + value.translation.width,
                    height: editorToolbarOffset.height + value.translation.height
                )
                let dock = nearestToolbarDock(to: proposed, in: size)
                toolbarDockRaw = dock.rawValue
                setToolbarOffset(dockedToolbarOffset(in: size, dock: dock), animated: true)
            }
    }

    private func displayedToolbarOffset(in size: CGSize) -> CGSize {
        clampedToolbarOffset(
            CGSize(
                width: editorToolbarOffset.width + toolbarDragTranslation.width,
                height: editorToolbarOffset.height + toolbarDragTranslation.height
            ),
            in: size
        )
    }

    private func toolbarFrameWidth(in size: CGSize) -> CGFloat {
        if toolbarDockRaw == ToolbarDock.left.rawValue || toolbarDockRaw == ToolbarDock.right.rawValue {
            return 52
        }
        let limit = toolbarWidthLimit(in: size)
        return min(limit, preferredToolbarWidth(for: toolbarLayout(in: size)))
    }

    private func toolbarWidthLimit(in size: CGSize) -> CGFloat {
        let normalWidth = EditorToolbarLayout.frameWidth(for: size.width)
        guard ToolbarDock(rawValue: toolbarDockRaw) == .bottom else { return normalWidth }
        // A narrow iPad window cannot fit the full toolbar and the page pill
        // side by side. Let the toolbar use its compact layout before it can
        // cover the bottom-right page control.
        let pageBarWidth: CGFloat = 160
        let reservedCorner = 18 + pageBarWidth + 12
        return min(normalWidth, max(size.width - 16 - reservedCorner, 1))
    }

    private var activeToolbarControlCount: CGFloat {
        editorTool.supportsColor && editorTool.supportsSize ? 2 : 1
    }

    private var verticalToolbarHeight: CGFloat {
        // Drag handle, dividers, five drawing tools, active controls, four
        // commands, and the editor toolbar's vertical padding.
        44 + 3 + CGFloat(DrawingTool.allCases.count) * 44
            + activeToolbarControlCount * 44 + 3 * 44 + 8
    }

    private func preferredToolbarWidth(for layout: EditorToolbarLayout) -> CGFloat {
        switch layout {
        case .expanded: return 418 + activeToolbarControlCount * 44
        case .compact: return 51 + max(220, 136 + activeToolbarControlCount * 44)
        case .narrow: return 47 + max(220, activeToolbarControlCount * 44, 132)
        }
    }

    private func toolbarLayout(in size: CGSize) -> EditorToolbarLayout {
        let limit = toolbarWidthLimit(in: size)
        if limit >= preferredToolbarWidth(for: .expanded) { return .expanded }
        if limit >= preferredToolbarWidth(for: .compact) { return .compact }
        return .narrow
    }

    private func clampedToolbarOffset(_ proposed: CGSize, in size: CGSize) -> CGSize {
        let width = toolbarSize.width > 0 ? toolbarSize.width : toolbarFrameWidth(in: size)
        let height = toolbarSize.height > 0 ? toolbarSize.height : 44
        let maxX = max((size.width - width) / 2 - 16, 0)
        // This geometry starts below the navigation bar, so only retain a small
        // content-edge margin. Reserving nav-bar height here prevented use of
        // the top portion of the page.
        let minY: CGFloat = 8
        let maxY = max(size.height - height + floatingControlBottomOverflow, minY)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, minY), maxY)
        )
    }

    private func setToolbarOffset(_ offset: CGSize, animated: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = !animated
        transaction.animation = animated ? .snappy(duration: 0.18) : nil
        withTransaction(transaction) {
            editorToolbarOffset = offset
        }
    }

    private func nearestToolbarDock(to offset: CGSize, in size: CGSize) -> ToolbarDock {
        let clamped = clampedToolbarOffset(offset, in: size)
        let height = toolbarSize.height > 0 ? toolbarSize.height : 52
        let maxY = max(size.height - height + floatingControlBottomOverflow, 8)
        let width = toolbarSize.width > 0 ? toolbarSize.width : toolbarFrameWidth(in: size)
        let maxX = max((size.width - width) / 2 - 16, 0)
        let distances: [(ToolbarDock, CGFloat)] = [
            (.top, abs(clamped.height - 8)), (.bottom, abs(clamped.height - maxY)),
            (.left, abs(clamped.width + maxX)), (.right, abs(clamped.width - maxX))
        ]
        return distances.min(by: { $0.1 < $1.1 })?.0 ?? .top
    }

    private func dockedToolbarOffset(in size: CGSize, dock: ToolbarDock? = nil) -> CGSize {
        let chosen = dock ?? ToolbarDock(rawValue: toolbarDockRaw) ?? .top
        let height = toolbarSize.height > 0 ? toolbarSize.height : 52
        let maxY = max(size.height - height + floatingControlBottomOverflow, 8)
        let width = toolbarSize.width > 0 ? toolbarSize.width : toolbarFrameWidth(in: size)
        let maxX = max((size.width - width) / 2 - 16, 0)
        switch chosen {
        case .top: return CGSize(width: 0, height: 8)
        case .bottom:
            // Make room for the page pill in the bottom-right corner. On a
            // narrow iPad window the centered toolbar otherwise occupies
            // part of that corner, so shift it left just enough to clear it.
            let pageBarWidth: CGFloat = 160
            let gap: CGFloat = 12
            let pageBarLeading = size.width - 18 - pageBarWidth
            let centeredToolbarTrailing = (size.width + width) / 2
            let neededShift = max(0, centeredToolbarTrailing + gap - pageBarLeading)
            return CGSize(width: -min(neededShift, maxX), height: maxY)
        case .left: return CGSize(width: -maxX, height: min(max(editorToolbarOffset.height, 8), maxY))
        case .right: return CGSize(width: maxX, height: min(max(editorToolbarOffset.height, 8), maxY))
        }
    }

    private var overviewSelectedIndex: Binding<Int> {
        Binding(
            get: { safePageIndex },
            set: { setPageIndex($0) }
        )
    }

    private func setPageIndex(_ index: Int, saveBeforeChange: Bool = true) {
        let pages = sortedPages
        guard !pages.isEmpty else { return }
        let targetIndex = min(max(0, index), pages.count - 1)
        let oldIndex = safePageIndex
        guard targetIndex != oldIndex else { return }

        pageTurnDirection = targetIndex > oldIndex ? .forward : .backward
        if saveBeforeChange {
            _ = saveChanges()
        }
        withAnimation(pageTurnAnimation) {
            currentPageIndex = targetIndex
        }
    }

    @discardableResult
    private func saveChanges() -> Bool {
        do {
            try context.save()
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

}

private extension View {
    @ViewBuilder
    func assistantPresentation<Presented: View>(
        isCompact: Bool,
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Presented
    ) -> some View {
        if isCompact {
            fullScreenCover(isPresented: isPresented, content: content)
        } else {
            inspector(isPresented: isPresented) {
                content()
                    .inspectorColumnWidth(min: 380, ideal: 410, max: 440)
            }
        }
    }
}

enum PageTurnDirection {
    case forward
    case backward

    var incomingOffsetMultiplier: CGFloat {
        self == .forward ? 1 : -1
    }
}

protocol UndoBannerClock: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousUndoBannerClock: UndoBannerClock {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

struct ClosureUndoBannerClock: UndoBannerClock {
    let sleepAction: @Sendable (Duration) async throws -> Void

    func sleep(for duration: Duration) async throws {
        try await sleepAction(duration)
    }
}

@MainActor
final class DeletionUndoBannerModel: ObservableObject {
    @Published private(set) var isPresented = false

    private let duration: Duration
    private let clock: any UndoBannerClock
    private var generation = 0
    private var currentPageKey: String?
    private var dismissalTask: Task<Void, Never>?

    init(duration: Duration = .seconds(5), clock: any UndoBannerClock = ContinuousUndoBannerClock()) {
        self.duration = duration
        self.clock = clock
    }

    func show(for pageKey: String) {
        generation += 1
        let expectedGeneration = generation
        let expectedKey = pageKey
        currentPageKey = pageKey
        isPresented = true
        dismissalTask?.cancel()
        dismissalTask = Task { [weak self, clock, duration] in
            do {
                try await clock.sleep(for: duration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.expire(pageKey: expectedKey, generation: expectedGeneration)
        }
    }

    func clear() {
        generation += 1
        dismissalTask?.cancel()
        dismissalTask = nil
        currentPageKey = nil
        isPresented = false
    }

    private func expire(pageKey: String, generation expectedGeneration: Int) {
        guard isPresented, currentPageKey == pageKey, generation == expectedGeneration else { return }
        isPresented = false
        currentPageKey = nil
        dismissalTask = nil
    }
}

private struct UndoBanner: View {
    let message: String
    var onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.subheadline)
            Button("Undo", action: onUndo)
                .bold()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page-deletion-undo-banner")
    }
}

private struct FirstUseHintBanner: View {
    let text: String
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lightbulb")
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Button(action: onDismiss) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                .buttonStyle(.plain).accessibilityLabel("Dismiss Hint")
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

// MARK: - Bird's-eye overview grid

private struct NotebookOverviewGrid: View {
    private enum Mode: String, CaseIterable { case pages = "Pages", trash = "Trash" }
    let notebook: Notebook
    @Binding var selectedIndex: Int
    let isReadOnly: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var searchText = ""
    @State private var recentlyDeletedPage: Page?
    @State private var saveError: String?
    @State private var mode: Mode = .pages
    @State private var permanentlyDeletingPage: Page?
    @StateObject private var deletionBanner = DeletionUndoBannerModel()

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 20)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Notebook Overview", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)

                if mode == .pages { pagesGrid } else { trashGrid }
            }
            .navigationTitle(notebook.title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search pages")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("overview-done")
                }
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                if let recentlyDeletedPage, deletionBanner.isPresented {
                    UndoBanner(message: AppLocalization.text("Page moved to trash")) {
                        guard PageOperations.restore(recentlyDeletedPage, in: notebook, isReadOnly: isReadOnly) else { return }
                        if saveChanges() {
                            deletionBanner.clear()
                            self.recentlyDeletedPage = nil
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
            .alert("Couldn't Save", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("Try Again") { _ = saveChanges() }
                Button("Dismiss", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            .alert(
                permanentDeletionTitle,
                isPresented: Binding(
                    get: { permanentlyDeletingPage != nil },
                    set: { if !$0 { permanentlyDeletingPage = nil } }
                )
            ) {
                Button("Delete Permanently", role: .destructive) {
                    guard let page = permanentlyDeletingPage else { return }
                    permanentlyDelete(page)
                    permanentlyDeletingPage = nil
                }
                Button("Cancel", role: .cancel) { permanentlyDeletingPage = nil }
            }
        }
    }

    private var pagesGrid: some View {
        ScrollView {
            if visibleItems.isEmpty {
                ContentUnavailableView("No Pages Found", systemImage: "magnifyingglass", description: Text("Try a different page number or note text."))
                    .padding(.top, 80)
            } else {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(visibleItems) { item in
                        Button {
                            selectedIndex = item.index
                            dismiss()
                        } label: {
                            PageThumbnail(page: item.page, index: item.index + 1, isSelected: selectedIndex == item.index)
                        }
                        .buttonStyle(.plain)
                        .pageDraggable(pageDragID(item.page), isEnabled: !isReadOnly)
                        .dropDestination(for: String.self) { identifiers, _ in
                            guard let identifier = identifiers.first else { return false }
                            return reorderPage(identifier, before: item.page)
                        }
                        .contextMenu {
                            Button(item.page.isBookmarked ? "Remove Bookmark" : "Bookmark", systemImage: item.page.isBookmarked ? "bookmark.slash" : "bookmark") {
                                guard PageOperations.setBookmark(!item.page.isBookmarked, for: item.page, in: notebook, isReadOnly: isReadOnly) else { return }
                                _ = saveChanges()
                            }
                            .disabled(isReadOnly)
                            Button("Move Earlier", systemImage: "arrow.up") { movePage(item.page, direction: -1) }
                                .disabled(isReadOnly || item.index == 0)
                            Button("Move Later", systemImage: "arrow.down") { movePage(item.page, direction: 1) }
                                .disabled(isReadOnly || item.index >= sortedPages.count - 1)
                            Button("Duplicate Page", systemImage: "plus.square.on.square") { duplicatePage(item.page) }.disabled(isReadOnly)
                            Button("Delete Page", systemImage: "trash", role: .destructive) { deletePage(item.page) }
                                .disabled(isReadOnly || sortedPages.isEmpty)
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    private var trashGrid: some View {
        ScrollView {
            if trashPages.isEmpty {
                ContentUnavailableView("Page Trash Is Empty", systemImage: "trash", description: Text("Deleted pages remain here until permanently removed."))
                    .padding(.top, 80)
            } else {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(trashPages, id: \.id) { page in
                        VStack(spacing: 8) {
                            // Show the page's own former position, not its
                            // offset within the trash list.
                            PageThumbnail(page: page, index: page.index + 1, isSelected: false)
                            HStack(spacing: 8) {
                                Button("Restore", systemImage: "arrow.uturn.backward") { restorePage(page) }
                                    .buttonStyle(.bordered).disabled(isReadOnly)
                                Button("Delete", systemImage: "trash", role: .destructive) { permanentlyDeletingPage = page }
                                    .buttonStyle(.bordered).disabled(isReadOnly)
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    private var sortedPages: [Page] {
        PageOperations.visiblePages(in: notebook)
    }

    private var trashPages: [Page] { PageOperations.trashedPages(in: notebook) }

    private var visibleItems: [PageOverviewItem] {
        let items = sortedPages.enumerated().map { PageOverviewItem(index: $0.offset, page: $0.element) }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return items }
        return items.filter { item in
            let pageNumber = "\(item.index + 1)"
            return pageNumber.contains(query) || searchableText(for: item.page).contains(query)
        }
    }

    private func searchableText(for page: Page) -> String {
        var parts = [page.ocrText]
        parts.append(contentsOf: page.elements.compactMap(\.text))
        return parts.joined(separator: " ").lowercased()
    }

    private func movePage(_ page: Page, direction: Int) {
        guard !isReadOnly else { return }
        let pages = sortedPages
        guard let index = pages.firstIndex(where: { $0.id == page.id }) else { return }
        let target = index + direction
        guard pages.indices.contains(target) else { return }

        let other = pages[target]
        let oldIndex = page.index
        page.index = other.index
        other.index = oldIndex
        notebook.modifiedAt = .now

        if selectedIndex == index {
            selectedIndex = target
        } else if selectedIndex == target {
            selectedIndex = index
        }
        _ = saveChanges()
    }

    private func pageDragID(_ page: Page) -> String { String(describing: page.id) }

    private func reorderPage(_ identifier: String, before destination: Page) -> Bool {
        guard !isReadOnly, let source = sortedPages.first(where: { pageDragID($0) == identifier }), source.id != destination.id,
              let sourceIndex = sortedPages.firstIndex(where: { $0.id == source.id }),
              let destinationIndex = sortedPages.firstIndex(where: { $0.id == destination.id }) else { return false }
        let current = sortedPages
        // Capture the identity of the currently selected page BEFORE any
        // index mutation. Resolving it afterwards read an already-reordered
        // array and could land the selection on the wrong page.
        let selectedPageID = current.indices.contains(selectedIndex) ? current[selectedIndex].id : nil

        var reordered = current
        let moved = reordered.remove(at: sourceIndex)
        reordered.insert(moved, at: destinationIndex)
        for (index, page) in reordered.enumerated() { page.index = index }

        if let selectedPageID,
           let newIndex = reordered.firstIndex(where: { $0.id == selectedPageID }) {
            selectedIndex = newIndex
        }
        notebook.modifiedAt = .now
        return saveChanges()
    }

    private func restorePage(_ page: Page) {
        guard PageOperations.restore(page, in: notebook, isReadOnly: isReadOnly) else { return }
        _ = saveChanges()
    }

    private func permanentlyDelete(_ page: Page) {
        guard PageOperations.permanentlyDelete(page, from: notebook, isReadOnly: isReadOnly) else { return }
        context.delete(page)
        _ = saveChanges()
    }

    private func duplicatePage(_ page: Page) {
        guard !isReadOnly else { return }
        let copy = PageOperations.clone(page, newIndex: sortedPages.count, notebook: notebook)
        notebook.pages.append(copy)
        notebook.modifiedAt = .now
        _ = saveChanges()
        selectedIndex = sortedPages.count - 1
    }

    private func deletePage(_ page: Page) {
        guard !isReadOnly, !sortedPages.isEmpty else { return }
        guard PageOperations.trash(page, in: notebook, isReadOnly: isReadOnly) else { return }
        recentlyDeletedPage = page
        deletionBanner.show(for: String(describing: page.persistentModelID))
        selectedIndex = min(max(0, selectedIndex), max(0, sortedPages.count - 1))
        _ = saveChanges()
    }

    private var permanentDeletionTitle: String {
        guard let page = permanentlyDeletingPage else { return "Delete page permanently?" }
        let name = page.title.isEmpty ? "Page \(page.index + 1)" : page.title
        return "Delete \"\(name)\" permanently?"
    }

    @discardableResult
    private func saveChanges() -> Bool {
        do {
            try context.save()
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

}

private struct PageOverviewItem: Identifiable {
    let index: Int
    let page: Page

    var id: PersistentIdentifier {
        page.id
    }
}

private extension View {
    @ViewBuilder
    func pageDraggable(_ identifier: String, isEnabled: Bool) -> some View {
        if isEnabled {
            draggable(identifier)
        } else {
            self
        }
    }
}

private struct PageInfoSheet: View {
    @Bindable var page: Page
    @Bindable var notebook: Notebook
    let isReadOnly: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var saveError: String?
    @State private var draftTitle = ""
    @State private var draftIsBookmarked = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Page") {
                    TextField("Page title", text: $draftTitle)
                    Toggle("Bookmark", isOn: $draftIsBookmarked)
                }
                .disabled(isReadOnly)
            }
            .navigationTitle("Page Info")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                draftTitle = page.title
                draftIsBookmarked = page.isBookmarked
            }
            .toolbar {
                // Edits are held in local drafts so Cancel actually discards
                // them. They used to write straight through to the model,
                // which left no way to back out.
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        guard !isReadOnly else { dismiss(); return }
                        page.title = draftTitle
                        page.isBookmarked = draftIsBookmarked
                        page.modifiedAt = .now
                        notebook.modifiedAt = .now
                        do {
                            guard let context = page.modelContext else {
                                throw PageInfoError.pageUnavailable
                            }
                            try context.save()
                            dismiss()
                        } catch {
                            saveError = error.localizedDescription
                        }
                    }
                    .bold()
                }
            }
            .alert("Couldn't Save", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
        .interactiveDismissDisabled()
    }
}

private enum PageInfoError: LocalizedError {
    case pageUnavailable

    var errorDescription: String? { AppLocalization.text("This page is no longer available.") }
}

// MARK: - Page Thumbnail

struct PageThumbnail: View {
    let page: Page
    let index: Int
    var isSelected: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let transform = ThumbnailTransform(
                    pageSize: page.pageOrientation.size,
                    thumbnailSize: geometry.size
                )
                ZStack(alignment: .topLeading) {
                    PageBackground(
                        backgroundHex: page.backgroundHex,
                        lineStyle: page.lines,
                        orientation: page.pageOrientation,
                        lineThickness: page.effectiveLineThickness,
                        lineOpacity: page.effectiveLineOpacity
                    )
                    .frame(width: transform.renderedSize.width, height: transform.renderedSize.height)
                    .offset(x: transform.origin.x, y: transform.origin.y)

                    if let data = page.inkData,
                       let drawing = try? PKDrawing(data: data) {
                        Image(uiImage: drawing.image(
                            from: CGRect(origin: .zero, size: page.pageOrientation.size),
                            scale: 1
                        ))
                        .resizable()
                        .frame(width: transform.renderedSize.width, height: transform.renderedSize.height)
                        .offset(x: transform.origin.x, y: transform.origin.y)
                    }

                    ForEach(page.orderedElements) { element in
                        ThumbnailElement(element: element, scale: transform.scale)
                            .rotationEffect(.degrees(element.rotation))
                            .position(transform.point(CGPoint(x: element.posX, y: element.posY)))
                    }

                    if !page.hasContent {
                        VStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .font(.title2)
                            Text("Blank")
                                .font(.caption2)
                        }
                        .foregroundStyle(.tertiary)
                        .position(transform.point(CGPoint(
                            x: page.pageOrientation.size.width / 2,
                            y: page.pageOrientation.size.height / 2
                        )))
                    }
                }
            }
            .aspectRatio(page.pageOrientation.size.width / page.pageOrientation.size.height, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color(.separator), lineWidth: isSelected ? 3 : 0.5)
            )
            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
            HStack(spacing: 4) {
                if page.isBookmarked {
                    Image(systemName: "bookmark.fill")
                        .foregroundStyle(.tint)
                }
                Text(page.title.isEmpty ? "Page \(index)" : page.title)
                    .lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(page.title.isEmpty ? "Page \(index) thumbnail" : "\(page.title) thumbnail")
        .accessibilityIdentifier("page-thumbnail-\(index)")
    }
}

private struct ThumbnailElement: View {
    let element: PageElement
    let scale: CGFloat
    var body: some View {
        Group {
            switch element.type {
            case .textBox, .stickyNote:
                Text(element.text ?? "").font(.system(size: max(3, CGFloat(element.fontSize) * scale))).lineLimit(3)
            case .image:
                if let data = element.imageData, let img = UIImage(data: data) {
                    Image(uiImage: img).resizable().scaledToFit()
                }
            case .shape:
                Image(systemName: (ShapeKind(rawValue: element.shapeKind ?? "") ?? .circle).icon)
                    .resizable().scaledToFit().foregroundStyle(element.tint)
            case .audioRecording:
                Image(systemName: "waveform").foregroundStyle(.secondary)
            case .tape:
                Image(systemName: "bandage.fill").foregroundStyle(.gray)
            case .assistantNote:
                Text(element.text ?? "")
                    .font(.system(size: max(3, CGFloat(element.fontSize) * scale)))
                    .lineLimit(3)
                    .foregroundStyle(element.tint)
            }
        }
        .frame(width: element.width * scale, height: element.height * scale)
    }
}
