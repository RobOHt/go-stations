import MapKit
import SwiftUI
import UIKit

// MARK: - Zoom steps

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

enum StationRole { case plain, home, work }

// MARK: - Camera control from SwiftUI

/// Lets SwiftUI move the map's camera. Commands sent before the map has a size
/// are held until its first layout.
@MainActor
final class MapController {
    fileprivate weak var mapView: MKMapView?
    private var pending: ((MKMapView) -> Void)?

    fileprivate func attach(_ mapView: MKMapView) {
        self.mapView = mapView
    }

    fileprivate func flushPending() {
        guard let mapView, !mapView.bounds.isEmpty, let action = pending else { return }
        pending = nil
        action(mapView)
    }

    private func perform(_ action: @escaping (MKMapView) -> Void) {
        if let mapView, !mapView.bounds.isEmpty {
            action(mapView)
        } else {
            pending = action
        }
    }

    /// Shows `coordinate` with about `width` metres across. With a half-height
    /// sheet up, the point lands in the visible top half of the screen.
    func show(_ coordinate: CLLocationCoordinate2D, width: CLLocationDistance = 5_000, sheetOpen: Bool) {
        perform { mapView in
            let size = MKMapPointsPerMeterAtLatitude(coordinate.latitude) * width
            let point = MKMapPoint(coordinate)
            let rect = MKMapRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
            let insets = UIEdgeInsets(
                top: mapView.safeAreaInsets.top,
                left: 0,
                bottom: sheetOpen ? mapView.bounds.height * 0.5 : mapView.safeAreaInsets.bottom,
                right: 0
            )
            mapView.setVisibleMapRect(rect, edgePadding: insets, animated: true)
        }
    }
}

// MARK: - Map

/// Apple Maps (UIKit's MKMapView) with the GO rail lines in their official colours,
/// a dot per station, and your location. North stays up; the camera is kept to
/// southern Ontario. Station dots ignore touches so pinch and pan work anywhere,
/// and taps are matched to the nearest station by the map itself.
struct NetworkMapView: UIViewRepresentable {
    let controller: MapController
    let selectedCode: String?
    let homeCode: String?
    let workCode: String?
    let onSelect: (Station) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> LayoutAwareMapView {
        let coordinator = context.coordinator
        _ = coordinator.update(from: self)

        let mapView = LayoutAwareMapView()
        mapView.delegate = coordinator

        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        configuration.showsTraffic = false
        mapView.preferredConfiguration = configuration

        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.showsCompass = false
        mapView.showsUserLocation = true

        let boundary: MKMapView.CameraBoundary? = MKMapView.CameraBoundary(coordinateRegion: RailNetwork.cameraCenterLimit)
        if let boundary {
            mapView.cameraBoundary = boundary
        }

        mapView.register(StationAnnotationView.self, forAnnotationViewWithReuseIdentifier: StationAnnotationView.reuseID)
        coordinator.installOverlays(on: mapView)
        mapView.addAnnotations(RailNetwork.shared.stations.map { StationAnnotation(station: $0) })

        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = coordinator
        mapView.addGestureRecognizer(tap)

        mapView.onLayout = { [weak coordinator, weak mapView] in
            guard let coordinator, let mapView else { return }
            coordinator.mapDidLayout(mapView)
        }

        coordinator.controller = controller
        controller.attach(mapView)
        return mapView
    }

