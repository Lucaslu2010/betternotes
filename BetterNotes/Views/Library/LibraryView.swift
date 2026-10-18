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
        case .favorites: return "Favorite notebooks and folders appear here"
        case .bookmarks: return "Bookmark a page from the page overview and it appears here"
        case .archive: return "Archived notebooks stay out of your main library"
        case .trash: return "Deleted notebooks and folders can be restored from here"
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

private struct NotebookDestination: Hashable {
    let notebookID: UUID
    var pageID: PersistentIdentifier? = nil
}

private final class IncomingDocument: Identifiable {
    let id = UUID()
    let url: URL
    private let hasScopedAccess: Bool

    init(url: URL) {
        self.url = url
        hasScopedAccess = url.startAccessingSecurityScopedResource()
    }

    deinit { if hasScopedAccess { url.stopAccessingSecurityScopedResource() } }
}

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var corpusStore: NoteCorpusStore
    @EnvironmentObject private var ocrService: OCRService
    @EnvironmentObject private var assistantCoordinator: AssistantCoordinator
    @Query(sort: \Notebook.modifiedAt, order: .reverse) private var notebooks: [Notebook]
    @Query(sort: \NotebookFolder.name) private var folders: [NotebookFolder]
    @State private var showingNewNotebook = false
    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    @State private var showingDocumentImporter = false
    @State private var incomingDocuments: [IncomingDocument] = []
    @State private var showingImportDestination = false
    @State private var chosenImportFolder: String?
    @State private var isImportingDocument = false
    @State private var documentImportError: String?
    @State private var showingBackupImporter = false
    @State private var backupImportError: String?
    @State private var exportError: String?
    @State private var operationError: String?
    @State private var notebookPath: [NotebookDestination] = []
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
    @State private var searchAnswerTask: Task<Void, Never>?
    @State private var notebookToDelete: Notebook?
    @State private var notebookToPermanentlyDelete: Notebook?
    @State private var recentlyTrashedNotebook: Notebook?
    @State private var sharingURL: URL?
    @State private var showingShare = false
    @State private var folderToDelete: NotebookFolder?
    @State private var renamingFolder: NotebookFolder?
    @State private var folderNameDraft = ""
    @State private var customizingFolder: NotebookFolder?
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

    private let columns = [
        GridItem(.adaptive(minimum: 200), spacing: 24, alignment: .top)
    ]

    private var sectionNotebooks: [Notebook] {
        let selected = notebooks.filter { notebook in
            let matchesSection: Bool
            switch librarySection {
            case .notes:
                matchesSection = notebook.trashedAt == nil && !notebook.isEffectivelyArchived
            case .favorites:
                matchesSection = notebook.trashedAt == nil && !notebook.isEffectivelyArchived && notebook.isFavorite
            case .bookmarks:
                // Handled by bookmarkedPages; not a notebook listing.
                matchesSection = false
            case .archive:
                matchesSection = notebook.trashedAt == nil && notebook.isEffectivelyArchived
                    && (selectedFolder != nil || !NotebookFolders.isArchived(notebook.folderName, in: folders))
            case .trash:
                matchesSection = notebook.trashedAt != nil && !NotebookFolders.isTrashed(notebook.folderName, in: folders)
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

    /// Only active folders are offered as move/import destinations.
    private var allFolders: [String] {
        folders.filter { NotebookFolders.isAvailable($0.path, in: folders) }.map(\.path)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var visibleFolders: [NotebookFolder] {
        folders.filter { folder in
            let archived = NotebookFolders.isArchived(folder.path, in: folders)
            let trashed = NotebookFolders.isTrashed(folder.path, in: folders)
            switch librarySection {
            case .notes:
                return !archived && !trashed && folder.parentPath == (selectedFolder ?? "")
            case .favorites:
                return folder.isFavorite && !archived && !trashed
            case .archive:
                guard !trashed else { return false }
                if let selectedFolder { return folder.parentPath == selectedFolder }
                return folder.isArchived && !folders.contains { $0 !== folder && $0.isArchived && FolderPath.contains(folder.path, in: $0.path) }
            case .trash:
                return folder.trashedAt != nil && !folders.contains { $0 !== folder && $0.trashedAt != nil && FolderPath.contains(folder.path, in: $0.path) }
            case .bookmarks: return false
            }
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private var creationFolder: String {
        let path = selectedFolder ?? ""
        return NotebookFolders.isAvailable(path, in: folders) ? path : ""
    }

    private var libraryTitle: String {
        if let selectedFolder { return FolderPath.name(of: selectedFolder) }
        return horizontalSizeClass == .regular ? librarySection.label : "BetterNotes"
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
        if librarySection == .notes || selectedFolder != nil {
            return FolderPath.containsNotebook(notebook.folderName, at: selectedFolder ?? "")
        }
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
        !selectedTags.isEmpty
    }

    private func clearFilters() {
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

    var body: some View { folderPresentations }

    private var folderPresentations: some View {
        libraryNavigation
            .sheet(item: $customizingFolder) { folder in FolderColourSheet(folder: folder) }
            .alert("Rename Folder", isPresented: Binding(
                get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } }
            )) {
                TextField("Folder name", text: $folderNameDraft)
                    .accessibilityIdentifier("rename-folder-name")
                Button("Cancel", role: .cancel) { renamingFolder = nil }
                Button("Save") { renameFolder() }
                    .disabled(folderNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .confirmationDialog("Move \"\(folderToDelete?.name ?? "")\" to Trash?", isPresented: Binding(
                get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } }
            ), titleVisibility: .visible) {
                Button("Move to Trash", role: .destructive) {
                    if let folder = folderToDelete { performFolderAction { try NotebookFolders.trash(folder, in: context) } }
                    folderToDelete = nil
                }
                Button("Cancel", role: .cancel) { folderToDelete = nil }
            } message: {
                Text("This moves the folder and its contents to Trash. You can restore them later.")
            }
    }

    /// Main library content. Extracted from `libraryNavigation` because the
    /// combined body exceeded what the SwiftUI type-checker will solve.
    @ViewBuilder
    private var libraryContent: some View {
        VStack(spacing: 0) {
            if librarySection == .notes || selectedFolder != nil { folderBreadcrumbs }
            ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchResults
            } else if librarySection.showsPages {
                bookmarksContent
            } else if sectionNotebooks.isEmpty && visibleFolders.isEmpty {
                VStack(spacing: 0) {
                    tagFilterBar
                    Spacer(minLength: 0)
                    if hasActiveFilters || selectedFolder != nil {
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
                        ForEach(visibleFolders) { folder in
                            folderTile(folder)
                        }
                        ForEach(sectionNotebooks) { notebook in
                            VStack(spacing: 0) {
                                NavigationLink(value: NotebookDestination(notebookID: notebook.stableID)) {
                                    NotebookCover(notebook: notebook)
                                }
                                .buttonStyle(NotebookLiftButtonStyle())
                                .disabled(librarySection == .trash)
                                .draggable(NotebookDragPayload(notebookID: notebook.stableID)) {
                                    NotebookCover(notebook: notebook)
                                        .frame(width: 200)
                                        .rotationEffect(.degrees(-2))
                                        .shadow(color: .black.opacity(0.2), radius: 16, y: 10)
                                }
                                .accessibilityIdentifier("library-notebook-\(notebook.stableID)")

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
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                        }
                    }
                    .padding(28)
                }
            }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: sectionNotebooks.map(\.stableID))
        .animation(.easeInOut(duration: 0.2), value: selectedFolder)
    }

    private func folderTile(_ folder: NotebookFolder) -> some View {
        VStack(spacing: 0) {
            LibraryFolderTile(path: folder.path,
                              notebookCount: notebooks.filter { $0.folderName == folder.path && (folder.trashedAt != nil || $0.trashedAt == nil) }.count,
                              folderCount: folders.filter { $0.parentPath == folder.path && (folder.trashedAt != nil || !NotebookFolders.isTrashed($0.path, in: folders)) }.count,
                              colorHex: folder.colorHex, isFavorite: folder.isFavorite,
                              acceptsDrops: NotebookFolders.isAvailable(folder.path, in: folders),
                              onOpen: { openFolder(folder.path) }, onMove: moveNotebooks)
                .disabled(folder.trashedAt != nil)
            if let date = folder.trashedAt {
                Text(TrashRetention.deletedLabel(date)).font(.caption2).foregroundStyle(.secondary)
                Text("Removed in \(TrashRetention.daysRemaining(date)) days").font(.caption2).foregroundStyle(.tertiary)
            }
            Menu { folderActions(for: folder) } label: {
                Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More actions for \(folder.name)")
            .accessibilityIdentifier("library-folder-actions-\(folder.path)")
        }
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private var folderBreadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                breadcrumb("", label: librarySection == .archive ? "Archive" : "Notes", icon: librarySection == .archive ? "archivebox" : "books.vertical")
                ForEach(FolderPath.ancestors(including: selectedFolder ?? ""), id: \.self) { path in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    breadcrumb(path, label: FolderPath.name(of: path), icon: "folder")
                }
            }
            .padding(.horizontal, 28)
        }
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func breadcrumb(_ path: String, label: String, icon: String) -> some View {
        Button {
            if path.isEmpty && librarySection == .archive { selectLibrarySection(.archive) }
            else { openFolder(path) }
        } label: {
            Label(label, systemImage: icon)
                .font(.subheadline.weight(path == (selectedFolder ?? "") ? .semibold : .regular))
                .padding(.horizontal, 8).frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library-location-\(path.isEmpty ? "root" : path)")
        .modifier(NotebookFolderDropTarget(path: path, onMove: moveNotebooks))
    }

    // The library body is split into stages. As one chained expression it
    // exceeded what the SwiftUI type-checker will solve in reasonable time.
    private var libraryNavigation: some View {
        NavigationStack(path: $notebookPath) {
            // The sidebar belongs to the library's root screen. Pushing an
            // editor naturally replaces it, without collapsing a split view
            // during the same navigation transition (which can pop it back).
            HStack(spacing: 0) {
                if horizontalSizeClass == .regular {
                    librarySidebar.frame(width: 240)
                    Divider()
                }
                libraryStageD
            }
                .navigationDestination(for: NotebookDestination.self) { destination in
                    if let notebook = notebooks.first(where: { $0.stableID == destination.notebookID && $0.trashedAt == nil }) {
                        NotebookWorkspaceView(initialNotebook: notebook, initialPageID: destination.pageID)
                    } else {
                        ContentUnavailableView("Notebook unavailable", systemImage: "book.closed")
                    }
                }
        }
        .onOpenURL { url in
            showingSettings = false
            showingNewNotebook = false
            showingNewFolder = false
            showingDocumentImporter = false
            showingBackupImporter = false
            showingShare = false
            incomingDocuments.append(IncomingDocument(url: url))
        }
        .task(id: incomingDocuments.first?.id) {
            guard !incomingDocuments.isEmpty else { return }
            chosenImportFolder = nil
            showingImportDestination = true
        }
        .sheet(isPresented: $showingImportDestination, onDismiss: completeImportDecision) {
            if let document = incomingDocuments.first {
                ImportDestinationPicker(fileName: document.url.lastPathComponent, folders: allFolders) { path in
                    chosenImportFolder = path
                    showingImportDestination = false
                }
            }
        }
        .overlay {
            if isImportingDocument {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Importing Document…").font(.subheadline.weight(.medium))
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .accessibilityIdentifier("document-import-progress")
            }
        }
        .alert("Document Import Failed", isPresented: Binding(
            get: { documentImportError != nil }, set: { if !$0 { documentImportError = nil } }
        )) {
            Button("OK", role: .cancel) { documentImportError = nil }
        } message: { Text(documentImportError ?? "") }
    }

    private var libraryStageA: some View {
        libraryContent
        .navigationTitle(libraryTitle)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search notebooks, text, handwriting")
        .onSubmit(of: .search) { performSearch() }
        .onChange(of: searchText) { _, newValue in
            searchAnswerTask?.cancel()
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
                HStack(spacing: 4) {
                if let selectedFolder {
                    Button {
                        let parent = FolderPath.parent(of: selectedFolder)
                        if parent.isEmpty && librarySection == .archive { selectLibrarySection(.archive) }
                        else { openFolder(parent) }
                    } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .accessibilityLabel("Parent Folder")
                    .accessibilityIdentifier("library-parent-folder")
                }
                if horizontalSizeClass == .compact {
                    Menu {
                        Section("Library Section") {
                            ForEach(LibrarySection.allCases, id: \.self) { section in
                                Button {
                                    selectLibrarySection(section)
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
                        if !allFolders.isEmpty {
                            Section("Folders") {
                                Button("Notes", systemImage: "books.vertical") { openFolder("") }
                                ForEach(allFolders, id: \.self) { folder in
                                    Button(folder, systemImage: selectedFolder == folder ? "folder.fill" : "folder") {
                                        openFolder(folder)
                                    }
                                }
                            }
                        }
                    } label: {
                        Label(librarySection.label, systemImage: librarySection.icon)
                    }
                }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 4) {
                    Button {
                        newFolderName = ""
                        showingNewFolder = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                    .accessibilityLabel("Add Folder")
                    .accessibilityIdentifier("library-add-folder")

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
                        if librarySection == .trash && (!sectionNotebooks.isEmpty || !visibleFolders.isEmpty) {
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
                            Button("Import Document", systemImage: "doc.badge.plus") {
                                showingDocumentImporter = true
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
            NewNotebookSheet(folderName: creationFolder)
        }
        .sheet(isPresented: $showingSettings) {
            BetterNotesSettingsSheet()
        }
        .fileImporter(
            isPresented: $showingBackupImporter,
            allowedContentTypes: [.betterNotesArchive],
            allowsMultipleSelection: false
        ) { result in
            importBackup(result)
        }
        .fileImporter(isPresented: $showingDocumentImporter,
                      allowedContentTypes: DocumentImporter.supportedTypes,
                      allowsMultipleSelection: true) { result in
            do { incomingDocuments.append(contentsOf: try result.get().map { IncomingDocument(url: $0) }) }
            catch { documentImportError = error.localizedDescription }
        }
        .alert("New Folder", isPresented: $showingNewFolder) {
            TextField("Folder name", text: $newFolderName)
                .accessibilityIdentifier("new-folder-name")
            Button("Cancel", role: .cancel) {}
            Button("Create") { createFolder() }
                .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text("Choose a name for your folder.") }
    }

    private var libraryStageC: some View {
        libraryStageB
        .confirmationDialog(
            "Empty Trash?",
            isPresented: $confirmingEmptyTrash,
            titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) {
                emptyTrash()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every folder and notebook in the trash, including folder contents, and cannot be undone.")
        }
        .sheet(item: $movingToFolderNotebook) { notebook in
            MoveToFolderSheet(notebook: notebook, existingFolders: allFolders)
        }
        .task {
            do { try NotebookFolders.preserveMemberships(in: context) }
            catch { operationError = error.localizedDescription }
            await corpusStore.rebuild(notebooks: notebooks)
        }
        .onChange(of: notebooks.map(\.folderName)) { _, _ in
            do { try NotebookFolders.preserveMemberships(in: context) }
            catch { operationError = error.localizedDescription }
        }
        .task {
            purgeExpiredTrash()
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteCorpusDidChange)) { _ in
            corpusStore.scheduleRebuild(notebooks: notebooks)
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

    /// Tags filter the current location; breadcrumbs handle folder navigation.
    @ViewBuilder
    private var tagFilterBar: some View {
        if !allTags.isEmpty || hasActiveFilters {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
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
            if selectedFolder != nil && selectedTags.isEmpty && librarySection == .notes {
                Label("This Folder Is Empty", systemImage: "folder")
            } else {
                Label("No Matching Notebooks", systemImage: "line.3.horizontal.decrease.circle")
            }
        } description: {
            if let selectedFolder, selectedTags.isEmpty, librarySection == .notes {
                Text("Create or import a notebook to add it to \(selectedFolder).")
            } else {
                Text("No notebooks in \(librarySection.label) match the current folder and tag filters.")
            }
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
                            NavigationLink(value: NotebookDestination(notebookID: entry.notebook.stableID, pageID: entry.page.persistentModelID)) {
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
                        selectLibrarySection(section)
                    } label: {
                        HStack {
                            Label(section.label, systemImage: section.icon)
                            Spacer()
                            if librarySection == section && selectedFolder == nil {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(librarySection == section && selectedFolder == nil ? .isSelected : [])
                    .modifier(NotebookFolderDropTarget(path: "", onMove: { ids, path in
                        section == .notes && moveNotebooks(ids, to: path)
                    }))
                }
            }

            if !allFolders.isEmpty {
                Section("Folders") {
                    ForEach(allFolders, id: \.self) { folder in
                        Button {
                            openFolder(folder)
                        } label: {
                            HStack {
                                Label(FolderPath.name(of: folder), systemImage: "folder")
                                    .foregroundStyle(Color(hex: folders.first { $0.path == folder }?.colorHex ?? "4A6FA5") ?? .accentColor)
                                    .padding(.leading, CGFloat(folder.split(separator: "/").count - 1) * 12)
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
                        .contextMenu { if let record = folders.first(where: { $0.path == folder }) { folderActions(for: record) } }
                        .modifier(NotebookFolderDropTarget(path: folder, onMove: moveNotebooks))
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
        .listStyle(.sidebar)
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
                        if let error = answer.error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        ForEach(answer.citations) { citation in
                            if let destination = searchDestination(for: citation) {
                                NavigationLink(value: NotebookDestination(notebookID: destination.notebook.stableID, pageID: destination.page?.persistentModelID)) {
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
                                NavigationLink(value: NotebookDestination(notebookID: destination.notebook.stableID, pageID: destination.page?.persistentModelID)) {
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

                if searchAnswersEnabled && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
        searchAnswerTask?.cancel()
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
        guard searchAnswersEnabled, !queryText.isEmpty, !isSearching, !isAnsweringSearch else { return }
        let requestID = searchRequestID
        searchAnswer = nil
        isAnsweringSearch = true
        let filters = activeSearchFilters
        searchAnswerTask = Task { @MainActor in
            do {
                let eligible = notebooks.filter {
                    $0.trashedAt == nil && (filters.notebookID == nil || filters.notebookID == $0.stableID)
                        && (filters.includeArchived || !$0.isEffectivelyArchived)
                }
                try await ocrService.refresh(pages: eligible.flatMap(\.pages).filter {
                    $0.trashedAt == nil && (!filters.bookmarkedOnly || $0.isBookmarked)
                })
                try Task.checkCancellation()
                guard searchRequestID == requestID else { return }
                try context.save()
                await corpusStore.rebuild(notebooks: notebooks)
                let results = await corpusStore.indexer.search(SearchQuery(text: queryText, filters: filters, limit: 50))
                try Task.checkCancellation()
                guard searchRequestID == requestID else { return }
                rankedSearchResults = results
                assistantCoordinator.answerSearch(question: queryText, results: results) { reply in
                    guard searchRequestID == requestID else { return }
                    searchAnswer = reply
                    isAnsweringSearch = false
                }
            } catch is CancellationError {
                if searchRequestID == requestID { isAnsweringSearch = false }
            } catch {
                guard searchRequestID == requestID else { return }
                isAnsweringSearch = false
                searchAnswer = AssistantReply(text: "Could not refresh note recognition. Your existing text was preserved. Try again or check OCR Settings.", citations: [], notice: nil, error: error.localizedDescription)
            }
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
                Button(notebook.isEffectivelyArchived ? "Move to Notes" : "Archive", systemImage: "archivebox") {
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
    @Query(sort: \Notebook.modifiedAt, order: .reverse) private var notebooks: [Notebook]
    @State private var openTabIDs: [UUID]
    @State private var selectedTabID: UUID?
    @StateObject private var editorState: EditorActionState

    init(initialNotebook: Notebook, initialPageID: PersistentIdentifier? = nil) {
        self.initialNotebook = initialNotebook
        self.initialPageID = initialPageID
        let id = initialNotebook.stableID
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
            .onChange(of: notebooks.filter { $0.trashedAt == nil }.map(\.stableID)) { _, _ in reconcileTabs() }
    }

    /// Compact dropdown menu for switching between open notebook tabs.
    private var tabSwitcherMenu: some View {
        Menu {
            ForEach(openNotebooks) { notebook in
                Button {
                    selectNotebook(notebook)
                } label: {
                    Label(notebook.title, systemImage: selectedTabID == notebook.stableID ? "book.fill" : "book")
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
            .id(selectedNotebook.stableID)
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
           let selected = notebooks.first(where: { $0.stableID == selectedTabID }) {
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
            notebooks.first(where: { $0.stableID == id })
        }
    }

    private var availableNotebooks: [Notebook] {
        notebooks.filter { $0.trashedAt == nil && !$0.isEffectivelyArchived && !openTabIDs.contains($0.stableID) }
    }

    private func openNotebook(_ notebook: Notebook) {
        if !openTabIDs.contains(notebook.stableID) {
            openTabIDs.append(notebook.stableID)
        }
        selectNotebook(notebook)
    }

    private func selectNotebook(_ notebook: Notebook, pageID: UUID? = nil) {
        selectedTabID = notebook.stableID
        let pages = notebook.pages.filter { $0.trashedAt == nil }.sorted { $0.index < $1.index }
        editorState.currentPageIndex = pageID.flatMap { stablePageID in
            pages.firstIndex { $0.stableID == stablePageID }
        } ?? 0
        editorState.presentedPanel = nil
        editorState.isAssistantPresented = false
    }

    private func openAssistantSource(notebookID: UUID, pageID: UUID?) {
        guard let notebook = notebooks.first(where: { $0.stableID == notebookID && $0.trashedAt == nil }) else { return }
        if !openTabIDs.contains(notebook.stableID) {
            openTabIDs.append(notebook.stableID)
        }
        selectNotebook(notebook, pageID: pageID)
    }

    private func removeFromWorkspace(_ notebook: Notebook) {
        guard openTabIDs.count > 1 else { return }
        guard let index = openTabIDs.firstIndex(of: notebook.stableID) else { return }
        openTabIDs.remove(at: index)
        if selectedTabID == notebook.stableID {
            selectedTabID = openTabIDs.isEmpty ? nil : openTabIDs[min(index, openTabIDs.count - 1)]
            editorState.currentPageIndex = 0
        }
        reconcileTabs()
    }

    private func reconcileTabs() {
        let validIDs = Set(notebooks.filter { $0.trashedAt == nil }.map(\.stableID))
        openTabIDs.removeAll { !validIDs.contains($0) }
        if openTabIDs.isEmpty, let first = notebooks.first(where: { $0.trashedAt == nil })?.stableID {
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
            newPage.pdfText = srcPage.pdfText
            newPage.ocrStorageVersion = srcPage.ocrStorageVersion
            newPage.ocrInkFingerprint = srcPage.ocrInkFingerprint
            newPage.ocrProviderIdentity = srcPage.ocrProviderIdentity
            newPage.ocrUpdatedAt = srcPage.ocrUpdatedAt
            newPage.backgroundHex = srcPage.backgroundHex
            newPage.lineStyle = srcPage.lineStyle
            newPage.orientation = srcPage.orientation
            for srcElem in srcPage.orderedElements {
                let e = PageElement.copy(of: srcElem)
                newPage.appendElement(e)
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
        if NotebookFolders.isTrashed(notebook.folderName, in: folders) { notebook.folderName = "" }
        notebook.trashedAt = nil
        notebook.modifiedAt = .now
        if saveChanges(), recentlyTrashedNotebook?.id == notebook.id {
            recentlyTrashedNotebook = nil
        }
    }

    private func emptyTrash() {
        do {
            let roots = folders.filter { folder in
                folder.trashedAt != nil && !folders.contains { $0 !== folder && $0.trashedAt != nil && FolderPath.contains(folder.path, in: $0.path) }
            }
            let separateNotebooks = notebooks.filter { notebook in
                notebook.trashedAt != nil && !roots.contains { FolderPath.contains(notebook.folderName, in: $0.path) }
            }
            for folder in roots { try NotebookFolders.removeContents(of: folder, in: context) }
            for notebook in separateNotebooks { context.delete(notebook) }
            recentlyTrashedNotebook = nil
            _ = saveChanges()
        } catch { operationError = error.localizedDescription }
    }

    /// Removes notebooks and pages that have sat in the trash past the
    /// retention window. Runs once when the library appears.
    private func purgeExpiredTrash() {
        var didChange = false
        let expired = folders.filter { folder in
            guard let date = folder.trashedAt else { return false }
            return TrashRetention.isExpired(date) && !folders.contains { $0 !== folder && $0.trashedAt != nil && FolderPath.contains(folder.path, in: $0.path) }
        }
        let remainingNotebooks = notebooks.filter { notebook in
            !expired.contains { FolderPath.contains(notebook.folderName, in: $0.path) }
        }
        let retainedTrashPaths = folders.filter { $0.trashedAt != nil }.map(\.path)
        do {
            for folder in expired { try NotebookFolders.removeContents(of: folder, in: context); didChange = true }
        } catch { operationError = error.localizedDescription }
        for notebook in remainingNotebooks {
            if let trashedAt = notebook.trashedAt, TrashRetention.isExpired(trashedAt),
               !retainedTrashPaths.contains(where: { FolderPath.contains(notebook.folderName, in: $0) }) {
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
        if notebook.isEffectivelyArchived {
            notebook.isArchived = false
            if NotebookFolders.isArchived(notebook.folderName, in: folders) { notebook.folderName = "" }
        } else { notebook.isArchived = true }
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
            incomingDocuments.append(IncomingDocument(url: url))
        } catch {
            backupImportError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func folderActions(for folder: NotebookFolder) -> some View {
        if folder.trashedAt != nil {
            Button("Restore", systemImage: "arrow.uturn.backward") {
                performFolderAction { try NotebookFolders.restore(folder, in: context) }
            }
        } else {
            Section("Organize") {
                Button(folder.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: folder.isFavorite ? "star.slash" : "star") {
                    let old = folder.isFavorite
                    performFolderAction {
                        folder.isFavorite.toggle()
                        do { try context.save() } catch { folder.isFavorite = old; throw error }
                    }
                }
                Button(folder.isArchived ? "Move to Notes" : "Archive", systemImage: "archivebox") {
                    let old = folder.isArchived
                    performFolderAction {
                        folder.isArchived.toggle()
                        do { try context.save() } catch { folder.isArchived = old; throw error }
                    }
                }
            }
            Section("Edit") {
                Button("Rename", systemImage: "pencil") { folderNameDraft = folder.name; renamingFolder = folder }
                Button("Customize Colour", systemImage: "paintbrush.pointed") { customizingFolder = folder }
            }
            Section("Delete") {
                Button("Move to Trash", systemImage: "trash", role: .destructive) { folderToDelete = folder }
            }
        }
    }

    private func performFolderAction(_ action: () throws -> Void) {
        do {
            try withAnimation(.easeInOut(duration: 0.2), action)
            if let selectedFolder {
                if NotebookFolders.isTrashed(selectedFolder, in: folders) { openFolder("") }
                else { librarySection = NotebookFolders.isArchived(selectedFolder, in: folders) ? .archive : .notes }
            }
            NotificationCenter.default.post(name: .noteCorpusDidChange, object: nil)
        } catch { operationError = error.localizedDescription }
    }

    private func renameFolder() {
        guard let folder = renamingFolder else { return }
        let old = folder.path
        performFolderAction {
            try NotebookFolders.rename(folder, to: folderNameDraft, in: context)
            if let selectedFolder {
                self.selectedFolder = FolderPath.replacingAncestor(in: selectedFolder, from: old, to: folder.path)
            }
        }
        renamingFolder = nil
    }

    private func createFolder() {
        do {
            _ = try NotebookFolders.create(newFolderName, in: context, parentPath: creationFolder)
            if librarySection != .notes { openFolder("") }
        } catch { operationError = error.localizedDescription }
    }

    private func openFolder(_ path: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedFolder = path.isEmpty ? nil : path
            selectedTags.removeAll()
            searchText = ""
            librarySection = NotebookFolders.isArchived(path, in: folders) ? .archive : .notes
        }
    }

    private func selectLibrarySection(_ section: LibrarySection) {
        if section == .notes { openFolder(""); return }
        selectedFolder = nil
        librarySection = section
    }

    private func moveNotebooks(_ ids: [UUID], to path: String) -> Bool {
        do {
            let moved = try withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                try NotebookFolders.move(notebookIDs: ids, to: path, in: context)
            }
            if moved { NotificationCenter.default.post(name: .noteCorpusDidChange, object: nil) }
            return moved
        } catch {
            operationError = error.localizedDescription
            return false
        }
    }

    /// Start only after the destination sheet has finished dismissing. This
    /// avoids racing a fast import against the next queued file's sheet.
    private func completeImportDecision() {
        guard let document = incomingDocuments.first else { return }
        guard let destination = chosenImportFolder else {
            incomingDocuments.removeFirst()
            return
        }
        chosenImportFolder = nil
        Task { @MainActor in
            await importDocument(document.url, folderName: destination)
            if incomingDocuments.first?.id == document.id { incomingDocuments.removeFirst() }
        }
    }

    @MainActor
    private func importDocument(_ url: URL, folderName: String) async {
        isImportingDocument = true
        defer { isImportingDocument = false }
        do {
            let notebook = try await DocumentImporter.importDocument(from: url, into: context, folderName: folderName)
            try NotebookFolders.preserveMemberships(in: context)
            NotificationCenter.default.post(name: .noteCorpusDidChange, object: nil)
            librarySection = .notes
            selectedFolder = folderName.isEmpty ? nil : folderName
            selectedTags.removeAll()
            searchText = ""
            notebookPath = [NotebookDestination(notebookID: notebook.stableID)]
        } catch is CancellationError {
            // The view's task was cancelled; no partial notebook is inserted.
        } catch { documentImportError = error.localizedDescription }
    }

    private func createQuickNote() {
        let notebook: Notebook
        if let existing = notebooks.first(where: {
            $0.title == "Quick Notes" && $0.trashedAt == nil && !$0.isEffectivelyArchived
                && $0.folderName == creationFolder
        }) {
            notebook = existing
        } else {
            notebook = Notebook(title: "Quick Notes", coverColorHex: "355C7D", coverEmoji: "📝")
            notebook.folderName = creationFolder
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
            notebookPath.append(NotebookDestination(notebookID: notebook.stableID))
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
                do {
                    try await ocrService.refresh(pages: [page], force: true)
                    indexingCompleted += 1
                } catch {
                    operationError = error.localizedDescription
                    _ = saveChanges()
                    return
                }
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
    var folderName: String = ""
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
        notebook.folderName = folderName
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
                    Button("Create and Move", action: createAndMove)
                        .disabled(newFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !notebook.folderName.isEmpty {
                    Section {
                        Button("Move to Notes", systemImage: "books.vertical") { apply("") }
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
        do {
            guard let context = notebook.modelContext else {
                throw NotebookEditError.notebookUnavailable
            }
            _ = try NotebookFolders.move(notebookIDs: [notebook.stableID], to: folder, in: context)
            NotificationCenter.default.post(name: .noteCorpusDidChange, object: nil)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func createAndMove() {
        do {
            guard let context = notebook.modelContext else { throw NotebookEditError.notebookUnavailable }
            let folder = try NotebookFolders.create(newFolder, in: context, parentPath: notebook.folderName)
            apply(folder.path)
        } catch { saveError = error.localizedDescription }
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
    @AppStorage(AppPreferenceKey.scribbleToErase) private var scribbleToErase = true
    @AppStorage(AppPreferenceKey.pencilDoubleTapEnabled) private var pencilDoubleTapEnabled = true
    @AppStorage(AppPreferenceKey.pencilDoubleTapTool) private var pencilDoubleTapToolRaw = DrawingTool.eraser.rawValue
    @AppStorage(AppPreferenceKey.librarySort) private var librarySort = LibrarySort.modified.rawValue
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var aiSettings: AISettingsStore
    @EnvironmentObject private var ocrSettings: OCRSettingsStore
    @AppStorage(AppPreferenceKey.assistantEnabled) private var assistantEnabled = true
    @AppStorage(AppPreferenceKey.searchAnswersEnabled) private var searchAnswersEnabled = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $allowsFingerDrawing) {
                        Label("Draw with Finger", systemImage: "hand.draw")
                    }
                    Toggle("Scribble to Erase", systemImage: "scribble", isOn: $scribbleToErase)
                        .accessibilityIdentifier("scribble-to-erase")
                } header: {
                    Text("Input")
                } footer: {
                    Text("When finger drawing is off, fingers scroll pages and operate controls. Apple Pencil still draws. With Scribble to Erase on, scratch back and forth over handwriting with the pen or pencil to erase crossed strokes. Undo restores them.")
                }

                Section("Library") {
                    Picker("Default Sort", selection: $librarySort) {
                        ForEach(LibrarySort.allCases, id: \.self) { sort in
                            Label(sort.label, systemImage: sort.icon).tag(sort.rawValue)
                        }
                    }
                }

                if UIDevice.current.userInterfaceIdiom == .pad {
                    Section {
                        Toggle("Double-Tap Tool Switch", isOn: $pencilDoubleTapEnabled)
                            .accessibilityIdentifier("pencil-double-tap-enabled")
                        Picker("Switch To", selection: $pencilDoubleTapToolRaw) {
                            ForEach(DrawingTool.allCases, id: \.self) { tool in
                                Label(tool.label, systemImage: tool.icon)
                                    .accessibilityLabel(tool.label)
                                    .accessibilityIdentifier("pencil-double-tap-option-\(tool.rawValue)")
                                    .tag(tool.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(!pencilDoubleTapEnabled)
                        .accessibilityIdentifier("pencil-double-tap-tool")
                    } header: {
                        Text("Apple Pencil Pro")
                    } footer: {
                        Text("Apple Pencil Pro only. Double-tap to switch to the selected tool; double-tap again to return to your previous tool. Enable Double Tap in iPad Settings > Apple Pencil.")
                    }
                }

                Section("Text Recognition") {
                    NavigationLink {
                        OCRSettingsView()
                    } label: {
                        Label("OCR Settings", systemImage: "text.viewfinder")
                    }
                    LabeledContent("Provider", value: ocrSettings.provider.label)
                    Text("Write ?? followed by a question on the same line to prepare it in the assistant.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("AI") {
                    Toggle(isOn: $aiSettings.automaticWritingSuggestions) {
                        Label("Automatic Writing Suggestions", systemImage: "sparkles")
                    }
                    .accessibilityValue(aiSettings.automaticWritingSuggestions ? "On" : "Off")

                    NavigationLink {
                        AIProviderSettingsSheet(service: ai)
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
            .accessibilityIdentifier("app-settings-form")
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .bold()
                }
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
