import SwiftUI

/// Perceived brightness of a color, 0 (black) to 1 (white).
/// Shared by the cover text contrast logic and the page-style dark-paper
/// warning, so there is one definition of "dark".
enum ColorLuminance {
    static func value(of color: Color) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return Double(0.299 * r + 0.587 * g + 0.114 * b)
    }

    static func value(ofHex hex: String) -> Double {
        value(of: Color(hex: hex) ?? .white)
    }

    /// Paper this dark makes the default dark ink colors effectively invisible.
    static func isDarkPaper(_ hex: String) -> Bool {
        value(ofHex: hex) < 0.45
    }
}

struct NotebookCover: View {
    let notebook: Notebook

    /// Determine whether cover text should be dark (for light backgrounds)
    /// or white (for dark backgrounds) based on luminance.
    private var textColor: Color {
        let colors: [Color] = [notebook.coverColor, notebook.coverColor2]
        let avgLuminance = colors.map { luminance(of: $0) }.reduce(0, +) / Double(colors.count)
        return avgLuminance > 0.6 ? .black : .white
    }

    private var subtitleColor: Color {
        textColor.opacity(0.7)
    }

    private var dateColor: Color {
        textColor.opacity(0.55)
    }

    private func luminance(of color: Color) -> Double {
        ColorLuminance.value(of: color)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .topLeading) {
                coverBackground

                // Book spine
                Rectangle()
                    .fill(.black.opacity(0.18))
                    .frame(width: 6)
                Rectangle()
                    .fill(.white.opacity(0.10))
                    .frame(width: 1)
                    .padding(.leading, 14)

                // Optional emoji/icon centered on the cover
                if let emoji = notebook.coverEmoji, !emoji.isEmpty {
                    VStack {
                        Spacer()
                        Text(emoji)
                            .font(.system(size: 42))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }

                // Title/subtitle/date at the bottom
                VStack(alignment: .leading) {
                    Spacer()
                    Text(notebook.title)
                        .font(.headline)
                        .foregroundStyle(textColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !notebook.subtitle.isEmpty {
                        Text(notebook.subtitle)
                            .font(.caption)
                            .foregroundStyle(subtitleColor)
                            .lineLimit(1)
                    }
                    Text(notebook.modifiedAt, format: .dateTime.month().day().year())
                        .font(.caption2)
                        .foregroundStyle(dateColor)
                        .padding(.top, 2)
                }
                .padding(16)
            }
            .aspectRatio(3.0/4.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 6)

            HStack(spacing: 6) {
                if notebook.isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.orange)
                }
                Image(systemName: "doc.text")
                    .font(.caption2)
                let pageCount = notebook.pages.filter { $0.trashedAt == nil }.count
                Text("\(pageCount) page\(pageCount == 1 ? "" : "s")")
                    .font(.caption2)
                if !notebook.folderName.isEmpty {
                    Text("·")
                    Text(notebook.folderName)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notebook.title)
        .accessibilityValue("\(notebook.pages.filter { $0.trashedAt == nil }.count) pages")
    }

    @ViewBuilder
    private var coverBackground: some View {
        switch notebook.style {
        case .solid:
            notebook.coverColor
        case .gradient:
            LinearGradient(
                colors: [notebook.coverColor, notebook.coverColor2],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .diagonal:
            LinearGradient(
                colors: [notebook.coverColor, notebook.coverColor2],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )
        case .pattern:
            notebook.coverColor
                .overlay(
                    Canvas { context, size in
                        let dotSize: CGFloat = 3
                        let spacing: CGFloat = 18
                        var y: CGFloat = spacing / 2
                        var row = 0
                        while y < size.height {
                            let xOffset: CGFloat = row % 2 == 0 ? 0 : spacing / 2
                            var x: CGFloat = spacing / 2 + xOffset
                            while x < size.width {
                                context.fill(
                                    Path(CGRect(x: x, y: y, width: dotSize, height: dotSize)),
                                    with: .color(.white.opacity(0.08))
                                )
                                x += spacing
                            }
                            y += spacing
                            row += 1
                        }
                    }
                )
        }
    }
}
