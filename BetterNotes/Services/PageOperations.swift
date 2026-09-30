import Foundation

enum PageOperations {
    static func clone(_ source: Page, newIndex: Int, notebook: Notebook? = nil) -> Page {
        let page = Page(index: newIndex)
        page.title = source.title.isEmpty ? "" : source.title + " Copy"
        page.isBookmarked = source.isBookmarked
        page.inkData = source.inkData
        page.ocrText = source.ocrText
        page.ocrUpdatedAt = source.ocrUpdatedAt
        page.backgroundHex = source.backgroundHex
        page.lineStyle = source.lineStyle
        page.lineThickness = source.lineThickness
        page.lineOpacity = source.lineOpacity
        page.orientation = source.orientation
        page.notebook = notebook
        for sourceElement in source.orderedElements {
            let element = PageElement.copy(of: sourceElement)
            page.appendElement(element)
        }
        return page
    }

    static func visiblePages(in notebook: Notebook) -> [Page] {
        notebook.pages.filter { $0.trashedAt == nil }.sorted { $0.index < $1.index }
    }

    static func trashedPages(in notebook: Notebook) -> [Page] {
        notebook.pages.filter { $0.trashedAt != nil }.sorted { ($0.trashedAt ?? .distantPast) > ($1.trashedAt ?? .distantPast) }
    }

    static func normalizeIndices(in notebook: Notebook) {
        for (index, page) in visiblePages(in: notebook).enumerated() {
            page.index = index
        }
    }

    /// Moves a page to trash while keeping its former insertion position so a
    /// later restore can put it back in the same place. Visible pages are
    /// normalized immediately; this prevents new pages from reusing a sparse
    /// index after a deletion.
    @discardableResult
    static func trash(_ page: Page, in notebook: Notebook, isReadOnly: Bool) -> Bool {
        guard !isReadOnly, page.trashedAt == nil else { return false }
        page.trashedAt = .now
        page.modifiedAt = .now
        normalizeIndices(in: notebook)
        notebook.modifiedAt = .now
        return true
    }

    @discardableResult
    static func move(_ page: Page, direction: Int, in notebook: Notebook, isReadOnly: Bool) -> Bool {
        guard !isReadOnly else { return false }
        let pages = visiblePages(in: notebook)
        guard let index = pages.firstIndex(where: { $0.id == page.id }) else { return false }
        let target = index + direction
        guard pages.indices.contains(target) else { return false }
        pages[index].index = target
        pages[target].index = index
        notebook.modifiedAt = .now
        return true
    }

    @discardableResult
    static func restore(_ page: Page, in notebook: Notebook, isReadOnly: Bool) -> Bool {
        guard !isReadOnly, page.trashedAt != nil else { return false }
        // `page.index` is the position it occupied when it was trashed. Shift
        // current pages to make room instead of relying on an unstable sort of
        // duplicate indices when multiple pages are restored.
        let targetIndex = min(max(page.index, 0), visiblePages(in: notebook).count)
        for visiblePage in visiblePages(in: notebook) where visiblePage.index >= targetIndex {
            visiblePage.index += 1
        }
        page.index = targetIndex
        page.trashedAt = nil
        page.modifiedAt = .now
        notebook.modifiedAt = .now
        return true
    }

    @discardableResult
    static func permanentlyDelete(_ page: Page, from notebook: Notebook, isReadOnly: Bool) -> Bool {
        guard !isReadOnly, page.trashedAt != nil else { return false }
        notebook.pages.removeAll { $0.id == page.id }
        normalizeIndices(in: notebook)
        notebook.modifiedAt = .now
        return true
    }

    @discardableResult
    static func setBookmark(_ isBookmarked: Bool, for page: Page, in notebook: Notebook, isReadOnly: Bool) -> Bool {
        guard !isReadOnly, page.trashedAt == nil else { return false }
        page.isBookmarked = isBookmarked
        page.modifiedAt = .now
        notebook.modifiedAt = .now
        return true
    }
}
