import Foundation

/// Holds the AI provider configuration and the deterministic on-device text
/// helpers used when no provider is configured (or a request fails).
///
/// Remote completions go through `AssistantCoordinator` and
/// `WritingSuggestionCoordinator`, which own their own request lifecycles;
/// this type only supplies configuration and the local fallbacks.
/// Provider credentials are user supplied and kept in Keychain, never bundled.
@MainActor
final class AIService: ObservableObject {
    let settingsStore: AISettingsStore
    let client: AIClient

    init(settingsStore: AISettingsStore? = nil, client: AIClient = AIClient()) {
        self.settingsStore = settingsStore ?? AISettingsStore()
        self.client = client
    }

    var configuredBaseURL: String { settingsStore.baseURL }
    var configuredModel: String { settingsStore.model }
    var isRemoteConfigured: Bool { settingsStore.isRemoteConfigured }

    func updateConfiguration(apiKey: String?, baseURL: String, model: String) throws {
        try settingsStore.update(apiKey: apiKey, baseURL: baseURL, model: model)
        objectWillChange.send()
    }

    func clearConfiguration() {
        settingsStore.clear()
        objectWillChange.send()
    }

    // MARK: - On-device assistance

    static func localSummary(_ text: String) -> String {
        let points = rankedLines(in: text, limit: 6)
        guard !points.isEmpty else { return "No readable note text was found." }
        return points.map { "- \($0)" }.joined(separator: "\n")
    }

    static func localQuiz(_ text: String) -> String {
        let points = rankedLines(in: text, limit: 5)
        guard !points.isEmpty else { return "No readable note text was found." }
        return points.enumerated().map { index, point in
            "Q\(index + 1): What is one important point from this section?\nA\(index + 1): \(point)"
        }.joined(separator: "\n\n")
    }

    static func localAnswer(question: String, context: String) -> String {
        let terms = Set(words(in: question).filter { $0.count > 2 && !stopWords.contains($0) })
        let candidates = contentLines(in: context)
        var scored: [(line: String, score: Int)] = []
        for line in candidates {
            let lineTerms = Set(words(in: line))
            let matchScore = lineTerms.intersection(terms).count
            if matchScore > 0 {
                scored.append((line: line, score: matchScore))
            }
        }
        scored.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.line.count < rhs.line.count : lhs.score > rhs.score
        }
        let matches = scored.prefix(3).map { $0.line }
        guard !matches.isEmpty else {
            return "I could not find a direct answer in the text currently indexed for this page."
        }
        return matches.map { "- \($0)" }.joined(separator: "\n")
    }

    static func localActionItems(_ text: String) -> String {
        let markers = ["todo", "must", "need to", "follow up", "deadline", "due", "remember", "action"]
        let matches = contentLines(in: text).filter { line in
            let lower = line.lowercased()
            return markers.contains { lower.contains($0) }
        }
        guard !matches.isEmpty else { return "No explicit action items were found." }
        return matches.prefix(10).map { "- [ ] \($0)" }.joined(separator: "\n")
    }

    static func localCleanup(_ text: String) -> String {
        let sections = text.components(separatedBy: "\n\n")
        return sections.compactMap { section -> String? in
            let lines = section.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { return nil }
            if lines[0].hasPrefix("[") {
                return ([lines[0]] + lines.dropFirst().map(normalizedSentence)).joined(separator: "\n")
            }
            return lines.map(normalizedSentence).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private static func rankedLines(in text: String, limit: Int) -> [String] {
        var seen = Set<String>()
        return contentLines(in: text)
            .filter { line in
                let key = line.lowercased()
                return seen.insert(key).inserted
            }
            .sorted { lhs, rhs in score(lhs) > score(rhs) }
            .prefix(limit)
            .map { $0 }
    }

    private static func contentLines(in text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ".!?")) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-*[ ]"))) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") && $0.count > 12 }
            .map(normalizedSentence)
    }

    private static func normalizedSentence(_ input: String) -> String {
        let collapsed = input.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard let first = collapsed.first else { return collapsed }
        return first.uppercased() + collapsed.dropFirst()
    }

    private static func score(_ line: String) -> Int {
        let usefulMarkers = ["because", "therefore", "important", "result", "means", "must", "key", "due"]
        let markerScore = usefulMarkers.reduce(0) { $0 + (line.lowercased().contains($1) ? 20 : 0) }
        return min(line.count, 180) + markerScore
    }

    private static func words(in text: String) -> [String] {
        text.lowercased().components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "from", "what", "when", "where", "which", "how", "why"
    ]
}
