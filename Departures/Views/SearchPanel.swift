import MapKit
import SwiftUI

/// A place found by search: a pin on the map, and a trip there.
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

    /// Drops the picked place and its pin.
    func clearPlace() {
        resolveTask?.cancel()
        place = nil
        isResolving = false
    }

    func clear() {
        clearPlace()
        clearQuery()
    }

    /// Looks up a suggestion's location (a trip there is planned once it's found).
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
        }
    }
}

/// Where trips were planned to from search, latest first, so they're a tap away
/// next time (on this device).
@MainActor
@Observable
final class SearchHistory {
    static let shared = SearchHistory()

    private(set) var items: [PlanDestination] = []

    /// How many are kept.
    static let limit = 8
    private static let key = "searchHistory"

    private init() {
        #if DEBUG
        // Debug launches start without one (the screenshots stay the same).
        if DebugScene.current != nil { UserDefaults.standard.removeObject(forKey: Self.key) }
        #endif
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([PlanDestination].self, from: data) {
            items = saved
        }
    }

    func add(_ destination: PlanDestination) {
        items.removeAll { $0.id == destination.id }
        items.insert(destination, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        save()
    }

    func remove(_ destination: PlanDestination) {
        items.removeAll { $0.id == destination.id }
        save()
    }

    func clear() {
        items = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.key)
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
    /// Apple's Maps logo and Legal link sit bottom left just above the search field
    /// (above the tracked train's button or the hint there, while there's one), and
    /// must stay visible.
    static let legalRoom: CGFloat = 28
    static let typicalRoom: CGFloat = 28 + 48 + 12
    static let maximumRoom: CGFloat = 28 + 48 + 8
}

/// Results in a glass card above the system search field: station matches and
/// Apple Maps suggestions while typing, and while the field is active but empty,
/// home and work and the places you planned trips to lately. A station opens its
/// board (with the trip there a tap away on it); a place or a recent trip, the
/// trip card.
struct SearchResults: View {
    @Bindable var model: PlaceSearchModel
    /// The search field is active (focused, or looking a place up).
    let isSearching: Bool
    let onStation: (Station) -> Void
    /// A place was picked: put the keyboard away while it's looked up.
    let onPickPlace: () -> Void
    /// A recent trip's destination was picked.
    let onRecent: (PlanDestination) -> Void

    @Environment(AppSettings.self) private var settings
    @State private var contentHeight: CGFloat = 0
    private let network = RailNetwork.shared
    private let history = SearchHistory.shared

    private struct SavedStation: Identifiable {
        let role: StationRole
        let station: Station
        var label: String { role == .work ? "Work" : "Home" }
        var id: String { label + station.code }
    }

    private var hasContent: Bool {
        model.isResolving || model.hasQuery || (isSearching && (!savedStations.isEmpty || !recents.isEmpty))
    }

    /// Recent trips, without home and work (they're listed above them).
    private var recents: [PlanDestination] {
        history.items.filter { $0.station == nil || ($0.station != settings.homeCode && $0.station != settings.workCode) }
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
                if model.hasQuery || model.isResolving {
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
                    if !savedStations.isEmpty {
                        sectionTitle("Your stations")
                        ForEach(savedStations) { saved in
                            stationRow(saved.station, detail: saved.label, role: saved.role) { onStation(saved.station) }
                        }
                    }
                    if !recents.isEmpty {
                        HStack {
                            sectionTitle("Recent")
                            Spacer()
                            Button("Clear") {
                                withAnimation(.snappy) { history.clear() }
                            }
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                        }
                        ForEach(recents) { recent in
                            recentRow(recent)
                        }
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

    /// A recent trip's destination, with a button to take it off the list.
    private func recentRow(_ recent: PlanDestination) -> some View {
        HStack(spacing: 0) {
            Button {
                onRecent(recent)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(recentColor(recent), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recent.name).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                        if !recent.subtitle.isEmpty {
                            Text(recent.subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .padding(.leading, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Trip to \(recent.name)")
            Button {
                withAnimation(.snappy) { history.remove(recent) }
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(recent.name) from recent trips")
        }
    }

    private func recentColor(_ recent: PlanDestination) -> Color {
        guard let code = recent.station, let station = network.station(code) else { return .red }
        return network.line(code: station.lineCodes.first ?? "")?.color ?? .gray
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
