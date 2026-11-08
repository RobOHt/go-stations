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

    /// How many days after today can be picked.
    static let daysAhead = 7

    /// The day to show, unless it's today (or gone by).
    func shownDay(at now: Date) -> Date? {
        guard let day, TorontoTime.dateWire(day) > TorontoTime.dateWire(now) else { return nil }
        return day
    }
}
