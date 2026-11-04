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

enum StationRole {
    case plain, home, work

    /// Apple Maps colours: home blue, work brown (same as `RoleColor`).
    var uiColor: UIColor { self == .work ? .systemBrown : .systemBlue }
    var symbolName: String { self == .work ? "briefcase.fill" : "house.fill" }
}

// MARK: - Camera control from SwiftUI

/// Lets SwiftUI move the map's camera. Commands sent before the map has a size
/// are held until its first layout.
@MainActor
final class MapController {
    fileprivate weak var mapView: MKMapView?
    private var pending: ((MKMapView) -> Void)?
    /// Where the last camera move meant to put a point, checked once the move ends.
    private var goal: (point: MKMapPoint, target: CGPoint, issued: Date)?
    /// A finger is on the map, or just left it: automatic camera moves wait.
    private var isTouching = false
    private var lastTouch: Date = .distantPast

    private var userIsIdle: Bool {
        !isTouching && Date().timeIntervalSince(lastTouch) > 1.5
    }

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

    /// Room the search bar takes at the bottom of the screen.
    private static let searchBarRoom = BottomBarMetrics.typicalRoom

    /// Shows `coordinate` with about `width` metres across, in the middle of the
    /// part of the map you can see: below the Dynamic Island and above the
    /// half-height sheet (or above the search bar when no sheet is up).
    func show(_ coordinate: CLLocationCoordinate2D, width: CLLocationDistance = 5_000, sheetOpen: Bool) {
        perform { mapView in
            let size = mapView.bounds.size
            let visibleTop = Self.topInset(of: mapView)
            let visibleBottom = sheetOpen ? size.height * 0.5 : size.height - Self.searchBarRoom
            let target = CGPoint(x: size.width / 2, y: (visibleTop + visibleBottom) / 2)
            let mapPerPoint = width * MKMapPointsPerMeterAtLatitude(coordinate.latitude) / Double(size.width)
            self.place(MKMapPoint(coordinate), at: target, mapPerPoint: mapPerPoint, in: mapView)
        }
    }

