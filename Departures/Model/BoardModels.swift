import Foundation

/// One line on the departure board.
struct BoardRow: Identifiable, Equatable, Sendable {
    let tripNumber: String
    let lineCode: String
    let lineName: String
    /// "To" column: the line name at Union (as on the real board), the destination elsewhere.
    let destination: String
    let stops: [String]
    let scheduled: Date
    let expected: Date
    let platform: String?
    let isExpress: Bool
    var isCancelled: Bool
    var reasonEnglish: String?
    var reasonFrench: String?

    var id: String { "\(tripNumber)-\(Int(scheduled.timeIntervalSince1970))" }

    var delayMinutes: Int {
        max(0, Int((expected.timeIntervalSince(scheduled) / 60).rounded()))
    }

    var isDelayed: Bool { !isCancelled && delayMinutes >= 2 }
}

struct StationAlert: Identifiable, Equatable, Sendable {
    let id: String
    let subjectEnglish: String
    let subjectFrench: String
    let body: String
}

struct BoardSnapshot: Equatable, Sendable {
    var rows: [BoardRow]
    var alerts: [StationAlert]
    var fetchedAt: Date
}

/// Metrolinx timestamps are naive Toronto wall-clock strings ("2026-07-17 16:46:52").
enum TorontoTime {
    static let zone = TimeZone(identifier: "America/Toronto") ?? .current

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = format
        return formatter
    }

    private static let full = formatter("yyyy-MM-dd HH:mm:ss")
    private static let fullT = formatter("yyyy-MM-dd'T'HH:mm:ss")
    private static let wire = formatter("yyyyMMdd")
    private static let hm = formatter("HH:mm")
    private static let hms = formatter("HH:mm:ss")

    static func parse(_ string: String?) -> Date? {
        guard let string = string?.trimmingCharacters(in: .whitespaces), !string.isEmpty else { return nil }
        return full.date(from: string) ?? fullT.date(from: string)
    }

    static func dateWire(_ date: Date) -> String { wire.string(from: date) }
    static func hourMinute(_ date: Date) -> String { hm.string(from: date) }
    static func clock(_ date: Date) -> String { hms.string(from: date) }

    static func hour(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.component(.hour, from: date)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var nonEmpty: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
    }

    /// "Aldershot GO" -> "Aldershot", "Union Station GO" -> "Union Station".
    var withoutGOSuffix: String {
        let value = trimmed
        if value.hasSuffix(" GO") { return String(value.dropLast(3)) }
        return value
    }

    /// Crude HTML-to-text for alert bodies.
    var plainText: String {
        var text = replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&quot;": "\"", "&#39;": "'", "&rsquo;": "’",
                        "&lt;": "<", "&gt;": ">", "&ndash;": "–", "&mdash;": "—"]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        text = text.replacingOccurrences(of: "\n\\s*\n+", with: "\n\n", options: .regularExpression)
        return text.trimmed
    }
}

/// "9 & 10" -> "9, 10"; "-" or "" -> nil.
func formatPlatform(_ raw: String?) -> String? {
    guard let value = raw?.trimmed, !value.isEmpty, value != "-", value != "--" else { return nil }
    return value
        .replacingOccurrences(of: " & ", with: ", ")
        .replacingOccurrences(of: "&", with: ", ")
}
