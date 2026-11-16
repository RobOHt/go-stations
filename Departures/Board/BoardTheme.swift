import SwiftUI

/// Colours sampled from the departure screens in GO stations.
enum BoardTheme {
    static let background = Color.black
    static let headerStrip = Color(hex: 0x1D1B1C)
    static let white = Color(hex: 0xF8F8F8)
    static let frenchGrey = Color(hex: 0xD4D4D0)
    static let time = Color(hex: 0xD8D8A0)
    static let platform = Color(hex: 0x82B420)
    static let cancelled = Color(hex: 0xC8322E)
    static let delayed = Color(hex: 0xF0B429)
    static let accessibleBlue = Color(hex: 0x036EC9)
    static let dots = Color(hex: 0x5E5E5E)
    /// The stops under each train: quieter than where it's going. The station's
    /// landscape screens have room for them beside the train; in portrait they sit
    /// under it, and at full strength they crowd the time, line and platform.
    static let stops = Color(hex: 0xA3A19B)

    /// Line badge colours as they appear on the boards (slightly brighter than print colours).
    static func badge(_ code: String) -> Color {
        switch code {
        case "LW": return Color(hex: 0xAF1A44)
        case "MI": return Color(hex: 0xF27A22)
        case "KI", "GT": return Color(hex: 0x027832)
        case "BR": return Color(hex: 0x0056B0)
        case "RH": return Color(hex: 0x0098C9)
        case "ST": return Color(hex: 0x8A5C2A)
        case "LE": return Color(hex: 0xD42C1E)
        default: return Color(hex: 0x555555)
        }
    }

    // Layout (portrait).
    static let timeWidth: CGFloat = 68
    static let boltWidth: CGFloat = 16
    static let badgeSize = CGSize(width: 25, height: 21)
    /// Between a row's line badge and where the train's going.
    static let badgeGap: CGFloat = 7
    static var detailIndent: CGFloat { timeWidth + boltWidth }
    /// Where the line's name starts in a row, past the time, the express bolt and the
    /// line badge: the "Line" heading starts there too.
    static var lineIndent: CGFloat { detailIndent + badgeSize.width + badgeGap }
    static let horizontalPadding: CGFloat = 12
}
