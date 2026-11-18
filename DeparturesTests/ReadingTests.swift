import Foundation
import Testing
@testable import Departures

/// How the app reads the bits of GO's data it shows as they come: platforms, times,
/// alert text; and how late it takes a train to be.
@Suite("Reading GO's values")
struct Reading {
    @Test("platforms however GO writes them", arguments: [
        ("7 & 8", "7, 8"), ("7&8", "7, 8"), ("7 & 8 & 9", "7, 8, 9"), (" 3 ", "3"), ("12", "12"),
        ("-", nil), ("--", nil), ("", nil), ("   ", nil),
    ] as [(String, String?)])
    func platform(_ raw: String, _ shown: String?) {
        #expect(formatPlatform(raw) == shown)
    }

    @Test("no platform at all")
    func noPlatform() {
        #expect(formatPlatform(nil) == nil)
    }

    @Test("GO's times, with a T or spaces round them; nothing, or junk, is no time")
    func times() throws {
        let time = try #require(TorontoTime.parse("2026-11-13 07:40:00"))
        #expect(Toronto.wall(time) == "2026-11-13 07:40:00")
        #expect(TorontoTime.parse("2026-11-13T07:40:00") == time)
        #expect(TorontoTime.parse("  2026-11-13 07:40:00 ") == time)
        for junk in [nil, "", " ", "soon", "07:40", "2026-13-45 99:99:99"] as [String?] {
            #expect(TorontoTime.parse(junk) == nil, "\(junk ?? "nil")")
        }
    }

    @Test("an alert's HTML as plain text: tags out, entities read, named or numbered")
    func alertText() {
        let text = "<p>Delays of <b>up to 15&nbsp;min</b> at Union&#8217;s platforms &amp; Oakville&#39;s.</p><br/>Sorry&#x2014;we&rsquo;re on it."
            .plainText
        #expect(!text.contains("<") && !text.contains("&#") && !text.contains("&nbsp;"), "\(text)")
        #expect(text.hasPrefix("Delays of up to 15 min at Union’s platforms & Oakville's."), "\(text)")
        #expect(text.hasSuffix("Sorry—we’re on it."), "\(text)")
    }

    @Test("a delay of a day or more isn't put on a train's stops; a couple of hours is")
    func absurdDelay() {
        let start = Toronto.today(12, 0)
        let stops = (0..<4).map { index in
            TripDetail.Stop(index: index, code: Timetable.east[index], time: start.addingTimeInterval(Double(index) * 600),
                            expected: nil, platform: nil)
        }
        let day = TripDetail.fillingDelay(stops, late: 26 * 3600, from: 1)
        #expect(day.allSatisfy { $0.expected == nil || $0.expected!.timeIntervalSince($0.time!) < 12 * 3600 },
                "\(day.map { $0.expected.map(Toronto.wall) ?? "-" })")
        let hours = TripDetail.fillingDelay(stops, late: 2 * 3600, from: 1)
        #expect(hours[1].expected == stops[1].time!.addingTimeInterval(2 * 3600))
        #expect(hours[0].expected == nil)
    }
}

/// The in-app self-checks (also run by the Screenshots workflow): the tracking
/// logic with made-up trips.
@Suite("Self-checks")
@MainActor
struct SelfChecks {
    @Test("every self-check passes")
    func all() {
        SelfCheck.run()
        let failed = SelfCheck.lines.filter { $0.hasPrefix("FAIL") }
        #expect(SelfCheck.lines.last == "done")
        #expect(failed.isEmpty, "\(failed.joined(separator: "\n"))")
    }
}
