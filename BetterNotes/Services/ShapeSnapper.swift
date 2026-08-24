import Foundation
import PencilKit
import CoreGraphics
import UIKit

struct GeneratedShapeStyle {
    let inkType: PKInkingTool.InkType
    let color: UIColor
    let opacity: CGFloat
    let width: CGFloat

    var ink: PKInk { PKInk(inkType, color: color) }
}

/// Recognizes a held freehand stroke and builds a clean PencilKit replacement.
enum ShapeSnapper {
    static func detect(from stroke: PKStroke) -> DetectedShape? {
        let rawPoints = stroke.path.map(\.location)
        let points = deduplicated(rawPoints, minimumDistance: 0.75)
        guard points.count >= 2,
              let start = points.first,
              let end = points.last else { return nil }

        let bounds = boundingBox(of: points)
        let diagonal = hypot(bounds.width, bounds.height)
        let length = pathLength(points)
        guard diagonal >= 14, length >= 18 else { return nil }

        let closureDistance = distance(start, end)
        let isClosed = closureDistance <= max(10, diagonal * 0.18)

        if !isClosed {
            if let arrow = detectArrow(in: points, diagonal: diagonal) {
                return arrow
            }

            let directness = distance(start, end) / max(length, 0.001)
            let maximumDeviation = points.map { distanceFromLine($0, start: start, end: end) }.max() ?? 0
            if directness >= 0.91, maximumDeviation <= max(4, diagonal * 0.055) {
                return .line(from: start, to: end)
            }
            return nil
        }

        guard points.count >= 6 else { return nil }

        let tolerance = max(2.25, diagonal * 0.025)
        let vertices = closedPolygonVertices(from: points, tolerance: tolerance)

        if let star = detectStar(vertices: vertices, bounds: bounds) {
            return star
        }

        if isRectangle(vertices) {
            return .rectangle(vertices)
        }

        if (3...8).contains(vertices.count),
           polygonFitError(points: points, vertices: vertices) <= diagonal * 0.055 {
            return .polygon(vertices)
        }

        if vertices.count >= 7, ellipseFitError(points: points, bounds: bounds) <= 0.13 {
            return .ellipse(bounds)
        }

        return nil
    }

    // MARK: - Result

    enum DetectedShape {
        case ellipse(CGRect)
        case rectangle([CGPoint])
        case polygon([CGPoint])
        case star(center: CGPoint, outerRadius: CGFloat, innerRadius: CGFloat, rotation: CGFloat, points: Int)
        case arrow(from: CGPoint, to: CGPoint, headLength: CGFloat, headAngle: CGFloat)
        case line(from: CGPoint, to: CGPoint)

        func renderedStroke(style: GeneratedShapeStyle) -> PKStroke {
            switch self {
            case .ellipse(let rect):
                return ShapeSnapper.makeEllipse(in: rect, style: style)
            case .rectangle(let vertices), .polygon(let vertices):
                return ShapeSnapper.makePolygon(vertices, closed: true, style: style)
            case .star(let center, let outerRadius, let innerRadius, let rotation, let points):
                return ShapeSnapper.makeStar(
                    center: center,
                    outerRadius: outerRadius,
                    innerRadius: innerRadius,
                    rotation: rotation,
                    points: points,
                    style: style
                )
            case .arrow(let start, let end, let headLength, let headAngle):
                return ShapeSnapper.makeArrow(
                    from: start,
                    to: end,
                    headLength: headLength,
                    headAngle: headAngle,
                    style: style
                )
            case .line(let start, let end):
                return ShapeSnapper.makeLine(from: start, to: end, style: style)
            }
        }
    }

    // MARK: - Recognition

