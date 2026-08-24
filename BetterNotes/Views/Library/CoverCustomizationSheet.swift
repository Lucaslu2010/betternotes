import SwiftUI
import SwiftData

/// Sheet for customizing a notebook's cover: color(s), style, and emoji.
/// Binds directly to the notebook so changes are live.
struct CoverCustomizationSheet: View {
    @Bindable var notebook: Notebook
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var saveError: String?
    /// Snapshot of the cover fields as they were when the sheet opened, so
    /// Cancel can undo the live-preview edits.
    @State private var original: CoverSnapshot?

    private struct CoverSnapshot {
        let colorHex: String
        let color2Hex: String
        let style: String
        let emoji: String?
    }

    private func captureOriginal() {
        guard original == nil else { return }
        original = CoverSnapshot(
            colorHex: notebook.coverColorHex,
            color2Hex: notebook.coverColor2Hex,
            style: notebook.coverStyle,
            emoji: notebook.coverEmoji
        )
    }

    private func revert() {
        guard let original else { return }
        notebook.coverColorHex = original.colorHex
        notebook.coverColor2Hex = original.color2Hex
        notebook.coverStyle = original.style
        notebook.coverEmoji = original.emoji
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Live preview
                    NotebookCover(notebook: notebook)
                        .frame(width: 180)

                    // Style picker
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Style")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 10)], spacing: 10) {
                            ForEach(NotebookCoverStyle.allCases, id: \.self) { style in
                                styleButton(style)
                            }
                        }
                    }

                    // Primary color
                    VStack(alignment: .leading, spacing: 10) {
                        Text(notebook.style == .solid ? "Color" : "Primary Color")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        colorGrid(selection: $notebook.coverColorHex)

                        ColorPicker("Custom", selection: Binding(
                            get: { Color(hex: notebook.coverColorHex) ?? .blue },
                            set: { notebook.coverColorHex = $0.hexString }
                        ), supportsOpacity: false)
                            .font(.subheadline)
                    }

                    // Secondary color (for gradient/diagonal only — pattern
                    // uses only the primary color).
                    if notebook.style == .gradient || notebook.style == .diagonal {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Accent Color")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)

                            colorGrid(selection: $notebook.coverColor2Hex)

                            ColorPicker("Custom", selection: Binding(
                                get: { Color(hex: notebook.coverColor2Hex) ?? .pink },
                                set: { notebook.coverColor2Hex = $0.hexString }
                            ), supportsOpacity: false)
                                .font(.subheadline)
                        }
                    }

                    // Emoji picker
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Cover Icon")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if notebook.coverEmoji != nil {
                                Button("Clear") {
                                    notebook.coverEmoji = nil
                                }
                                .font(.caption)
                            }
                        }

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                            ForEach(CoverPalette.emojis, id: \.self) { emoji in
                                Button {
                                    notebook.coverEmoji = emoji
                                } label: {
                                    Text(emoji)
                                        .font(.title2)
                                        .frame(width: 44, height: 44)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(notebook.coverEmoji == emoji ?
                                                      Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(notebook.coverEmoji == emoji ?
                                                        Color.accentColor : Color.clear, lineWidth: 2)
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Cover icon \(emoji)")
                                .accessibilityAddTraits(notebook.coverEmoji == emoji ? .isSelected : [])
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Customize Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The sheet binds straight to the model for a live preview, so
                // Cancel restores the snapshot taken when it opened.
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        revert()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: save).bold()
                }
            }
            .onAppear(perform: captureOriginal)
            .alert("Couldn’t Save Cover", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("Try Again", action: save)
                Button("Dismiss", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled()
    }

    private func colorGrid(selection: Binding<String>) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 8)], spacing: 8) {
            ForEach(CoverPalette.colors, id: \.self) { hex in
                Button { selection.wrappedValue = hex } label: {
                    Circle()
                        .fill(Color(hex: hex) ?? .blue)
                        .frame(width: 36, height: 36)
                        .overlay(
                            Circle()
                                .stroke(.white, lineWidth: selection.wrappedValue == hex ? 3 : 0)
                        )
                        .overlay(
                            Circle()
                                .stroke(selection.wrappedValue == hex ? Color.accentColor : Color.primary.opacity(0.15),
                                        lineWidth: selection.wrappedValue == hex ? 2 : 1)
                        )
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cover color \(hex)")
                .accessibilityAddTraits(selection.wrappedValue == hex ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private func styleButton(_ style: NotebookCoverStyle) -> some View {
        let isSelected = notebook.style == style
        Button {
            notebook.coverStyle = style.rawValue
        } label: {
            VStack(spacing: 6) {
                Image(systemName: style.icon)
                    .font(.title3)
                Text(style.label)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func save() {
        notebook.modifiedAt = .now
        do {
            try context.save()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
