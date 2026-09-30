import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private enum MacLibraryFilter: String, CaseIterable {
    case notes = "Notes"
    case archive = "Archive"
    case trash = "Trash"
}

struct MacLibraryView: View {
    let startupError: String?
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var corpus: NoteCorpusStore
    @EnvironmentObject private var nearbySync: NearbySyncCoordinator
    @Query(sort: \Notebook.modifiedAt, order: .reverse) private var notebooks: [Notebook]
    @State private var selectedNotebookID: UUID?
    @State private var selectedPageID: UUID?
    @State private var showingAssistant = false
    @State private var showingImport = false
    @State private var showingTextImport = false
    @State private var showingBackupImport = false
    @State private var showingNearbySync = false
    @State private var alertMessage: String?
    @State private var searchText = ""
    @State private var searchResults: [SearchResult] = []
    @State private var libraryFilter = MacLibraryFilter.notes
    @State private var notebookToPermanentlyDelete: UUID?

    private var visibleNotebooks: [Notebook] {
        notebooks.filter { item in
            switch libraryFilter {
            case .notes: return item.trashedAt == nil && !item.isArchived
            case .archive: return item.trashedAt == nil && item.isArchived
            case .trash: return item.trashedAt != nil
            }
        }
    }

    private var notebook: Notebook? {
        visibleNotebooks.first { $0.stableID == selectedNotebookID }
    }

    private var pages: [Page] {
        notebook?.pages.filter { $0.trashedAt == nil }.sorted { $0.index < $1.index } ?? []
    }

    private var page: Page? {
        pages.first { $0.stableID == selectedPageID }
    }

