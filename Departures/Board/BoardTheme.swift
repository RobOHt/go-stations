import SwiftUI

/// Colours sampled from the departure screens in GO stations.
enum BoardTheme {
    static let background = Color.black
    static let headerStrip = Color(hex: 0x1D1B1C)
    static let white = Color(hex: 0xF8F8F8)
    static let frenchGrey = Color(hex: 0xD4D4D0)
    static let dimGrey = Color(hex: 0xC0BCBC)
    static let time = Color(hex: 0xD8D8A0)
    static let platform = Color(hex: 0x82B420)
    static let cancelled = Color(hex: 0xC8322E)
    static let delayed = Color(hex: 0xF0B429)
    static let accessibleBlue = Color(hex: 0x036EC9)
    static let dots = Color(hex: 0x5E5E5E)

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
    static let timeWidth: CGFloat = 58
    static let boltWidth: CGFloat = 16
    static let badgeSize = CGSize(width: 25, height: 21)
    static var detailIndent: CGFloat { timeWidth + boltWidth }
    static let horizontalPadding: CGFloat = 12
}
