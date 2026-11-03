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
    @State private var pendingAutoSelect = false
    @AppStorage("hasSeenSetup") private var hasSeenSetup = false

    private let network = RailNetwork.shared

    var body: some View {
        NetworkMapView(
            controller: mapController,
            selectedCode: selected?.code,
            homeCode: settings.homeCode,
            workCode: settings.workCode
        ) { station in
            select(station, detent: .medium)
        }
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) { controls }
        .sheet(isPresented: stationSheetPresented) {
            if let selected {
                StationSheet(station: selected) { self.selected = nil }
                    .presentationDetents([.medium, .large], selection: $detent)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            // First run: once the key is in, open the board you most likely want.
            guard pendingAutoSelect, settings.hasAPIKey else { return }
            pendingAutoSelect = false
            Task { await autoSelect() }
        }) {
            SettingsView()
        }
        .task {
            // Only push Settings on the very first launch; after that the station
            // sheet shows a "add your key" card until there is one.
            if !settings.hasAPIKey, !hasSeenSetup {
                hasSeenSetup = true
                pendingAutoSelect = true
                showSettings = true
            }
            await autoSelect()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                backgroundedAt = .now
            case .active:
                settings.reloadFromCloud()
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

    // MARK: Floating controls

    private var controls: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                Button {
                    Task { await showMyLocation() }
                } label: {
                    Image(systemName: "location.fill")
                        .frame(width: 24, height: 24)
                }
                .accessibilityLabel("Show my location")

                if let home = settings.homeCode.flatMap(network.station) {
                    Button {
                        select(home, detent: .large)
                    } label: {
                        Image(systemName: "house.fill")
                            .frame(width: 24, height: 24)
                    }
                    .accessibilityLabel("Home station: \(home.name)")
                }

                if let work = settings.workCode.flatMap(network.station) {
                    Button {
                        select(work, detent: .large)
                    } label: {
                        Image(systemName: "briefcase.fill")
                            .frame(width: 24, height: 24)
                    }
                    .accessibilityLabel("Work station: \(work.name)")
                }

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
        .padding(.trailing, 14)
        .padding(.top, 8)
    }

    // MARK: Actions

    private func select(_ station: Station, detent newDetent: PresentationDetent) {
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

        // SwiftUI can't show the station sheet on top of Settings, and there's
        // no board to show without a key.
        var board: Station?
        if settings.hasAPIKey, !showSettings {
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
