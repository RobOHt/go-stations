import MapKit
import SwiftUI

/// A place found by search, shown as a pin with its nearest stations.
struct SearchPlace: Equatable {
    let name: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D

    static func == (lhs: SearchPlace, rhs: SearchPlace) -> Bool {
        lhs.name == rhs.name
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

struct NearbyStation: Identifiable, Sendable {
    let station: Station
    /// Driving time from the place; nil when Apple Maps couldn't route it.
    let travelTime: TimeInterval?
    let distance: CLLocationDistance

    var id: String { station.code }
}

/// Station and place search for the bottom search bar.
@MainActor
@Observable
final class PlaceSearchModel {
    var query = "" {
        didSet { queryChanged() }
    }
    private(set) var stationMatches: [Station] = []
    private(set) var places: [MKLocalSearchCompletion] = []
    private(set) var place: SearchPlace?
    private(set) var nearby: [NearbyStation] = []
    private(set) var isResolving = false
    /// True while Apple Maps is still suggesting places for the latest text.
    private(set) var isSuggesting = false
    private(set) var placeError: String?

    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    @ObservationIgnored private let bridge = CompleterBridge()
    @ObservationIgnored private var resolveTask: Task<Void, Never>?

    private let network = RailNetwork.shared

    init() {
        completer.delegate = bridge
        completer.region = RailNetwork.serviceArea
        completer.resultTypes = [.address, .pointOfInterest]
        bridge.onResults = { [weak self] results in
            guard let self, self.place == nil else { return }
            self.places = Array(results.prefix(5))
            self.isSuggesting = false
        }
    }

    var hasQuery: Bool { !query.trimmed.isEmpty }

    private func queryChanged() {
        // A picked place lives on its own card while the search is closed, so the
        // text never touches it; starting a new search clears it (clearPlace).
        placeError = nil

        let text = query.trimmed
        stationMatches = Self.matches(text, in: network.stations)
        if text.count >= 2 {
            isSuggesting = true
            completer.queryFragment = text
        } else {
            completer.cancel()
            isSuggesting = false
            places = []
        }
    }

    private static func matches(_ text: String, in stations: [Station]) -> [Station] {
        guard !text.isEmpty else { return [] }
        let wanted = text.lowercased()
        let hits = stations.filter {
            $0.name.lowercased().contains(wanted) || $0.code.lowercased() == wanted
        }
        return Array(hits.sorted { a, b in
            let aPrefix = a.name.lowercased().hasPrefix(wanted)
            let bPrefix = b.name.lowercased().hasPrefix(wanted)
            if aPrefix != bPrefix { return aPrefix }
            return a.name < b.name
        }.prefix(5))
    }

    /// Clears the typed text and its suggestions, keeping a picked place.
    func clearQuery() {
        if !query.isEmpty { query = "" }
        placeError = nil
    }

    /// Drops the picked place, its pin and its closest stations.
    func clearPlace() {
        resolveTask?.cancel()
        place = nil
        nearby = []
        isResolving = false
    }

    func clear() {
        clearPlace()
        clearQuery()
    }

    /// Looks up a suggestion's location and its nearest stations by driving time.
    func choose(_ completion: MKLocalSearchCompletion) {
        let request = MKLocalSearch.Request(completion: completion)
        resolve(request, fallbackName: completion.title, subtitle: completion.subtitle)
    }

    /// Return key: open an exact station match, otherwise search places for the text.
    func submit() -> Station? {
        let text = query.trimmed
        guard !text.isEmpty else { return nil }
        if let exact = stationMatches.first(where: { $0.name.lowercased() == text.lowercased() })
            ?? (stationMatches.count == 1 && places.isEmpty ? stationMatches.first : nil) {
            return exact
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        resolve(request, fallbackName: text, subtitle: "")
        return nil
    }

    private func resolve(_ request: MKLocalSearch.Request, fallbackName: String, subtitle: String) {
        resolveTask?.cancel()
        request.region = RailNetwork.serviceArea
        isResolving = true
        placeError = nil
        nearby = []

        resolveTask = Task {
            let response = try? await MKLocalSearch(request: request).start()
            guard !Task.isCancelled else { return }
            isResolving = false
            guard let item = response?.mapItems.first else {
                placeError = "Couldn't find that place."
                return
            }
            let found = SearchPlace(
                name: item.name ?? fallbackName,
                subtitle: subtitle,
                coordinate: item.placeCoordinate
            )
            place = found
            completer.cancel()
            isSuggesting = false
            places = []
            stationMatches = []

            let stations = await StationFinder.nearest(to: found.coordinate)
            guard !Task.isCancelled, place == found else { return }
            nearby = stations
        }
    }
}

extension MKMapItem {
    /// Where it is: its `location` from iOS 26, its placemark's before.
    var placeCoordinate: CLLocationCoordinate2D {
        if #available(iOS 26.0, *) {
            location.coordinate
        } else {
            placemark.coordinate
        }
    }

    /// A map item at a point, for directions.
    static func at(_ location: CLLocation) -> MKMapItem {
        if #available(iOS 26.0, *) {
            MKMapItem(location: location, address: nil)
        } else {
            MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
        }
    }
}

/// Receives MKLocalSearchCompleter results and hands them on.
private final class CompleterBridge: NSObject, MKLocalSearchCompleterDelegate {
    var onResults: (([MKLocalSearchCompletion]) -> Void)?

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        onResults?(completer.results)
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        onResults?([])
    }
}

