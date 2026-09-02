import Foundation
import SwiftUI
import PencilKit
import UIKit

/// Renders a page (or an entire notebook) into a PDF document.
/// Each page is drawn with its background, line pattern, PencilKit ink,
/// and a flattened render of all page elements (text, images, shapes, sticky, audio badge).
enum PDFExport {

    // MARK: - Single page

    static func renderPage(_ page: Page) -> Data {
        let pageSize = page.pageOrientation.size
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        return renderer.pdfData { ctx in
            ctx.beginPage()
            drawBackground(page, in: ctx)
            drawInk(page, in: pageSize)
            drawElements(page, in: pageSize)
        }
    }

    // MARK: - Entire notebook

    static func renderNotebook(_ notebook: Notebook) -> Data {
        let sorted = notebook.pages.filter { $0.trashedAt == nil }.sorted(by: { $0.index < $1.index })
        guard !sorted.isEmpty else {
            let size = PageOrientation.portrait.size
            let r = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size))
            return r.pdfData { c in c.beginPage() }
        }
        // Use the first page's bounds for the renderer. Each page sets its own
        // bounds via beginPage(withBounds:), which UIGraphicsPDFRenderer supports
        // for mixed-orientation documents. Previously maxSize (max of all pages)
        // caused landscape pages to be clipped in portrait-first documents.
        let firstSize = sorted[0].pageOrientation.size
        let format = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: firstSize), format: format)
        return renderer.pdfData { ctx in
            for page in sorted {
                let size = page.pageOrientation.size
                ctx.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
                drawBackground(page, in: ctx)
                drawInk(page, in: size)
                drawElements(page, in: size)
            }
        }
    }

    // MARK: - Drawing helpers

    private static func drawBackground(_ page: Page, in ctx: UIGraphicsPDFRendererContext) {
        let size = page.pageOrientation.size
        let rect = CGRect(origin: .zero, size: size)

        // Fill background color.
        UIColor(page.background).setFill()
        UIRectFill(rect)

        // Draw line pattern on top.
        drawLines(page, in: rect)
    }

    private static func drawLines(_ page: Page, in rect: CGRect) {
        switch page.lines {
        case .blank:
            break
        case .ruled:
            let spacing: CGFloat = 36
            UIColor.gray.withAlphaComponent(0.25).setStroke()
            let path = UIBezierPath()
            var y = spacing
            while y < rect.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: rect.width, y: y))
                y += spacing
            }
            path.lineWidth = 0.5
            path.stroke()
        case .grid:
            let spacing: CGFloat = 36
            UIColor.gray.withAlphaComponent(0.2).setStroke()
            let path = UIBezierPath()
            var x: CGFloat = spacing
            while x < rect.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: rect.height))
                x += spacing
            }
            var y: CGFloat = spacing
            while y < rect.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: rect.width, y: y))
                y += spacing
            }
            path.lineWidth = 0.5
            path.stroke()
        case .dots:
            let spacing: CGFloat = 28
            UIColor.gray.withAlphaComponent(0.35).setFill()
            let dotSize: CGFloat = 2
            var y = spacing
            while y < rect.height {
                var x = spacing
                while x < rect.width {
                    let dotRect = CGRect(x: x - dotSize/2, y: y - dotSize/2, width: dotSize, height: dotSize)
                    UIBezierPath(ovalIn: dotRect).fill()
                    x += spacing
                }
                y += spacing
            }
        case .cornell:
            let marginX = min(180, rect.width * 0.24)
            UIColor.systemBlue.withAlphaComponent(0.45).setStroke()
            let divider = UIBezierPath()
            divider.move(to: CGPoint(x: marginX, y: 0))
            divider.addLine(to: CGPoint(x: marginX, y: rect.height))
            divider.lineWidth = 1.2
            divider.stroke()
            drawRuled(in: rect, startY: 52, spacing: 30)
        case .checklist:
            drawRuled(in: rect, startY: 60, spacing: 40)
            UIColor.gray.withAlphaComponent(0.45).setStroke()
            var y: CGFloat = 40
            while y < rect.height {
                UIBezierPath(rect: CGRect(x: 18, y: y - 11, width: 20, height: 20)).stroke()
                y += 40
            }
        case .weeklyPlanner:
            let headerHeight: CGFloat = 54
            let columnWidth = rect.width / 7
            let grid = UIBezierPath()
            for index in 0...7 {
                let x = CGFloat(index) * columnWidth
                grid.move(to: CGPoint(x: x, y: headerHeight))
                grid.addLine(to: CGPoint(x: x, y: rect.height))
            }
            let rowHeight = max(42, (rect.height - headerHeight) / 6)
            var y = headerHeight
            while y <= rect.height {
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: rect.width, y: y))
                y += rowHeight
            }
            UIColor.gray.withAlphaComponent(0.4).setStroke()
            grid.lineWidth = 0.8
            grid.stroke()
        }
    }

    private static func drawRuled(in rect: CGRect, startY: CGFloat, spacing: CGFloat) {
        UIColor.gray.withAlphaComponent(0.25).setStroke()
        let path = UIBezierPath()
        var y = startY
        while y < rect.height {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: rect.width, y: y))
            y += spacing
        }
        path.lineWidth = 0.5
        path.stroke()
    }

    private static func drawInk(_ page: Page, in size: CGSize) {
        guard let data = page.inkData,
              let drawing = try? PKDrawing(data: data) else { return }
        let bounds = drawing.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        // Draw the ink at its natural position.
        let img = drawing.image(from: bounds, scale: 2)
        img.draw(in: bounds)
    }

    private static func drawElements(_ page: Page, in pageSize: CGSize) {
        let context = UIGraphicsGetCurrentContext()
        // orderedElements, not elements: the array's order is the canvas
        // stacking order but SwiftData does not guarantee it, so an export
        // reading the raw relationship can stack a page differently from the
        // way it looks on screen — tape over an answer, say.
        for element in page.orderedElements {
            // posX/posY are the center (matching SwiftUI .position()).
            let frame = CGRect(x: element.posX - element.width/2,
                               y: element.posY - element.height/2,
                               width: element.width,
                               height: element.height)
            // Every on-screen renderer applies element.rotation via
            // .rotationEffect, which pivots about the centre. Without the same
            // transform here, exporting silently straightens the layout.
            let isRotated = element.rotation != 0
            if isRotated, let context {
                context.saveGState()
                context.translateBy(x: frame.midX, y: frame.midY)
                context.rotate(by: CGFloat(element.rotation * .pi / 180))
                context.translateBy(x: -frame.midX, y: -frame.midY)
            }
            defer { if isRotated, let context { context.restoreGState() } }
            switch element.type {
            case .textBox, .stickyNote:
                drawText(element, in: frame)
            case .image:
                drawImage(element, in: frame)
            case .shape:
                drawShape(element, in: frame)
            case .audioRecording:
                drawAudioBadge(element, in: frame)
            case .tape:
                drawTape(element, in: frame)
            }
        }
    }

    private static func drawText(_ element: PageElement, in frame: CGRect) {
        let bg = element.type == .stickyNote
            ? UIColor(element.tint).withAlphaComponent(0.35)
            : UIColor.systemGray6
        var bgRect = frame
        if element.type == .stickyNote { bgRect = bgRect.insetBy(dx: -2, dy: -2) }
        bg.setFill()
        UIBezierPath(roundedRect: bgRect, cornerRadius: 6).fill()

        let attributed = element.resolvedRichText
        let insetFrame = frame.insetBy(dx: 8, dy: 6)
        attributed.draw(
            with: insetFrame,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
    }

    private static func drawImage(_ element: PageElement, in frame: CGRect) {
        guard let data = element.imageData, let img = UIImage(data: data) else { return }
        img.draw(in: frame)
    }

    private static func drawShape(_ element: PageElement, in frame: CGRect) {
        let color = UIColor(element.tint)
        color.setStroke()
        let kind = ShapeKind(rawValue: element.shapeKind ?? "circle") ?? .circle
        let path = UIBezierPath()
        path.lineWidth = 3
        switch kind {
        case .circle:
            path.append(UIBezierPath(ovalIn: frame))
        case .rectangle:
            path.append(UIBezierPath(roundedRect: frame, cornerRadius: 6))
        case .line:
            path.move(to: CGPoint(x: frame.minX, y: frame.midY))
            path.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
        case .arrow:
            path.move(to: CGPoint(x: frame.minX, y: frame.maxY))
            path.addLine(to: CGPoint(x: frame.maxX, y: frame.minY))
        case .star:
            let starPath = starPath(in: frame)
            path.append(starPath)
        }
        path.stroke()
    }

    private static func drawAudioBadge(_ element: PageElement, in frame: CGRect) {
        UIColor.systemGray5.setFill()
        UIBezierPath(roundedRect: frame, cornerRadius: frame.height/2).fill()
        let font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.label
        ]
        let dur = element.audioDuration.map { String(format: "%d:%02d", Int($0)/60, Int($0)%60) } ?? "Recording"
        let label = "♪ \(dur)" as NSString
        let textRect = CGRect(x: frame.minX + 8, y: frame.minY + 4,
                              width: frame.width - 16, height: frame.height - 8)
        label.draw(in: textRect, withAttributes: attrs)
    }

    private static func drawTape(_ element: PageElement, in frame: CGRect) {
        if element.isRevealed {
            // Transparent — just dashed outline.
            UIColor.gray.withAlphaComponent(0.3).setStroke()
            let path = UIBezierPath(roundedRect: frame, cornerRadius: 4)
            path.lineWidth = 1
            path.setLineDash([4, 4], count: 2, phase: 0)
            path.stroke()
        } else {
            // Opaque tape.
            UIColor.gray.withAlphaComponent(0.8).setFill()
            UIBezierPath(roundedRect: frame, cornerRadius: 4).fill()
            let font = UIFont.systemFont(ofSize: 12)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white.withAlphaComponent(0.7)
            ]
            ("Tape" as NSString).draw(at: CGPoint(x: frame.midX - 15, y: frame.midY - 6), withAttributes: attrs)
        }
    }

    private static func starPath(in rect: CGRect) -> UIBezierPath {
        let cx = rect.midX, cy = rect.midY
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.4
        let pts = 5
        let path = UIBezierPath()
        for i in 0..<(pts * 2 + 1) {
            let r = i % 2 == 0 ? outer : inner
            let a = CGFloat(i) / CGFloat(pts * 2) * 2 * .pi - .pi / 2
            let p = CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}

// MARK: - Share helpers

extension PDFExport {
    /// Writes PDF data to a temp file and returns the URL for sharing.
    static func writePDF(_ data: Data, name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(Int(Date().timeIntervalSince1970)).pdf")
        try? data.write(to: url)
        return url
    }
}
