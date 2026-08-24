import SwiftUI
import SwiftData
import UniformTypeIdentifiers

private enum LibrarySection: String, CaseIterable {
    case notes, favorites, bookmarks, archive, trash

    var label: String {
        switch self {
        case .notes: return "Notes"
        case .favorites: return "Favorites"
        case .bookmarks: return "Bookmarks"
        case .archive: return "Archive"
        case .trash: return "Trash"
        }
    }

    var icon: String {
        switch self {
        case .notes: return "books.vertical"
        case .favorites: return "star"
        case .bookmarks: return "bookmark"
        case .archive: return "archivebox"
        case .trash: return "trash"
        }
    }

    var emptyTitle: String {
        switch self {
        case .notes: return "No Notebooks Yet"
        case .favorites: return "No Favorites"
        case .bookmarks: return "No Bookmarked Pages"
        case .archive: return "Archive Is Empty"
        case .trash: return "Trash Is Empty"
        }
    }

    var emptyMessage: String {
        switch self {
        case .notes: return "Create a notebook to start writing and drawing"
        case .favorites: return "Favorite notebooks appear here"
        case .bookmarks: return "Bookmark a page from the page overview and it appears here"
        case .archive: return "Archived notebooks stay out of your main library"
        case .trash: return "Deleted notebooks can be restored from here"
        }
    }

    /// Bookmarks lists pages rather than notebooks, so it uses its own layout.
    var showsPages: Bool { self == .bookmarks }
}

/// How long a trashed notebook or page is kept before it is purged on launch.
enum TrashRetention {
    static let days = 30

    static func isExpired(_ trashedAt: Date, now: Date = .now) -> Bool {
        guard let deadline = Calendar.current.date(byAdding: .day, value: days, to: trashedAt) else {
            return false
        }
        return now >= deadline
    }

    /// Short human label such as "Deleted today" or "Deleted 4 days ago".
    static func deletedLabel(_ trashedAt: Date, now: Date = .now) -> String {
        let elapsed = Calendar.current.dateComponents([.day], from: trashedAt, to: now).day ?? 0
        switch elapsed {
        case ..<1: return "Deleted today"
        case 1: return "Deleted yesterday"
        default: return "Deleted \(elapsed) days ago"
        }
    }

    /// Days left before automatic removal, floored at zero.
    static func daysRemaining(_ trashedAt: Date, now: Date = .now) -> Int {
        let elapsed = Calendar.current.dateComponents([.day], from: trashedAt, to: now).day ?? 0
        return max(0, days - elapsed)
    }
}

private enum LibrarySort: String, CaseIterable {
    case modified, created, title

    var label: String {
        switch self {
        case .modified: return "Last Modified"
        case .created: return "Date Created"
        case .title: return "Title"
        }
    }

    var icon: String {
        switch self {
        case .modified: return "clock"
        case .created: return "calendar"
        case .title: return "textformat"
        }
    }
}

private enum SearchDateFilter: String, CaseIterable {
    case any, week, month, year

