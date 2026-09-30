import AppKit
import PencilKit

/// Pages have a fixed paper color, so PencilKit ink must use the same
/// appearance regardless of the Mac's window appearance.
@MainActor
enum MacInkRenderer {
    static func image(from drawing: PKDrawing, in rect: CGRect, scale: CGFloat = 1) -> NSImage {
        var image = NSImage()
        let paperAppearance = NSAppearance(named: .aqua)!
        paperAppearance.performAsCurrentDrawingAppearance {
            image = drawing.image(from: rect, scale: scale)
        }
        return image
    }
}
