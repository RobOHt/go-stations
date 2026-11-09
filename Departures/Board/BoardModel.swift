import Foundation
import Observation

/// Keeps one station's board fresh while its sheet is on screen.
@MainActor
@Observable
final class BoardModel {
    private(set) var snapshot: BoardSnapshot?
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private(set) var stationCode: String?

    /// Matches how long the proxy caches live answers, so each refresh can bring new data.
    static let refreshInterval: Duration = .seconds(20)

    /// Runs until the calling task is cancelled (the sheet closes or the station changes).
    func run(station: Station) async {
        if stationCode != station.code {
            stationCode = station.code
            snapshot = nil
            errorMessage = nil
        }
        while !Task.isCancelled {
            await refresh(station: station)
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    func refresh(station: Station) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await BoardService.shared.board(for: station)
            guard stationCode == station.code else { return }
            self.snapshot = snapshot
            errorMessage = nil
        } catch {
            if error is CancellationError { return }
            if let urlError = error as? URLError, urlError.code == .cancelled { return }
            guard stationCode == station.code else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// The day the boards show when it isn't today: picked on a board's week strip. It
/// stays for every board opened after it (planning a trip means looking at a few
/// stations) until Today is picked again, the day comes, or the app has been away a
/// while.
@MainActor
@Observable
final class BoardTime {
    static let shared = BoardTime()

    /// A later day at midnight; nil for today, with live times.
    var day: Date?
    /// The part of the day the board narrows to, when it has many trains.
    var period: DayPeriod = .allDay

    /// How many days after today can be picked.
    static let daysAhead = 7

    /// The day to show, unless it's today (or gone by).
    func shownDay(at now: Date) -> Date? {
        guard let day, TorontoTime.dateWire(day) > TorontoTime.dateWire(now) else { return nil }
        return day
    }
}

/// A part of the day on a board with many trains: the morning until 11:00, noon until
/// 14:00, and the afternoon on to the last train (past midnight).
enum DayPeriod: String, CaseIterable, Hashable {
    case allDay, morning, noon, afternoon

    /// The parts, without the whole day.
    static let parts: [DayPeriod] = [.morning, .noon, .afternoon]

    var label: String {
        switch self {
        case .allDay: "All day"
        case .morning: "Morning"
        case .noon: "Noon"
        case .afternoon: "Afternoon"
        }
    }

    func contains(_ date: Date) -> Bool {
        let hour = TorontoTime.hour(date)
        switch self {
        case .allDay: return true
        case .morning: return (4..<11).contains(hour)
        case .noon: return (11..<14).contains(hour)
        case .afternoon: return hour >= 14 || hour < 4
        }
    }
}
