import Foundation
import PencilKit

/// Conservative scratch-out recognition in page coordinates. A gesture needs
/// three substantial passes and must cross existing ink more than once.
/// Ordinary writing, underlining, circles and blank-area scribbles stay ink.
enum ScribbleEraser {
    static func containsScratch(in drawing: PKDrawing, newStrokesFrom start: Int) -> Bool {
        guard start >= 0, start < drawing.strokes.count else { return false }
        return drawing.strokes[start...].contains { isScratch(points(in: $0)) }
    }

    static func erasing(in drawing: PKDrawing, newStrokesFrom start: Int) -> PKDrawing? {
        let strokes = drawing.strokes
        guard start > 0, start < strokes.count else { return nil }
        var removed = Set<Int>()
        for index in start..<strokes.count {
            let scratch = points(in: strokes[index])
            guard isScratch(scratch) else { continue }
            let scratchBounds = bounds(of: scratch)
            let padding = min(18, max(12, min(scratchBounds.width, scratchBounds.height) * 0.5))
            let area = scratchBounds.insetBy(dx: -padding, dy: -padding)
            var targets: [Int] = []
            for target in 0..<start where !removed.contains(target) {
                guard strokes[target].renderBounds.intersects(area) else { continue }
                let ink = points(in: strokes[target])
                guard ink.count > 1,
                      Double(ink.filter { area.contains($0) }.count) / Double(ink.count) >= 0.2 else { continue }
                var crossings = 0
                for (a, b) in zip(scratch, scratch.dropFirst()) {
                    if zip(ink, ink.dropFirst()).contains(where: { intersects(a, b, $0.0, $0.1) }) {
                        crossings += 1
                    }
                    if crossings >= 2 { break }
                }
                if crossings >= 2 { targets.append(target) }
            }
            if !targets.isEmpty {
                // Include punctuation dots and short detached strokes near a
                // directly crossed character. Do not absorb adjacent words.
                let directlyHitBounds = targets.reduce(CGRect.null) { $0.union(strokes[$1].renderBounds) }
                for target in 0..<start where !removed.contains(target) && !targets.contains(target) {
                    let dot = strokes[target].renderBounds
                    guard max(dot.width, dot.height) <= 16,
                          dot.midX >= area.minX, dot.midX <= area.maxX,
                          dot.maxX >= directlyHitBounds.minX - 10, dot.minX <= directlyHitBounds.maxX + 10,
                          dot.minY <= directlyHitBounds.maxY + 22, dot.maxY >= directlyHitBounds.minY - 22 else { continue }
                    targets.append(target)
                }
                removed.formUnion(targets)
                removed.insert(index)
            }
        }
        guard !removed.isEmpty else { return nil }
        return PKDrawing(strokes: strokes.enumerated().compactMap { removed.contains($0.offset) ? nil : $0.element })
    }

    static func isScratch(_ points: [CGPoint]) -> Bool {
        guard points.count >= 8 else { return false }
        let area = bounds(of: points)
        let horizontal = area.width >= area.height
        let span = max(area.width, area.height)
        guard span >= 18, min(area.width, area.height) <= span * 0.9 else { return false }
        let length = zip(points, points.dropFirst()).reduce(CGFloat.zero) {
            $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)
        }
        guard length >= max(48, span * 2.1) else { return false }
        let threshold = max(6, span * 0.14)
        let coordinates = points.map { horizontal ? $0.x : $0.y }
        let travel = zip(coordinates, coordinates.dropFirst()).reduce(CGFloat.zero) { $0 + abs($1.1 - $1.0) }
        // Closed loops can reverse twice without making three scratch passes.
        // Measure travel along the main axis so 8 and ∞ are not erase gestures.
        guard travel >= span * 2.4 else { return false }
        var extreme = coordinates[0]
        var direction: CGFloat = 0
        var reversals = 0
        for coordinate in coordinates.dropFirst() {
            if direction == 0 {
                if abs(coordinate - extreme) >= threshold {
                    direction = coordinate > extreme ? 1 : -1
                    extreme = coordinate
                }
            } else if (coordinate - extreme) * direction >= 0 {
                extreme = coordinate
            } else if abs(coordinate - extreme) >= threshold {
                reversals += 1
                direction *= -1
                extreme = coordinate
            }
        }
        return reversals >= 2
    }

    private static func points(in stroke: PKStroke) -> [CGPoint] {
        stroke.path.interpolatedPoints(by: .distance(3)).prefix(1600).map {
            $0.location.applying(stroke.transform)
        }
    }

    private static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func intersects(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        func cross(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        guard max(a.x, b.x) >= min(c.x, d.x), max(c.x, d.x) >= min(a.x, b.x),
              max(a.y, b.y) >= min(c.y, d.y), max(c.y, d.y) >= min(a.y, b.y) else { return false }
        return cross(a, b, c) * cross(a, b, d) <= 0 && cross(c, d, a) * cross(c, d, b) <= 0
    }
}
