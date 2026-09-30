import AppKit
import PencilKit

/// Flattens the same page coordinates shown in MacPageEditor for optional AI image context.
@MainActor
enum MacPageSnapshot {
    static func jpeg(_ page: Page) -> Data? {
        let size = page.pageOrientation.size
        let image = NSImage(size: size, flipped: true) { rect in
            (NSColor(page.background).usingColorSpace(.deviceRGB) ?? .white).setFill()
            rect.fill()
            if let data = page.inkData, let drawing = try? PKDrawing(data: data) {
                MacInkRenderer.image(from: drawing, in: rect).draw(in: rect)
            }
            for element in page.orderedElements {
                let frame = CGRect(x: element.posX - element.width / 2,
                                   y: element.posY - element.height / 2,
                                   width: element.width, height: element.height)
                if element.type == .image, let data = element.imageData,
                   let imported = NSImage(data: data) {
                    imported.draw(in: frame)
                } else if element.type == .textBox || element.type == .stickyNote {
                    element.resolvedRichText.draw(in: frame.insetBy(dx: 8, dy: 8))
                }
            }
            return true
        }
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}