    var body: some View {
        NavigationSplitView { notebookList } content: { pageList } detail: { pageDetail }
        .toolbar {
            Button { addNotebook() } label: { Label("New Notebook", systemImage: "plus") }
                .help("New Notebook")
            Button { addPage() } label: { Label("New Page", systemImage: "doc.badge.plus") }
                .disabled(notebook == nil)
                .help("New Page")
            Button { showingImport = true } label: { Label("Import Image", systemImage: "photo.badge.plus") }
                .disabled(page == nil)
            Button { showingTextImport = true } label: { Label("Import Text", systemImage: "text.badge.plus") }
                .disabled(page == nil)
            Button { showingBackupImport = true } label: { Label("Import Backup", systemImage: "square.and.arrow.down") }
            Button { showingNearbySync = true } label: { Label("Nearby Sync", systemImage: "laptopcomputer.and.ipad") }
                .disabled(startupError != nil)
            Button { showingAssistant = true } label: { Label("Assistant", systemImage: "sparkles") }
        }
        .searchable(text: $searchText, prompt: "Search all notes")
        .safeAreaInset(edge: .bottom) { statusBar }
        .fileImporter(isPresented: $showingImport, allowedContentTypes: [.image]) { result in
            guard let page else { return }
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try MacImageImporter.add(data: Data(contentsOf: url), to: page, in: context)
                save(page)
            } catch { alertMessage = error.localizedDescription }
        }
        .fileImporter(isPresented: $showingTextImport, allowedContentTypes: [.plainText, .text]) { result in
            guard let page else { return }
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try MacTextImporter.add(data: Data(contentsOf: url), to: page, in: context)
                save(page)
            } catch { alertMessage = error.localizedDescription }
        }
        .fileImporter(
            isPresented: $showingBackupImport,
            allowedContentTypes: [UTType(filenameExtension: "betternotes") ?? .json]
        ) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let imported = try CloudTranslator.importArchive(from: url, into: context)
                selectedNotebookID = imported.stableID
                selectedPageID = imported.pages.first?.stableID
            } catch { alertMessage = error.localizedDescription }
        }
        .sheet(isPresented: $showingAssistant) {
            MacAssistantView(notebook: notebook, page: page)
                .frame(minWidth: 650, minHeight: 600)
        }
        .sheet(isPresented: $showingNearbySync) {
            NearbySyncSheet().frame(minWidth: 450, minHeight: 420)
        }
        .alert("Operation Failed", isPresented: Binding(
            get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } }
        )) { Button("OK") { alertMessage = nil } } message: { Text(alertMessage ?? "") }
        .confirmationDialog("Delete notebook permanently?", isPresented: Binding(
            get: { notebookToPermanentlyDelete != nil },
            set: { if !$0 { notebookToPermanentlyDelete = nil } }
        )) {
            Button("Delete Permanently", role: .destructive) { deletePermanently() }
        } message: {
            Text("This removes the notebook and all of its pages from this library.")
        }
        .onChange(of: selectedNotebookID) { _, _ in
            if !pages.contains(where: { $0.stableID == selectedPageID }) {
                selectedPageID = pages.first?.stableID
            }
        }
        .onChange(of: notebooks.count) { _, _ in
            if selectedNotebookID == nil { selectedNotebookID = visibleNotebooks.first?.stableID }
        }
        .task {
            selectedNotebookID = visibleNotebooks.first?.stableID
            await corpus.rebuild(notebooks: notebooks)
        }
        .onChange(of: libraryFilter) { _, _ in
            selectedNotebookID = visibleNotebooks.first?.stableID
            selectedPageID = nil
        }
        .onChange(of: notebooks.map(\.modifiedAt)) { _, _ in corpus.scheduleRebuild(notebooks: notebooks) }
        .onChange(of: searchText) { _, query in
            Task {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    searchResults = []
                } else {
                    searchResults = await corpus.indexer.search(SearchQuery(text: query))
                }
            }
        }
        .frame(minWidth: 1320, minHeight: 700)
    }

    private var notebookList: some View {
        VStack(spacing: 0) {
            Picker("Library", selection: $libraryFilter) {
                ForEach(MacLibraryFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            List(selection: $selectedNotebookID) {
                ForEach(visibleNotebooks, id: \.stableID) { item in
                    Label(item.title, systemImage: "book.closed")
                        .tag(item.stableID)
                        .contextMenu {
                            if libraryFilter == .trash {
                                Button("Restore") {
                                    item.trashedAt = nil
                                    save(item)
                                }
                                Button("Delete Permanently", role: .destructive) {
                                    notebookToPermanentlyDelete = item.stableID
                                }
                            } else {
                                Button(libraryFilter == .archive ? "Move to Notes" : "Archive") {
                                    item.isArchived = libraryFilter != .archive
                                    save(item)
                                }
                                Button("Export Editable Backup") { exportBackup(item) }
                                Button("Move to Trash", role: .destructive) {
                                    item.trashedAt = .now
                                    save(item)
                                }
                            }
                        }
                }
            }
            .overlay {
                if visibleNotebooks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "books.vertical").font(.largeTitle).foregroundStyle(.secondary)
                        Text(libraryFilter == .notes ? "No Notebooks Yet" : "Nothing Here")
                            .font(.headline)
                        if libraryFilter == .notes {
                            Button("Create Notebook", action: addNotebook)
                        }
                    }
                    .padding()
                }
            }
            if libraryFilter == .trash, let notebook {
                HStack {
                    Button("Restore") {
                        notebook.trashedAt = nil
                        save(notebook)
                    }
                    Button("Delete", role: .destructive) {
                        notebookToPermanentlyDelete = notebook.stableID
                    }
                }
                .padding(8)
            }
        }
        .navigationTitle("Notebooks")
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
    }

    @ViewBuilder
    private var pageList: some View {
        if libraryFilter == .trash {
            ContentUnavailableView("Notebook in Trash", systemImage: "trash")
        } else if !searchText.isEmpty {
            List(searchResults, id: \.id) { result in
                Button {
                    selectedPageID = result.chunk.pageID
                    selectedNotebookID = result.chunk.notebookID
                } label: {
                    VStack(alignment: .leading) {
                        Text(result.chunk.notebookTitle).font(.headline)
                        Text(result.snippet).font(.caption).lineLimit(2)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Search Results")
        } else if let notebook {
            List(selection: $selectedPageID) {
                ForEach(pages, id: \.stableID) { item in
                    Label(pageLabel(item), systemImage: "doc.text")
                        .tag(item.stableID)
                        .contextMenu {
                            Button("Move Up") { movePage(item, by: -1) }
                                .disabled(item.index == 0)
                            Button("Move Down") { movePage(item, by: 1) }
                                .disabled(item.index >= pages.count - 1)
                        }
                }
            }
            .navigationTitle(notebook.title)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } else {
            ContentUnavailableView("Select a Notebook", systemImage: "books.vertical")
        }
    }

    @ViewBuilder
    private var pageDetail: some View {
        if libraryFilter != .trash, let page, let notebook {
            MacPageEditor(notebook: notebook, page: page).id(page.stableID)
        } else {
            ContentUnavailableView("Select a Page", systemImage: "doc.text")
        }
    }

    private var statusBar: some View {
        HStack {
            if let startupError {
                Label("Notes store unavailable: \(startupError)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else {
                Label(nearbySync.isPaired ? nearbySync.status : "Open Nearby Sync to pair an iPad",
                      systemImage: "laptopcomputer.and.ipad")
            }
            Spacer()
        }
        .font(.caption)
        .padding(8)
        .background(.bar)
    }

    private func addNotebook() {
        libraryFilter = .notes
        let notebook = Notebook(title: "Untitled Notebook")
        context.insert(notebook)
        let page = Page()
        page.notebook = notebook
        notebook.pages.append(page)
        context.insert(page)
        try? context.save()
        selectedNotebookID = notebook.stableID
        selectedPageID = page.stableID
    }

    private func deletePermanently() {
        guard let id = notebookToPermanentlyDelete,
              let notebook = notebooks.first(where: { $0.stableID == id }) else { return }
        notebookToPermanentlyDelete = nil
        if selectedNotebookID == id { selectedNotebookID = nil; selectedPageID = nil }
        context.delete(notebook)
        do { try context.save() } catch { alertMessage = error.localizedDescription }
    }

    private func pageLabel(_ page: Page) -> String {
        page.title.isEmpty ? "Page \(page.index + 1)" : page.title
    }

    private func addPage() {
        guard let notebook else { return }
        let page = Page(index: pages.count)
        page.notebook = notebook
        page.lineStyle = notebook.defaultLineStyle
        page.lineThickness = notebook.defaultLineThickness
        page.lineOpacity = notebook.defaultLineOpacity
        page.backgroundHex = notebook.defaultBackgroundHex
        page.orientation = notebook.defaultOrientation
        notebook.pages.append(page)
        context.insert(page)
        save(notebook)
        selectedPageID = page.stableID
    }

    private func movePage(_ page: Page, by delta: Int) {
        let ordered = pages
        guard let index = ordered.firstIndex(where: { $0.stableID == page.stableID }),
              ordered.indices.contains(index + delta) else { return }
        let other = ordered[index + delta]
        let oldIndex = page.index
        page.index = other.index
        other.index = oldIndex
        if let notebook { save(notebook) }
    }

    private func exportBackup(_ notebook: Notebook) {
        do {
            let data = try CloudTranslator.archiveData(for: notebook)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = notebook.title + ".betternotes"
            panel.allowedContentTypes = [UTType(filenameExtension: "betternotes") ?? .json]
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url, options: .atomic)
            }
        } catch { alertMessage = error.localizedDescription }
    }

    private func save(_ notebook: Notebook) {
        notebook.modifiedAt = .now
        do { try context.save() } catch { alertMessage = error.localizedDescription }
    }

    private func save(_ page: Page) {
        page.modifiedAt = .now
        if let notebook = page.notebook { save(notebook) }
    }
}
