import SwiftUI
import SwiftData
import CoreTransferable
import UniformTypeIdentifiers

struct NotebookDragPayload: Codable, Transferable {
    let notebookID: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "com.betternotes.notebook-reference", conformingTo: .data))
    }
}

/// Button press animation hands off to the system's native drag lift preview.
/// No extra long-press recognizer competes with navigation or dragging.
struct NotebookLiftButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 1.035 : 1)
            .rotationEffect(.degrees(configuration.isPressed && !reduceMotion ? -1.5 : 0))
            .shadow(color: .black.opacity(configuration.isPressed ? 0.16 : 0), radius: 12, y: 8)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

struct LibraryFolderTile: View {
    let path: String
    let notebookCount: Int
    let folderCount: Int
    var colorHex: String = "4A6FA5"
    var isFavorite = false
    var acceptsDrops = true
    var onOpen: () -> Void
    var onMove: ([UUID], String) -> Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false
    @State private var dropCount = 0

    private var tint: Color { Color(hex: colorHex) ?? .accentColor }

    private var detail: String {
        let parts = [notebookCount > 0 ? "\(notebookCount) notebook\(notebookCount == 1 ? "" : "s")" : nil,
                     folderCount > 0 ? "\(folderCount) folder\(folderCount == 1 ? "" : "s")" : nil].compactMap { $0 }
        return parts.isEmpty ? "Empty folder" : parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 14) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(tint.opacity(isTargeted ? 0.18 : 0.07))
                    Image(systemName: isTargeted ? "folder.badge.plus" : "folder.fill")
                        .resizable().scaledToFit()
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(tint)
                        .padding(.horizontal, 22).padding(.bottom, 46).padding(.top, 12)
                        .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : dropCount)
                        .contentTransition(.symbolEffect(.replace))
                    Text(FolderPath.name(of: path))
                        .font(.headline).foregroundStyle(.primary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .padding(16)
                }
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(isTargeted ? 0.9 : 0.16), lineWidth: isTargeted ? 2 : 1))
                .shadow(color: .black.opacity(isTargeted ? 0.15 : 0.04), radius: isTargeted ? 12 : 5, y: 5)
                HStack(spacing: 6) {
                    if isFavorite { Image(systemName: "star.fill").foregroundStyle(.orange) }
                    Text(isTargeted ? "Move Here" : detail)
                        .foregroundStyle(isTargeted ? tint : .secondary)
                }
                .font(.caption2).padding(.leading, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isTargeted && !reduceMotion ? 1.055 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: isTargeted)
        .accessibilityLabel(FolderPath.name(of: path))
        .accessibilityValue(detail)
        .accessibilityHint("Open folder")
        .accessibilityIdentifier("library-folder-tile-\(path)")
        .dropDestination(for: NotebookDragPayload.self) { items, _ in
            guard acceptsDrops else { return false }
            let accepted = onMove(items.map(\.notebookID), path)
            if accepted { dropCount += 1 }
            return accepted
        } isTargeted: { isTargeted = acceptsDrops && $0 }
        .sensoryFeedback(.success, trigger: dropCount)
    }
}

/// Breadcrumbs and sidebar rows also accept drops, including moving to Notes.
struct NotebookFolderDropTarget: ViewModifier {
    let path: String
    var onMove: ([UUID], String) -> Bool
    @State private var isTargeted = false
    func body(content: Content) -> some View {
        content
            .background(Color.accentColor.opacity(isTargeted ? 0.18 : 0), in: RoundedRectangle(cornerRadius: 8))
            .animation(.easeOut(duration: 0.18), value: isTargeted)
            .dropDestination(for: NotebookDragPayload.self) { items, _ in
                onMove(items.map(\.notebookID), path)
            } isTargeted: { isTargeted = $0 }
    }
}

struct ImportDestinationPicker: View {
    let fileName: String
    let folders: [String]
    var onChoose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPath = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(fileName).font(.headline).lineLimit(3)
                } footer: { Text("Choose where to save this document.") }
                Section("Save To") {
                    destination("", label: "Notes", icon: "books.vertical")
                    ForEach(folders, id: \.self) { path in
                        destination(path, label: FolderPath.name(of: path), icon: "folder.fill")
                            .padding(.leading, CGFloat(path.split(separator: "/").count - 1) * 16 + 16)
                    }
                }
            }
            .navigationTitle("Import Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { onChoose(selectedPath) }.bold()
                        .accessibilityIdentifier("document-import-confirm")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func destination(_ path: String, label: String, icon: String) -> some View {
        Button { selectedPath = path } label: {
            HStack {
                Label(label, systemImage: icon)
                Spacer()
                if selectedPath == path { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("document-import-location-\(path.isEmpty ? "root" : path)")
        .accessibilityValue(path.isEmpty ? "Notes" : "Notes / " + path)
        .accessibilityAddTraits(selectedPath == path ? .isSelected : [])
    }
}

/// Uses a draft so Cancel and swipe-to-dismiss never save a preview colour.
struct FolderColourSheet: View {
    let folder: NotebookFolder
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var colourHex = "4A6FA5"
    @State private var loaded = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    LibraryFolderTile(path: folder.path, notebookCount: 0, folderCount: 0,
                                      colorHex: colourHex, isFavorite: folder.isFavorite,
                                      acceptsDrops: false, onOpen: {}, onMove: { _, _ in false })
                        .frame(width: 180).frame(maxWidth: .infinity).allowsHitTesting(false)
                    Text("Colour").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                        ForEach(CoverPalette.colors, id: \.self) { hex in
                            Button { colourHex = hex } label: {
                                Circle().fill(Color(hex: hex) ?? .blue).frame(width: 36, height: 36)
                                    .overlay(Circle().stroke(colourHex == hex ? Color.accentColor : .clear, lineWidth: 3).padding(-3))
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Folder colour \(hex)")
                            .accessibilityAddTraits(colourHex == hex ? .isSelected : [])
                        }
                    }
                    ColorPicker("Custom", selection: Binding(
                        get: { Color(hex: colourHex) ?? .blue }, set: { colourHex = $0.hexString }
                    ), supportsOpacity: false)
                }.padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Customize Colour")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: save).bold() }
            }
            .onAppear { if !loaded { colourHex = folder.colorHex; loaded = true } }
            .alert("Couldn’t Save Colour", isPresented: Binding(
                get: { saveError != nil }, set: { if !$0 { saveError = nil } }
            )) { Button("OK", role: .cancel) { saveError = nil } } message: { Text(saveError ?? "") }
        }
        .presentationDetents([.large])
    }

    private func save() {
        let old = folder.colorHex
        folder.colorHex = colourHex
        do { try context.save(); dismiss() }
        catch { folder.colorHex = old; saveError = error.localizedDescription }
    }
}