enum StationFinder {
    /// How much longer than the closest station another one may take and still be
    /// listed: 25% (a 20 min drive lists others up to 25 min; a 4 min drive, up to 5).
    static let closeEnough = 0.25

    /// The closest stations to a point by driving time. Apple Maps routes the six
    /// nearest in a straight line. The fastest is always listed; others only when
    /// they're nearly as close (see `closeEnough`), up to `count` in all.
    static func nearest(to coordinate: CLLocationCoordinate2D, count: Int = 3) async -> [NearbyStation] {
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let candidates = RailNetwork.shared.stations
            .map { (station: $0, distance: $0.location.distance(from: origin)) }
            .sorted { $0.distance < $1.distance }
            .prefix(6)

        let results = await withTaskGroup(of: NearbyStation.self) { group in
            for candidate in candidates {
                group.addTask {
                    await drive(from: coordinate, to: candidate.station, straightLine: candidate.distance)
                }
            }
            var all: [NearbyStation] = []
            for await result in group { all.append(result) }
            return all
        }

        let sorted = results.sorted { a, b in
            switch (a.travelTime, b.travelTime) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.distance < b.distance
            }
        }
        guard let best = sorted.first else { return [] }
        let comparable = sorted.filter { candidate in
            if let time = candidate.travelTime, let bestTime = best.travelTime {
                return time <= bestTime * (1 + closeEnough)
            }
            // No drive time from Apple Maps: compare road (or straight-line) distance.
            return candidate.distance <= best.distance * (1 + closeEnough)
        }
        return Array(comparable.prefix(count))
    }

    @MainActor
    private static func drive(from coordinate: CLLocationCoordinate2D, to station: Station,
                              straightLine: CLLocationDistance) async -> NearbyStation {
        let request = MKDirections.Request()
        request.source = MKMapItem.at(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        request.destination = MKMapItem.at(station.location)
        request.transportType = .automobile
        let eta = try? await MKDirections(request: request).calculateETA()
        return NearbyStation(station: station, travelTime: eta?.expectedTravelTime,
                             distance: eta?.distance ?? straightLine)
    }
}

// MARK: - View

/// Room taken by the system's bottom search field (Apple's own in Settings on
/// iOS 26 is 48 pt tall, 28 pt from the bottom edge). Only used to frame the map
/// and keep Apple's Legal link above it: the field itself comes from
/// `.searchable`, so iOS sizes and places it on every iPhone.
enum BottomBarMetrics {
    /// The map buttons sit 16 pt from the right edge, as in Apple Maps.
    static let controlsTrailingInset: CGFloat = 16
    /// Gap between the search field (or the sheet) and the results or buttons above it.
    static let gapAbove: CGFloat = 10
    static let typicalRoom: CGFloat = 28 + 48 + 12
    static let maximumRoom: CGFloat = 28 + 48 + 8
}

/// Results in a glass card above the system search field: station matches and
/// Apple Maps suggestions while typing, the closest stations by car for a picked
/// place, and home/work while the field is active but empty.
struct SearchResults: View {
    @Bindable var model: PlaceSearchModel
    /// The search field is active (focused, or showing a picked place).
    let isSearching: Bool
    let onStation: (Station) -> Void
    /// A place was picked: put the keyboard away (its results stay up).
    let onPickPlace: () -> Void

