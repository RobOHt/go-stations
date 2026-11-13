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
    /// A trip being planned to somewhere picked in search (its card, and the trip
    /// on the map).
    @State private var tripPlan: TripPlanModel?
    @State private var planDetent: PresentationDetent = .medium
    /// How far up a train's stops are: half way when they open.
    @State private var tripDetent: PresentationDetent = .medium
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
    /// The tracked train's button or the hint, bottom left: how tall it is.
    @State private var leadingHeight: CGFloat = 0
    #if DEBUG
    /// Apple's logo moved up by hand, for the recorded tour (see `DebugScene.mapTour`).
    @State private var debugLift: CGFloat?
    #endif

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
                StationSheet(station: selected) { plan in
                    getHere(to: selected, plan: plan)
                }
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
                .presentationDetents([.medium, .large], selection: $tripDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $tripPlan, onDismiss: { search.clearPlace() }) { model in
            TripPlanSheet(model: model, onBack: model.backTo.map { code in { backToBoard(code) } }) {
                tripPlan = nil
            }
                .environment(settings)
                // Its visible top edge, as for the station sheet.
                .background {
                    Color.clear
                        .ignoresSafeArea()
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { sheetTop = $0 }
                }
                .presentationDetents([.medium, .large], selection: $planDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
        }
        .onChange(of: tripPlan?.shown?.id) { _, _ in
            // The trip on the map: all of it in view, above the card.
            frameTripPlan()
        }
        .onChange(of: tripPlan == nil) { _, closed in
            if closed, selected == nil { sheetTop = nil }
        }
        .onChange(of: TripTracker.shared.trip?.startedAt) { _, started in
            // A newly tracked trip: show where the train is and where it goes (behind
            // the sheets until they close); all of a trip planned from search.
            guard started != nil, let trip = TripTracker.shared.trip else { return }
            let stations = trip.route.map { $0.flatMap(\.stops) } ?? [trip.boardingCode, trip.destinationCode]
            var coordinates = stations.compactMap { network.station($0)?.coordinate }
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
                // Its train cancelled: the Live Activity says so, and you're told.
                await TripTracker.shared.checkCancelled()
                TripTracker.shared.dropIfFinished()
                // Its first train gone without you: you're told, and it stops.
                await TripTracker.shared.checkMissed()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onChange(of: AppRoute.shared.planTo) { _, code in
            // A missed train's notification, tapped: plan another trip.
            if code != nil { followRoute() }
        }
        .onChange(of: AppRoute.shared.board) { _, code in
            // A cancelled train's notification, tapped: your station's board.
            if code != nil { followRoute() }
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
            // A place found: the search closes and the trip there comes up (its pin
            // stays on the map while the card's up).
            endSearch()
            planTrip(to: PlanDestination(place: place))
        }
        .task {
            refreshTimetable()
            #if DEBUG
            if let scene = DebugScene.current {
                await show(scene)
                return
            }
            #endif
            // Opened by tapping a missed (or cancelled) train's notification: plan
            // another trip, or open your station's board.
            if AppRoute.shared.planTo != nil || AppRoute.shared.board != nil {
                followRoute()
                return
            }
            await autoSelect()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                backgroundedAt = .now
                // The Live Activity takes over: bring it up to date as the app goes.
                TripTracker.shared.dropIfFinished()
                #if DEBUG
                if DebugScene.current == .liveActivity || DebugScene.current == .trackedJourney {
                    TripActivityController.shared.alertForScreenshot()
                }
                #endif
            case .active:
                settings.reloadFromCloud()
                if let backgroundedAt, Date.now.timeIntervalSince(backgroundedAt) > 15 * 60 {
                    // A day picked in a board's day menu was for then: back to today.
                    BoardTime.shared.day = nil
                    BoardTime.shared.period = .allDay
                }
                TripTracker.shared.dropIfFinished()
                Task {
                    await TripTracker.shared.refresh()
                    await TripTracker.shared.checkCancelled()
                    await TripTracker.shared.checkMissed()
                }
                if wantsLiveTrains { Task { await LiveTrains.shared.refresh() } }
                refreshTimetable()
                if backgroundedAt != nil, TripTracker.shared.trip != nil, tripPlan == nil {
                    // Tracking a train: back on it every time you come back.
                    openTrackedTrip()
                } else if let backgroundedAt, Date.now.timeIntervalSince(backgroundedAt) > 180, tripPlan == nil {
                    Task { await autoSelect() }
                }
                backgroundedAt = nil
            default:
                break
            }
        }
    }

    /// The search plans a trip to what you pick.
    private static let searchPrompt = "Plan a trip: station or place"

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
            place: tripPlan?.destination.place ?? search.place,
            onTapMap: { searchFocused = false },
            trackedTrip: TripTracker.shared.trip,
            onSelectTrain: { openTrackedTrip() },
            runningTrips: settings.showsAllTrains ? runningTrips : [],
            onSelectRunningTrain: { trip, next in openRunningTrain(trip, at: next) },
            attributionLift: attributionLift,
            journey: tripPlan?.shown,
            onSelect: { station in select(station, detent: .medium) }
        )
        .ignoresSafeArea()
        // The map softly blurred behind the search bar, so it and the buttons above
        // it stand out from busy streets (#19).
        .overlay { SearchBarBlur() }
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

    /// Apple's logo and Legal link sit just above the search bar, bottom left: while
    /// the tracked train's button or the hint is there, they go up above it instead
    /// (they must stay in sight). Going by whether there's one, not whether it shows
    /// right now, so the map doesn't shift as the sheet comes and goes.
    private var attributionLift: CGFloat {
        #if DEBUG
        if let debugLift { return debugLift }
        #endif
        guard TripTracker.shared.trip != nil || showsMapHint else { return 0 }
        // Its height, and a little room (they sit a few points below the buttons'
        // bottom edge otherwise).
        return (leadingHeight > 0 ? leadingHeight : 48) + 10
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

    /// How far above the bottom of the floating area the station sheet (or the
    /// trip card) reaches.
    private var sheetLift: CGFloat? {
        guard selected != nil || tripPlan != nil, let sheetTop else { return nil }
        return max(0, floatingBottom - sheetTop)
    }

    private var showsControls: Bool {
        if selected != nil || tripPlan != nil {
            // Ride above the half-height sheet; the full-height one covers them.
            guard (selected != nil ? detent : planDetent) != .large, let sheetTop else { return false }
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
                    // Level with the map buttons; Apple's Maps logo and Legal link move
                    // up above it (see `attributionLift`).
                    Group {
                        if let trip = TripTracker.shared.trip {
                            TrackedTripButton(trip: trip) { openTrackedTrip() }
                                .transition(.scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
                        } else if showsMapHint {
                            MapHint()
                                .transition(.opacity)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { leadingHeight = $0 }
                    .padding(.leading, BottomBarMetrics.controlsTrailingInset)
                    Spacer(minLength: 0)
                    controls
                        .padding(.trailing, BottomBarMetrics.controlsTrailingInset)
                }
                .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
            }
            if selected == nil, tripPlan == nil, searchActive {
                SearchResults(
                    model: search,
                    isSearching: searchPresented || searchFocused,
                    onStation: { station in openFromSearch(station) },
                    onPickPlace: { searchFocused = false },
                    onRecent: { destination in
                        endSearch()
                        planTrip(to: destination)
                    }
                )
                .padding(.horizontal, 16)
                .layoutPriority(1)
            }
        }
        .padding(.bottom, sheetLift.map { $0 + 12 } ?? BottomBarMetrics.gapAbove)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { floatingBottom = $0 }
        .animation(.smooth(duration: 0.3), value: selected == nil)
        .animation(.smooth(duration: 0.3), value: tripPlan == nil)
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

    /// The Search key: a trip to an exact station match, otherwise look the text up as a place.
    private func submitSearch() {
        if let station = search.submit() {
            openFromSearch(station)
        } else {
            // Searching places: put the keyboard away for the results.
            searchFocused = false
        }
    }

    /// A station picked in search: its board, as on the map, with the trip there
    /// a tap away on it (Get here).
    private func openFromSearch(_ station: Station) {
        endSearch()
        search.clearPlace()
        select(station, detent: .medium)
    }

    /// A board's Get here: the trip card to its station (with the plan the button
    /// made, while it's made afresh), and the way back to the board.
    private func getHere(to station: Station, plan: TripPlan?) {
        planTrip(to: PlanDestination(station: station), plan: plan, backTo: station.code)
    }

    /// The trip card's way back: the board it was opened from.
    private func backToBoard(_ code: String) {
        guard let station = network.station(code) else {
            tripPlan = nil
            return
        }
        select(station, detent: .medium)
    }

    /// Where a tapped notification asked to go: the trip card to its station, or
    /// a station's board.
    private func followRoute() {
        if let code = AppRoute.shared.board {
            AppRoute.shared.board = nil
            openBoard(code)
            return
        }
        guard let code = AppRoute.shared.planTo else { return }
        AppRoute.shared.planTo = nil
        guard let station = network.station(code) else { return }
        planTrip(to: PlanDestination(station: station))
    }

    /// Opens a station's board at half height (closing a train's stops or
    /// Settings first): where to find another train after a cancelled one.
    private func openBoard(_ code: String) {
        guard let station = network.station(code) else { return }
        guard trackedSelection != nil || showSettings else {
            select(station, detent: .medium)
            return
        }
        trackedSelection = nil
        showSettings = false
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            select(station, detent: .medium)
        }
    }

    /// Opens the trip card to `destination` (closing any other sheet first), and
    /// keeps it in the search history. `plan`: one already made, shown while it's
    /// made afresh; `backTo`: the board it was opened from, to go back to.
    private func planTrip(to destination: PlanDestination, plan: TripPlan? = nil, backTo: String? = nil) {
        searchFocused = false
        SearchHistory.shared.add(destination)
        let model = TripPlanModel(destination: destination, home: settings.homeCode, work: settings.workCode,
                                  plan: plan, backTo: backTo)
        model.start()
        mapController.frame([destination.coordinate], minWidth: 6_000, coveredFraction: 0.5, asked: true)
        guard selected != nil || showSettings || trackedSelection != nil else {
            planDetent = .medium
            tripPlan = model
            return
        }
        selected = nil
        showSettings = false
        trackedSelection = nil
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            planDetent = .medium
            tripPlan = model
        }
    }

    /// The trip on the trip card's map: its stations (and the place) in view,
    /// above the half-height card.
    private func frameTripPlan() {
        guard let plan = tripPlan else { return }
        var coordinates = (plan.shown?.stationCodes ?? []).compactMap { network.station($0)?.coordinate }
        if plan.destination.isPlace || coordinates.isEmpty { coordinates.append(plan.destination.coordinate) }
        mapController.frame(coordinates, minWidth: 4_000, coveredFraction: 0.5, asked: true)
    }

    /// Closes the system search field and its suggestions (a place card stays).
    private func endSearch() {
        searchFocused = false
        searchPresented = false
        search.clearQuery()
    }

    private func select(_ station: Station, detent newDetent: PresentationDetent) {
        searchFocused = false
        if tripPlan != nil {
            // The trip card goes first (one sheet at a time).
            tripPlan = nil
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                select(station, detent: newDetent)
            }
            return
        }
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
        guard let here = await LocationProvider.shared.currentLocation(maxAge: 30),
              RailNetwork.isInServiceArea(here.coordinate) else { return }
        // As at start-up: you and the station you'd most likely want, its board open.
        let choice = await StartupStation.choose(at: here, home: settings.homeCode,
                                                 work: settings.workCode, now: AppClock.now)
        let board = choice?.station.flatMap(network.station) ?? bestStation(near: here)
        // (A train's stops are up: no board on top of them, but both in view.)
        show(you: here, board: board, opensBoard: trackedSelection == nil && !showSettings, asked: true)
    }

    /// You and `board`'s station, both in view above the half-height sheet (the
    /// station is often a few kilometres off), its board open; just you without one.
    private func show(you here: CLLocation, board: Station?, opensBoard: Bool = true, asked: Bool = false) {
        guard let board else {
            center(on: here.coordinate, sheetOpen: selected != nil)
            return
        }
        if opensBoard {
            detent = .medium
            selected = board
        }
        mapController.frame([here.coordinate, board.coordinate], minWidth: 3_000, coveredFraction: 0.55,
                            asked: asked)
    }

    /// Opens the tracked trip's details (closing the station sheet or Settings first)
    /// and goes to the train on the map: where the map draws it (with you, when
    /// you're on it), else where its times put it.
    private func openTrackedTrip() {
        guard let trip = TripTracker.shared.trip, let station = network.station(trip.boardingCode) else { return }
        // Cancelled before you got on: where to find another train instead (your
        // station's board, or for a trip from search the trip card).
        if trip.cancelled != nil, !trip.hasLeftBoarding {
            if trip.journeyKey != nil, let destination = network.station(trip.finalDestinationCode) {
                planTrip(to: PlanDestination(station: destination))
            } else {
                openBoard(station.code)
            }
            return
        }
        if let drawn = mapController.trackedTrain {
            center(on: drawn, sheetOpen: true)
        } else if let train = trip.position(at: Date(), on: StartupStation.geometry) {
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

    /// Shows a train's stops (closing the station sheet, the trip card or Settings first).
    private func openTrip(_ selection: TripSelection) {
        searchFocused = false
        tripDetent = .medium
        #if DEBUG
        // `-tripLarge YES`: at full height, for a screenshot.
        if UserDefaults.standard.bool(forKey: "tripLarge") { tripDetent = .large }
        #endif
        guard selected != nil || showSettings || tripPlan != nil else {
            trackedSelection = selection
            return
        }
        selected = nil
        showSettings = false
        tripPlan = nil
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            trackedSelection = selection
        }
    }

    private func openSettings() {
        guard selected != nil || tripPlan != nil else {
            showSettings = true
            return
        }
        selected = nil
        tripPlan = nil
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
            show(you: here, board: board)
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
        // `-boardDaysAhead N`: boards show that day, as if picked in the day menu.
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
            // As if typed and submitted with the Search key (`-placeQuery` to look
            // up another place): its trip card comes up.
            center(on: union.coordinate, sheetOpen: false)
            searchPresented = true
            searchFocused = true
            try? await Task.sleep(for: .milliseconds(800))
            search.query = UserDefaults.standard.string(forKey: "placeQuery") ?? "Pickering Town Centre"
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
            // Apple's logo up (as above the tracked train's button) and down again with
            // the map still: the map mustn't shift as it goes.
            try? await Task.sleep(for: .seconds(5.5))
            debugLift = 58
            try? await Task.sleep(for: .seconds(2))
            debugLift = 0
        case .trackedTrip, .liveActivity:
            await trackDebugTrain()
        case .tripPlan, .trackedJourney:
            await planDebugTrip(scene)
        case .selfCheck:
            break  // Run at launch (AppDelegate).
        case .activityGallery:
            break  // DeparturesApp shows the gallery in place of the map.
        }
    }

    /// A trip card, as if the station were picked in search: `-planTo CODE`
    /// (Oakville, or Unionville for the tracked journey), `-planDaysAhead N` for
    /// another day, `-planOpenFirst YES` to open the first trip, `-planLarge YES`
    /// at full height. The tracked journey then tracks the trip it offers.
    private func planDebugTrip(_ scene: DebugScene) async {
        let defaults = UserDefaults.standard
        let code = defaults.string(forKey: "planTo") ?? (scene == .trackedJourney ? "UI" : "OA")
        guard let station = network.station(code) else { return }
        planTrip(to: PlanDestination(station: station))
        let ahead = defaults.integer(forKey: "planDaysAhead")
        if ahead > 0 {
            let today = BoardDay.calendar.startOfDay(for: AppClock.now)
            tripPlan?.pickDay(BoardDay.calendar.date(byAdding: .day, value: ahead, to: today))
        }
        var waited = 0
        while waited < 60, tripPlan?.plan == nil || tripPlan?.isPlanning == true {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 1
        }
        if defaults.bool(forKey: "planLarge") { planDetent = .large }
        if defaults.bool(forKey: "planOpenFirst"), let first = tripPlan?.plan?.journeys.first {
            tripPlan?.openID = first.id
        }
        guard scene == .trackedJourney, let model = tripPlan, let plan = model.plan else { return }
        let now = AppClock.now
        if let journey = plan.recommended ?? plan.journeys.first(where: { model.canTrack($0, at: now) }) {
            await model.track(journey)
        }
        // `-openTripAfter <seconds>`: then the tracked train's stops, with the rest of the trip.
        let wait = defaults.double(forKey: "openTripAfter")
        if wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
            openTrackedTrip()
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

/// Behind the search bar along the bottom: the map blurred, more and more from about
/// the top of the bar down to about its bottom, and fully below that. As tall as the
/// bar's part of the safe area plus a little, less a fifth of that. While the keyboard
/// is up, the bar rides on it and its part of the safe area takes in the keyboard: the
/// blur then reaches down behind the keyboard, but starts and gets to full where it
/// would without it, by the bar. No tint, so the map keeps its colours, in dark mode
/// too (see `ProgressiveBlur`). It takes no touches, so the map still pans under it.
/// With Reduce Transparency on, none.
private struct SearchBarBlur: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// The bottom safe area with the keyboard down: the bar's own.
    @State private var barInset: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let inset = proxy.safeAreaInsets.bottom
            let bar = barInset ?? inset
            // Its height without the keyboard, and with it (reaching down behind it).
            let bare = 0.8 * (bar + 14)
            let height = max(1, bare + inset - bar)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if !reduceTransparency {
                    ProgressiveBlur(radius: 10, fullAt: min(1, 0.75 * bare / height))
                        .frame(height: height)
                }
            }
            .ignoresSafeArea()
            .onChange(of: inset, initial: true) { _, inset in
                // The keyboard adds a couple of hundred points at least; anything less
                // is the bar's own. (Going by the keyboard's notifications didn't work:
                // on the simulator, the safe area had taken it in before they got here.)
                if let barInset, inset > barInset + 150 { return }
                barInset = inset
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