    func updateUIView(_ mapView: LayoutAwareMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.controller = controller
        if coordinator.update(from: self) {
            coordinator.refreshStations(in: mapView)
        }
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var controller: MapController?

        private var onSelect: (Station) -> Void = { _ in }
        private var selectedCode: String?
        private var homeCode: String?
        private var workCode: String?
        private var zoom = MapZoom(span: RailNetwork.overviewRegion.span.latitudeDelta)
        private var renderers: [ObjectIdentifier: MKPolylineRenderer] = [:]
        private var didInitialLayout = false
        private var didSetZoomRange = false

        /// Returns true when anything the station dots depend on changed.
        func update(from view: NetworkMapView) -> Bool {
            onSelect = view.onSelect
            let changed = selectedCode != view.selectedCode
                || homeCode != view.homeCode
                || workCode != view.workCode
            selectedCode = view.selectedCode
            homeCode = view.homeCode
            workCode = view.workCode
            return changed
        }

        // MARK: Setup

        func installOverlays(on mapView: MKMapView) {
            let paths = RailNetwork.shared.trackPaths.filter { $0.coordinates.count >= 2 }
            // White casing first so overlapping lines stay readable.
            mapView.addOverlays(paths.map { TrackPolyline.make($0, casing: true) }, level: .aboveRoads)
            mapView.addOverlays(paths.map { TrackPolyline.make($0, casing: false) }, level: .aboveRoads)
        }

        func mapDidLayout(_ mapView: MKMapView) {
            if !didInitialLayout {
                didInitialLayout = true
                mapView.setRegion(RailNetwork.overviewRegion, animated: false)
            }
            controller?.flushPending()
        }

        /// Caps how far out you can zoom: about `RailNetwork.maxVisibleWidth` across.
        /// MapKit limits zoom by camera distance, so measure how distance relates to
        /// visible width on this screen and convert.
        private func setZoomRangeIfNeeded(_ mapView: MKMapView) {
            guard !didSetZoomRange, mapView.bounds.width > 0 else { return }
            let span = mapView.region.span
            guard span.latitudeDelta > 0, span.latitudeDelta < 5 else { return }
            let widthInMetres = mapView.visibleMapRect.size.width
                / MKMapPointsPerMeterAtLatitude(mapView.centerCoordinate.latitude)
            let distance = mapView.camera.centerCoordinateDistance
            guard widthInMetres > 0, distance > 0 else { return }

            let maxDistance = RailNetwork.maxVisibleWidth * (distance / widthInMetres)
            let range: MKMapView.CameraZoomRange? = MKMapView.CameraZoomRange(
                minCenterCoordinateDistance: 250,
                maxCenterCoordinateDistance: maxDistance
            )
            if let range {
                didSetZoomRange = true
                mapView.setCameraZoomRange(range, animated: true)
            }
        }

        // MARK: Stations

        private func role(for station: Station) -> StationRole {
            if station.code == homeCode { return .home }
            if station.code == workCode { return .work }
            return .plain
        }

        private func configure(_ view: StationAnnotationView, for station: Station) {
            view.configure(
                zoom: zoom,
                isSelected: station.code == selectedCode,
                role: role(for: station),
                name: station.name
            )
        }

        func refreshStations(in mapView: MKMapView) {
            for case let annotation as StationAnnotation in mapView.annotations {
                if let view = mapView.view(for: annotation) as? StationAnnotationView {
                    configure(view, for: annotation.station)
                }
            }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let mapView = recognizer.view as? MKMapView else { return }
            let point = recognizer.location(in: mapView)
            var best: (station: Station, distance: CGFloat)?
            for station in RailNetwork.shared.stations {
                let stationPoint = mapView.convert(station.coordinate, toPointTo: mapView)
                let distance = hypot(stationPoint.x - point.x, stationPoint.y - point.y)
                if distance < (best?.distance ?? .greatestFiniteMagnitude) {
                    best = (station, distance)
                }
            }
            let reach = max(24, zoom.dotSize / 2 + 18)
            if let best, best.distance <= reach {
                onSelect(best.station)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? StationAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: StationAnnotationView.reuseID, for: annotation)
            guard let stationView = view as? StationAnnotationView else { return view }
            configure(stationView, for: annotation.station)
            return stationView
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let track = overlay as? TrackPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: track)
            renderer.strokeColor = track.isCasing ? UIColor.white.withAlphaComponent(0.9) : track.color
            renderer.lineWidth = track.isCasing ? zoom.casingWidth : zoom.lineWidth
            renderer.lineCap = .round
            renderer.lineJoin = .round
            renderers[ObjectIdentifier(track)] = renderer
            return renderer
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            setZoomRangeIfNeeded(mapView)

            // Only re-render when the zoom crosses a step.
            let newZoom = MapZoom(span: mapView.region.span.latitudeDelta)
            guard newZoom != zoom else { return }
            zoom = newZoom
            refreshStations(in: mapView)
            for renderer in renderers.values {
                guard let track = renderer.polyline as? TrackPolyline else { continue }
                renderer.lineWidth = track.isCasing ? zoom.casingWidth : zoom.lineWidth
                renderer.setNeedsDisplay()
            }
        }
    }
}

