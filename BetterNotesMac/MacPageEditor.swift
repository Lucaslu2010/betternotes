import AppKit
import PencilKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import Vision

struct MacPageEditor: View {
    let notebook: Notebook
    let page: Page
    @Environment(\.modelContext) private var context
    @State private var selectedElementID: PersistentIdentifier?
    @State private var zoom = 0.75
    @State private var errorMessage: String?

    private var selectedElement: PageElement? {
        page.elements.first { $0.id == selectedElementID }
    }

    private var pageSize: CGSize { page.pageOrientation.size }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    canvas
                        .frame(width: pageSize.width, height: pageSize.height)
                        .scaleEffect(zoom, anchor: .topLeading)
                }
                .frame(width: pageSize.width * zoom, height: pageSize.height * zoom,
                       alignment: .topLeading)
                .padding(32)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            inspector.frame(width: 270)
        }
        .navigationTitle(page.title.isEmpty ? "Page \(page.index + 1)" : page.title)
        .toolbar {
            Button("Text", systemImage: "textformat") { addText() }
            Button("Paste", systemImage: "doc.on.clipboard") { paste() }
                .keyboardShortcut("v", modifiers: .command)
            Slider(value: $zoom, in: 0.4...1.4).frame(width: 120)
                .help("Page zoom")
        }
        .onDrop(of: [.fileURL, .png, .tiff, .plainText], isTargeted: nil, perform: handleDrop)
        .alert("Could Not Save", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            page.background
            pageLines
            if let inkData = page.inkData,
               let drawing = try? PKDrawing(data: inkData) {
                Image(nsImage: MacInkRenderer.image(from: drawing,
                    in: CGRect(origin: .zero, size: pageSize)))
                    .resizable()
                    .frame(width: pageSize.width, height: pageSize.height)
            }
            ForEach(page.orderedElements) { element in
                MacElementView(element: element, selected: element.id == selectedElementID, zoom: zoom) {
                    selectedElementID = element.id
                } onMove: { dx, dy in
                    element.posX = min(max(element.posX + dx, element.width / 2), pageSize.width - element.width / 2)
                    element.posY = min(max(element.posY + dy, element.height / 2), pageSize.height - element.height / 2)
                    save()
                } onResize: { dw, dh in
                    element.width = min(max(80, element.width + dw), pageSize.width)
                    element.height = min(max(60, element.height + dh), pageSize.height)
                    save()
                }
                .position(x: element.posX, y: element.posY)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height)
        .clipShape(Rectangle())
        .shadow(color: .black.opacity(0.15), radius: 12)
        .onTapGesture { selectedElementID = nil }
    }

    @ViewBuilder
    private var pageLines: some View {
        switch page.lines {
        case .blank: EmptyView()
        case .ruled, .cornell, .checklist, .weeklyPlanner:
            Path { path in
                stride(from: CGFloat(36), through: pageSize.height, by: 36).forEach { y in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: pageSize.width, y: y))
                }
            }
            .stroke(.black.opacity(page.effectiveLineOpacity), lineWidth: CGFloat(page.effectiveLineThickness))
        case .grid, .dots:
            Path { path in
                stride(from: CGFloat(36), through: pageSize.height, by: 36).forEach { y in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: pageSize.width, y: y))
                }
                stride(from: CGFloat(36), through: pageSize.width, by: 36).forEach { x in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: pageSize.height))
                }
            }
            .stroke(.black.opacity(page.effectiveLineOpacity), lineWidth: CGFloat(page.effectiveLineThickness))
        }
    }

    private var inspector: some View {
        Form {
            Section("Notebook") {
                TextField("Name", text: Binding(get: { notebook.title }, set: { notebook.title = $0; save() }))
                TextField("Folder", text: Binding(get: { notebook.folderName }, set: { notebook.folderName = $0; save() }))
                TextField("Tags", text: Binding(get: { notebook.tagsText }, set: { notebook.tagsText = $0; save() }))
                Toggle("Favorite", isOn: Binding(get: { notebook.isFavorite }, set: { notebook.isFavorite = $0; save() }))
                Button("Move to Trash", role: .destructive) {
                    notebook.trashedAt = .now
                    save()
                }
            }
            Section("Page") {
                TextField("Title", text: Binding(get: { page.title }, set: { page.title = $0; save() }))
                Text("Ink is view-only on Mac").font(.caption).foregroundStyle(.secondary)
            }
            if let element = selectedElement {
                Section("Selected Element") {
                    Text(element.type == .image ? "Image" : "Text")
                    if element.type == .textBox || element.type == .stickyNote {
                        TextEditor(text: Binding(
                            get: { element.text ?? "" },
                            set: {
                                let attributes = element.resolvedRichText.length > 0
                                    ? element.resolvedRichText.attributes(at: 0, effectiveRange: nil)
                                    : element.defaultTextAttributes
                                element.text = $0
                                element.richTextData = RichTextCodec.encode(NSAttributedString(string: $0, attributes: attributes))
                                save()
                            }
                        ))
                        .frame(height: 160)
                    }
                    HStack {
                        Text("X")
                        TextField("X", value: Binding(get: { element.posX }, set: { element.posX = $0; save() }), format: .number)
                        Text("Y")
                        TextField("Y", value: Binding(get: { element.posY }, set: { element.posY = $0; save() }), format: .number)
                    }
                    HStack {
                        Text("W")
                        TextField("Width", value: Binding(get: { element.width }, set: { element.width = max(80, $0); save() }), format: .number)
                        Text("H")
                        TextField("Height", value: Binding(get: { element.height }, set: { element.height = max(60, $0); save() }), format: .number)
                    }
                    Button("Delete Element", role: .destructive) {
                        page.elements.removeAll { $0.id == element.id }
                        context.delete(element)
                        selectedElementID = nil
                        save()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addText(_ string: String = "New text") {
        let element = PageElement(type: .textBox, x: pageSize.width / 2,
                                  y: 180, width: 360, height: 150)
        element.text = string
        context.insert(element)
        page.appendElement(element)
        save()
        selectedElementID = element.id
    }

    private func paste() {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            addImage(data)
        } else if let string = pasteboard.string(forType: .string), !string.isEmpty {
            addText(string)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return }
                let isText = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .text) == true
                Task { @MainActor in
                    if isText { self.addTextFile(data) }
                    else { self.addImage(data) }
                }
            }
            return true
        }
        for type in [UTType.png, .tiff] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                guard let data else { return }
                Task { @MainActor in self.addImage(data) }
            }
            return true
        }
        if provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let string = object as? String else { return }
                Task { @MainActor in self.addText(string) }
            }
            return true
        }
        return false
    }

    private func addImage(_ data: Data) {
        do {
            let element = try MacImageImporter.add(data: data, to: page, in: context)
            save()
            selectedElementID = element.id
        } catch { errorMessage = error.localizedDescription }
    }

    private func addTextFile(_ data: Data) {
        do {
            let element = try MacTextImporter.add(data: data, to: page, in: context)
            save()
            selectedElementID = element.id
        } catch { errorMessage = error.localizedDescription }
    }

    private func save() {
        page.modifiedAt = .now
        notebook.modifiedAt = .now
        do { try context.save() } catch { errorMessage = error.localizedDescription }
    }
}

