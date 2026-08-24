import CoreGraphics
import Foundation
import PencilKit

enum HandwritingBeautifier {
    private static let profileKey = "handwritingBeautifier.profile"

    struct Profile: Codable {
        var sampleCount: Int = 0
        var averagePointSpacing: Double = 4
        var averageTremor: Double = 0.12
        var averageStrokeLength: Double = 32

        var confidence: CGFloat {
            min(CGFloat(sampleCount) / 450, 1)
        }

        var smoothingStrength: CGFloat {
            let tremor = min(max(CGFloat(averageTremor), 0), 1)
            let strength = 0.28 + confidence * 0.10 + tremor * 0.20
            return min(max(strength, 0.28), 0.52)
        }

        mutating func learn(from metrics: StrokeMetrics) {
            let weight = sampleCount == 0 ? 1 : min(0.08, 1 / sqrt(Double(sampleCount + 1)))
            averagePointSpacing = blended(averagePointSpacing, metrics.pointSpacing, weight: weight)
            averageTremor = blended(averageTremor, metrics.tremor, weight: weight)
            averageStrokeLength = blended(averageStrokeLength, metrics.length, weight: weight)
            sampleCount += 1
        }

        private func blended(_ old: Double, _ new: Double, weight: Double) -> Double {
            old * (1 - weight) + new * weight
        }
    }

    struct StrokeMetrics {
        let pointSpacing: Double
        let tremor: Double
        let length: Double
    }

    static var profile: Profile {
        loadProfile()
    }

    static func resetProfile() {
        UserDefaults.standard.removeObject(forKey: profileKey)
    }

    static func learn(from strokes: [PKStroke]) {
        var profile = loadProfile()
        var learned = false
        for stroke in strokes {
            guard let metrics = metrics(for: stroke) else { continue }
            profile.learn(from: metrics)
            learned = true
        }
        if learned {
            save(profile)
        }
    }

    static func beautified(strokes: [PKStroke]) -> [PKStroke] {
        let profile = loadProfile()
        return strokes.map { beautified(stroke: $0, profile: profile) }
    }

    static func beautified(drawing: PKDrawing) -> PKDrawing {
        PKDrawing(strokes: beautified(strokes: drawing.strokes))
    }

    private static func beautified(stroke: PKStroke, profile: Profile) -> PKStroke {
        let points = Array(stroke.path)
        guard points.count >= 4 else { return stroke }

        let locations = points.map(\.location)
        let length = pathLength(locations)
        guard length >= 8 else { return stroke }

        let smoothed = smoothedLocations(locations, strength: profile.smoothingStrength)
        let controlPoints = zip(points, smoothed).map { point, location in
            PKStrokePoint(
                location: location,
                timeOffset: point.timeOffset,
                size: point.size,
                opacity: point.opacity,
                force: point.force,
                azimuth: point.azimuth,
                altitude: point.altitude
            )
        }
        let path = PKStrokePath(controlPoints: controlPoints, creationDate: stroke.path.creationDate)
        if #available(iOS 16.0, *) {
            return PKStroke(
                ink: stroke.ink,
                path: path,
                transform: stroke.transform,
                mask: stroke.mask,
                randomSeed: stroke.randomSeed
            )
        } else {
            return PKStroke(ink: stroke.ink, path: path, transform: stroke.transform, mask: stroke.mask)
        }
    }

    private static func smoothedLocations(_ locations: [CGPoint], strength: CGFloat) -> [CGPoint] {
        guard locations.count >= 4 else { return locations }

        var current = locations
        let passes = strength > 0.40 ? 3 : 2
        for _ in 0..<passes {
            var next = current
            for index in 1..<(current.count - 1) {
                let previous = current[index - 1]
                let point = current[index]
                let following = current[index + 1]
                let weightedAverage = CGPoint(
                    x: (previous.x + point.x * 2 + following.x) / 4,
                    y: (previous.y + point.y * 2 + following.y) / 4
                )
                let cornerFactor = cornerPreservationFactor(previous: previous, point: point, following: following)
                next[index] = interpolated(from: point, to: weightedAverage, amount: strength * cornerFactor)
            }
            current = next
        }
        return current
    }

    private static func cornerPreservationFactor(previous: CGPoint, point: CGPoint, following: CGPoint) -> CGFloat {
        let first = CGVector(dx: point.x - previous.x, dy: point.y - previous.y)
        let second = CGVector(dx: following.x - point.x, dy: following.y - point.y)
        let firstLength = hypot(first.dx, first.dy)
        let secondLength = hypot(second.dx, second.dy)
        guard firstLength > 0.001, secondLength > 0.001 else { return 1 }

        let cosine = min(max((first.dx * second.dx + first.dy * second.dy) / (firstLength * secondLength), -1), 1)
        let angle = acos(cosine)
        if angle > .pi * 0.56 { return 0.18 }
        if angle > .pi * 0.36 { return 0.45 }
        if angle > .pi * 0.22 { return 0.72 }
        return 1
    }

    private static func interpolated(from start: CGPoint, to end: CGPoint, amount: CGFloat) -> CGPoint {
        CGPoint(
            x: start.x + (end.x - start.x) * amount,
            y: start.y + (end.y - start.y) * amount
        )
    }

    private static func metrics(for stroke: PKStroke) -> StrokeMetrics? {
        let locations = stroke.path.map(\.location)
        guard locations.count >= 4 else { return nil }

        let length = pathLength(locations)
        guard length >= 8 else { return nil }

        let spacing = length / CGFloat(locations.count - 1)
        let tremor = localTremor(in: locations, spacing: max(spacing, 1))
        return StrokeMetrics(
            pointSpacing: Double(spacing),
            tremor: Double(tremor),
            length: Double(length)
        )
    }

    private static func localTremor(in locations: [CGPoint], spacing: CGFloat) -> CGFloat {
        guard locations.count >= 3 else { return 0 }

        var total: CGFloat = 0
        var count: CGFloat = 0
        for index in 1..<(locations.count - 1) {
            let projected = projection(of: locations[index], ontoLineFrom: locations[index - 1], to: locations[index + 1])
            total += distance(locations[index], projected)
            count += 1
        }
        guard count > 0 else { return 0 }
        return min((total / count) / spacing, 1)
    }

    private static func projection(of point: CGPoint, ontoLineFrom start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let denominator = dx * dx + dy * dy
        guard denominator > 0.001 else { return start }

        let t = ((point.x - start.x) * dx + (point.y - start.y) * dy) / denominator
        let clamped = min(max(t, 0), 1)
        return CGPoint(x: start.x + dx * clamped, y: start.y + dy * clamped)
    }

    private static func pathLength(_ locations: [CGPoint]) -> CGFloat {
        guard locations.count > 1 else { return 0 }
        var total: CGFloat = 0
        for index in 1..<locations.count {
            total += distance(locations[index - 1], locations[index])
        }
        return total
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(rhs.x - lhs.x, rhs.y - lhs.y)
    }

    private static func loadProfile() -> Profile {
        guard let data = UserDefaults.standard.data(forKey: profileKey),
              let profile = try? JSONDecoder().decode(Profile.self, from: data) else {
            return Profile()
        }
        return profile
    }

    private static func save(_ profile: Profile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: profileKey)
    }
}