/// MKMapView that reports layout, so camera commands wait until it has a size.
final class LayoutAwareMapView: MKMapView {
    var onLayout: (() -> Void)?
    private var lastSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        onLayout?()
    }
}

// MARK: - Overlays and annotations

final class TrackPolyline: MKPolyline {
    private(set) var color: UIColor = .gray
    private(set) var isCasing = false

    static func make(_ path: TrackPath, casing: Bool) -> TrackPolyline {
        let polyline = TrackPolyline(coordinates: path.coordinates, count: path.coordinates.count)
        polyline.color = path.uiColor
        polyline.isCasing = casing
        return polyline
    }
}

final class StationAnnotation: NSObject, MKAnnotation {
    let station: Station
    let coordinate: CLLocationCoordinate2D

    init(station: Station) {
        self.station = station
        self.coordinate = station.coordinate
    }

    var title: String? { station.name }
}

/// A station dot with an optional name tag. It never takes touches: the map
/// handles every gesture and picks stations on tap.
final class StationAnnotationView: MKAnnotationView {
    static let reuseID = "station"
    private static let ink = UIColor(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1)

    private let dot = CAShapeLayer()
    private let icon = UIImageView()
    private let nameTag = PaddedLabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        isUserInteractionEnabled = false
        isEnabled = false
        canShowCallout = false
        displayPriority = .required
        collisionMode = .circle
        clipsToBounds = false
        backgroundColor = .clear

        dot.fillColor = UIColor.white.cgColor
        dot.strokeColor = Self.ink.cgColor
        dot.shadowColor = UIColor.black.cgColor
        dot.shadowOffset = CGSize(width: 0, height: 0.5)
        layer.addSublayer(dot)

        icon.tintColor = Self.ink
        icon.contentMode = .center
        addSubview(icon)

        nameTag.textColor = .label
        nameTag.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.85)
        nameTag.layer.cornerRadius = 5
        nameTag.layer.masksToBounds = true
        addSubview(nameTag)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(zoom: MapZoom, isSelected: Bool, role: StationRole, name: String) {
        isUserInteractionEnabled = false

        let size = isSelected ? min(22, max(12, zoom.dotSize + 7)) : zoom.dotSize
        let border = isSelected ? max(2.5, zoom.dotBorder + 1) : zoom.dotBorder
        let box = CGRect(x: 0, y: 0, width: size, height: size)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bounds = box
        dot.frame = box
        dot.path = UIBezierPath(ovalIn: box.insetBy(dx: border / 2, dy: border / 2)).cgPath
        dot.lineWidth = border
        dot.shadowPath = UIBezierPath(ovalIn: box).cgPath
        dot.shadowOpacity = zoom <= .city ? 0.25 : 0.15
        dot.shadowRadius = zoom <= .city ? 1.5 : 0.8
        CATransaction.commit()

        let showsRole = role != .plain && size >= 13
        icon.isHidden = !showsRole
        if showsRole {
            let symbol = role == .home ? "house.fill" : "briefcase.fill"
            icon.image = UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: size * 0.42, weight: .bold)
            )
            icon.frame = box
        }

        let showsName = isSelected || zoom <= .city
        nameTag.isHidden = !showsName
        if showsName {
            nameTag.text = name
            nameTag.font = .systemFont(ofSize: isSelected ? 12 : 11, weight: isSelected ? .bold : .semibold)
            let tagSize = nameTag.intrinsicContentSize
            nameTag.frame = CGRect(x: (size - tagSize.width) / 2, y: size + 3,
                                   width: tagSize.width, height: tagSize.height)
        }

        zPriority = isSelected ? .max : (role == .plain ? .defaultUnselected : .defaultSelected)
        accessibilityLabel = name
    }
}

/// A label with a little padding, used for station name tags.
final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 2, left: 5, bottom: 2, right: 5)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right,
                      height: size.height + insets.top + insets.bottom)
    }
}
