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

/// The time the boards show when it isn't now: a day (up to a week ahead) and hour
/// picked from a board's clock. It stays for every board opened after it (planning a
/// trip means looking at a few stations) until Now is picked again, it goes by, or
/// the app has been away a while.
@MainActor
@Observable
final class BoardTime {
    static let shared = BoardTime()

    /// Nil: now, with live times.
    var chosen: Date?

    /// How far ahead a day can be picked.
    static let daysAhead = 7

    /// The time to show, unless it's already gone by.
    func shown(at now: Date) -> Date? {
        guard let chosen, chosen > now else { return nil }
        return chosen
    }
}
