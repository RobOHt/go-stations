import MapKit
import SwiftUI

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase

    @State private var position: MapCameraPosition = .region(RailNetwork.overviewRegion)
    @State private var selected: Station?
    @State private var detent: PresentationDetent = .medium
    @State private var showSettings = false
    @State private var backgroundedAt: Date?
    @Namespace private var mapScope

    private let network = RailNetwork.shared

    var body: some View {
        NetworkMapView(
            position: $position,
            selectedCode: selected?.code,
            homeCode: settings.homeCode,
            workCode: settings.workCode,
            scope: mapScope
        ) { station in
            select(station, detent: .medium)
        }
        .overlay(alignment: .topTrailing) { controls }
        .mapScope(mapScope)
        .sheet(isPresented: stationSheetPresented) {
            if let selected {
                StationSheet(station: selected) { self.selected = nil }
                    .presentationDetents([.medium, .large], selection: $detent)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .task {
            if settings.hasAPIKey {
                await autoSelect()
            } else {
                showSettings = true
            }
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
                MapUserLocationButton(scope: mapScope)
                    .buttonBorderShape(.circle)

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
        // Keep the station visible above the sheet.
        let center = CLLocationCoordinate2D(latitude: station.latitude - 0.012, longitude: station.longitude)
        withAnimation(.smooth(duration: 0.6)) {
            position = .region(MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 0.06, longitudeDelta: 0.06)
            ))
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

    /// Opens the board you most likely want: the station you're standing at,
    /// otherwise whichever of home/work is closer to you.
    private func autoSelect() async {
        guard let here = await LocationProvider.shared.currentLocation() else {
            if let home = settings.homeCode.flatMap(network.station) {
                select(home, detent: .large)
            }
            return
        }

        if let nearest = network.nearestStation(to: here), nearest.distance < 400 {
            select(nearest.station, detent: .large)
            return
        }

        let saved = [settings.homeCode, settings.workCode]
            .compactMap { $0 }
            .compactMap { network.station($0) }
        if let best = saved.min(by: { $0.location.distance(from: here) < $1.location.distance(from: here) }) {
            select(best, detent: .large)
        } else if let nearest = network.nearestStation(to: here), nearest.distance < 3_000 {
            select(nearest.station, detent: .medium)
        } else {
            withAnimation(.smooth) {
                position = .userLocation(fallback: .region(RailNetwork.overviewRegion))
            }
        }
    }
}
