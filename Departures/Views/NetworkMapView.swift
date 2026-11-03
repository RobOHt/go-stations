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

    @State private var zoom = MapZoom(span: RailNetwork.overviewRegion.span.latitudeDelta)
    /// MapKit's own selection, so tapping a station doesn't need a Button
    /// (a Button swallows touches, which broke pinch-to-zoom over stations).
    @State private var mapSelection: String?

    private let network = RailNetwork.shared

    private var showNames: Bool { zoom <= .city }

    var body: some View {
        // North stays up: no rotating or tilting, just pan and zoom.
        Map(position: $position, bounds: RailNetwork.cameraBounds, interactionModes: [.pan, .zoom],
            selection: $mapSelection, scope: scope) {
            // White casing first so overlapping lines stay readable.
            ForEach(network.trackPaths) { path in
                MapPolyline(coordinates: path.coordinates)
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: zoom.casingWidth, lineCap: .round, lineJoin: .round))
            }
            .mapOverlayLevel(level: .aboveRoads)

            ForEach(network.trackPaths) { path in
                MapPolyline(coordinates: path.coordinates)
                    .stroke(path.color, style: StrokeStyle(lineWidth: zoom.lineWidth, lineCap: .round, lineJoin: .round))
            }
            .mapOverlayLevel(level: .aboveRoads)

            ForEach(network.stations) { station in
                Annotation(station.name, coordinate: station.coordinate, anchor: .center) {
                    StationDot(
                        isSelected: station.code == selectedCode,
                        role: role(for: station),
                        zoom: zoom
                    )
                    .accessibilityLabel(station.name)
                    .accessibilityAddTraits(.isButton)
                }
                .tag(station.code)
                .annotationTitles(showNames || station.code == selectedCode ? .visible : .hidden)
            }

            UserAnnotation()
        }
        .ignoresSafeArea()
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls {
            MapScaleView()
        }
        .onMapCameraChange(frequency: .continuous) { context in
            // Only re-render the dots when the zoom crosses a step.
            let newZoom = MapZoom(span: context.region.span.latitudeDelta)
            if newZoom != zoom { zoom = newZoom }
        }
        .onChange(of: mapSelection) { _, code in
            guard let code else { return }
            // Hand the tap to the app and clear MapKit's selection so the same
            // station can be tapped again later.
            mapSelection = nil
            if let station = network.station(code) {
                onSelect(station)
            }
        }
    }

    private func role(for station: Station) -> StationDot.Role {
        if station.code == homeCode { return .home }
        if station.code == workCode { return .work }
        return .plain
    }
}

/// Zoom steps, from street level out to the whole network.
enum MapZoom: Int, Comparable {
    case street, city, region, network, province

    init(span latitudeDelta: Double) {
        switch latitudeDelta {
        case ..<0.08: self = .street
        case ..<0.22: self = .city
        case ..<0.5: self = .region
        case ..<1.0: self = .network
        default: self = .province
        }
    }

    static func < (lhs: MapZoom, rhs: MapZoom) -> Bool { lhs.rawValue < rhs.rawValue }

    var dotSize: CGFloat {
        switch self {
        case .street: return 16
        case .city: return 13
        case .region: return 9
        case .network: return 6.5
        case .province: return 5
        }
    }

    var dotBorder: CGFloat {
        switch self {
        case .street: return 3.5
        case .city: return 3
        case .region: return 2
        case .network: return 1.5
        case .province: return 1.2
        }
    }

    var lineWidth: CGFloat {
        switch self {
        case .street: return 6
        case .city: return 5.5
        case .region: return 4.2
        case .network: return 3
        case .province: return 2.4
        }
    }

    var casingWidth: CGFloat { lineWidth + (self <= .city ? 3.5 : 2) }
}

struct StationDot: View {
    enum Role { case plain, home, work }

    let isSelected: Bool
    let role: Role
    var zoom: MapZoom = .city

    private var size: CGFloat {
        isSelected ? min(22, max(12, zoom.dotSize + 7)) : zoom.dotSize
    }

    private var border: CGFloat {
        isSelected ? max(2.5, zoom.dotBorder + 1) : zoom.dotBorder
    }

    private var showsRole: Bool {
        role != .plain && size >= 13
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(.white)
            Circle()
                .strokeBorder(Color(hex: 0x1C1C1E), lineWidth: border)
            if showsRole {
                Image(systemName: role == .home ? "house.fill" : "briefcase.fill")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(Color(hex: 0x1C1C1E))
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(zoom <= .city ? 0.25 : 0.15), radius: zoom <= .city ? 1.5 : 0.8, y: 0.5)
        .frame(width: max(size + 14, 22), height: max(size + 14, 22))
        .contentShape(Circle())
        .animation(.snappy, value: isSelected)
        .animation(.snappy, value: zoom)
    }
}
