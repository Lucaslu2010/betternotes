import Foundation
import PencilKit
import SwiftData
import SwiftUI

/// The editor's single selection contract. Stroke indices refer to the current
/// PKDrawing, while element IDs refer to the current page relationship.
struct SelectionState: Equatable {
    var strokeIndices: Set<Int> = []
    var elementIDs: Set<PersistentIdentifier> = []
    var bounds: CGRect = .null

    var isEmpty: Bool { strokeIndices.isEmpty && elementIDs.isEmpty }
    var count: Int { strokeIndices.count + elementIDs.count }

    mutating func clear() {
        strokeIndices.removeAll()
        elementIDs.removeAll()
        bounds = .null
    }
}

/// A serializable clipboard snapshot. Keeping stroke and element snapshots
/// independent makes mixed selections lossless and avoids depending on model
/// object identity after a paste or app relaunch.
struct SelectionPayload: Codable, Equatable {
    static let currentVersion = 1

    struct ElementSnapshot: Codable, Equatable {
        var type: String
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var rotation: Double
        var text: String?
        var richTextData: Data?
        var fontName: String
        var fontSize: Double
        var isBold: Bool
        var isItalic: Bool
        var isUnderline: Bool
        var textAlignment: String
        var shapeKind: String?
        var colorHex: String?
        var imageData: Data?
        var audioData: Data?
        var audioDuration: Double?
        var transcript: String?
        var isRevealed: Bool
        var isLocked: Bool

        init(_ element: PageElement, relativeTo origin: CGPoint) {
            type = element.elementType
            x = element.posX - origin.x
            y = element.posY - origin.y
            width = element.width
            height = element.height
            rotation = element.rotation
            text = element.text
            richTextData = element.richTextData
            fontName = element.fontName
            fontSize = element.fontSize
            isBold = element.isBold
            isItalic = element.isItalic
            isUnderline = element.isUnderline
            textAlignment = element.textAlignment
            shapeKind = element.shapeKind
            colorHex = element.colorHex
            imageData = element.imageData
            audioData = element.audioData
            audioDuration = element.audioDuration
            transcript = element.transcript
            isRevealed = element.isRevealed
            isLocked = element.isLocked
        }

        func makeElement(at origin: CGPoint, page: Page) -> PageElement {
            let element = PageElement(
                type: ElementType(rawValue: type) ?? .textBox,
                x: origin.x + x,
                y: origin.y + y,
                width: width,
                height: height,
                rotation: rotation
            )
            element.text = text
            element.richTextData = richTextData
            element.fontName = fontName
            element.fontSize = fontSize
            element.isBold = isBold
            element.isItalic = isItalic
            element.isUnderline = isUnderline
            element.textAlignment = textAlignment
            element.shapeKind = shapeKind
            element.colorHex = colorHex
            element.imageData = imageData
            element.audioData = audioData
            element.audioDuration = audioDuration
            element.transcript = transcript
            element.isRevealed = isRevealed
            element.isLocked = isLocked
            element.page = page
            return element
        }
    }

    var version: Int = SelectionPayload.currentVersion
    var strokes: [Data] = []
    var elements: [ElementSnapshot] = []
    var bounds: CGRect = .zero

    var isEmpty: Bool { strokes.isEmpty && elements.isEmpty }
}

enum StrokeSelectionGeometry {
    /// Selects strokes by their rendered path. Bounds are only used as a fast
    /// rejection; a large bounding rectangle crossing the lasso is not enough.
    static func indices(in drawing: PKDrawing, rect: CGRect) -> Set<Int> {
        Set(drawing.strokes.enumerated().compactMap { index, stroke in
            let bounds = stroke.renderBounds
            guard bounds.intersects(rect) else { return nil }
            let points = stroke.path.map { $0.location.applying(stroke.transform) }
            return pathIntersects(points, rect: rect) ? index : nil
        })
    }

    static func indices(in drawing: PKDrawing, polygon: [CGPoint]) -> Set<Int> {
        guard polygon.count >= 3 else { return [] }
        return Set(drawing.strokes.enumerated().compactMap { index, stroke in
            let points = stroke.path.map { $0.location.applying(stroke.transform) }
            return pathIntersects(points, polygon: polygon) ? index : nil
        })
    }

