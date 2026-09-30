import SwiftUI

enum TextAlign: String, CaseIterable, Codable {
    case leading, center, trailing

    var swiftUITextAlignment: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var nsTextAlignment: NSTextAlignment {
        switch self {
        case .leading: return .left
        case .center: return .center
        case .trailing: return .right
        }
    }

    init(nsTextAlignment: NSTextAlignment) {
        switch nsTextAlignment {
        case .center: self = .center
        case .right: self = .trailing
        default: self = .leading
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: return .topLeading
        case .center: return .center
        case .trailing: return .topTrailing
        }
    }

    var label: String {
        switch self {
        case .leading: return AppLocalization.text("Left")
        case .center: return AppLocalization.text("Center")
        case .trailing: return AppLocalization.text("Right")
        }
    }

    var icon: String {
        switch self {
        case .leading: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .trailing: return "text.alignright"
        }
    }
}