    private static func detectArrow(in points: [CGPoint], diagonal: CGFloat) -> DetectedShape? {
        let simplified = simplifyOpen(points, tolerance: max(2, diagonal * 0.018))
        guard simplified.count >= 4, let start = simplified.first else { return nil }

        var best: (score: CGFloat, shape: DetectedShape)?
        for tipIndex in 1..<(simplified.count - 1) {
            let tip = simplified[tipIndex]
            let shaftLength = distance(start, tip)
            guard shaftLength >= diagonal * 0.48 else { continue }

            let prefix = Array(simplified[0...tipIndex])
            let shaftDirectness = shaftLength / max(pathLength(prefix), 0.001)
            guard shaftDirectness >= 0.84 else { continue }

            let backward = normalized(CGVector(dx: start.x - tip.x, dy: start.y - tip.y))
            guard backward != .zero else { continue }

            var leftCandidates: [(length: CGFloat, angle: CGFloat)] = []
            var rightCandidates: [(length: CGFloat, angle: CGFloat)] = []
            var headIsLocal = true

            for point in simplified[(tipIndex + 1)...] {
                let headLength = distance(tip, point)
                if headLength > shaftLength * 0.62 {
                    headIsLocal = false
                }
                guard headLength >= shaftLength * 0.10,
                      headLength <= shaftLength * 0.55 else { continue }

                let vector = normalized(CGVector(dx: point.x - tip.x, dy: point.y - tip.y))
                let cosine = clampedDot(backward, vector)
                let angle = acos(cosine)
                guard angle >= .pi * 0.08, angle <= .pi * 0.46 else { continue }

                let side = cross(backward, vector)
                if side > 0.12 {
                    leftCandidates.append((headLength, angle))
                } else if side < -0.12 {
                    rightCandidates.append((headLength, angle))
                }
            }

            guard headIsLocal,
                  let left = leftCandidates.max(by: { $0.length < $1.length }),
                  let right = rightCandidates.max(by: { $0.length < $1.length }) else { continue }

            let headLength = (left.length + right.length) / 2
            let headAngle = (left.angle + right.angle) / 2
            let symmetryPenalty = abs(left.length - right.length) / max(headLength, 0.001)
            let score = shaftDirectness - symmetryPenalty * 0.2
            let shape = DetectedShape.arrow(
                from: start,
                to: tip,
                headLength: headLength,
                headAngle: headAngle
            )
            if best == nil || score > best!.score {
                best = (score, shape)
            }
        }
        return best?.shape
    }

    private static func detectStar(vertices: [CGPoint], bounds: CGRect) -> DetectedShape? {
        guard vertices.count >= 8,
              vertices.count <= 14,
              vertices.count.isMultiple(of: 2) else { return nil }

        let center = vertices.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }.scaled(by: 1 / CGFloat(vertices.count))
        let radii = vertices.map { distance($0, center) }