    static func pathIntersects(_ points: [CGPoint], rect: CGRect) -> Bool {
        guard !points.isEmpty else { return false }
        if points.contains(where: rect.contains) { return true }
        let edges = [
            (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY)),
            (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)),
            (CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)),
            (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY))
        ]
        return zip(points, points.dropFirst()).contains { a, b in
            edges.contains { segmentsIntersect(a, b, $0.0, $0.1) }
        }
    }

    static func pathIntersects(_ points: [CGPoint], polygon: [CGPoint]) -> Bool {
        guard !points.isEmpty else { return false }
        if points.contains(where: { pointInPolygon($0, polygon: polygon) }) { return true }
        let edges = zip(polygon, polygon.dropFirst() + [polygon[0]])
        return zip(points, points.dropFirst()).contains { a, b in
            edges.contains { segmentsIntersect(a, b, $0.0, $0.1) }
        }
    }

    static func pointInPolygon(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if ((a.y > point.y) != (b.y > point.y)) &&
                point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    static func segmentsIntersect(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        func orientation(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        let o1 = orientation(a, b, c)
        let o2 = orientation(a, b, d)
        let o3 = orientation(c, d, a)
        let o4 = orientation(c, d, b)
        let epsilon: CGFloat = 0.001
        func onSegment(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> Bool {
            q.x >= min(p.x, r.x) - epsilon && q.x <= max(p.x, r.x) + epsilon &&
                q.y >= min(p.y, r.y) - epsilon && q.y <= max(p.y, r.y) + epsilon
        }
        if abs(o1) <= epsilon && onSegment(a, c, b) { return true }
        if abs(o2) <= epsilon && onSegment(a, d, b) { return true }
        if abs(o3) <= epsilon && onSegment(c, a, d) { return true }
        if abs(o4) <= epsilon && onSegment(c, b, d) { return true }
        return ((o1 > epsilon && o2 < -epsilon) || (o1 < -epsilon && o2 > epsilon)) &&
            ((o3 > epsilon && o4 < -epsilon) || (o3 < -epsilon && o4 > epsilon))
    }
}

enum SelectionTransform {
    static let minimumDimension: CGFloat = 8

    static func affine(scaleX: CGFloat = 1, scaleY: CGFloat = 1,
                       rotation: CGFloat = 0, translation: CGSize = .zero,
                       anchor: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
            .concatenating(.init(scaleX: scaleX, y: scaleY))
            .concatenating(.init(rotationAngle: rotation))
            .concatenating(.init(translationX: anchor.x, y: anchor.y))
            .concatenating(.init(translationX: translation.width, y: translation.height))
    }

    static func clampedBounds(_ bounds: CGRect, pageSize: CGSize) -> CGRect {
        let width = max(minimumDimension, min(bounds.width, pageSize.width))
        let height = max(minimumDimension, min(bounds.height, pageSize.height))
        let x = min(max(bounds.midX, width / 2), pageSize.width - width / 2)
        let y = min(max(bounds.midY, height / 2), pageSize.height - height / 2)
        return CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }

    static func recoveryTranslation(for bounds: CGRect, pageSize: CGSize) -> CGSize {
        let dx: CGFloat
        let dy: CGFloat
        if bounds.width > pageSize.width { dx = pageSize.width / 2 - bounds.midX }
        else if bounds.minX < 0 { dx = -bounds.minX }
        else if bounds.maxX > pageSize.width { dx = pageSize.width - bounds.maxX }
        else { dx = 0 }
        if bounds.height > pageSize.height { dy = pageSize.height / 2 - bounds.midY }
        else if bounds.minY < 0 { dy = -bounds.minY }
        else if bounds.maxY > pageSize.height { dy = pageSize.height - bounds.maxY }
        else { dy = 0 }
        return CGSize(width: dx, height: dy)
    }
}

enum SelectionPasteGeometry {
    static func origin(for payloadBounds: CGRect, visibleCenter: CGPoint, pageSize: CGSize) -> CGPoint {
        let proposedX = visibleCenter.x - payloadBounds.width / 2
        let proposedY = visibleCenter.y - payloadBounds.height / 2
        let x = payloadBounds.width > pageSize.width
            ? (pageSize.width - payloadBounds.width) / 2
            : min(max(proposedX, 0), pageSize.width - payloadBounds.width)
        let y = payloadBounds.height > pageSize.height
            ? (pageSize.height - payloadBounds.height) / 2
            : min(max(proposedY, 0), pageSize.height - payloadBounds.height)
        return CGPoint(x: x, y: y)
    }
}

enum ElementLayering {
    static func canMove<ID: Hashable>(_ order: [ID], selected: Set<ID>, forward: Bool) -> Bool {
        guard !selected.isEmpty else { return false }
        if forward {
            return order.indices.dropLast().contains { selected.contains(order[$0]) && !selected.contains(order[$0 + 1]) }
        }
        return order.indices.dropFirst().contains { selected.contains(order[$0]) && !selected.contains(order[$0 - 1]) }
    }

    static func moving<ID: Hashable>(_ order: [ID], selected: Set<ID>, forward: Bool) -> [ID] {
        guard canMove(order, selected: selected, forward: forward) else { return order }
        var result = order
        if forward {
            for index in stride(from: result.count - 2, through: 0, by: -1)
            where selected.contains(result[index]) && !selected.contains(result[index + 1]) {
                result.swapAt(index, index + 1)
            }
        } else {
            for index in 1..<result.count
            where selected.contains(result[index]) && !selected.contains(result[index - 1]) {
                result.swapAt(index, index - 1)
            }
        }
        return result
    }
}

struct ThumbnailTransform: Equatable {
    let scale: CGFloat
    let origin: CGPoint
    let renderedSize: CGSize

    init(pageSize: CGSize, thumbnailSize: CGSize) {
        let widthScale = thumbnailSize.width / max(pageSize.width, 1)
        let heightScale = thumbnailSize.height / max(pageSize.height, 1)
        scale = min(widthScale, heightScale)
        renderedSize = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
        origin = CGPoint(
            x: (thumbnailSize.width - renderedSize.width) / 2,
            y: (thumbnailSize.height - renderedSize.height) / 2
        )
    }

    func point(_ pagePoint: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + pagePoint.x * scale, y: origin.y + pagePoint.y * scale)
    }

    func size(_ pageSize: CGSize) -> CGSize {
        CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
    }
}