    @Environment(AppSettings.self) private var settings
    @State private var contentHeight: CGFloat = 0
    private let network = RailNetwork.shared

    private struct SavedStation: Identifiable {
        let role: StationRole
        let station: Station
        var label: String { role == .work ? "Work" : "Home" }
        var id: String { label + station.code }
    }

    private var hasContent: Bool {
        model.place != nil || model.hasQuery || (isSearching && !savedStations.isEmpty)
    }

    private var savedStations: [SavedStation] {
        var result: [SavedStation] = []
        if let home = settings.homeCode.flatMap(network.station) { result.append(SavedStation(role: .home, station: home)) }
        if let work = settings.workCode.flatMap(network.station) { result.append(SavedStation(role: .work, station: work)) }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasContent {
                results
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: hasContent)
    }

    // MARK: Results

    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let place = model.place {
                    nearbySection(place)
                } else if model.hasQuery {
                    if !model.stationMatches.isEmpty {
                        sectionTitle("Stations")
                        ForEach(model.stationMatches) { station in
                            stationRow(station, detail: nil) { onStation(station) }
                        }
                    }
                    if !model.places.isEmpty {
                        sectionTitle("Places")
                        ForEach(model.places, id: \.self) { completion in
                            placeRow(completion)
                        }
                    }
                    if model.isResolving {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
                    } else if let error = model.placeError {
                        Text(error).font(.subheadline).foregroundStyle(.secondary).padding(12)
                    } else if model.stationMatches.isEmpty && model.places.isEmpty {
                        if model.isSuggesting {
                            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
                        } else {
                            Text("No matches").font(.subheadline).foregroundStyle(.secondary).padding(12)
                        }
                    }
                } else {
                    sectionTitle("Your stations")
                    ForEach(savedStations) { saved in
                        stationRow(saved.station, detail: saved.label, role: saved.role) { onStation(saved.station) }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        // Scrolling keeps the keyboard: putting it away closes the search.
        .scrollDismissesKeyboard(.never)
        // As tall as the results, up to 340 pt, and shorter when the keyboard leaves less room.
        .frame(maxHeight: min(max(contentHeight, 1), 340))
        .glass(.plain, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    @ViewBuilder
    private func nearbySection(_ place: SearchPlace) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "mappin.circle.fill")
                .font(.title2)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(place.name).font(.headline).lineLimit(1)
                Text(place.subtitle.isEmpty ? "Closest by car" : place.subtitle)
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                model.clear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)

        if model.nearby.isEmpty {
            HStack(spacing: 8) {
                ProgressView()
                Text("Finding the closest stations by driving time…")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(12)
        } else {
            sectionTitle(model.nearby.count == 1 ? "Closest station by car" : "Closest stations by car")
            ForEach(model.nearby) { nearby in
                stationRow(nearby.station, detail: Self.describe(nearby)) { onStation(nearby.station) }
            }
        }
    }

    private static func describe(_ nearby: NearbyStation) -> String {
        let kilometres = nearby.distance / 1000
        let distance = kilometres < 10 ? String(format: "%.1f km", kilometres) : String(format: "%.0f km", kilometres)
        guard let time = nearby.travelTime else { return distance }
        let minutes = max(1, Int((time / 60).rounded()))
        return "\(minutes) min drive · \(distance)"
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func stationRow(_ station: Station, detail: String?, role: StationRole = .plain,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: role == .plain ? "tram.fill" : role.symbolName)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(iconColor(for: station, role: role), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(station.name).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    if let detail {
                        Text(detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                // At most three badges, so long names stay on one line (Union has seven lines).
                HStack(spacing: 3) {
                    ForEach(station.lineCodes.prefix(3), id: \.self) { LineBadge(code: $0) }
                    if station.lineCodes.count > 3 {
                        Text("+\(station.lineCodes.count - 3)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func iconColor(for station: Station, role: StationRole) -> Color {
        switch role {
        case .home: return RoleColor.home
        case .work: return RoleColor.work
        case .plain: return network.line(code: station.lineCodes.first ?? "")?.color ?? .gray
        }
    }

    private func placeRow(_ completion: MKLocalSearchCompletion) -> some View {
        Button {
            onPickPlace()
            model.choose(completion)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "mappin")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.red, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(completion.title).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    if !completion.subtitle.isEmpty {
                        Text(completion.subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}