        for outerParity in 0...1 {
            let outer = radii.enumerated().compactMap { index, radius in
                index.isMultiple(of: 2) == outerParity.isMultiple(of: 2) ? radius : nil
            }
            let inner = radii.enumerated().compactMap { index, radius in
                index.isMultiple(of: 2) != outerParity.isMultiple(of: 2) ? radius : nil
            }
            guard !outer.isEmpty, !inner.isEmpty else { continue }

            let outerRadius = outer.reduce(0, +) / CGFloat(outer.count)
            let innerRadius = inner.reduce(0, +) / CGFloat(inner.count)
            guard outerRadius >= innerRadius * 1.32,
                  coefficientOfVariation(outer) <= 0.28,
                  coefficientOfVariation(inner) <= 0.34,
                  outerRadius >= hypot(bounds.width, bounds.height) * 0.28 else { continue }

            let firstOuterIndex = outerParity
            let firstOuter = vertices[firstOuterIndex]
            let rotation = atan2(firstOuter.y - center.y, firstOuter.x - center.x)
            return .star(
                center: center,
                outerRadius: outerRadius,
                innerRadius: innerRadius,
                rotation: rotation,
                points: vertices.count / 2
            )
        }
        return nil
    }

    private static func isRectangle(_ vertices: [CGPoint]) -> Bool {
        guard vertices.count == 4 else { return false }

        let edges = vertices.indices.map { index -> CGVector in
            let next = vertices[(index + 1) % vertices.count]
            return CGVector(dx: next.x - vertices[index].x, dy: next.y - vertices[index].y)
        }
        let lengths = edges.map { hypot($0.dx, $0.dy) }
        guard let longest = lengths.max(),
              let shortest = lengths.min(),
              shortest >= max(7, longest * 0.12) else { return false }

        for index in edges.indices {
            let lhs = normalized(edges[index])
            let rhs = normalized(edges[(index + 1) % edges.count])
            guard abs(clampedDot(lhs, rhs)) <= 0.48 else { return false }
        }

        let firstParallel = abs(clampedDot(normalized(edges[0]), normalized(edges[2])))
        let secondParallel = abs(clampedDot(normalized(edges[1]), normalized(edges[3])))
        return firstParallel >= 0.86 && secondParallel >= 0.86
    }

    private static func ellipseFitError(points: [CGPoint], bounds: CGRect) -> CGFloat {
        let radiusX = bounds.width / 2
        let radiusY = bounds.height / 2
        guard radiusX > 4, radiusY > 4 else { return .greatestFiniteMagnitude }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let errors = points.map { point -> CGFloat in
            let x = (point.x - center.x) / radiusX
            let y = (point.y - center.y) / radiusY
            return abs(sqrt(x * x + y * y) - 1)
        }
        return errors.reduce(0, +) / CGFloat(errors.count)
    }

    private static func polygonFitError(points: [CGPoint], vertices: [CGPoint]) -> CGFloat {
        guard vertices.count >= 3 else { return .greatestFiniteMagnitude }
        let total = points.reduce(CGFloat.zero) { partial, point in
            let nearest = vertices.indices.map { index -> CGFloat in
                let next = vertices[(index + 1) % vertices.count]
                return distanceFromSegment(point, start: vertices[index], end: next)
            }.min() ?? .greatestFiniteMagnitude
            return partial + nearest
        }
        return total / CGFloat(points.count)
    }

    // MARK: - Stroke builders

    static func makeCircle(center: CGPoint, radius: CGFloat, style: GeneratedShapeStyle) -> PKStroke {
        let rect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        return makeStroke(coordinates: ellipseCoordinates(in: rect), style: style)
    }

    static func makeRect(_ rect: CGRect, style: GeneratedShapeStyle) -> PKStroke {
        let vertices = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]
        return makeStroke(coordinates: polylineCoordinates(vertices, closed: true), style: style)
    }

    static func makeLine(from start: CGPoint, to end: CGPoint, style: GeneratedShapeStyle) -> PKStroke {
        makeStroke(coordinates: polylineCoordinates([start, end], closed: false), style: style)
    }

    static func makeShape(_ shape: ShapeKind, in rect: CGRect, style: GeneratedShapeStyle) -> [PKStroke] {
        switch shape {
        case .circle:
            return [makeCircle(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2, style: style)]
        case .rectangle:
            return [makeRect(rect, style: style)]
        case .line:
            return [makeLine(from: CGPoint(x: rect.minX, y: rect.midY), to: CGPoint(x: rect.maxX, y: rect.midY), style: style)]
        case .arrow:
            let start = CGPoint(x: rect.minX, y: rect.maxY)
            let end = CGPoint(x: rect.maxX, y: rect.minY)
            return [makeArrow(from: start, to: end, headLength: min(24, min(rect.width, rect.height) * 0.3), headAngle: .pi / 4, style: style)]
        case .star:
            return [makeStar(
                center: CGPoint(x: rect.midX, y: rect.midY),
                outerRadius: min(rect.width, rect.height) / 2,
                innerRadius: min(rect.width, rect.height) * 0.2,
                rotation: -.pi / 2,
                points: 5,
                style: style
            )]
        }
    }

    private static func makeEllipse(in rect: CGRect, style: GeneratedShapeStyle) -> PKStroke {
        makeStroke(coordinates: ellipseCoordinates(in: rect), style: style)
    }

    private static func makePolygon(_ vertices: [CGPoint], closed: Bool, style: GeneratedShapeStyle) -> PKStroke {
        makeStroke(coordinates: polylineCoordinates(vertices, closed: closed), style: style)
    }

    private static func makeStar(
        center: CGPoint,
        outerRadius: CGFloat,
        innerRadius: CGFloat,
        rotation: CGFloat,
        points: Int,
        style: GeneratedShapeStyle
    ) -> PKStroke {
        let vertices = (0..<(points * 2)).map { index -> CGPoint in
            let radius = index.isMultiple(of: 2) ? outerRadius : innerRadius
            let angle = rotation + CGFloat(index) * .pi / CGFloat(points)
            return CGPoint(
                x: center.x + radius * cos(angle),
                y: center.y + radius * sin(angle)
            )
        }
        return makeStroke(coordinates: polylineCoordinates(vertices, closed: true), style: style)
    }

    private static func makeArrow(
        from start: CGPoint,
        to end: CGPoint,
        headLength: CGFloat,
        headAngle: CGFloat,
        style: GeneratedShapeStyle
    ) -> PKStroke {
        let shaftAngle = atan2(end.y - start.y, end.x - start.x)
        let backwardAngle = shaftAngle + .pi
        let left = CGPoint(
            x: end.x + headLength * cos(backwardAngle - headAngle),
            y: end.y + headLength * sin(backwardAngle - headAngle)
        )
        let right = CGPoint(
            x: end.x + headLength * cos(backwardAngle + headAngle),
            y: end.y + headLength * sin(backwardAngle + headAngle)
        )
        let coordinates = polylineCoordinates([start, end, left, end, right], closed: false)
        return makeStroke(coordinates: coordinates, style: style)
    }

    private static func makeStroke(coordinates: [CGPoint], style: GeneratedShapeStyle) -> PKStroke {
        let path = PKStrokePath(controlPoints: makePoints(coordinates, style: style), creationDate: .now)
        return PKStroke(ink: style.ink, path: path)
    }

    private static func makePoints(_ coordinates: [CGPoint], style: GeneratedShapeStyle) -> [PKStrokePoint] {
        coordinates.enumerated().map { index, point in
            PKStrokePoint(
                location: point,
                timeOffset: TimeInterval(index) * 0.004,
                size: CGSize(width: style.width, height: style.width),
                opacity: style.opacity,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
    }

    private static func ellipseCoordinates(in rect: CGRect) -> [CGPoint] {
        let circumference = .pi * (3 * (rect.width + rect.height) - sqrt((3 * rect.width + rect.height) * (rect.width + 3 * rect.height)))
        let count = min(max(Int(circumference / 4), 36), 180)
        return (0...count).map { index in
            let angle = CGFloat(index) / CGFloat(count) * 2 * .pi
            return CGPoint(
                x: rect.midX + rect.width / 2 * cos(angle),
                y: rect.midY + rect.height / 2 * sin(angle)
            )
        }
    }

    private static func polylineCoordinates(_ vertices: [CGPoint], closed: Bool) -> [CGPoint] {
        guard vertices.count >= 2 else { return vertices }
        var result: [CGPoint] = []
        let segmentCount = closed ? vertices.count : vertices.count - 1
        for index in 0..<segmentCount {
            let start = vertices[index]
            let end = vertices[(index + 1) % vertices.count]
            let steps = min(max(Int(distance(start, end) / 4), 2), 80)
            for step in 0..<steps {
                let progress = CGFloat(step) / CGFloat(steps)
                result.append(interpolate(start, end, progress: progress))
            }
        }
        result.append(closed ? vertices[0] : vertices[vertices.count - 1])
        return result
    }

    // MARK: - Geometry

    private static func closedPolygonVertices(from points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        var openPoints = points
        if let first = openPoints.first,
           let last = openPoints.last,
           distance(first, last) <= tolerance * 2 {
            openPoints.removeLast()
        }
        guard openPoints.count >= 3, let first = openPoints.first else { return [] }

        let splitIndex = openPoints.indices.max(by: {
            distance(first, openPoints[$0]) < distance(first, openPoints[$1])
        }) ?? openPoints.index(before: openPoints.endIndex)
        guard splitIndex > 0, splitIndex < openPoints.count else { return [] }

        let firstHalf = Array(openPoints[0...splitIndex])
        var secondHalf = Array(openPoints[splitIndex...])
        secondHalf.append(first)

        let simplifiedFirst = simplifyOpen(firstHalf, tolerance: tolerance)
        let simplifiedSecond = simplifyOpen(secondHalf, tolerance: tolerance)
        var vertices = simplifiedFirst
        if simplifiedSecond.count > 2 {
            vertices.append(contentsOf: simplifiedSecond.dropFirst().dropLast())
        }
        return prunedClosedVertices(vertices, tolerance: tolerance)
    }

    private static func prunedClosedVertices(_ input: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        var vertices = input
        var didRemove = true
        while didRemove, vertices.count > 3 {
            didRemove = false
            for index in vertices.indices {
                let previous = vertices[(index - 1 + vertices.count) % vertices.count]
                let current = vertices[index]
                let next = vertices[(index + 1) % vertices.count]
                let shortEdge = min(distance(previous, current), distance(current, next)) < tolerance * 1.2
                let lineDeviation = distanceFromSegment(current, start: previous, end: next)
                if shortEdge || lineDeviation < tolerance * 0.72 {
                    vertices.remove(at: index)
                    didRemove = true
                    break
                }
            }
        }
        return vertices
    }

    private static func simplifyOpen(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2, let first = points.first, let last = points.last else { return points }

        var maximumDistance: CGFloat = 0
        var maximumIndex = 0
        for index in 1..<(points.count - 1) {
            let deviation = distanceFromSegment(points[index], start: first, end: last)
            if deviation > maximumDistance {
                maximumDistance = deviation
                maximumIndex = index
            }
        }

        guard maximumDistance > tolerance else { return [first, last] }
        let left = simplifyOpen(Array(points[0...maximumIndex]), tolerance: tolerance)
        let right = simplifyOpen(Array(points[maximumIndex...]), tolerance: tolerance)
        return Array(left.dropLast()) + right
    }

    private static func deduplicated(_ points: [CGPoint], minimumDistance: CGFloat) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var result = [first]
        for point in points.dropFirst() where distance(result[result.count - 1], point) >= minimumDistance {
            result.append(point)
        }
        if let last = points.last, result.last != last {
            result.append(last)
        }
        return result
    }

    private static func coefficientOfVariation(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return .greatestFiniteMagnitude }
        let mean = values.reduce(0, +) / CGFloat(values.count)
        guard mean > 0.001 else { return .greatestFiniteMagnitude }
        let variance = values.reduce(CGFloat.zero) { $0 + pow($1 - mean, 2) } / CGFloat(values.count)
        return sqrt(variance) / mean
    }

    private static func boundingBox(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func pathLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return 0 }
        return zip(points, points.dropFirst()).reduce(CGFloat.zero) { partial, pair in
            partial + distance(pair.0, pair.1)
        }
    }

    private static func distanceFromLine(_ point: CGPoint, start: CGPoint, end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let denominator = hypot(dx, dy)
        guard denominator > 0.001 else { return distance(point, start) }
        return abs(dy * point.x - dx * point.y + end.x * start.y - end.y * start.x) / denominator
    }

    private static func distanceFromSegment(_ point: CGPoint, start: CGPoint, end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let denominator = dx * dx + dy * dy
        guard denominator > 0.001 else { return distance(point, start) }
        let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy) / denominator
        let progress = min(max(projection, 0), 1)
        return distance(point, CGPoint(x: start.x + dx * progress, y: start.y + dy * progress))
    }

    private static func normalized(_ vector: CGVector) -> CGVector {
        let length = hypot(vector.dx, vector.dy)
        guard length > 0.001 else { return .zero }
        return CGVector(dx: vector.dx / length, dy: vector.dy / length)
    }

    private static func clampedDot(_ lhs: CGVector, _ rhs: CGVector) -> CGFloat {
        min(max(lhs.dx * rhs.dx + lhs.dy * rhs.dy, -1), 1)
    }

    private static func cross(_ lhs: CGVector, _ rhs: CGVector) -> CGFloat {
        lhs.dx * rhs.dy - lhs.dy * rhs.dx
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(rhs.x - lhs.x, rhs.y - lhs.y)
    }

    private static func interpolate(_ start: CGPoint, _ end: CGPoint, progress: CGFloat) -> CGPoint {
        CGPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
    }
}

private extension CGPoint {
    func scaled(by factor: CGFloat) -> CGPoint {
        CGPoint(x: x * factor, y: y * factor)
    }
}