private struct MacElementView: View {
    let element: PageElement
    let selected: Bool
    let zoom: Double
    let onSelect: () -> Void
    let onMove: (Double, Double) -> Void
    let onResize: (Double, Double) -> Void
    @State private var dragOffset = CGSize.zero
    @State private var resizeOffset = CGSize.zero

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if element.type == .image, let data = element.imageData,
                   let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else if element.type == .textBox || element.type == .stickyNote {
                    Text(AttributedString(element.resolvedRichText))
                        .font(.system(size: element.fontSize))
                        .fontWeight(element.isBold ? .bold : .regular)
                        .italic(element.isItalic)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(8)
                        .background(element.type == .stickyNote ? Color.yellow.opacity(0.3) : .clear)
                } else {
                    Label(element.type.rawValue, systemImage: "square.dashed")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: element.width, height: element.height)
            .contentShape(Rectangle())
            .overlay(Rectangle().stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
            .onTapGesture(perform: onSelect)
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged {
                    dragOffset = CGSize(width: $0.translation.width / zoom,
                                        height: $0.translation.height / zoom)
                    onSelect()
                }
                .onEnded { value in
                    dragOffset = .zero
                    onMove(value.translation.width / zoom, value.translation.height / zoom)
                })

            if selected && (element.type == .image || element.type == .textBox || element.type == .stickyNote) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption)
                    .padding(5)
                    .background(.regularMaterial)
                    .overlay(Rectangle().stroke(.tint))
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged {
                            resizeOffset = CGSize(width: $0.translation.width / zoom,
                                                  height: $0.translation.height / zoom)
                        }
                        .onEnded { value in
                            resizeOffset = .zero
                            onResize(value.translation.width / zoom, value.translation.height / zoom)
                        })
            }
        }
        .offset(dragOffset)
    }
}

enum MacImageImporter {
    enum ImportError: LocalizedError {
        case unreadableImage
        var errorDescription: String? { "This image could not be opened." }
    }

    @MainActor
    @discardableResult
    static func add(data: Data, to page: Page, in context: ModelContext) throws -> PageElement {
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ImportError.unreadableImage
        }
        let size = page.pageOrientation.size
        let scale = min(440 / Double(cgImage.width), 320 / Double(cgImage.height), 1)
        let element = PageElement(type: .image, x: size.width / 2, y: 240,
                                  width: max(80, Double(cgImage.width) * scale),
                                  height: max(60, Double(cgImage.height) * scale))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        element.imageData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) ?? data
        context.insert(element)
        page.appendElement(element)
        Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage)
            try? handler.perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            await MainActor.run {
                guard element.modelContext != nil else { return }
                element.text = text
                page.modifiedAt = .now
                page.notebook?.modifiedAt = .now
                try? context.save()
            }
        }
        return element
    }
}

enum MacTextImporter {
    enum ImportError: LocalizedError {
        case unreadableText
        var errorDescription: String? { "This text file could not be opened." }
    }

    @MainActor
    @discardableResult
    static func add(data: Data, to page: Page, in context: ModelContext) throws -> PageElement {
        guard let string = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16), !string.isEmpty else {
            throw ImportError.unreadableText
        }
        let size = page.pageOrientation.size
        let element = PageElement(type: .textBox, x: size.width / 2, y: min(310, size.height / 2),
                                  width: min(540, size.width - 80), height: min(500, size.height - 180))
        element.text = string
        context.insert(element)
        page.appendElement(element)
        return element
    }
}
