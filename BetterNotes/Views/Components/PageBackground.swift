import SwiftUI

/// Draws a page's background color and line pattern, including student templates.
struct PageBackground: View {
    let backgroundHex: String
    let lineStyle: PageLineStyle
    let orientation: PageOrientation
    var lineThickness: Double = PageLineAppearance.defaultThickness
    var lineOpacity: Double = PageLineAppearance.defaultOpacity

    var body: some View {
        ZStack {
            Color(hex: backgroundHex) ?? .white
            lineOverlay
        }
    }

    @ViewBuilder
    private var lineOverlay: some View {
        Canvas { context, size in
            let pageSize = orientation.size
            let scale = min(size.width / max(pageSize.width, 1), size.height / max(pageSize.height, 1))
            let stroke = GraphicsContext.Shading.color(.black.opacity(PageLineAppearance.opacity(lineOpacity)))
            let width = max(0.2, CGFloat(PageLineAppearance.thickness(lineThickness)) * scale)
            switch lineStyle {
            case .blank:
                break
            case .ruled:
                let spacing: Double = 36 * scale
                var y = spacing
                while y < size.height {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: stroke, lineWidth: width)
                    y += spacing
                }
            case .grid:
                let spacing: Double = 36 * scale
                var x = spacing
                while x < size.width {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(p, with: stroke, lineWidth: width)
                    x += spacing
                }
                var y = spacing
                while y < size.height {
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(p, with: stroke, lineWidth: width)
                    y += spacing
                }
            case .dots:
                let spacing: Double = 28 * scale
                var y = spacing
                while y < size.height {
                    var x = spacing
                    while x < size.width {
                        let dotSize = max(1, CGFloat(PageLineAppearance.thickness(lineThickness)) * 4 * scale)
                        let rect = CGRect(x: x - dotSize / 2, y: y - dotSize / 2, width: dotSize, height: dotSize)
                        context.fill(Path(ellipseIn: rect), with: stroke)
                        x += spacing
                    }
                    y += spacing
                }
            case .cornell:
                let marginX: CGFloat = min(180 * scale, size.width * 0.24)
                var divider = Path()
                divider.move(to: CGPoint(x: marginX, y: 0))
                divider.addLine(to: CGPoint(x: marginX, y: size.height))
                context.stroke(divider, with: stroke, lineWidth: width * 1.5)
                drawRuled(context: context, size: size, startY: 52 * scale, spacing: 30 * scale, stroke: stroke, width: width)
            case .checklist:
                drawRuled(context: context, size: size, startY: 60 * scale, spacing: 40 * scale, stroke: stroke, width: width)
                let spacing: CGFloat = 40 * scale
                var y = spacing
                while y < size.height {
                    context.stroke(
                        Path(CGRect(x: 18 * scale, y: y - 11 * scale, width: 20 * scale, height: 20 * scale)),
                        with: stroke,
                        lineWidth: width
                    )
                    y += spacing
                }
            case .weeklyPlanner:
                let columns = 7
                let headerHeight: CGFloat = 54 * scale
                let columnWidth = size.width / CGFloat(columns)
                var grid = Path()
                for index in 0...columns {
                    let x = CGFloat(index) * columnWidth
                    grid.move(to: CGPoint(x: x, y: headerHeight))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                }
                let rowHeight = max(42 * scale, (size.height - headerHeight) / 6)
                var y = headerHeight
                while y <= size.height {
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                    y += rowHeight
                }
                grid.move(to: CGPoint(x: 0, y: headerHeight))
                grid.addLine(to: CGPoint(x: size.width, y: headerHeight))
                context.stroke(grid, with: stroke, lineWidth: width)
            }
        }
    }

    private func drawRuled(context: GraphicsContext, size: CGSize, startY: CGFloat, spacing: CGFloat,
                           stroke: GraphicsContext.Shading, width: CGFloat) {
        var y = startY
        while y < size.height {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: stroke, lineWidth: width)
            y += spacing
        }
    }
}

struct PageTemplatePicker: View {
    @Binding var selection: PageLineStyle
    let backgroundHex: String
    let orientation: PageOrientation
    var lineThickness: Double = PageLineAppearance.defaultThickness
    var lineOpacity: Double = PageLineAppearance.defaultOpacity

    private let columns = [GridItem(.adaptive(minimum: 132), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(PageLineStyle.allCases, id: \.self) { style in
                let isSelected = selection == style
                Button {
                    selection = style
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        PageBackground(
                            backgroundHex: backgroundHex,
                            lineStyle: style,
                            orientation: orientation,
                            lineThickness: lineThickness,
                            lineOpacity: lineOpacity
                        )
                        .aspectRatio(orientation.size.width / orientation.size.height, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isSelected ? 2 : 0.5)
                        )

                        HStack(spacing: 6) {
                            Image(systemName: style.icon)
                            Text(style.label)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .fontWeight(.bold)
                            }
                        }
                        .font(.caption.weight(.medium))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Template \(style.label)")
                .accessibilityIdentifier("template-choice-\(style.rawValue)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
    }
}

struct LineAppearanceControls: View {
    @Binding var thickness: Double
    @Binding var opacity: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Thickness", value: String(format: "%.2f pt", thickness))
            Slider(value: $thickness, in: PageLineAppearance.thicknessRange, step: 0.25)
                .accessibilityIdentifier("line-thickness-slider")
        }
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Opacity", value: "\(Int((opacity * 100).rounded()))%")
            Slider(value: $opacity, in: PageLineAppearance.opacityRange, step: 0.05)
                .accessibilityIdentifier("line-opacity-slider")
            HStack {
                Text("Grey")
                Spacer()
                Text("Black")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
