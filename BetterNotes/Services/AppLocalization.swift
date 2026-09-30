import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        }
    }
}

/// Localizes labels assembled as String values before they reach a SwiftUI view.
/// Static Text and Label literals use SwiftUI's locale environment directly.
enum AppLocalization {
    private static var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "app.language") ?? "") ?? .english
    }

    static func text(_ key: String) -> String {
        let selected = selectedLanguage
        guard selected != .english,
              let path = Bundle.main.path(forResource: selected.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale(identifier: selectedLanguage.rawValue), arguments: arguments)
    }

    /// Sync activity is persisted as English text by older builds. Translate
    /// the known status forms when displayed so changing languages also updates
    /// the last completed activity without changing any stored notebook data.
    static func nearbyStatus(_ status: String) -> String {
        guard selectedLanguage != .english else { return status }
        if let parts = captures(#"^Synced with (.+?) at (.+?) · (\d+) new, (\d+) updated, (\d+) conflict copies$"#, in: status),
           let added = Int64(parts[2]), let updated = Int64(parts[3]), let conflicts = Int64(parts[4]) {
            return format("Synced with %@ at %@ · %lld new, %lld updated, %lld conflict copies",
                          parts[0], parts[1], added, updated, conflicts)
        }
        if let parts = captures(#"^Synced with (.+?) at (.+)$"#, in: status) {
            return format("Synced with %@ at %@", parts[0], parts[1])
        }
        if let parts = captures(#"^Received (\d+) new, (\d+) updated, (\d+) conflict copies from (.+)\.$"#, in: status),
           let added = Int64(parts[0]), let updated = Int64(parts[1]), let conflicts = Int64(parts[2]) {
            return format("Received %lld new, %lld updated, %lld conflict copies from %@.",
                          added, updated, conflicts, parts[3])
        }
        if let parts = captures(#"^Sending (\d+) notebooks to (.+)…$"#, in: status),
           let count = Int64(parts[0]) {
            return format("Sending %lld notebooks to %@…", count, parts[1])
        }
        for (prefix, key) in [
            ("Connecting to ", "Connecting to %@…"),
            ("Receiving notes from ", "Receiving notes from %@…")
        ] where status.hasPrefix(prefix) && status.hasSuffix("…") {
            return format(key, String(status.dropFirst(prefix.count).dropLast()))
        }
        if let parts = captures(#"^Connected to (.+)\.$"#, in: status) {
            return format("Connected to %@.", parts[0])
        }
        if let parts = captures(#"^Connection to (.+) ended before sync finished\.$"#, in: status) {
            return format("Connection to %@ ended before sync finished.", parts[0])
        }
        for prefix in ["Could not send sync request: ", "Transfer failed: ",
                       "Could not prepare the notes library: ", "Could not import the nearby library: ",
                       "Nearby search failed: ", "Nearby sharing failed: "] where status.hasPrefix(prefix) {
            return format(prefix + "%@", String(status.dropFirst(prefix.count)))
        }
        return text(status)
    }

    private static func captures(_ pattern: String, in value: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else {
            return nil
        }
        let string = value as NSString
        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : string.substring(with: range)
        }
    }
}