    var label: String {
        switch self {
        case .any: return "Any Date"
        case .week: return "Past Week"
        case .month: return "Past Month"
        case .year: return "Past Year"
        }
    }
}

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var corpusStore: NoteCorpusStore
    @EnvironmentObject private var assistantCoordinator: AssistantCoordinator
    @Query(sort: \Notebook.modifiedAt, order: .reverse) private var notebooks: [Notebook]
    @State private var showingNewNotebook = false
    @State private var showingBackupImporter = false
    @State private var backupImportError: String?
    @State private var exportError: String?
    @State private var operationError: String?
    @State private var quickNotebook: Notebook?
    @State private var searchText = ""
    @State private var rankedSearchResults: [SearchResult] = []
    @State private var searchAnswer: AssistantReply?
    @State private var isSearching = false
    @State private var isAnsweringSearch = false
    @State private var searchNotebookFilter: UUID?
    @State private var searchContentFilter: NoteSourceKind?
    @State private var searchDateFilter = SearchDateFilter.any
    @State private var searchBookmarkedOnly = false
    @State private var searchIncludeArchived = true
    @State private var searchRequestID = UUID()
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var notebookToDelete: Notebook?
    @State private var notebookToPermanentlyDelete: Notebook?
    @State private var recentlyTrashedNotebook: Notebook?
    @State private var sharingURL: URL?
    @State private var showingShare = false
    @State private var renamingNotebook: Notebook?
    @State private var customizingCoverNotebook: Notebook?
    @State private var indexingNotebookID: PersistentIdentifier?
    @State private var librarySection: LibrarySection = .notes
    @State private var showingSettings = false
    @State private var selectedFolder: String?
    @State private var selectedTags: Set<String> = []
    @State private var confirmingEmptyTrash = false
    @State private var movingToFolderNotebook: Notebook?
    @State private var indexingTotal = 0
    @State private var indexingCompleted = 0
    @AppStorage(AppPreferenceKey.librarySort) private var librarySort = LibrarySort.modified.rawValue
    @AppStorage(AppPreferenceKey.searchAnswersEnabled) private var searchAnswersEnabled = true

    // Cloud sync state. Created together so the engine always references the
    // same auth instance.
    @StateObject private var syncState: SyncState
    @State private var showingSyncLogin = false
    @State private var showingSyncAccount = false

    init() {
        let auth = SyncAuth()
        let engine = SyncEngine(auth: auth)
        _syncState = StateObject(wrappedValue: SyncState(auth: auth, engine: engine))
    }

    private let columns = [
        GridItem(.adaptive(minimum: 200), spacing: 24)
    ]

    private var sectionNotebooks: [Notebook] {
        let selected = notebooks.filter { notebook in
            let matchesSection: Bool
            switch librarySection {
            case .notes:
                matchesSection = notebook.trashedAt == nil && !notebook.isArchived
            case .favorites:
                matchesSection = notebook.trashedAt == nil && !notebook.isArchived && notebook.isFavorite
            case .bookmarks:
                // Handled by bookmarkedPages; not a notebook listing.
                matchesSection = false
            case .archive:
                matchesSection = notebook.trashedAt == nil && notebook.isArchived
            case .trash:
                matchesSection = notebook.trashedAt != nil
            }
            return matchesSection && matchesFolder(notebook) && matchesTags(notebook)
        }
        switch LibrarySort(rawValue: librarySort) ?? .modified {
        case .modified: return selected.sorted { $0.modifiedAt > $1.modifiedAt }
        case .created: return selected.sorted { $0.createdAt > $1.createdAt }
        case .title: return selected.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    // MARK: - Folder and tag filtering

    /// Every folder name in use, sorted for display.
    private var allFolders: [String] {
        let names = notebooks
            .filter { $0.trashedAt == nil }
            .map(\.folderName)
            .filter { !$0.isEmpty }
        return Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Every tag in use, sorted for display.
    private var allTags: [String] {
        let tags = notebooks
            .filter { $0.trashedAt == nil }
            .flatMap(\.tags)
        return Array(Set(tags)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func folderCount(_ folder: String) -> Int {
        notebooks.filter { $0.trashedAt == nil && $0.folderName == folder }.count
    }

    private func matchesFolder(_ notebook: Notebook) -> Bool {
        guard let selectedFolder else { return true }
        return notebook.folderName == selectedFolder
    }

    /// A notebook must carry every selected tag (AND), which is what makes
    /// stacking chips useful for narrowing down.
    private func matchesTags(_ notebook: Notebook) -> Bool {
        guard !selectedTags.isEmpty else { return true }
        return selectedTags.isSubset(of: Set(notebook.tags))
    }

    private var hasActiveFilters: Bool {
        selectedFolder != nil || !selectedTags.isEmpty
    }

    private func clearFilters() {
        selectedFolder = nil
        selectedTags.removeAll()
    }

    /// Bookmarked pages across every live notebook, newest first.
    private var bookmarkedPages: [(notebook: Notebook, page: Page)] {
        notebooks
            .filter { $0.trashedAt == nil && matchesFolder($0) && matchesTags($0) }
            .flatMap { notebook in
                PageOperations.visiblePages(in: notebook)
                    .filter(\.isBookmarked)
                    .map { (notebook: notebook, page: $0) }
            }
            .sorted { $0.page.modifiedAt > $1.page.modifiedAt }
    }

    private var syncableNotebooks: [Notebook] {
        notebooks.filter { notebook in
            // Live notebooks always sync. Trashed ones sync too — but only if
            // they were pushed before (they have a cloudID), so the server
            // learns about the deletion instead of keeping a copy that a later
            // pull would resurrect. A notebook trashed before it ever synced
            // has nothing to tell the server about.
            if notebook.trashedAt == nil { return true }
            return !(notebook.cloudID ?? "").isEmpty
        }
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    librarySidebar
                } detail: {
                    libraryNavigation
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                libraryNavigation
            }
        }
        .environmentObject(syncState.engine)
    }

    /// Main library content. Extracted from `libraryNavigation` because the
    /// combined body exceeded what the SwiftUI type-checker will solve.
    @ViewBuilder
    private var libraryContent: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchResults
            } else if librarySection.showsPages {
                bookmarksContent
            } else if sectionNotebooks.isEmpty {
                VStack(spacing: 0) {
                    tagFilterBar
                    Spacer(minLength: 0)
                    if hasActiveFilters {
                        filteredEmptyState
                    } else {
                        emptyState
                    }
                    Spacer(minLength: 0)
                }
            } else {
                ScrollView {
                    tagFilterBar
                    LazyVGrid(columns: columns, spacing: 28) {
                        ForEach(sectionNotebooks) { notebook in
                            VStack(spacing: 0) {
                                NavigationLink {
                                    NotebookWorkspaceView(initialNotebook: notebook, sidebarVisibility: $columnVisibility)
                                } label: {
                                    NotebookCover(notebook: notebook)
                                }
                                .buttonStyle(.plain)
                                .disabled(librarySection == .trash)

                                if librarySection == .trash, let trashedAt = notebook.trashedAt {
                                    Text(TrashRetention.deletedLabel(trashedAt))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text("Removed in \(TrashRetention.daysRemaining(trashedAt)) days")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }

                                Menu {
                                    notebookActions(for: notebook)
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.title3)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("More actions for \(notebook.title)")
                            }
                        }
                    }
                    .padding(28)
                }
            }
        }
    }

    // The library body is split into stages. As one chained expression it
    // exceeded what the SwiftUI type-checker will solve in reasonable time.
    private var libraryNavigation: some View {
        NavigationStack {
            libraryStageD
        }
    }

    private var libraryStageA: some View {
        libraryContent
        .navigationTitle(horizontalSizeClass == .regular ? librarySection.label : "BetterNotes")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search notebooks, text, handwriting")
        .onSubmit(of: .search) { performSearch() }
        .onChange(of: searchText) { _, newValue in
            assistantCoordinator.cancel()
            searchRequestID = UUID()
            rankedSearchResults = []
            searchAnswer = nil
            isAnsweringSearch = false
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                isSearching = false
                return
            }
            // Debounce: wait 300ms after the last keystroke before
            // performing the search. Without this, every keystroke
            // triggers a full corpus rebuild + search, which hangs the UI.
            searchDebounceTask?.cancel()
            isSearching = true
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                performSearch()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if horizontalSizeClass == .compact {
                    Menu {
                        Section("Library Section") {
                            ForEach(LibrarySection.allCases, id: \.self) { section in
                                Button {
                                    librarySection = section
                                } label: {
                                    Label(section.label, systemImage: librarySection == section ? "checkmark" : section.icon)
                                }
                            }
                        }
                        Section("Sort") {
                            ForEach(LibrarySort.allCases, id: \.self) { sort in
                                Button {
                                    librarySort = sort.rawValue
                                } label: {
                                    Label(sort.label, systemImage: librarySort == sort.rawValue ? "checkmark" : sort.icon)
                                }
                            }
                        }
                    } label: {
                        Label(librarySection.label, systemImage: librarySection.icon)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 4) {
                    Button {
                        if syncState.auth.isLoggedIn {
                            showingSyncAccount = true
                        } else {
                            showingSyncLogin = true
                        }
                    } label: {
                        Group {
                            if syncState.engine.isSyncing {
                                ProgressView()
                            } else {
                                Image(systemName: syncState.auth.isLoggedIn ? "icloud.fill" : "icloud")
                                    .font(.title3)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                    .accessibilityLabel(
                        syncState.engine.isSyncing
                            ? "Syncing Notes"
                            : (syncState.auth.isLoggedIn ? "Cloud Sync Account" : "Sign in to Cloud Sync")
                    )

                    Button {
                        showingNewNotebook = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.title3.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                    .accessibilityLabel("New Notebook")
                    .accessibilityIdentifier("library-new-notebook")

                    Menu {
                        if librarySection == .trash && !sectionNotebooks.isEmpty {
                            Section("Trash") {
                                Button("Empty Trash", systemImage: "trash.slash", role: .destructive) {
                                    confirmingEmptyTrash = true
                                }
                                .accessibilityIdentifier("library-empty-trash")
                            }
                        }
                        Section("Create and Import") {
                            Button("Quick Note", systemImage: "square.and.pencil") {
                                createQuickNote()
                            }
                            Button("Import BetterNotes Backup", systemImage: "square.and.arrow.down") {
                                showingBackupImporter = true
                            }
                        }
                        Section("App") {
                            Button("Settings", systemImage: "gearshape") {
                                showingSettings = true
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                    .accessibilityLabel("More")
                }
            }
        }
    }

    private var libraryStageB: some View {
        libraryStageA
        .sheet(isPresented: $showingNewNotebook) {
            NewNotebookSheet()
        }
        .sheet(isPresented: $showingSettings) {
            BetterNotesSettingsSheet()
        }
        .fileImporter(
            isPresented: $showingBackupImporter,
            allowedContentTypes: [UTType(filenameExtension: "betternotes") ?? .json],
            allowsMultipleSelection: false
        ) { result in
            importBackup(result)
        }
        .navigationDestination(isPresented: Binding(
            get: { quickNotebook != nil },
            set: { if !$0 { quickNotebook = nil } }
        )) {
            if let quickNotebook {
                NotebookWorkspaceView(initialNotebook: quickNotebook, sidebarVisibility: $columnVisibility)
            }
        }
        .sheet(isPresented: $showingSyncLogin) {
            SyncLoginView(auth: syncState.auth)
                .onDisappear {
                    // After successful login, kick off a sync.
                    if syncState.auth.isLoggedIn {
                        Task { await syncState.engine.fullSync(notebooks: syncableNotebooks, into: context) }
                    }
                }
        }
        .sheet(isPresented: $showingSyncAccount) {
            SyncAccountSheet(
                auth: syncState.auth,
                engine: syncState.engine,
                onSyncNow: {
                    Task { await syncState.engine.fullSync(notebooks: syncableNotebooks, into: context) }
                }
            )
        }
    }

    private var libraryStageC: some View {
        libraryStageB
        .refreshable {
            // Pull-to-refresh triggers a full sync when logged in. When signed
            // out it used to complete silently, which read as a broken sync.
            if syncState.auth.isLoggedIn {
                await syncState.engine.fullSync(notebooks: syncableNotebooks, into: context)
            } else {
                showingSyncLogin = true
            }
        }
        .confirmationDialog(
            "Empty Trash?",
            isPresented: $confirmingEmptyTrash,
            titleVisibility: .visible
        ) {
            Button("Delete \(sectionNotebooks.count) Notebooks", role: .destructive) {
                emptyTrash()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every notebook in the trash and cannot be undone.")
        }
        .sheet(item: $movingToFolderNotebook) { notebook in
            MoveToFolderSheet(notebook: notebook, existingFolders: allFolders)
        }
        .task {
            await corpusStore.rebuild(notebooks: notebooks)
        }
        .task {
            purgeExpiredTrash()
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteCorpusDidChange)) { _ in
            corpusStore.scheduleRebuild(notebooks: notebooks)
        }
        .task {
            if syncState.auth.isLoggedIn && syncState.engine.lastSyncDate == nil {
                await syncState.engine.fullSync(notebooks: syncableNotebooks, into: context)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active, syncState.auth.isLoggedIn, !syncState.engine.isSyncing else { return }
            Task { await syncState.engine.fullSync(notebooks: syncableNotebooks, into: context) }
        }
    }

    private var libraryStageD: some View {
        libraryStageC
        .overlay {
            if indexingNotebookID != nil, indexingTotal > 0 {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView(value: Double(indexingCompleted), total: Double(indexingTotal))
                            .progressViewStyle(.linear)
                            .frame(width: 220)
                        Text("Reading handwriting — page \(min(indexingCompleted + 1, indexingTotal)) of \(indexingTotal)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .transition(.opacity)
                .accessibilityIdentifier("handwriting-index-progress")
            }
        }
        .sheet(isPresented: $showingShare) {
            if let url = sharingURL {
                ShareSheet(items: [url])
            }
        }
        .sheet(item: $renamingNotebook) { nb in
            RenameNotebookSheet(notebook: nb)
        }
        .sheet(item: $customizingCoverNotebook) { nb in
            CoverCustomizationSheet(notebook: nb)
        }
        .confirmationDialog(
            "Move \"\(notebookToDelete?.title ?? "")\" to Trash?",
            isPresented: Binding(
                get: { notebookToDelete != nil },
                set: { if !$0 { notebookToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let nb = notebookToDelete { deleteNotebook(nb) }
                notebookToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                notebookToDelete = nil
            }
        } message: {
            Text("You can restore it later from Trash.")
        }
        .alert("Backup Import Failed", isPresented: Binding(
            get: { backupImportError != nil },
            set: { if !$0 { backupImportError = nil } }
        )) {
            Button("OK", role: .cancel) { backupImportError = nil }
        } message: {
            Text(backupImportError ?? "")
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .alert("Couldn’t Save Changes", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("Try Again") { _ = saveChanges() }
            Button("Dismiss", role: .cancel) { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
        .confirmationDialog(
            "Delete \"\(notebookToPermanentlyDelete?.title ?? "")\" permanently?",
            isPresented: Binding(
                get: { notebookToPermanentlyDelete != nil },
                set: { if !$0 { notebookToPermanentlyDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                if let notebook = notebookToPermanentlyDelete {
                    context.delete(notebook)
                    _ = saveChanges()
                }
                notebookToPermanentlyDelete = nil
            }
            Button("Cancel", role: .cancel) { notebookToPermanentlyDelete = nil }
        } message: {
            Text("This removes every page and cannot be undone.")
        }
        .safeAreaInset(edge: .bottom) {
            if let recentlyTrashedNotebook {
                HStack(spacing: 12) {
                    Text("Notebook moved to trash")
                    Button("Undo") { restoreNotebook(recentlyTrashedNotebook) }
                        .bold()
                }
                .font(.subheadline)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 6)
            }
        }
    }

    /// Horizontal chip row for tag filtering, plus the active-folder chip so
    /// compact widths (which have no sidebar) can still clear a folder.
    @ViewBuilder
    private var tagFilterBar: some View {
        if !allTags.isEmpty || hasActiveFilters {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let selectedFolder {
                        Button {
                            self.selectedFolder = nil
                        } label: {
                            Label(selectedFolder, systemImage: "folder.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Clear folder filter \(selectedFolder)")
                    }

                    ForEach(allTags, id: \.self) { tag in
                        let isOn = selectedTags.contains(tag)
                        Button {
                            if isOn { selectedTags.remove(tag) } else { selectedTags.insert(tag) }
                        } label: {
                            Text("#\(tag)")
                        }
                        .buttonStyle(.bordered)
                        .tint(isOn ? .accentColor : .secondary)
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                        .accessibilityIdentifier("library-tag-\(tag)")
                    }

                    if hasActiveFilters {
                        Button("Clear", systemImage: "xmark.circle", action: clearFilters)
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("library-clear-filters")
                    }
                }
                .font(.caption)
                .padding(.horizontal, 28)
                .padding(.top, 12)
            }
        }
    }

    private var filteredEmptyState: some View {
        ContentUnavailableView {
            Label("No Matching Notebooks", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("No notebooks in \(librarySection.label) match the current folder and tag filters.")
        } actions: {
            Button("Clear Filters", action: clearFilters)
                .buttonStyle(.borderedProminent)
        }
    }

    private var bookmarksContent: some View {
        Group {
            if bookmarkedPages.isEmpty {
                VStack(spacing: 0) {
                    tagFilterBar
                    Spacer(minLength: 0)
                    emptyState
                    Spacer(minLength: 0)
                }
            } else {
                ScrollView {
                    tagFilterBar
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 20)], spacing: 24) {
                        ForEach(bookmarkedPages, id: \.page.id) { entry in
                            NavigationLink {
                                NotebookWorkspaceView(
                                    initialNotebook: entry.notebook,
                                    initialPageID: entry.page.persistentModelID,
                                    sidebarVisibility: $columnVisibility
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    PageThumbnail(page: entry.page, index: entry.page.index + 1)
                                    Text(entry.notebook.title)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("bookmark-page-\(entry.page.index + 1)")
                        }
                    }
                    .padding(28)
                }
            }
        }
    }

    private var librarySidebar: some View {
        List {
            Section("Library") {
                ForEach(LibrarySection.allCases, id: \.self) { section in
                    Button {
                        librarySection = section
                    } label: {
                        HStack {
                            Label(section.label, systemImage: section.icon)
                            Spacer()
                            if librarySection == section {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(librarySection == section ? .isSelected : [])
                }
            }

            if !allFolders.isEmpty {
                Section("Folders") {
                    Button {
                        selectedFolder = nil
                    } label: {
                        HStack {
                            Label("All Folders", systemImage: "tray.full")
                            Spacer()
                            if selectedFolder == nil {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedFolder == nil ? .isSelected : [])

                    ForEach(allFolders, id: \.self) { folder in
                        Button {
                            selectedFolder = (selectedFolder == folder) ? nil : folder
                        } label: {
                            HStack {
                                Label(folder, systemImage: "folder")
                                Spacer()
                                Text("\(folderCount(folder))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if selectedFolder == folder {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedFolder == folder ? .isSelected : [])
                        .accessibilityIdentifier("library-folder-\(folder)")
                    }
                }
            }

            Section("Sort") {
                Picker("Notebook sort", selection: $librarySort) {
                    ForEach(LibrarySort.allCases, id: \.self) { sort in
                        Label(sort.label, systemImage: sort.icon).tag(sort.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .navigationTitle("BetterNotes")
        .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 280)
    }

    private var searchResults: some View {
        List {
            Section {
                searchFilterBar
            }

            if isSearching {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Updating results...").foregroundStyle(.secondary)
                    }
                }
            }

            if isAnsweringSearch || searchAnswer != nil {
                Section("Ask Notes") {
                    if isAnsweringSearch {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Synthesizing an answer...").foregroundStyle(.secondary)
                        }
                    }
                    if let answer = searchAnswer {
                        Text(AssistantMarkdown.render(answer.text))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("search-ai-answer")
                        if let notice = answer.notice {
                            Label(notice, systemImage: "iphone")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(answer.citations) { citation in
                            if let destination = searchDestination(for: citation) {
                                NavigationLink {
                                    NotebookWorkspaceView(initialNotebook: destination.notebook, initialPageID: destination.page?.persistentModelID, sidebarVisibility: $columnVisibility)
                                } label: {
                                    Label("[\(citation.token)] \(citation.sourceLabel)", systemImage: "doc.text.magnifyingglass")
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            }

            if rankedSearchResults.isEmpty && !isSearching {
                Section {
                    ContentUnavailableView.search(text: searchText)
                }
            } else {
                ForEach(groupedRankedResults, id: \.notebookID) { group in
                    Section(group.notebookTitle) {
                        ForEach(group.results) { result in
                            if let destination = searchDestination(for: result.chunk) {
                                NavigationLink {
                                    NotebookWorkspaceView(
                                        initialNotebook: destination.notebook,
                                        initialPageID: destination.page?.persistentModelID,
                                        sidebarVisibility: $columnVisibility
                                    )
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Label(result.chunk.pageTitle ?? result.chunk.label, systemImage: resultIcon(result.chunk.sourceKind))
                                                .font(.body.weight(.medium))
                                            Spacer()
                                            Text(result.chunk.sourceKind.label)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(highlightedSnippet(result.snippet, terms: result.highlights))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(3)
                                    }
                                    .padding(.vertical, 3)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var searchFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Button("All Notebooks") { searchNotebookFilter = nil; performSearch() }
                    ForEach(notebooks.filter { $0.trashedAt == nil }) { notebook in
                        Button(notebook.title) { searchNotebookFilter = notebook.stableID; performSearch() }
                    }
                } label: {
                    Label(searchNotebookName, systemImage: "book.closed")
                }
                Menu {
                    Button("All Content") { searchContentFilter = nil; performSearch() }
                    ForEach(NoteSourceKind.allCases, id: \.self) { kind in
                        Button(kind.label) { searchContentFilter = kind; performSearch() }
                    }
                } label: {
                    Label(searchContentFilter?.label ?? "All Content", systemImage: "doc.text")
                }
                Menu {
                    ForEach(SearchDateFilter.allCases, id: \.self) { dateFilter in
                        Button(dateFilter.label) { searchDateFilter = dateFilter; performSearch() }
                    }
                } label: {
                    Label(searchDateFilter.label, systemImage: "calendar")
                }
                Toggle(isOn: Binding(
                    get: { searchBookmarkedOnly },
                    set: { searchBookmarkedOnly = $0; performSearch() }
                )) {
                    Image(systemName: "bookmark")
                }
                .toggleStyle(.button)
                .accessibilityLabel("Bookmarked pages only")
                Toggle(isOn: Binding(
                    get: { searchIncludeArchived },
                    set: { searchIncludeArchived = $0; performSearch() }
                )) {
                    Image(systemName: "archivebox")
                }
                .toggleStyle(.button)
                .accessibilityLabel("Include archived notes")

                if searchAnswersEnabled && !rankedSearchResults.isEmpty {
                    Button {
                        askNotesAboutSearch()
                    } label: {
                        Label("Ask Notes", systemImage: "sparkles")
                    }
                    .disabled(isSearching || isAnsweringSearch)
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private var groupedRankedResults: [(notebookID: UUID, notebookTitle: String, results: [SearchResult])] {
        let grouped = Dictionary(grouping: rankedSearchResults, by: { $0.chunk.notebookID })
        return grouped.map { id, results in
            (id, results.first?.chunk.notebookTitle ?? "Notebook", results)
        }.sorted { $0.notebookTitle.localizedStandardCompare($1.notebookTitle) == .orderedAscending }
    }

    private var searchNotebookName: String {
        guard let searchNotebookFilter else { return "All Notebooks" }
        return notebooks.first(where: { $0.stableID == searchNotebookFilter })?.title ?? "Notebook"
    }

    private func performSearch() {
        let queryText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !queryText.isEmpty else { return }
        assistantCoordinator.cancel()
        let requestID = UUID()
        searchRequestID = requestID
        rankedSearchResults = []
        searchAnswer = nil
        isSearching = true
        isAnsweringSearch = false
        Task {
            await corpusStore.rebuild(notebooks: notebooks)
            guard searchText.trimmingCharacters(in: .whitespacesAndNewlines) == queryText,
                  searchRequestID == requestID else { return }
            let results = await corpusStore.indexer.search(SearchQuery(
                text: queryText,
                filters: activeSearchFilters,
                limit: 50
            ))
            guard searchText.trimmingCharacters(in: .whitespacesAndNewlines) == queryText,
                  searchRequestID == requestID else { return }
            rankedSearchResults = results
            isSearching = false
        }
    }

    private func askNotesAboutSearch() {
        let queryText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard searchAnswersEnabled, !queryText.isEmpty, !rankedSearchResults.isEmpty else { return }
        let requestID = searchRequestID
        searchAnswer = nil
        isAnsweringSearch = true
        assistantCoordinator.answerSearch(question: queryText, results: rankedSearchResults) { reply in
            guard searchText.trimmingCharacters(in: .whitespacesAndNewlines) == queryText,
                  searchRequestID == requestID else { return }
            searchAnswer = reply
            isAnsweringSearch = false
        }
    }

    private var activeSearchFilters: SearchFilters {
        let calendar = Calendar.current
        let modifiedAfter: Date?
        switch searchDateFilter {
        case .any: modifiedAfter = nil
        case .week: modifiedAfter = calendar.date(byAdding: .day, value: -7, to: .now)
        case .month: modifiedAfter = calendar.date(byAdding: .month, value: -1, to: .now)
        case .year: modifiedAfter = calendar.date(byAdding: .year, value: -1, to: .now)
        }
        return SearchFilters(
            notebookID: searchNotebookFilter,
            contentKinds: searchContentFilter.map { [$0] } ?? [],
            modifiedAfter: modifiedAfter,
            bookmarkedOnly: searchBookmarkedOnly,
            includeArchived: searchIncludeArchived
        )
    }

    private func searchDestination(for chunk: NoteChunk) -> (notebook: Notebook, page: Page?)? {
        guard let notebook = notebooks.first(where: { $0.stableID == chunk.notebookID && $0.trashedAt == nil }) else { return nil }
        let page = chunk.pageID.flatMap { id in notebook.pages.first { $0.stableID == id && $0.trashedAt == nil } }
        return (notebook, page)
    }

    private func searchDestination(for citation: SourceCitation) -> (notebook: Notebook, page: Page?)? {
        guard let notebook = notebooks.first(where: { $0.stableID == citation.notebookID && $0.trashedAt == nil }) else { return nil }
        let page = citation.pageID.flatMap { id in notebook.pages.first { $0.stableID == id && $0.trashedAt == nil } }
        return (notebook, page)
    }

    private func highlightedSnippet(_ value: String, terms: [String]) -> AttributedString {
        var attributed = AttributedString(value)
        for term in terms where !term.isEmpty {
            var searchRange = attributed.startIndex..<attributed.endIndex
            while let range = attributed[searchRange].range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                attributed[range].font = .caption.bold()
                attributed[range].foregroundColor = .accentColor
                searchRange = range.upperBound..<attributed.endIndex
            }
        }
        return attributed
    }

    private func resultIcon(_ kind: NoteSourceKind) -> String {
        switch kind {
        case .notebookTitle, .tags: return "book.closed"
        case .transcript: return "waveform"
        case .imageText: return "photo"
        case .ocr: return "text.viewfinder"
        default: return "doc.text"
        }
    }

    @ViewBuilder
    private func notebookActions(for notebook: Notebook) -> some View {
        if notebook.trashedAt != nil {
            Section("Organize") {
                Button("Restore", systemImage: "arrow.uturn.backward") {
                    restoreNotebook(notebook)
                }
            }
            Section("Delete") {
                Button("Delete Permanently", systemImage: "trash", role: .destructive) {
                    notebookToPermanentlyDelete = notebook
                }
            }
        } else {
            Section("Organize") {
                Button(notebook.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: notebook.isFavorite ? "star.slash" : "star") {
                    toggleFavorite(notebook)
                }
                Button(notebook.isArchived ? "Move to Notes" : "Archive", systemImage: "archivebox") {
                    toggleArchive(notebook)
                }
                Button("Move to Folder", systemImage: "folder") {
                    movingToFolderNotebook = notebook
                }
            }
            Section("Export") {
                Button("Export as PDF", systemImage: "square.and.arrow.up") {
                    exportNotebook(notebook)
                }
                Button("Export Editable Backup", systemImage: "externaldrive") {
                    exportBackup(notebook)
                }
            }
            Section("Edit") {
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    duplicateNotebook(notebook)
                }
                Button("Update Handwriting Search", systemImage: "text.viewfinder") {
                    updateHandwritingIndex(for: notebook)
                }
                .disabled(indexingNotebookID == notebook.id)
                Button("Rename", systemImage: "pencil") {
                    renamingNotebook = notebook
                }
                Button("Customize Cover", systemImage: "paintbrush.pointed") {
                    customizingCoverNotebook = notebook
                }
            }
            Section("Delete") {
                Button("Move to Trash", systemImage: "trash", role: .destructive) {
                    notebookToDelete = notebook
                }
            }
        }
    }

// MARK: - Notebook Workspace

private struct NotebookWorkspaceView: View {
    let initialNotebook: Notebook
    let initialPageID: PersistentIdentifier?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \Notebook.modifiedAt, order: .reverse) private var notebooks: [Notebook]
    @State private var openTabIDs: [PersistentIdentifier]
    @State private var selectedTabID: PersistentIdentifier?
    @StateObject private var editorState: EditorActionState
    @Binding var sidebarVisibility: NavigationSplitViewVisibility

    init(initialNotebook: Notebook, initialPageID: PersistentIdentifier? = nil, sidebarVisibility: Binding<NavigationSplitViewVisibility> = .constant(.all)) {
        self.initialNotebook = initialNotebook
        self.initialPageID = initialPageID
        self._sidebarVisibility = sidebarVisibility
        let id = initialNotebook.id
        let pages = initialNotebook.pages.filter { $0.trashedAt == nil }.sorted { $0.index < $1.index }
        let initialIndex = initialPageID.flatMap { pageID in
            pages.firstIndex { $0.persistentModelID == pageID }
        } ?? 0
        _openTabIDs = State(initialValue: [id])
        _selectedTabID = State(initialValue: id)
        _editorState = StateObject(wrappedValue: EditorActionState(currentPageIndex: initialIndex))
    }

    var body: some View {
        notebookContent
            .background(Color(.systemGroupedBackground).ignoresSafeArea(.container, edges: .bottom))
            .background(DisableInteractivePop())
            .navigationBarBackButtonHidden(true)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(selectedNotebook?.title ?? "Notebook")
                            .font(.headline)
                            .lineLimit(1)
                        if editorState.isViewOnly {
                            Text("View Only")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(editorHeadingAccessibilityLabel)
                    .accessibilityIdentifier("notebook-title")
                }
                // Compact tab switcher in the trailing toolbar. Replaces the
                // old sidebar that wasted ~250pt of horizontal space.
                // Always shown: it is the only entry point to "Open Notebook",
                // so gating it on openTabIDs.count > 1 made a second tab
                // impossible to open in the first place.
                ToolbarItemGroup(placement: .topBarTrailing) {
                    tabSwitcherMenu
                }
            }
            .onAppear(perform: reconcileTabs)
            .onChange(of: notebooks.count) { _, _ in reconcileTabs() }
            .onAppear {
                // Collapse the library sidebar so the editor gets full width.
                if horizontalSizeClass == .regular {
                    sidebarVisibility = .detailOnly
                }
            }
            .onDisappear {
                // Restore the sidebar when returning to the library.
                if horizontalSizeClass == .regular {
                    sidebarVisibility = .all
                }
            }
    }

    /// Compact dropdown menu for switching between open notebook tabs.
    private var tabSwitcherMenu: some View {
        Menu {
            ForEach(openNotebooks) { notebook in
                Button {
                    selectNotebook(notebook)
                } label: {
                    Label(notebook.title, systemImage: selectedTabID == notebook.id ? "book.fill" : "book")
                }
            }
            Divider()
            if !availableNotebooks.isEmpty {
                Menu("Open Notebook") {
                    ForEach(availableNotebooks) { notebook in
                        Button(notebook.title) { openNotebook(notebook) }
                    }
                }
            }
            if openTabIDs.count > 1 {
                Button("Close Current Tab", systemImage: "xmark") {
                    if let current = selectedNotebook {
                        removeFromWorkspace(current)
                    }
                }
            }
        } label: {
            Image(systemName: "books.vertical")
        }
        .accessibilityLabel("Switch Notebook")
    }

    @ViewBuilder
    private var notebookContent: some View {
        if let selectedNotebook {
            NotebookView(
                notebook: selectedNotebook,
                editorState: editorState,
                onOpenAssistantSource: openAssistantSource
            )
            // PencilKit owns stateful UIKit content, so switching notebooks
            // must create a fresh canvas hierarchy.
            .id(selectedNotebook.id)
        } else {
            ContentUnavailableView(
                "Notebook unavailable",
                systemImage: "book.closed",
                description: Text("Return to the library and choose a notebook.")
            )
        }
    }

    private var selectedNotebook: Notebook? {
        if let selectedTabID,
           let selected = notebooks.first(where: { $0.id == selectedTabID }) {
            return selected
        }
        return openNotebooks.first
    }

    private var editorHeadingAccessibilityLabel: String {
        let title = selectedNotebook?.title ?? "Notebook"
        return editorState.isViewOnly ? "\(title), View Only" : title
    }

    private var openNotebooks: [Notebook] {
        openTabIDs.compactMap { id in
            notebooks.first(where: { $0.id == id })
        }
    }

    private var availableNotebooks: [Notebook] {
        notebooks.filter { $0.trashedAt == nil && !$0.isArchived && !openTabIDs.contains($0.id) }
    }

    private func openNotebook(_ notebook: Notebook) {
        if !openTabIDs.contains(notebook.id) {
            openTabIDs.append(notebook.id)
        }
        selectNotebook(notebook)
    }

    private func selectNotebook(_ notebook: Notebook, pageID: UUID? = nil) {
        selectedTabID = notebook.id
        let pages = notebook.pages.filter { $0.trashedAt == nil }.sorted { $0.index < $1.index }
        editorState.currentPageIndex = pageID.flatMap { stablePageID in
            pages.firstIndex { $0.stableID == stablePageID }
        } ?? 0
        editorState.presentedPanel = nil
        editorState.isAssistantPresented = false
    }

    private func openAssistantSource(notebookID: UUID, pageID: UUID?) {
        guard let notebook = notebooks.first(where: { $0.stableID == notebookID && $0.trashedAt == nil }) else { return }
        if !openTabIDs.contains(notebook.id) {
            openTabIDs.append(notebook.id)
        }
        selectNotebook(notebook, pageID: pageID)
    }

    private func removeFromWorkspace(_ notebook: Notebook) {
        guard openTabIDs.count > 1 else { return }
        guard let index = openTabIDs.firstIndex(of: notebook.id) else { return }
        openTabIDs.remove(at: index)
        if selectedTabID == notebook.id {
            selectedTabID = openTabIDs.isEmpty ? nil : openTabIDs[min(index, openTabIDs.count - 1)]
            editorState.currentPageIndex = 0
        }
        reconcileTabs()
    }

    private func reconcileTabs() {
        let validIDs = Set(notebooks.filter { $0.trashedAt == nil }.map(\.id))
        openTabIDs.removeAll { !validIDs.contains($0) }
        if openTabIDs.isEmpty, let first = notebooks.first(where: { $0.trashedAt == nil })?.id {
            openTabIDs = [first]
        }
        if let selectedTabID, openTabIDs.contains(selectedTabID) {
            return
        }
        selectedTabID = openTabIDs.first
    }
}

private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "book.closed")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)
            Text(librarySection.emptyTitle)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(librarySection.emptyMessage)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            if librarySection == .notes {
                Button {
                    showingNewNotebook = true
                } label: {
                    Label("New Notebook", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("empty-new-notebook")
            }
        }
    }

    // MARK: - Notebook management

    private func duplicateNotebook(_ original: Notebook) {
        let copy = Notebook(
            title: original.title + " Copy",
            subtitle: original.subtitle,
            coverColorHex: original.coverColorHex,
            coverColor2Hex: original.coverColor2Hex,
            coverStyle: original.coverStyle,
            coverEmoji: original.coverEmoji
        )
        copy.folderName = original.folderName
        copy.tagsText = original.tagsText
        copy.defaultLineStyle = original.defaultLineStyle
        copy.defaultBackgroundHex = original.defaultBackgroundHex
        copy.defaultOrientation = original.defaultOrientation
        for (newIndex, srcPage) in original.pages.filter({ $0.trashedAt == nil }).sorted(by: { $0.index < $1.index }).enumerated() {
            let newPage = Page(index: newIndex)
            newPage.title = srcPage.title
            newPage.isBookmarked = srcPage.isBookmarked
            newPage.inkData = srcPage.inkData
            newPage.ocrText = srcPage.ocrText
            newPage.ocrUpdatedAt = srcPage.ocrUpdatedAt
            newPage.backgroundHex = srcPage.backgroundHex
            newPage.lineStyle = srcPage.lineStyle
            newPage.orientation = srcPage.orientation
            for srcElem in srcPage.elements {
                let e = PageElement.copy(of: srcElem)
                e.page = newPage
                newPage.elements.append(e)
            }
            newPage.notebook = copy
            copy.pages.append(newPage)
        }
        context.insert(copy)
        _ = saveChanges()
    }

    private func deleteNotebook(_ notebook: Notebook) {
        notebook.trashedAt = .now
        notebook.modifiedAt = .now
        recentlyTrashedNotebook = notebook
        _ = saveChanges()
    }

    private func restoreNotebook(_ notebook: Notebook) {
        notebook.trashedAt = nil
        notebook.modifiedAt = .now
        if saveChanges(), recentlyTrashedNotebook?.id == notebook.id {
            recentlyTrashedNotebook = nil
        }
    }

    private func emptyTrash() {
        for notebook in notebooks where notebook.trashedAt != nil {
            context.delete(notebook)
        }
        _ = saveChanges()
    }

    /// Removes notebooks and pages that have sat in the trash past the
    /// retention window. Runs once when the library appears.
    private func purgeExpiredTrash() {
        var didChange = false
        for notebook in notebooks {
            if let trashedAt = notebook.trashedAt, TrashRetention.isExpired(trashedAt) {
                context.delete(notebook)
                didChange = true
                continue
            }
            // Also purge individually trashed pages inside live notebooks.
            for page in PageOperations.trashedPages(in: notebook) {
                guard let pageTrashedAt = page.trashedAt,
                      TrashRetention.isExpired(pageTrashedAt) else { continue }
                notebook.pages.removeAll { $0.id == page.id }
                context.delete(page)
                didChange = true
            }
        }
        if didChange { _ = saveChanges() }
    }

    private func toggleFavorite(_ notebook: Notebook) {
        notebook.isFavorite.toggle()
        notebook.modifiedAt = .now
        _ = saveChanges()
    }

    private func toggleArchive(_ notebook: Notebook) {
        notebook.isArchived.toggle()
        notebook.modifiedAt = .now
        _ = saveChanges()
    }

    private func exportNotebook(_ notebook: Notebook) {
        let data = PDFExport.renderNotebook(notebook)
        sharingURL = PDFExport.writePDF(data, name: notebook.title)
        showingShare = true
    }

    private func exportBackup(_ notebook: Notebook) {
        do {
            sharingURL = try CloudTranslator.writeArchive(for: notebook)
            showingShare = true
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func importBackup(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            quickNotebook = try CloudTranslator.importArchive(from: url, into: context)
            librarySection = .notes
        } catch {
            backupImportError = error.localizedDescription
        }
    }

    private func createQuickNote() {
        let notebook: Notebook
        if let existing = notebooks.first(where: {
            $0.title == "Quick Notes" && $0.trashedAt == nil && !$0.isArchived
        }) {
            notebook = existing
        } else {
            notebook = Notebook(title: "Quick Notes", coverColorHex: "355C7D", coverEmoji: "📝")
            context.insert(notebook)
        }
        let page = Page(index: notebook.pages.filter { $0.trashedAt == nil }.count)
        page.title = Date.now.formatted(date: .abbreviated, time: .shortened)
        page.lineStyle = notebook.defaultLineStyle
        page.backgroundHex = notebook.defaultBackgroundHex
        page.orientation = notebook.defaultOrientation
        page.notebook = notebook
        notebook.pages.append(page)
        notebook.modifiedAt = .now
        if saveChanges() {
            quickNotebook = notebook
        }
    }

    private func updateHandwritingIndex(for notebook: Notebook) {
        guard indexingNotebookID == nil else { return }
        indexingNotebookID = notebook.id
        let pages = notebook.pages.sorted(by: { $0.index < $1.index })
        indexingTotal = pages.count
        indexingCompleted = 0
        Task { @MainActor in
            defer {
                indexingNotebookID = nil
                indexingTotal = 0
                indexingCompleted = 0
            }
            for page in pages {
                let recognized = await HandwritingOCR.recognizeText(
                    from: page.inkData,
                    pageSize: page.pageOrientation.size
                )
                page.ocrText = recognized
                page.ocrUpdatedAt = .now
                indexingCompleted += 1
            }
            notebook.modifiedAt = .now
            _ = saveChanges()
        }
    }

    @discardableResult
    private func saveChanges() -> Bool {
        do {
            try context.save()
            NotificationCenter.default.post(name: .noteCorpusDidChange, object: nil)
            operationError = nil
            return true
        } catch {
            operationError = error.localizedDescription
            return false
        }
    }
}

private struct NewNotebookSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var selectedColor = "4A6FA5"
    @State private var selectedColor2 = "C06C84"
    @State private var selectedStyle: NotebookCoverStyle = .solid
    @State private var selectedEmoji: String? = nil
    @State private var selectedLineStyle: PageLineStyle = .blank
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Untitled Notebook", text: $title)
                }

                Section("Page Template") {
                    PageTemplatePicker(
                        selection: $selectedLineStyle,
                        backgroundHex: "FFFFFF",
                        orientation: .portrait
                    )
                }

                Section {
                    // Style picker
                    Picker("Style", selection: $selectedStyle) {
                        ForEach(NotebookCoverStyle.allCases, id: \.self) { style in
                            Label(style.label, systemImage: style.icon).tag(style)
                        }
                    }
                }

                Section(selectedStyle == .solid ? "Color" : "Primary Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        ForEach(CoverPalette.colors, id: \.self) { hex in
                            Button { selectedColor = hex } label: {
                                Circle()
                                    .fill(Color(hex: hex) ?? .blue)
                                    .frame(width: 44, height: 44)
                                    .overlay(
                                        Circle().stroke(.white.opacity(selectedColor == hex ? 0.9 : 0.2), lineWidth: selectedColor == hex ? 4 : 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Primary cover color \(hex)")
                            .accessibilityAddTraits(selectedColor == hex ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 6)
                }

                if selectedStyle != .solid {
                    Section("Accent Color") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                            ForEach(CoverPalette.colors, id: \.self) { hex in
                                Button { selectedColor2 = hex } label: {
                                    Circle()
                                        .fill(Color(hex: hex) ?? .blue)
                                        .frame(width: 44, height: 44)
                                        .overlay(
                                            Circle().stroke(.white.opacity(selectedColor2 == hex ? 0.9 : 0.2), lineWidth: selectedColor2 == hex ? 4 : 1)
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Accent cover color \(hex)")
                                .accessibilityAddTraits(selectedColor2 == hex ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }

                Section("Icon (optional)") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 8) {
                        ForEach(CoverPalette.emojis, id: \.self) { emoji in
                            Button {
                                    selectedEmoji = selectedEmoji == emoji ? nil : emoji
                                } label: {
                                    Text(emoji)
                                        .font(.title3)
                                        .frame(width: 44, height: 44)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(selectedEmoji == emoji ? Color.accentColor.opacity(0.15) : Color.clear)
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Cover icon \(emoji)")
                                .accessibilityAddTraits(selectedEmoji == emoji ? .isSelected : [])
                        }
                    }
                }
            }
            .navigationTitle("New Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create", action: createNotebook).bold()
                }
            }
            .alert("Couldn’t Create Notebook", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private func createNotebook() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let notebook = Notebook(
            title: trimmedTitle.isEmpty ? "Untitled" : trimmedTitle,
            coverColorHex: selectedColor,
            coverColor2Hex: selectedColor2,
            coverStyle: selectedStyle.rawValue,
            coverEmoji: selectedEmoji
        )
        let page = Page(index: 0)
        notebook.defaultLineStyle = selectedLineStyle.rawValue
        page.lineStyle = selectedLineStyle.rawValue
        page.notebook = notebook
        notebook.pages.append(page)
        context.insert(notebook)
        do {
            try context.save()
            dismiss()
        } catch {
            context.delete(notebook)
            saveError = error.localizedDescription
        }
    }
}

// MARK: - Move to Folder

private struct MoveToFolderSheet: View {
    @Bindable var notebook: Notebook
    let existingFolders: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var newFolder = ""
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Current Folder") {
                    Text(notebook.folderName.isEmpty ? "None" : notebook.folderName)
                        .foregroundStyle(.secondary)
                }

                if !existingFolders.isEmpty {
                    Section("Move To") {
                        ForEach(existingFolders, id: \.self) { folder in
                            Button {
                                apply(folder)
                            } label: {
                                HStack {
                                    Label(folder, systemImage: "folder")
                                    Spacer()
                                    if notebook.folderName == folder {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("New Folder") {
                    TextField("Folder name", text: $newFolder)
                    Button("Create and Move") { apply(newFolder) }
                        .disabled(newFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !notebook.folderName.isEmpty {
                    Section {
                        Button("Remove from Folder", role: .destructive) { apply("") }
                    }
                }
            }
            .navigationTitle("Move to Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Couldn’t Move Notebook", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private func apply(_ folder: String) {
        notebook.folderName = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        notebook.modifiedAt = .now
        do {
            guard let context = notebook.modelContext else {
                throw NotebookEditError.notebookUnavailable
            }
            try context.save()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

// MARK: - Rename Sheet

private struct RenameNotebookSheet: View {
    @Bindable var notebook: Notebook
    @Environment(\.dismiss) private var dismiss
    @State private var title: String = ""
    @State private var subtitle = ""
    @State private var folderName = ""
    @State private var tagsText = ""
    @State private var isFavorite = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Notebook Name", text: $title)
                }
                Section("Subtitle") {
                    TextField("Optional subtitle", text: $subtitle)
                }
                Section("Organization") {
                    TextField("Folder", text: $folderName)
                    TextField("Tags, separated by commas", text: $tagsText)
                    Toggle("Favorite", isOn: $isFavorite)
                }
            }
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save).bold()
                }
            }
            .onAppear {
                title = notebook.title
                subtitle = notebook.subtitle
                folderName = notebook.folderName
                tagsText = notebook.tagsText
                isFavorite = notebook.isFavorite
            }
            .alert("Couldn’t Save Notebook", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { notebook.title = trimmedTitle }
        notebook.subtitle = subtitle
        notebook.folderName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        notebook.tagsText = tagsText
        notebook.isFavorite = isFavorite
        notebook.modifiedAt = .now
        do {
            guard let context = notebook.modelContext else {
                throw NotebookEditError.notebookUnavailable
            }
            try context.save()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

private enum NotebookEditError: LocalizedError {
    case notebookUnavailable

    var errorDescription: String? { "This notebook is no longer available." }
}

// MARK: - Notebook Manage Menu

// MARK: - App Settings

struct BetterNotesSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppPreferenceKey.allowsFingerDrawing) private var allowsFingerDrawing = true
    @AppStorage(AppPreferenceKey.librarySort) private var librarySort = LibrarySort.modified.rawValue
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var aiSettings: AISettingsStore
    @State private var showingAIProviderSettings = false
    @State private var syncServer = SyncConfig.baseURL
    @State private var syncServerError: String?
    @AppStorage(AppPreferenceKey.assistantEnabled) private var assistantEnabled = true
    @AppStorage(AppPreferenceKey.searchAnswersEnabled) private var searchAnswersEnabled = true

    private func saveSyncServer() {
        do {
            try SyncConfig.setBaseURL(syncServer)
            syncServer = SyncConfig.baseURL
            syncServerError = nil
        } catch {
            syncServerError = error.localizedDescription
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $allowsFingerDrawing) {
                        Label("Draw with Finger", systemImage: "hand.draw")
                    }
                } header: {
                    Text("Input")
                } footer: {
                    Text("When this is off, fingers scroll pages and operate controls. Apple Pencil still draws.")
                }

                Section("Library") {
                    Picker("Default Sort", selection: $librarySort) {
                        ForEach(LibrarySort.allCases, id: \.self) { sort in
                            Label(sort.label, systemImage: sort.icon).tag(sort.rawValue)
                        }
                    }
                }

                Section {
                    TextField(SyncConfig.defaultBaseURL, text: $syncServer)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityLabel("Sync server address")
                    if let syncServerError {
                        Text(syncServerError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Button("Save Server") { saveSyncServer() }
                        .disabled(syncServer.trimmingCharacters(in: .whitespacesAndNewlines) == SyncConfig.baseURL)
                    if SyncConfig.hasOverride {
                        Button("Use Default Server", role: .destructive) {
                            try? SyncConfig.setBaseURL(nil)
                            syncServer = SyncConfig.baseURL
                            syncServerError = nil
                        }
                    }
                } header: {
                    Text("Cloud Sync")
                } footer: {
                    Text("Currently syncing with \(SyncConfig.baseURL). Use https, or http on localhost or your local network.")
                }

                Section("AI") {
                    Toggle(isOn: $aiSettings.automaticWritingSuggestions) {
                        Label("Automatic Writing Suggestions", systemImage: "sparkles")
                    }
                    .accessibilityValue(aiSettings.automaticWritingSuggestions ? "On" : "Off")

                    Button {
                        showingAIProviderSettings = true
                    } label: {
                        Label("AI Provider Settings", systemImage: "gearshape")
                    }

                    LabeledContent("Mode") {
                        Label(
                            ai.isRemoteConfigured ? "Remote" : "On-device",
                            systemImage: ai.isRemoteConfigured ? "checkmark.shield" : "iphone"
                        )
                        .foregroundStyle(.secondary)
                    }
                    LabeledContent("Model", value: ai.isRemoteConfigured ? ai.configuredModel : "Local fallback")
                    Toggle("Assistant", systemImage: "bubble.left.and.bubble.right", isOn: $assistantEnabled)
                    Toggle("Ask Notes in Search", systemImage: "magnifyingglass", isOn: $searchAnswersEnabled)
                }
                Section {
                    Text("Writing suggestions run only after you opt in. Ask Notes appears after search results and runs only when you choose it. Suggestions and answers never change notes until you accept an edit.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Build", value: buildNumber)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .bold()
                }
            }
            .sheet(isPresented: $showingAIProviderSettings) {
                AIProviderSettingsSheet(service: ai)
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
}
