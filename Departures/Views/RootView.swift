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
    @State private var backgroundedAt: Date?

    @State private var search = PlaceSearchModel()
    @FocusState private var searchFocused: Bool
    /// Top edge of the station sheet on screen, so the buttons can sit just above it.
    @State private var sheetTop: CGFloat?
    /// Bottom edge of the area the floating UI lives in: the screen's bottom edge, or the keyboard's top.
    @State private var floatingBottom: CGFloat = 0
    @State private var panelHeight: CGFloat = 0

    private let network = RailNetwork.shared

    var body: some View {
        NetworkMapView(
            controller: mapController,
            selectedCode: selected?.code,
            homeCode: settings.homeCode,
            workCode: settings.workCode,
            place: search.place,
            onTapMap: { searchFocused = false },
            onSelect: { station in select(station, detent: .medium) }
        )
        .ignoresSafeArea()
        .overlay { floatingUI }
        .sheet(isPresented: stationSheetPresented) {
            if let selected {
                StationSheet(station: selected)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { sheetTop = $0 }
                    .presentationDetents([.medium, .large], selection: $detent)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationDragIndicator(.visible)
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
            mapController.frame([place.coordinate], minWidth: 4_000)
        }
        .onChange(of: search.nearby.map(\.id)) { _, ids in
            guard let place = search.place, !ids.isEmpty else { return }
            mapController.frame([place.coordinate] + search.nearby.map(\.station.coordinate))
        }
        .task {
            // Keep the fallback timetable fresh in the background.
            Task.detached(priority: .background) { await ScheduleStore.shared.refreshIfNeeded() }
            await autoSelect()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                backgroundedAt = .now
            case .active:
                settings.reloadFromCloud()
                Task.detached(priority: .background) { await ScheduleStore.shared.refreshIfNeeded() }
                if let backgroundedAt, Date.now.timeIntervalSince(backgroundedAt) > 180 {
                    Task { await autoSelect() }
                }
                backgroundedAt = nil
            default:
                break
            }
        }
    }

    private var stationSheetPresented: Binding<Bool> {
        Binding(
            get: { selected != nil },
            set: { if !$0 { selected = nil } }
        )
    }

    // MARK: Floating controls and search

    private var searchActive: Bool {
        searchFocused || search.hasQuery || search.place != nil
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

    private var floatingSideInset: CGFloat {
        searchFocused && selected == nil ? BottomBarMetrics.focusedSideInset : BottomBarMetrics.edgeInset
    }

    /// Bottom spacing, from the screen edge (or the keyboard's top while typing).
    private var floatingBottomPadding: CGFloat {
        if let sheetLift { return sheetLift + 12 }
        return searchFocused ? BottomBarMetrics.keyboardGap : BottomBarMetrics.edgeInset
    }

    /// The four buttons, bottom right, sitting on the search bar (or on the sheet
    /// when a station is open), with the search bar along the bottom.
    private var floatingUI: some View {
        VStack(alignment: .trailing, spacing: 12) {
            Spacer(minLength: 0)
            if showsControls {
                controls
                    .transition(.scale(scale: 0.85, anchor: .bottomTrailing).combined(with: .opacity))
            }
            if selected == nil {
                SearchPanel(model: search, isFocused: $searchFocused) { station in
                    openFromSearch(station)
                }
                .layoutPriority(1)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, floatingSideInset)
        .padding(.bottom, floatingBottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        // Like system bars, measure from the screen's bottom edge rather than the
        // home-indicator safe area. The keyboard still pushes everything up.
        .ignoresSafeArea(.container, edges: .bottom)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { floatingBottom = $0 }
        .animation(.smooth(duration: 0.35), value: searchFocused)
        .animation(.smooth(duration: 0.3), value: selected == nil)
        .animation(.smooth(duration: 0.3), value: showsControls)
        .animation(.smooth(duration: 0.25), value: sheetLift)
    }

    private var controls: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                if let home = settings.homeCode.flatMap(network.station) {
                    Button {
                        select(home, detent: .medium)
                    } label: {
                        Image(systemName: "house.fill")
                            .foregroundStyle(RoleColor.home)
                            .frame(width: 24, height: 24)
                    }
                    .accessibilityLabel("Home station: \(home.name)")
                }

                if let work = settings.workCode.flatMap(network.station) {
                    Button {
                        select(work, detent: .medium)
                    } label: {
                        Image(systemName: "briefcase.fill")
                            .foregroundStyle(RoleColor.work)
                            .frame(width: 24, height: 24)
                    }
                    .accessibilityLabel("Work station: \(work.name)")
                }

                Button {
                    Task { await showMyLocation() }
                } label: {
                    Image(systemName: "location.fill")
                        .frame(width: 24, height: 24)
                }
                .accessibilityLabel("Show my location")

                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .frame(width: 24, height: 24)
                }
                .accessibilityLabel("Settings")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
        }
    }

    // MARK: Actions

    private func openFromSearch(_ station: Station) {
        searchFocused = false
        // A station picked by name is done with; nearby results for a place stay
        // so you can come back and compare the other stations.
        if search.place == nil { search.clear() }
        select(station, detent: .medium)
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

    /// Centres the map on you, and opens the board you most likely want: the
    /// station you're standing at, otherwise whichever of home/work is closer.
    private func autoSelect() async {
        let here = await LocationProvider.shared.currentLocation()

        // SwiftUI can't show the station sheet on top of Settings.
        var board: Station?
        if !showSettings {
            board = here.flatMap(bestStation(near:)) ?? settings.homeCode.flatMap(network.station)
        }

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
