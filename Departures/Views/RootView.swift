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
    /// With Show All Trains on: the trains running now, from the timetable.
    @State private var runningTrips: [ScheduleStore.RunningTrip] = []

    @State private var search = PlaceSearchModel()
    /// The system search field is active (expanded, with its close button).
    @State private var searchPresented = false
    @FocusState private var searchFocused: Bool
    /// Top edge of the station sheet on screen, so the buttons can sit just above it.
    @State private var sheetTop: CGFloat?
    /// A board has been open at some point (opened at launch or by a tap): no more
    /// hint on how to get one.
    @AppStorage("openedABoard") private var openedABoard = false
    /// Bottom edge of the area the floating UI lives in: just above the search
    /// field (which itself rides above the keyboard while typing).
    @State private var floatingBottom: CGFloat = 0

    private let network = RailNetwork.shared

    var body: some View {
        NavigationStack {
            searchableMap
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
                .onSubmit(of: .search) { submitSearch() }
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
            // A newly tracked trip: show where the train is and where it goes (behind
            // the sheets until they close).
            guard started != nil, let trip = TripTracker.shared.trip else { return }
            var coordinates = [trip.boardingCode, trip.destinationCode].compactMap { network.station($0)?.coordinate }
            if let train = trip.position(at: Date(), on: StartupStation.geometry) {
                let place = TrackGeometry.coordinate(train)
                coordinates.append(CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude))
            }
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
            if closed { sheetTop = nil } else { openedABoard = true }
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
                // The Live Activity takes over: bring it up to date as the app goes.
                TripTracker.shared.dropIfFinished()
                #if DEBUG
                if DebugScene.current == .liveActivity {
                    TripActivityController.shared.alertForScreenshot()
                }
                #endif
            case .active:
                settings.reloadFromCloud()
                if let backgroundedAt, Date.now.timeIntervalSince(backgroundedAt) > 15 * 60 {
                    // A day picked on a board's week strip was for then: back to today.
                    BoardTime.shared.day = nil
                    BoardTime.shared.period = .allDay
                }
                TripTracker.shared.dropIfFinished()
                Task { await TripTracker.shared.refresh() }
                if wantsLiveTrains { Task { await LiveTrains.shared.refresh() } }
                refreshTimetable()
                if backgroundedAt != nil, TripTracker.shared.trip != nil {
                    // Tracking a train: back on it every time you come back.
                    openTrackedTrip()
                } else if let backgroundedAt, Date.now.timeIntervalSince(backgroundedAt) > 180 {
                    Task { await autoSelect() }
                }
                backgroundedAt = nil
            default:
                break
            }
        }
    }

    private static let searchPrompt = "Search stations or places"

    /// The map with its search field. On iOS 26 the field is the system's own
    /// (`.searchable` in the bottom toolbar), so iOS sizes and places it like
    /// Settings' on every iPhone, and handles the keyboard, the close button and
    /// larger text. Before iOS 26 there's no search field in a bottom bar, so it's
    /// one of our own in the same place. The navigation bar is hidden either way:
    /// the map runs edge to edge.
    @ViewBuilder
    private var searchableMap: some View {
        if #available(iOS 26.0, *) {
            mapScreen
                .toolbar {
                    DefaultToolbarItem(kind: .search, placement: .bottomBar)
                }
                .toolbarVisibility(.hidden, for: .navigationBar)
                .searchable(text: $search.query, isPresented: $searchPresented, prompt: Self.searchPrompt)
                .searchFocused($searchFocused)
        } else {
            mapScreen
                .toolbarVisibility(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .bottom, spacing: 0) { searchBar }
        }
    }

    /// Before iOS 26: the bottom search field, frosted like the map buttons, with a
    /// close button beside it while the search is open (as iOS 26's has).
    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField(Self.searchPrompt, text: $search.query)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit { submitSearch() }
                if search.hasQuery {
                    Button {
                        search.clearQuery()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear text")
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .background {
                // Anywhere on the field, not just its text, starts typing.
                Capsule()
                    .fill(.clear)
                    .contentShape(Capsule())
                    .onTapGesture { searchFocused = true }
            }
            .glass(in: Capsule())

            if searchPresented {
                GlassCloseButton { endSearch() }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .animation(.smooth(duration: 0.25), value: searchPresented)
        .onChange(of: searchFocused) { _, focused in
            // Tapping in opens the search, as tapping the system's field does.
            if focused { searchPresented = true }
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
            runningTrips: settings.showsAllTrains ? runningTrips : [],
            onSelectRunningTrain: { trip, next in openRunningTrain(trip, at: next) },
            onSelect: { station in select(station, detent: .medium) }
        )
        .ignoresSafeArea()
        .overlay { floatingUI }
        .task(id: settings.showsAllTrains) {
            // Which trains are running, once a minute (the map moves them in between),
            // with the ones setting off before the next look, and the ones that just
            // got in (the map shows them standing there a minute).
            guard settings.showsAllTrains else {
                runningTrips = []
                return
            }
            while !Task.isCancelled {
                // Trains that got in a while ago too: live reports say when a late
                // one really gets in.
                runningTrips = await ScheduleStore.shared.runningTrips(
                    at: Date(), ahead: 120, behind: 45 * 60) ?? []
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .task(id: wantsLiveTrains && scenePhase == .active) {
            // Where the trains really are, every 5 seconds while the map shows any
            // and the app is open: each new report soon after it's out, so the map's
            // guesses from the latest one stay short (see
            // NetworkMapView.Coordinator.replayDelay). (Restarted when either
            // changes: a running task only ever sees them as they were when it began.)
            guard wantsLiveTrains, scenePhase == .active else { return }
            while !Task.isCancelled {
                await LiveTrains.shared.refresh(maxAge: 4)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Someone new (no home or work, and no board opened yet, say with location off or
    /// far from GO): a hint on what to tap.
    private var showsMapHint: Bool {
        !openedABoard && settings.homeCode == nil && settings.workCode == nil
    }

    /// The map shows the tracked train or all trains: worth knowing where they are.
    private var wantsLiveTrains: Bool {
        TripTracker.shared.trip != nil || settings.showsAllTrains
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
                    // Above Apple's Maps logo and Legal link (behind the sheet when one's open).
                    Group {
                        if let trip = TripTracker.shared.trip {
                            TrackedTripButton(trip: trip) { openTrackedTrip() }
                                .transition(.scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
                        } else if showsMapHint {
                            MapHint()
                                .transition(.opacity)
                        }
                    }
                    .padding(.leading, BottomBarMetrics.controlsTrailingInset)
                    .padding(.bottom, selected == nil ? BottomBarMetrics.legalRoom : 0)
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
        return GlassGroup(spacing: 10) {
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

    /// The Search key: open an exact station match, otherwise look the text up as a place.
    private func submitSearch() {
        if let station = search.submit() {
            openFromSearch(station)
        } else {
            // Searching places: put the keyboard away for the results.
            searchFocused = false
        }
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
    /// Opens the tracked trip's details and goes to the train on the map.
    private func openTrackedTrip() {
        guard let trip = TripTracker.shared.trip, let station = network.station(trip.boardingCode) else { return }
        if let train = trip.position(at: Date(), on: StartupStation.geometry) {
            let place = TrackGeometry.coordinate(train)
            center(on: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude), sheetOpen: true)
        }
        openTrip(TripSelection(row: trip.row, station: station, fromBoard: trip.hasStartingStop))
    }

    /// Opens a running train's stops (Show All Trains), from the station it's heading for.
    private func openRunningTrain(_ trip: ScheduleStore.RunningTrip, at next: Int) {
        guard let row = BoardService.row(for: trip, at: next),
              let station = network.station(trip.pattern[next]) else { return }
        openTrip(TripSelection(row: row, station: station))
    }

    /// Shows a train's stops (closing the station sheet or Settings first).
    private func openTrip(_ selection: TripSelection) {
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

    /// At launch and after a while away. With a train tracked: the train, on the map
    /// and its stops open (as every time you come back to the app while tracking). Otherwise centres the map on you, and opens the board you
    /// most likely want (see CommutePlanner): your home or work station when you're
    /// near it, the next change station when you're on a train of your commute,
    /// otherwise the station you'd get home (or, weekday mornings, to work) soonest from.
    private func autoSelect() async {
        // Tracking a train: open on it (its stops, the map on the train), whatever
        // station would be picked otherwise.
        if TripTracker.shared.trip != nil {
            openTrackedTrip()
            return
        }
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
                // You and the board's station, both in view above the half-height sheet
                // (the station is often a few kilometres off).
                mapController.frame([here.coordinate, board.coordinate], minWidth: 3_000, coveredFraction: 0.55)
            } else {
                center(on: here.coordinate, sheetOpen: false)
            }
        } else if let board {
            select(board, detent: .medium)
        }
    }

    #if DEBUG
    /// Opens the app straight into a state, for simulator screenshots.
    private func show(_ scene: DebugScene) async {
        try? await Task.sleep(for: .seconds(1.5))
        guard let union = network.station("UN") else { return }
        // `-boardPeriod noon`: boards narrow to that part of the day, when they can.
        if let period = UserDefaults.standard.string(forKey: "boardPeriod").flatMap(DayPeriod.init(rawValue:)) {
            BoardTime.shared.period = period
        }
        // `-boardDaysAhead N`: boards show that day, as if picked on the week strip.
        let ahead = UserDefaults.standard.integer(forKey: "boardDaysAhead")
        if ahead > 0 {
            BoardTime.shared.day = BoardDay.calendar.date(byAdding: .day, value: ahead,
                                                          to: BoardDay.calendar.startOfDay(for: Date()))
        }
        switch scene {
        case .map:
            // `-mapCenter 43.65,-79.38 -mapWidth 15000`: the map there, that many metres across.
            let parts = (UserDefaults.standard.string(forKey: "mapCenter") ?? "").split(separator: ",").compactMap { Double($0) }
            let width = UserDefaults.standard.double(forKey: "mapWidth")
            let spot = parts.count == 2 ? CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]) : union.coordinate
            mapController.show(spot, width: width > 0 ? width : 5_000, sheetOpen: false)
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
        case .station:
            // `-debugStation CODE`: another station's board than Union's.
            let code = UserDefaults.standard.string(forKey: "debugStation")
            select(code.flatMap(network.station) ?? union, detent: .medium)
        case .trip, .homeDialog, .workDialog, .stationEarlier:
            select(union, detent: .medium)
        case .stationLarge, .stationScrolled:
            let code = UserDefaults.standard.string(forKey: "debugStation")
            select(code.flatMap(network.station) ?? union, detent: .large)

        case .allTrains:
            mapController.show(union.coordinate, width: 60_000, sheetOpen: false)
        case .mapTour:
            mapController.show(union.coordinate, width: 40_000, sheetOpen: false)
            try? await Task.sleep(for: .seconds(4))
            mapController.show(union.coordinate, width: 15_000, sheetOpen: false)
            try? await Task.sleep(for: .seconds(3))
            if let exhibition = network.station("EX") { select(exhibition, detent: .medium) }
            try? await Task.sleep(for: .seconds(3.5))
            selected = nil
            try? await Task.sleep(for: .seconds(2))
            // Slowly along the lake to Danforth: the tags move with the map, on and off
            // the screen, without changing.
            if let danforth = network.station("DA") {
                mapController.glide(to: danforth.coordinate, duration: 4)
            }
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
            TripTracker.shared.track(TripSelection(row: picked.0, station: station, fromBoard: true), detail: picked.1,
                                     home: settings.homeCode, work: settings.workCode)
        }
        // `-openTripAfter <seconds>`: then its stops, for a screenshot of them on the move.
        let wait = UserDefaults.standard.double(forKey: "openTripAfter")
        if wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
            openTrackedTrip()
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
        // No home or work yet: the nearest station, so a new user starts on a board.
        if let nearest = network.nearestStation(to: here), nearest.distance < CommutePlanner.nearestMax {
            return nearest.station
        }
        return nil
    }
}

/// Bottom left of the map for someone new, until they first open a board.
private struct MapHint: View {
    var body: some View {
        Label {
            Text("Tap a station for its departures")
        } icon: {
            Image(systemName: "hand.tap.fill")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
        .glass(.plain, in: Capsule())
    }
}
