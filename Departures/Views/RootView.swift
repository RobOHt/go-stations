import MapKit
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase

    @State private var mapController = MapController()
    @State private var selected: Station?
    @State private var detent: PresentationDetent = .medium
    @State private var showSettings = false
    /// The tracked trip's details, opened from the map.
    @State private var trackedSelection: TripSelection?
    @State private var backgroundedAt: Date?

    @State private var search = PlaceSearchModel()
    /// The system search field is active (expanded, with its close button).
    @State private var searchPresented = false
    @FocusState private var searchFocused: Bool
    /// Top edge of the station sheet on screen, so the buttons can sit just above it.
    @State private var sheetTop: CGFloat?
    /// Bottom edge of the area the floating UI lives in: just above the search
    /// field (which itself rides above the keyboard while typing).
    @State private var floatingBottom: CGFloat = 0

    private let network = RailNetwork.shared

    var body: some View {
        // The search field is the system's own (`.searchable` in the bottom toolbar),
        // so iOS sizes and places it like Settings' on every iPhone, and handles the
        // keyboard, the close button and larger text. The navigation bar is hidden:
        // the map runs edge to edge.
        NavigationStack {
            mapScreen
                .toolbar {
                    DefaultToolbarItem(kind: .search, placement: .bottomBar)
                }
                .toolbarVisibility(.hidden, for: .navigationBar)
                .searchable(text: $search.query, isPresented: $searchPresented, prompt: "Search stations or places")
                .searchFocused($searchFocused)
                .onChange(of: searchFocused) { _, focused in
                    // Putting the keyboard away (tapping the map, say) closes the search, so
                    // it's never left open behind the map, where it gets in the way of
                    // pinches and drags. A place being looked up keeps it until its card shows.
                    if !focused, !search.isResolving, search.place == nil {
                        endSearch()
                    }
                }
                .onChange(of: searchPresented) { _, presented in
                    // A new search replaces the place card.
                    if presented, search.place != nil { search.clearPlace() }
                }
                .autocorrectionDisabled()
                .onSubmit(of: .search) {
                    if let station = search.submit() {
                        openFromSearch(station)
                    } else {
                        // Searching places: put the keyboard away for the results.
                        searchFocused = false
                    }
                }
        }
        .sheet(isPresented: stationSheetPresented) {
            if let selected {
                StationSheet(station: selected)
                    // The sheet's visible top edge. Its content starts lower (iOS keeps a
                    // safe area at the top of the sheet for the grabber), so measure a
                    // background that ignores the safe area and spans the whole sheet.
                    .background {
                        Color.clear
                            .ignoresSafeArea()
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { sheetTop = $0 }
                    }
                    .presentationDetents([.medium, .large], selection: $detent)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(item: $trackedSelection) { selection in
            TripSheet(selection: selection)
                .environment(settings)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
        }
        .onChange(of: TripTracker.shared.trip?.startedAt) { _, started in
            // A newly tracked trip: show where it goes (behind the sheets until they close).
            guard started != nil, let trip = TripTracker.shared.trip else { return }
            let coordinates = [trip.boardingCode, trip.destinationCode].compactMap { network.station($0)?.coordinate }
            mapController.frame(coordinates, minWidth: 6_000)
        }
        .task {
            // Keep the tracked train's times (and its Live Activity) up to date, and
            // stop tracking a while after it reaches your stop.
            while !Task.isCancelled {
                await TripTracker.shared.refresh()
                TripTracker.shared.dropIfFinished()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onOpenURL { url in
            // Tapping the Live Activity opens the trip.
            if url.scheme == TripActivityAttributes.openURL.scheme, url.host() == TripActivityAttributes.openURL.host() {
                openTrackedTrip()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onChange(of: selected == nil) { _, closed in
            if closed { sheetTop = nil }
        }
        .onChange(of: search.place) { _, place in
            guard let place else { return }
            // Like Apple Maps: a picked place closes the search and shows as a card
            // (with its own close button) above the resting search bar.
            endSearch()
            mapController.frame([place.coordinate], minWidth: 4_000)
        }
        .onChange(of: search.nearby.map(\.id)) { _, ids in
            guard let place = search.place, !ids.isEmpty else { return }
            mapController.frame([place.coordinate] + search.nearby.map(\.station.coordinate))
        }
        .task {
            refreshTimetable()
            #if DEBUG
            if let scene = DebugScene.current {
                await show(scene)
                return
            }
            #endif
            await autoSelect()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                backgroundedAt = .now
                #if DEBUG
                if DebugScene.current == .liveActivity {
                    TripActivityController.shared.alertForScreenshot()
                }
                #endif
            case .active:
                settings.reloadFromCloud()
                TripTracker.shared.dropIfFinished()
                Task { await TripTracker.shared.refresh() }
                refreshTimetable()
                if let backgroundedAt, Date.now.timeIntervalSince(backgroundedAt) > 180 {
                    Task { await autoSelect() }
                }
                backgroundedAt = nil
            default:
                break
            }
        }
    }

    private var mapScreen: some View {
        NetworkMapView(
            controller: mapController,
            selectedCode: selected?.code,
            homeCode: settings.homeCode,
            workCode: settings.workCode,
            place: search.place,
            onTapMap: { searchFocused = false },
            trackedTrip: TripTracker.shared.trip,
            onSelectTrain: { openTrackedTrip() },
            onSelect: { station in select(station, detent: .medium) }
        )
        .ignoresSafeArea()
        .overlay { floatingUI }
    }

    private var stationSheetPresented: Binding<Bool> {
        Binding(
            get: { selected != nil },
            set: { if !$0 { selected = nil } }
        )
    }

    // MARK: Floating controls and search

    private var searchActive: Bool {
        searchPresented || searchFocused || search.hasQuery || search.place != nil
    }

    /// How far above the bottom of the floating area the station sheet reaches.
    private var sheetLift: CGFloat? {
        guard selected != nil, let sheetTop else { return nil }
        return max(0, floatingBottom - sheetTop)
    }

    private var showsControls: Bool {
        if selected != nil {
            // Ride above the half-height sheet; the full-height one covers them.
            guard detent != .large, let sheetTop else { return false }
            return sheetTop > 300
        }
        return !searchActive
    }

    /// The map buttons, bottom right just above the search field (or above the
    /// sheet when a station is open), and search results above the field. The
    /// area respects the safe area, which includes the system search field.
    private var floatingUI: some View {
        VStack(alignment: .trailing, spacing: 12) {
            Spacer(minLength: 0)
            if showsControls {
                // The tracked trip bottom left; the map buttons bottom right.
                HStack(alignment: .bottom, spacing: 12) {
                    if let trip = TripTracker.shared.trip {
                        TrackedTripButton(trip: trip) { openTrackedTrip() }
                            .padding(.leading, BottomBarMetrics.controlsTrailingInset)
                            .transition(.scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
                    }
                    Spacer(minLength: 0)
                    controls
                        .padding(.trailing, BottomBarMetrics.controlsTrailingInset)
                }
                .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
            }
            if selected == nil, searchActive {
                SearchResults(
                    model: search,
                    isSearching: searchPresented || searchFocused,
                    onStation: { station in openFromSearch(station) },
                    onPickPlace: { searchFocused = false }
                )
                .padding(.horizontal, 16)
                .layoutPriority(1)
            }
        }
        .padding(.bottom, sheetLift.map { $0 + 12 } ?? BottomBarMetrics.gapAbove)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { floatingBottom = $0 }
        .animation(.smooth(duration: 0.3), value: selected == nil)
        .animation(.smooth(duration: 0.3), value: showsControls)
        .animation(.smooth(duration: 0.3), value: TripTracker.shared.trip?.startedAt)
        .animation(.smooth(duration: 0.25), value: sheetLift)
    }

    /// Home and work share one glass; settings and my location share another,
    /// like Apple Maps' map controls. My location is at the very bottom.
    private var controls: some View {
        let home = settings.homeCode.flatMap(network.station)
        let work = settings.workCode.flatMap(network.station)
        return GlassEffectContainer(spacing: 10) {
            VStack(spacing: 12) {
                if home != nil || work != nil {
                    GlassButtonGroup {
                        if let home {
                            Button {
                                select(home, detent: .medium)
                            } label: {
                                GlassIcon(systemName: "house.fill", color: RoleColor.home)
                            }
                            .accessibilityLabel("Home station: \(home.name)")
                        }
                        if let work {
                            Button {
                                select(work, detent: .medium)
                            } label: {
                                GlassIcon(systemName: "briefcase.fill", color: RoleColor.work)
                            }
                            .accessibilityLabel("Work station: \(work.name)")
                        }
                    }
                }

                GlassButtonGroup {
                    Button {
                        openSettings()
                    } label: {
                        GlassIcon(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("Settings")

                    Button {
                        Task { await showMyLocation() }
                    } label: {
                        GlassIcon(systemName: "location.fill")
                    }
                    .accessibilityLabel("Show my location")
                }
            }
        }
    }

    // MARK: Actions

    /// Keeps the fallback timetable fresh in the background (not while a debug
    /// check has fixed the time, so that runs on the bundled timetable).
    private func refreshTimetable() {
        #if DEBUG
        if DebugScene.fixedNow != nil { return }
        #endif
        Task.detached(priority: .background) { await ScheduleStore.shared.refreshIfNeeded() }
    }

    private func openFromSearch(_ station: Station) {
        // A station picked by name ends the search; a place card stays so you can come
        // back and compare its other stations.
        if search.place == nil { endSearch() }
        select(station, detent: .medium)
    }

    /// Closes the system search field and its suggestions (a place card stays).
    private func endSearch() {
        searchFocused = false
        searchPresented = false
        search.clearQuery()
    }

    private func select(_ station: Station, detent newDetent: PresentationDetent) {
        searchFocused = false
        detent = newDetent
        selected = station
        center(on: station.coordinate, sheetOpen: true)
    }

    /// Centres the map on a point, placed above the half-height sheet when one is up.
    private func center(on coordinate: CLLocationCoordinate2D, sheetOpen: Bool) {
        mapController.show(coordinate, sheetOpen: sheetOpen)
    }

    private func showMyLocation() async {
        if LocationProvider.shared.isDenied {
            // Location was turned off for the app: take the user to where they can turn it on.
            if let url = URL(string: UIApplication.openSettingsURLString) {
                _ = await UIApplication.shared.open(url)
            }
            return
        }
        guard let here = await LocationProvider.shared.currentLocation(maxAge: 30) else { return }
        if RailNetwork.isInServiceArea(here.coordinate) {
            center(on: here.coordinate, sheetOpen: selected != nil)
        }
    }

    /// Opens the tracked trip's details (closing the station sheet or Settings first).
    private func openTrackedTrip() {
        guard let trip = TripTracker.shared.trip, let station = network.station(trip.boardingCode) else { return }
        let selection = TripSelection(row: trip.row, station: station)
        searchFocused = false
        guard selected != nil || showSettings else {
            trackedSelection = selection
            return
        }
        selected = nil
        showSettings = false
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            trackedSelection = selection
        }
    }

    private func openSettings() {
        guard selected != nil else {
            showSettings = true
            return
        }
        selected = nil
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            showSettings = true
        }
    }

    /// Centres the map on you, and opens the board you most likely want (see
    /// CommutePlanner): your home or work station when you're near it, the next
    /// change station when you're on a train of your commute, otherwise the
    /// station you'd get home (or, weekday mornings, to work) soonest from.
    private func autoSelect() async {
        let here = await LocationProvider.shared.currentLocation()

        // SwiftUI can't show the station sheet on top of Settings.
        var board: Station?
        if !showSettings {
            if let here, RailNetwork.isInServiceArea(here.coordinate) {
                let choice = await StartupStation.choose(at: here, home: settings.homeCode,
                                                         work: settings.workCode, now: AppClock.now)
                #if DEBUG
                DebugScene.record(choice)
                #endif
                board = choice?.station.flatMap(network.station)
            }
            if board == nil {
                board = here.flatMap(bestStation(near:)) ?? settings.homeCode.flatMap(network.station)
            }
        }
        // Settings, or the tracked trip (from its Live Activity), may have opened
        // while that was worked out.
        if showSettings || trackedSelection != nil { board = nil }

        if let here, RailNetwork.isInServiceArea(here.coordinate) {
            if let board {
                detent = .medium
                selected = board
            }
            center(on: here.coordinate, sheetOpen: selected != nil)
        } else if let board {
            select(board, detent: .medium)
        }
    }

    #if DEBUG
    /// Opens the app straight into a state, for simulator screenshots.
    private func show(_ scene: DebugScene) async {
        try? await Task.sleep(for: .seconds(1.5))
        guard let union = network.station("UN") else { return }
        switch scene {
        case .map:
            center(on: union.coordinate, sheetOpen: false)
        case .searchFocused:
            center(on: union.coordinate, sheetOpen: false)
            searchPresented = true
            searchFocused = true
        case .searchTapAway:
            // Open the empty search, then tap the map: it should close again.
            center(on: union.coordinate, sheetOpen: false)
            searchPresented = true
            searchFocused = true
            try? await Task.sleep(for: .seconds(2))
            searchFocused = false
        case .searchTyping:
            center(on: union.coordinate, sheetOpen: false)
            searchPresented = true
            searchFocused = true
            search.query = "Oak"
        case .place:
            // As if typed and submitted with the Search key.
            center(on: union.coordinate, sheetOpen: false)
            searchPresented = true
            searchFocused = true
            try? await Task.sleep(for: .milliseconds(800))
            search.query = "CN Tower"
            try? await Task.sleep(for: .milliseconds(800))
            _ = search.submit()
            searchFocused = false
        case .station, .trip, .homeDialog, .workDialog:
            select(union, detent: .medium)
        case .stationLarge, .stationScrolled:
            select(union, detent: .large)

        case .trackedTrip, .liveActivity:
            await trackDebugTrain()
        case .activityGallery:
            break  // DeparturesApp shows the gallery in place of the map.
        }
    }

    /// Tracks a train as if picked on your home station's board (Union's without
    /// one): one already on its way there when there is one, so it moves on the
    /// map. (Trains on Union's board mostly start there and just sit.)
    private func trackDebugTrain() async {
        guard let station = settings.homeCode.flatMap(network.station) ?? network.station("UN") else { return }
        center(on: station.coordinate, sheetOpen: false)
        guard let board = try? await BoardService.shared.board(for: station) else { return }
        var picked: (BoardRow, TripDetail)?
        for row in board.rows.prefix(8) where !row.isCancelled {
            let detail = await BoardService.shared.tripDetail(for: row, from: station)
            if picked == nil { picked = (row, detail) }
            if TrainState(stops: detail.stops, now: Date()).isMoving {
                picked = (row, detail)
                break
            }
        }
        if let picked {
            TripTracker.shared.track(TripSelection(row: picked.0, station: station), detail: picked.1,
                                     home: settings.homeCode, work: settings.workCode)
        }
    }
    #endif

    private func bestStation(near here: CLLocation) -> Station? {
        if let nearest = network.nearestStation(to: here), nearest.distance < 400 {
            return nearest.station
        }
        let saved = [settings.homeCode, settings.workCode]
            .compactMap { $0 }
            .compactMap { network.station($0) }
        if let best = saved.min(by: { $0.location.distance(from: here) < $1.location.distance(from: here) }) {
            return best
        }
        if let nearest = network.nearestStation(to: here), nearest.distance < 3_000 {
            return nearest.station
        }
        return nil
    }
}
