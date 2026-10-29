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

    static let refreshInterval: Duration = .seconds(30)

    /// Runs until the calling task is cancelled (the sheet closes or the station changes).
    func run(station: Station, apiKey: String) async {
        if stationCode != station.code {
            stationCode = station.code
            snapshot = nil
            errorMessage = nil
        }
        guard !apiKey.isEmpty else { return }

        while !Task.isCancelled {
            await refresh(station: station, apiKey: apiKey)
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    func refresh(station: Station, apiKey: String) async {
        guard !apiKey.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await BoardService.shared.board(for: station, apiKey: apiKey)
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
