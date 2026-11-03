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
        if let place {
            // The field shows the picked place's name; typing anything else starts over.
            if query == place.name { return }
            self.place = nil
            nearby = []
        }
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

    func clear() {
        resolveTask?.cancel()
        place = nil
        nearby = []
        query = ""
        placeError = nil
        isResolving = false
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
                coordinate: item.location.coordinate
            )
            // Set the place first so the field can show its name without new suggestions.
            place = found
            query = found.name
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
        request.source = MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
                                   address: nil)
        request.destination = MKMapItem(location: station.location, address: nil)
        request.transportType = .automobile
        let eta = try? await MKDirections(request: request).calculateETA()
        return NearbyStation(station: station, travelTime: eta?.expectedTravelTime,
                             distance: eta?.distance ?? straightLine)
    }
}

// MARK: - View

/// Geometry of the bottom search bar, taken from iOS 26's own floating bar
/// (the tab bar in Apple's apps): 62 pt tall and 21 pt in from the sides and
/// from the bottom edge of the screen, so its rounded ends follow the curve of
/// the display corners. While typing it works like system search fields: the
/// field drops to 48 pt, rides just above the keyboard, and a separate glass
/// close button grows out of it.
enum BottomBarMetrics {
    static let restingHeight: CGFloat = 62
    static let edgeInset: CGFloat = 21
    static let focusedHeight: CGFloat = 48
    static let focusedSideInset: CGFloat = 16
    static let keyboardGap: CGFloat = 12
}

/// The glass search bar at the bottom of the map, with results above it.
struct SearchPanel: View {
    @Bindable var model: PlaceSearchModel
    @FocusState.Binding var isFocused: Bool
    let onStation: (Station) -> Void

    @Environment(AppSettings.self) private var settings
    @State private var contentHeight: CGFloat = 0
    @Namespace private var glass
    private let network = RailNetwork.shared

    private struct SavedStation: Identifiable {
        let role: StationRole
        let station: Station
        var label: String { role == .work ? "Work" : "Home" }
        var id: String { label + station.code }
    }

    private var showsResults: Bool {
        model.place != nil || model.hasQuery || (isFocused && !savedStations.isEmpty)
    }

    private var savedStations: [SavedStation] {
        var result: [SavedStation] = []
        if let home = settings.homeCode.flatMap(network.station) { result.append(SavedStation(role: .home, station: home)) }
        if let work = settings.workCode.flatMap(network.station) { result.append(SavedStation(role: .work, station: work)) }
        return result
    }

    var body: some View {
        VStack(spacing: 10) {
            if showsResults {
                results
                    .layoutPriority(1)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            searchBar
        }
        .animation(.snappy, value: showsResults)
    }

    // MARK: Bar

    private var searchBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                field
                if isFocused {
                    closeButton
                }
            }
        }
        .animation(.smooth(duration: 0.35), value: isFocused)
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Search stations or places", text: $model.query)
                .focused($isFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit {
                    if let station = model.submit() { openStation(station) }
                }
            if model.hasQuery || model.place != nil {
                Button {
                    model.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, isFocused ? 16 : 22)
        .frame(height: isFocused ? BottomBarMetrics.focusedHeight : BottomBarMetrics.restingHeight)
        .contentShape(Capsule())
        // The whole bar, not just the text, opens the keyboard.
        .onTapGesture { isFocused = true }
        .glassEffect(.regular.interactive(), in: Capsule())
        .glassEffectID("field", in: glass)
    }

    /// Ends the search, like the close button beside system search fields.
    private var closeButton: some View {
        Button {
            isFocused = false
            model.clear()
        } label: {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: BottomBarMetrics.focusedHeight, height: BottomBarMetrics.focusedHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .glassEffectID("close", in: glass)
        .accessibilityLabel("Close search")
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
                            stationRow(station, detail: nil) { openStation(station) }
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
                        stationRow(saved.station, detail: saved.label, role: saved.role) { openStation(saved.station) }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.immediately)
        // As tall as the results, up to 340 pt, and shorter when the keyboard leaves less room.
        .frame(maxHeight: min(max(contentHeight, 1), 340))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
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
                stationRow(nearby.station, detail: Self.describe(nearby)) { openStation(nearby.station) }
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
                    Text(station.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    if let detail {
                        Text(detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    ForEach(station.lineCodes, id: \.self) { LineBadge(code: $0) }
                }
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
            isFocused = false
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

    private func openStation(_ station: Station) {
        isFocused = false
        onStation(station)
    }
}