    /// Fits all `coordinates` in the part of the map above the bottom `coveredFraction`
    /// (search results or a sheet), at least `minWidth` metres across.
    func frame(_ coordinates: [CLLocationCoordinate2D], minWidth: CLLocationDistance = 3_000,
               coveredFraction: CGFloat = 0.45) {
        // Search results arriving never yank the map out from under a pinch or drag.
        guard let first = coordinates.first, userIsIdle else { return }
        perform { mapView in
            let points = coordinates.map { MKMapPoint($0) }
            let minX = points.map(\.x).min() ?? 0, maxX = points.map(\.x).max() ?? 0
            let minY = points.map(\.y).min() ?? 0, maxY = points.map(\.y).max() ?? 0
            let minSize = MKMapPointsPerMeterAtLatitude(first.latitude) * minWidth
            let width = max(maxX - minX, minSize)
            let height = max(maxY - minY, minSize)

            let size = mapView.bounds.size
            let top = Self.topInset(of: mapView) + 48
            let bottom = max(top + 80, size.height * (1 - coveredFraction) - 24)
            let left: CGFloat = 40
            let right = size.width - 40
            let mapPerPoint = max(width / Double(right - left), height / Double(bottom - top))
            let target = CGPoint(x: (left + right) / 2, y: (top + bottom) / 2)
            self.place(MKMapPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2), at: target,
                       mapPerPoint: mapPerPoint, in: mapView)
        }
    }

    /// The status bar / Dynamic Island inset, whatever safe area SwiftUI gives the map.
    private static func topInset(of mapView: MKMapView) -> CGFloat {
        max(mapView.window?.safeAreaInsets.top ?? 0, mapView.safeAreaInsets.top)
    }

    /// Moves the camera so `point` lands at `target` (in the map view's points),
    /// at `mapPerPoint` map units per point.
    ///
    /// MapKit's visible rect may not span the whole view (it can leave out the
    /// layout margins), so first measure which part of the screen it covers right
    /// now, then build the new rect in those same terms. Once the move ends,
    /// `checkPlacement` confirms the point really landed there.
    private func place(_ point: MKMapPoint, at target: CGPoint, mapPerPoint: Double, in mapView: MKMapView) {
        let current = mapView.visibleMapRect
        let topLeft = mapView.convert(MKMapPoint(x: current.minX, y: current.minY).coordinate, toPointTo: mapView)
        let bottomRight = mapView.convert(MKMapPoint(x: current.maxX, y: current.maxY).coordinate, toPointTo: mapView)
        var box = CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
        if !(box.width > 1 && box.height > 1) || !box.origin.x.isFinite || !box.origin.y.isFinite {
            box = mapView.bounds
        }

        let rect = MKMapRect(
            x: point.x - Double(target.x - box.minX) * mapPerPoint,
            y: point.y - Double(target.y - box.minY) * mapPerPoint,
            width: Double(box.width) * mapPerPoint,
            height: Double(box.height) * mapPerPoint
        )
        goal = (point, target, Date())
        mapView.setVisibleMapRect(rect, animated: true)
    }

    /// After a camera move: if the point isn't where it was meant to be (MapKit
    /// adjusted the move), slide the map the rest of the way. Runs once per move.
    fileprivate func checkPlacement(_ mapView: MKMapView) {
        guard let goal else { return }
        let age = Date().timeIntervalSince(goal.issued)
        // A change reported right as a move starts is the previous move being cut
        // short, not this one finishing.
        guard age > 0.2 else { return }
        self.goal = nil
        guard age < 3 else { return }
        let actual = mapView.convert(goal.point.coordinate, toPointTo: mapView)
        let dx = Double(actual.x - goal.target.x)
        let dy = Double(actual.y - goal.target.y)
        guard abs(dx) > 6 || abs(dy) > 6, dx.isFinite, dy.isFinite else { return }
        let mapPerPoint = mapView.visibleMapRect.size.width / Double(max(mapView.bounds.width, 1))
        let shifted = mapView.visibleMapRect.offsetBy(dx: dx * mapPerPoint, dy: dy * mapPerPoint)
        mapView.setVisibleMapRect(shifted, animated: true)
    }

    /// You moved the map yourself, so leave it where you put it.
    fileprivate func userGesture(_ state: UIGestureRecognizer.State) {
        switch state {
        case .began:
            goal = nil
            isTouching = true
        case .ended, .cancelled, .failed:
            isTouching = false
            lastTouch = Date()
        default:
            break
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
    /// A place picked in search, shown as a red pin.
    var place: SearchPlace? = nil
    /// Any tap on the map, station or not (used to put the keyboard away).
    var onTapMap: () -> Void = {}
    let onSelect: (Station) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // Nothing over the map at the top: built with the iOS 27 SDK, MKMapView draws
    // the system's own soft blur under the status bar, as in Apple Maps.
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
        mapView.register(RolePinView.self, forAnnotationViewWithReuseIdentifier: RolePinView.reuseID)
        mapView.register(PlacePinView.self, forAnnotationViewWithReuseIdentifier: PlacePinView.reuseID)
        coordinator.installOverlays(on: mapView)
        mapView.addAnnotations(RailNetwork.shared.stations.map { StationAnnotation(station: $0) })
        coordinator.syncRolePins(in: mapView)

        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = coordinator
        mapView.addGestureRecognizer(tap)

        // Watch (never block) pans and pinches, so a camera move you interrupt
        // isn't "corrected" afterwards.
        for watcher in [UIPanGestureRecognizer(), UIPinchGestureRecognizer()] {
            watcher.addTarget(coordinator, action: #selector(Coordinator.userMovedMap(_:)))
            watcher.delegate = coordinator
            watcher.cancelsTouchesInView = false
            mapView.addGestureRecognizer(watcher)
        }

        // Apple's logo and Legal link sit inside the layout margins: keep them just
        // above the search bar. These margins never change afterwards, because
        // MapKit treats them as covered space and re-centres the map when they do.
        mapView.insetsLayoutMarginsFromSafeArea = false
        mapView.layoutMargins = UIEdgeInsets(
            top: 8, left: 8,
            bottom: BottomBarMetrics.maximumRoom,
            right: 8
        )

        mapView.onLayout = { [weak coordinator, weak mapView] in
            guard let coordinator, let mapView else { return }
            coordinator.mapDidLayout(mapView)
        }

        coordinator.controller = controller
        controller.attach(mapView)
        coordinator.syncPlace(place, in: mapView)
        return mapView
    }

    func updateUIView(_ mapView: LayoutAwareMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.controller = controller
        if coordinator.update(from: self) {
            coordinator.syncRolePins(in: mapView)
            coordinator.refreshStations(in: mapView)
        }
        coordinator.syncPlace(place, in: mapView)
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var controller: MapController?

        private var onSelect: (Station) -> Void = { _ in }
        private var onTapMap: () -> Void = {}
        private var placePin: PlaceAnnotation?
        private var selectedCode: String?
        private var homeCode: String?
        private var workCode: String?
        private var zoom = MapZoom(span: RailNetwork.overviewRegion.span.latitudeDelta)
        private var renderers: [ObjectIdentifier: MKPolylineRenderer] = [:]
        private var didInitialLayout = false
        private var didSetZoomRange = false
        private var rolePins: [RoleAnnotation] = []

        /// Returns true when anything the station dots depend on changed.
        func update(from view: NetworkMapView) -> Bool {
            onSelect = view.onSelect
            onTapMap = view.onTapMap
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

        /// Home and work get a pin above their station dot.
        func syncRolePins(in mapView: MKMapView) {
            let network = RailNetwork.shared
            var wanted: [(Station, StationRole)] = []
            if let home = homeCode.flatMap(network.station) { wanted.append((home, .home)) }
            if let work = workCode.flatMap(network.station) { wanted.append((work, .work)) }

            let current = rolePins.map { "\($0.station.code)|\($0.role)" }
            let next = wanted.map { "\($0.0.code)|\($0.1)" }
            guard current != next else { return }

            mapView.removeAnnotations(rolePins)
            rolePins = wanted.map { RoleAnnotation(station: $0.0, role: $0.1) }
            mapView.addAnnotations(rolePins)
        }

        /// Shows, moves or removes the search pin.
        func syncPlace(_ place: SearchPlace?, in mapView: MKMapView) {
            if let current = placePin, let place, current.place == place { return }
            if let current = placePin {
                mapView.removeAnnotation(current)
                placePin = nil
            }
            if let place {
                let pin = PlaceAnnotation(place: place)
                placePin = pin
                mapView.addAnnotation(pin)
            }
        }

        private func configure(_ view: RolePinView, for pin: RoleAnnotation) {
            let isSelected = pin.station.code == selectedCode
            let dotSize = isSelected ? min(22, max(12, zoom.dotSize + 7)) : zoom.dotSize
            // Home and work at the same station: place the two pins side by side.
            let shared = homeCode != nil && homeCode == workCode
            let xOffset: CGFloat = shared ? (pin.role == .home ? -17 : 17) : 0
            view.configure(role: pin.role, tipGap: dotSize / 2 + 1, xOffset: xOffset)
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
            for annotation in mapView.annotations {
                if let annotation = annotation as? StationAnnotation,
                   let view = mapView.view(for: annotation) as? StationAnnotationView {
                    configure(view, for: annotation.station)
                } else if let pin = annotation as? RoleAnnotation,
                          let view = mapView.view(for: pin) as? RolePinView {
                    configure(view, for: pin)
                }
            }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let mapView = recognizer.view as? MKMapView else { return }
            onTapMap()
            let point = recognizer.location(in: mapView)
            for pin in rolePins {
                guard let view = mapView.view(for: pin) else { continue }
                let frame = view.convert(view.bounds, to: mapView).insetBy(dx: -8, dy: -8)
                if frame.contains(point) {
                    onSelect(pin.station)
                    return
                }
            }
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
            if let place = annotation as? PlaceAnnotation {
                return mapView.dequeueReusableAnnotationView(withIdentifier: PlacePinView.reuseID, for: place)
            }
            if let pin = annotation as? RoleAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: RolePinView.reuseID, for: pin)
                guard let pinView = view as? RolePinView else { return view }
                configure(pinView, for: pin)
                return pinView
            }
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

        @objc func userMovedMap(_ recognizer: UIGestureRecognizer) {
            controller?.userGesture(recognizer.state)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            controller?.checkPlacement(mapView)
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

final class PlaceAnnotation: NSObject, MKAnnotation {
    let place: SearchPlace
    let coordinate: CLLocationCoordinate2D

    init(place: SearchPlace) {
        self.place = place
        self.coordinate = place.coordinate
    }

    var title: String? { place.name }
}

/// The red Apple Maps-style pin for a searched place. Like the station dots it
/// ignores touches, so gestures always reach the map.
final class PlacePinView: MKMarkerAnnotationView {
    static let reuseID = "place"

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        isUserInteractionEnabled = false
        isEnabled = false
        canShowCallout = false
        markerTintColor = .systemRed
        titleVisibility = .hidden
        subtitleVisibility = .hidden
        displayPriority = .required
        zPriority = .max
        animatesWhenAdded = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A station dot with an optional name tag. It never takes touches: the map
/// handles every gesture and picks stations on tap.
final class StationAnnotationView: MKAnnotationView {
    static let reuseID = "station"
    private static let ink = UIColor(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1)

    private let dot = CAShapeLayer()
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

        let showsName = isSelected || zoom <= .city
        nameTag.isHidden = !showsName
        if showsName {
            nameTag.text = name
            nameTag.font = .systemFont(ofSize: isSelected ? 12 : 11, weight: isSelected ? .bold : .semibold)
            let tagSize = nameTag.intrinsicContentSize
            nameTag.frame = CGRect(x: (size - tagSize.width) / 2, y: size + 3,
                                   width: tagSize.width, height: tagSize.height)
        }

        zPriority = MKAnnotationViewZPriority(rawValue: isSelected ? 900 : (role == .plain ? 500 : 600))
        accessibilityLabel = name
    }
}

final class RoleAnnotation: NSObject, MKAnnotation {
    let station: Station
    let role: StationRole
    let coordinate: CLLocationCoordinate2D

    init(station: Station, role: StationRole) {
        self.station = station
        self.role = role
        self.coordinate = station.coordinate
    }

    var title: String? { role == .home ? "Home: \(station.name)" : "Work: \(station.name)" }
}

/// A round home/work badge with a small triangle pointing down at the station dot.
/// Same size at every zoom level. Like the dots it never takes touches; the map's
/// tap handler checks pins first.
/// The home/work marker: Apple Maps' balloon pin (a round head with a point
/// underneath), blue for home and brown for work, with a white glyph. It stays
/// the same size at every zoom, and its point sits just above the station dot.
final class RolePinView: MKAnnotationView {
    static let reuseID = "role"
    private static let headSize: CGFloat = 30
    private static let pointLength: CGFloat = 7

    private let balloon = CAShapeLayer()
    private let icon = UIImageView()
    private var role: StationRole = .home

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        isUserInteractionEnabled = false
        isEnabled = false
        canShowCallout = false
        displayPriority = .required
        collisionMode = .none
        backgroundColor = .clear

        let side = Self.headSize
        bounds = CGRect(x: 0, y: 0, width: side, height: side + Self.pointLength)

        balloon.path = Self.balloonPath().cgPath
        balloon.strokeColor = UIColor.black.withAlphaComponent(0.12).cgColor
        balloon.lineWidth = 0.5
        layer.addSublayer(balloon)

        icon.frame = CGRect(x: 0, y: 0, width: side, height: side)
        icon.contentMode = .center
        icon.tintColor = .white
        addSubview(icon)

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.28
        layer.shadowRadius = 2.5
        layer.shadowOffset = CGSize(width: 0, height: 1.5)
        layer.shadowPath = balloon.path

        // Layer colours don't follow light/dark mode by themselves.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (pin: RolePinView, _) in
            pin.applyColor()
        }
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A circle with its two tangents meeting at a point below it.
    private static func balloonPath() -> UIBezierPath {
        let radius = headSize / 2
        let center = CGPoint(x: radius, y: radius)
        let point = CGPoint(x: radius, y: headSize + pointLength)
        let reach = radius + pointLength
        // Where the tangent lines from the point touch the circle.
        let spread = CGFloat.pi / 2 - asin(radius / reach)
        let right = CGFloat.pi / 2 - spread
        let left = CGFloat.pi / 2 + spread

        let path = UIBezierPath()
        path.move(to: point)
        path.addLine(to: CGPoint(x: center.x + radius * cos(right), y: center.y + radius * sin(right)))
        path.addArc(withCenter: center, radius: radius, startAngle: right, endAngle: left, clockwise: false)
        path.close()
        return path
    }

    /// Puts the balloon's point `tipGap` points above the station's centre.
    func configure(role: StationRole, tipGap: CGFloat, xOffset: CGFloat) {
        isUserInteractionEnabled = false
        self.role = role
        applyColor()
        icon.image = UIImage(
            systemName: role.symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        )
        centerOffset = CGPoint(x: xOffset, y: -(bounds.height / 2 + tipGap))
        zPriority = MKAnnotationViewZPriority(rawValue: 800)
        accessibilityLabel = role == .work ? "Work station" : "Home station"
    }

    private func applyColor() {
        balloon.fillColor = role.uiColor.resolvedColor(with: traitCollection).cgColor
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
