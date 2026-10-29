import MapKit
import SwiftUI

/// Apple Maps with the GO rail lines drawn thick in their official colours,
/// a dot per station, and your location.
struct NetworkMapView: View {
    @Binding var position: MapCameraPosition
    let selectedCode: String?
    let homeCode: String?
    let workCode: String?
    let scope: Namespace.ID
    let onSelect: (Station) -> Void

    @State private var latitudeSpan: Double = RailNetwork.overviewRegion.span.latitudeDelta

    private let network = RailNetwork.shared

    private var showNames: Bool { latitudeSpan < 0.22 }
    private var zoomedOut: Bool { latitudeSpan > 0.6 }

    var body: some View {
        Map(position: $position, scope: scope) {
            // White casing first so overlapping lines stay readable.
            ForEach(network.trackPaths) { path in
                MapPolyline(coordinates: path.coordinates)
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: zoomedOut ? 6 : 9, lineCap: .round, lineJoin: .round))
            }
            .mapOverlayLevel(level: .aboveRoads)

            ForEach(network.trackPaths) { path in
                MapPolyline(coordinates: path.coordinates)
                    .stroke(path.color, style: StrokeStyle(lineWidth: zoomedOut ? 3.5 : 5.5, lineCap: .round, lineJoin: .round))
            }
            .mapOverlayLevel(level: .aboveRoads)

            ForEach(network.stations) { station in
                Annotation(station.name, coordinate: station.coordinate, anchor: .center) {
                    Button {
                        onSelect(station)
                    } label: {
                        StationDot(
                            isSelected: station.code == selectedCode,
                            role: role(for: station),
                            small: zoomedOut
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(station.name)
                }
                .annotationTitles(showNames || station.code == selectedCode ? .visible : .hidden)
            }

            UserAnnotation()
        }
        .ignoresSafeArea()
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            latitudeSpan = context.region.span.latitudeDelta
        }
    }

    private func role(for station: Station) -> StationDot.Role {
        if station.code == homeCode { return .home }
        if station.code == workCode { return .work }
        return .plain
    }
}

struct StationDot: View {
    enum Role { case plain, home, work }

    let isSelected: Bool
    let role: Role
    var small: Bool = false

    private var size: CGFloat {
        if isSelected { return 22 }
        return small ? 10 : 14
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(.white)
            Circle()
                .strokeBorder(Color(hex: 0x1C1C1E), lineWidth: isSelected ? 4 : (small ? 2 : 3))
            if role != .plain, !small || isSelected {
                Image(systemName: role == .home ? "house.fill" : "briefcase.fill")
                    .font(.system(size: isSelected ? 9 : 7, weight: .bold))
                    .foregroundStyle(Color(hex: 0x1C1C1E))
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
        .frame(width: 36, height: 36)
        .contentShape(Circle())
        .animation(.snappy, value: isSelected)
    }
}
