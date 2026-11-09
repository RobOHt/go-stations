import MapKit
import SwiftUI
import UIKit

// MARK: - Zoom steps

/// Zoom steps, from street level out to the whole network.
enum MapZoom: Int, Comparable {
    case street, city, region, network, province

    /// Where each step ends: the degrees of latitude the map spans top to bottom.
    private static let ends: [Double] = [0.08, 0.22, 0.5, 1.0]
    /// How far past its end a step lasts (see `init(span:keeping:)`).
    static let overshoot = 1.08

    init(span latitudeDelta: Double) {
        self = MapZoom(rawValue: Self.ends.firstIndex { latitudeDelta < $0 } ?? Self.ends.count) ?? .province
    }

    /// The step for a span, staying at `current` while the span is only just past
    /// the edge of it, so a pinch that hovers at the edge doesn't flip the map's
    /// dots and tags back and forth between two steps.
    init(span latitudeDelta: Double, keeping current: MapZoom) {
        let plain = MapZoom(span: latitudeDelta)
        // A little further back the way it came: still the current step?
        let back = MapZoom(span: plain > current ? latitudeDelta / Self.overshoot : latitudeDelta * Self.overshoot)
        self = back == current ? current : plain
    }

    /// The degrees of latitude the map spans where this step starts and ends (none
    /// at the ends of the range), not counting the overshoot.
    var spans: (from: Double?, to: Double?) {
        (rawValue > 0 ? Self.ends[rawValue - 1] : nil, rawValue < Self.ends.count ? Self.ends[rawValue] : nil)
    }

    static func < (lhs: MapZoom, rhs: MapZoom) -> Bool { lhs.rawValue < rhs.rawValue }

    var dotSize: CGFloat {
        switch self {
        case .street: return 16
        case .city: return 13
        case .region: return 10
        case .network: return 8
        case .province: return 6.5
        }
    }

    var dotBorder: CGFloat {
        switch self {
        case .street: return 3.5
        case .city: return 3
        case .region: return 2
        case .network: return 2
        case .province: return 1.6
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
            // Clear of what sits over the map: the Dynamic Island, with room for a
            // station's tag standing above its dot; the map buttons down the right side;
            // and the sheet (or search results) at the bottom, with room to spare.
            let top = Self.topInset(of: mapView) + 56
            let bottom = max(top + 80, size.height * (1 - coveredFraction) - 44)
            let left: CGFloat = 48
            let right = size.width - (BottomBarMetrics.controlsTrailingInset + 48 + 24)
            let mapPerPoint = max(width / Double(right - left), height / Double(bottom - top))
            let target = CGPoint(x: (left + right) / 2, y: (top + bottom) / 2)
            self.place(MKMapPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2), at: target,
                       mapPerPoint: mapPerPoint, in: mapView)
        }
    }

    #if DEBUG
    /// Slides the map over to `coordinate` slowly, at the same zoom: for recordings
    /// of the map moving.
    func glide(to coordinate: CLLocationCoordinate2D, duration: TimeInterval) {
        perform { mapView in
            guard let camera = mapView.camera.copy() as? MKMapCamera else { return }
            camera.centerCoordinate = coordinate
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut]) {
                mapView.camera = camera
            }
        }
    }
    #endif

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
    /// The train being tracked, shown moving along its line.
    var trackedTrip: TrackedTrip? = nil
    /// The tracked train was tapped.
    var onSelectTrain: () -> Void = {}
    /// With Show All Trains on: every other train running now, from the timetable.
    var runningTrips: [ScheduleStore.RunningTrip] = []
    /// One of those was tapped: the trip, and the index of the stop it's heading for.
    var onSelectRunningTrain: (ScheduleStore.RunningTrip, Int) -> Void = { _, _ in }
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

        // Your location in iOS's usual blue: in the app's green it passed for a station
        // or a Kitchener line train.
        mapView.tintColor = .systemBlue
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.showsCompass = false
        mapView.showsUserLocation = true

        let boundary: MKMapView.CameraBoundary? = MKMapView.CameraBoundary(coordinateRegion: RailNetwork.cameraCenterLimit)
        if let boundary {
            mapView.cameraBoundary = boundary
        }

        mapView.register(StationAnnotationView.self, forAnnotationViewWithReuseIdentifier: StationAnnotationView.reuseID)
        mapView.register(StationTagView.self, forAnnotationViewWithReuseIdentifier: StationTagView.reuseID)
        mapView.register(PlacePinView.self, forAnnotationViewWithReuseIdentifier: PlacePinView.reuseID)
        mapView.register(MKUserLocationView.self, forAnnotationViewWithReuseIdentifier: Coordinator.userLocationID)
        mapView.register(TrainAnnotationView.self, forAnnotationViewWithReuseIdentifier: TrainAnnotationView.reuseID)
        coordinator.installOverlays(on: mapView)
        coordinator.installStations(on: mapView)

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
        coordinator.syncTrip(trackedTrip, in: mapView)
        coordinator.syncRunning(runningTrips, in: mapView)
        return mapView
    }

    func updateUIView(_ mapView: LayoutAwareMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.controller = controller
        if coordinator.update(from: self) {
            // Where the tags go first, then how they look: each tag changes once.
            coordinator.placeNames(in: mapView)
            coordinator.refreshStations(in: mapView)
        }
        coordinator.syncPlace(place, in: mapView)
        coordinator.syncTrip(trackedTrip, in: mapView)
        coordinator.syncRunning(runningTrips, in: mapView)
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var controller: MapController?

        private var onSelect: (Station) -> Void = { _ in }
        private var onTapMap: () -> Void = {}
        private var onSelectTrain: () -> Void = {}
        private var onSelectRunningTrain: (ScheduleStore.RunningTrip, Int) -> Void = { _, _ in }
        private var placePin: PlaceAnnotation?
        private var selectedCode: String?
        private var homeCode: String?
        private var workCode: String?
        private var zoom = MapZoom(span: RailNetwork.overviewRegion.span.latitudeDelta)
        private var renderers: [ObjectIdentifier: MKPolylineRenderer] = [:]
        private var didInitialLayout = false
        private var didSetZoomRange = false

        /// Returns true when anything the stations' dots and tags depend on changed.
        func update(from view: NetworkMapView) -> Bool {
            onSelect = view.onSelect
            onTapMap = view.onTapMap
            onSelectTrain = view.onSelectTrain
            onSelectRunningTrain = view.onSelectRunningTrain
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

        /// A dot for every station, and its tag: a separate marker, so the tags can sit
        /// above the trains (which would hide the names) while the dots stay below them.
        func installStations(on mapView: MKMapView) {
            let stations = RailNetwork.shared.stations
            stationTags = stations.map { StationTagAnnotation(station: $0, coordinate: onTrack($0)) }
            mapView.addAnnotations(stations.map { StationAnnotation(station: $0, coordinate: onTrack($0)) })
            mapView.addAnnotations(stationTags)
            // The busier stations' names go first, so the names wait (a moment) for the
            // timetable to say which they are, rather than show and then reshuffle.
            Task { [weak self, weak mapView] in
                let counts = await ScheduleStore.shared.trainsPerStation()
                guard let self, let mapView else { return }
                self.trainsAt = counts
                self.namesReady = true
                self.placeNames(in: mapView)
            }
            Task { [weak self, weak mapView] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, let mapView, !self.namesReady else { return }
                self.namesReady = true
                self.placeNames(in: mapView)
            }
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

        /// Where a station's dot goes: on its line, where the track passes it.
        func onTrack(_ station: Station) -> CLLocationCoordinate2D {
            geometry.stop(station.code).map { Self.coordinate($0) } ?? station.coordinate
        }

        private func role(for station: Station) -> StationRole {
            if station.code == homeCode { return .home }
            if station.code == workCode { return .work }
            return .plain
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

        private func configure(_ view: StationAnnotationView, for station: Station, animated: Bool) {
            view.configure(zoom: zoom, isSelected: station.code == selectedCode, role: role(for: station),
                           station: station, animated: animated)
        }

        private func configure(_ view: StationTagView, for station: Station, animated: Bool) {
            view.configure(
                zoom: zoom,
                isSelected: station.code == selectedCode,
                role: role(for: station),
                station: station,
                dotSize: dotSize(for: station),
                place: namePlaces[station.code],
                animated: animated
            )
        }

        // MARK: Station tags

        private var stationTags: [StationTagAnnotation] = []

        /// Where each station's tag goes on the map as it stands (none: no room).
        private var namePlaces: [String: StationTagPlace] = [:]

        /// How many trains stop at each station on a weekday, from the timetable.
        private var trainsAt: [String: Int] = [:]
        /// The timetable's counts are in (or took too long): names can go up.
        private var namesReady = false

        /// Stations at the ends of the lines' runs.
        private static let lineEnds = Set(RailNetwork.shared.lines.flatMap { line in
            line.patterns.flatMap { [$0.first, $0.last].compactMap { $0 } }
        })

        /// Which tags matter most, and get the room first: the open station, home and
        /// work, Union, then where lines meet and where they end, then the rest (the
        /// busiest first, see `placeNames`).
        private func nameRank(_ station: Station) -> Int {
            if station.code == selectedCode { return 0 }
            if station.code == homeCode || station.code == workCode { return 1 }
            if station.isUnion { return 2 }
            if station.lineCodes.count > 1 { return 3 }
            if Self.lineEnds.contains(station.code) { return 4 }
            return 5
        }

        private func dotSize(for station: Station) -> CGFloat {
            station.code == selectedCode ? min(22, max(12, zoom.dotSize + 7)) : zoom.dotSize
        }

        /// How many metres a point covers through this zoom step on a map this size,
        /// from most zoomed in to most zoomed out (a little past its ends, where it
        /// lasts: see `MapZoom.init(span:keeping:)`).
        private static func scales(for zoom: MapZoom, in size: CGSize) -> (closest: CGFloat, farthest: CGFloat) {
            // Metres a point covers per degree of latitude the map spans top to bottom.
            let perDegree = 111_195 / size.height
            let spans = zoom.spans
            let closest = spans.from.map { CGFloat($0 / MapZoom.overshoot) * perDegree } ?? 0.3
            let farthest = spans.to.map { CGFloat($0 * MapZoom.overshoot) * perDegree }
                ?? CGFloat(RailNetwork.maxVisibleWidth) / size.width
            return (closest, max(closest, farthest))
        }

        /// Where a coordinate lies, in metres east and south of the middle of the
        /// network: near enough flat across it, for laying out the tags.
        private static func metres(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
            let middle = RailNetwork.serviceArea.center
            return CGPoint(x: CGFloat((coordinate.longitude - middle.longitude) * cos(middle.latitude * .pi / 180) * 111_195),
                           y: CGFloat((middle.latitude - coordinate.latitude) * 111_195))
        }

        /// Lays the station tags out, pins with their names standing on their dots,
        /// for the whole network at once at this zoom step: the ones that matter most
        /// first, each above its dot (centred, else running right or left of its
        /// point) where it covers no other tag or dot. They're laid out where the dots
        /// are closest together, at the step's zoomed-out end, so they stay apart
        /// wherever you are in it. Zoomed right out, only the tags that matter most.
        /// Trains don't count: they move, and the tags sit above them instead.
        ///
        /// So the tags stay put as the map moves, coming onto the screen and going off
        /// it with the map like its own names. They change (animated) only when the
        /// zoom step does, a station opens, home or work changes, or you move near
        /// one, and each keeps its side of its dot while it still fits there.
        func placeNames(in mapView: MKMapView) {
            let size = mapView.bounds.size
            guard namesReady, size.width > 0, size.height > 0 else { return }
            let scales = Self.scales(for: zoom, in: size)
            // Every station's dot, in points, with the map at the step's zoomed-out end.
            var points: [String: CGPoint] = [:]
            var dots: [String: CGRect] = [:]
            for station in RailNetwork.shared.stations {
                let metres = Self.metres(onTrack(station))
                let point = CGPoint(x: metres.x / scales.farthest, y: metres.y / scales.farthest)
                points[station.code] = point
                let radius = dotSize(for: station) / 2 + 1
                dots[station.code] = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            }
            // Your location's blue dot is drawn over everything: no tag's name goes
            // under it, anywhere in the step (checked at a dozen zooms across it).
            let you = isOnBoard ? nil : mapView.userLocation.location.map { Self.metres($0.coordinate) }
            let samples = (0...11).map { step -> CGFloat in
                scales.closest * CGFloat(pow(Double(scales.farthest / scales.closest), Double(step) / 11))
            }
            let above: [StationTagPlace] = [.centre, .runningRight, .runningLeft]

            var places: [String: StationTagPlace] = [:]
            var tags: [CGRect] = []
            // The ones that matter most first; among the rest, the ones more trains stop at.
            func order(_ station: Station) -> (Int, Int, String) {
                (nameRank(station), -(trainsAt[station.code] ?? 0), station.name)
            }
            for station in RailNetwork.shared.stations.sorted(by: { order($0) < order($1) }) {
                let rank = nameRank(station)
                if zoom == .province, rank > 4 { continue }
                guard let point = points[station.code] else { continue }
                let size = StationTag.size(name: station.name,
                                           font: StationTagView.font(zoom: zoom, isSelected: rank == 0),
                                           hasGlyph: role(for: station) != .plain)
                let radius = dotSize(for: station) / 2
                func frame(_ place: StationTagPlace) -> CGRect {
                    StationTagView.rect(size: size, radius: radius, place: place)
                        .offsetBy(dx: point.x, dy: point.y)
                }
                // How far you are from the station, in metres (when you're near).
                var fromHere: CGPoint?
                if let you {
                    let here = Self.metres(onTrack(station))
                    let offset = CGPoint(x: you.x - here.x, y: you.y - here.y)
                    if hypot(offset.x, offset.y) < 5_000 { fromHere = offset }
                }
                // A tag hanging below for you stays there until there's clear room
                // above, so it doesn't flip back and forth as your location wobbles.
                let reach: CGFloat = 11 + (namePlaces[station.code] == .below ? 6 : 0)
                func coversYou(_ place: StationTagPlace) -> Bool {
                    guard let fromHere else { return false }
                    // The tag's body, that is: your dot on its point is fine.
                    var body = StationTagView.rect(size: size, radius: radius, place: place)
                    body.size.height -= StationTag.pointLength
                    if place == .below { body.origin.y += StationTag.pointLength }
                    return samples.contains { scale in
                        CGRect(x: fromHere.x / scale - reach, y: fromHere.y / scale - reach,
                               width: reach * 2, height: reach * 2).intersects(body)
                    }
                }
                func fits(_ place: StationTagPlace) -> Bool {
                    let rect = frame(place)
                    return !coversYou(place)
                        && !tags.contains { $0.intersects(rect) }
                        && !dots.contains { $0.key != station.code && $0.value.intersects(rect) }
                }
                // Where it is now first, if it still fits there: tags don't hop about.
                let current = namePlaces[station.code]
                let tries = above.filter { $0 == current } + above.filter { $0 != current }
                var chosen = tries.first(where: fits)
                // You're where its tag would stand (at the station, say): it hangs below.
                if chosen == nil, above.contains(where: coversYou), fits(.below) {
                    chosen = .below
                }
                // The open station, home and work always have theirs, over other dots
                // and tags if need be (still not under you, if it can help it).
                if chosen == nil, rank <= 1 {
                    chosen = (tries + [.below]).first { !coversYou($0) } ?? tries.first
                }
                if let chosen {
                    places[station.code] = chosen
                    tags.append(frame(chosen))
                }
            }
            guard places != namePlaces else { return }
            let moved = Set(places.keys).union(namePlaces.keys).filter { places[$0] != namePlaces[$0] }
            namePlaces = places
            for annotation in stationTags where moved.contains(annotation.station.code) {
                if let view = mapView.view(for: annotation) as? StationTagView {
                    configure(view, for: annotation.station, animated: true)
                }
            }
            keepOrder(in: mapView)
        }

        /// Brings every dot and tag on the map up to date (zoom, open station, home and
        /// work), changing smoothly.
        func refreshStations(in mapView: MKMapView) {
            for annotation in mapView.annotations {
                if let annotation = annotation as? StationAnnotation,
                   let view = mapView.view(for: annotation) as? StationAnnotationView {
                    configure(view, for: annotation.station, animated: true)
                } else if let annotation = annotation as? StationTagAnnotation,
                          let view = mapView.view(for: annotation) as? StationTagView {
                    configure(view, for: annotation.station, animated: true)
                }
            }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let mapView = recognizer.view as? MKMapView else { return }
            onTapMap()
            let point = recognizer.location(in: mapView)
            if let train, let view = mapView.view(for: train) {
                let frame = view.convert(view.bounds, to: mapView).insetBy(dx: -4, dy: -4)
                if frame.contains(point) {
                    onSelectTrain()
                    return
                }
            }
            // A station's tag, a pin with its name, opens it. Tags sit above the other
            // trains, so they come first; a tap just outside one counts, unless it's
            // nearer another.
            var tagged: (station: Station, miss: CGFloat)?
            for annotation in stationTags {
                guard let view = mapView.view(for: annotation) as? StationTagView,
                      let frame = view.tagFrame(in: mapView) else { continue }
                let miss = hypot(max(frame.minX - point.x, 0, point.x - frame.maxX),
                                 max(frame.minY - point.y, 0, point.y - frame.maxY))
                if miss <= 5, miss < (tagged?.miss ?? .greatestFiniteMagnitude) {
                    tagged = (annotation.station, miss)
                }
            }
            if let tagged {
                onSelect(tagged.station)
                return
            }
            if let hit = runningTrain(at: point, in: mapView) {
                onSelectRunningTrain(hit.0, hit.1)
                return
            }
            var best: (station: Station, distance: CGFloat)?
            for station in RailNetwork.shared.stations {
                let stationPoint = mapView.convert(onTrack(station), toPointTo: mapView)
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

        static let userLocationID = "user-location"

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let user = annotation as? MKUserLocation {
                // MapKit's own blue dot, as in Apple Maps, but always on top: by default
                // it sits below the station markers, which hid it at a station.
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: Self.userLocationID, for: user)
                view.zPriority = .max
                view.displayPriority = .required
                // On board, the train marker shows where you are.
                view.isHidden = isOnBoard
                return view
            }
            if let marker = annotation as? TrainAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: TrainAnnotationView.reuseID, for: marker)
                guard let trainView = view as? TrainAnnotationView else { return view }
                let now = Date()
                trainView.setMapHeading(mapView.camera.heading)
                if let running = marker.running {
                    trainView.zPriority = MKAnnotationViewZPriority(rawValue: 980)
                    trainView.configure(color: lineColor(running.lineCode), animatesPointer: false, isOnBoard: false,
                                        scale: runningScale)
                    trainView.setHeading(spots[running.id]?.heading, animated: false)
                } else if let trip {
                    trainView.zPriority = MKAnnotationViewZPriority(rawValue: 990)
                    trainView.configure(color: lineColor(trip.lineCode), animatesPointer: trainIsMoving(at: now),
                                        isOnBoard: isOnBoard)
                    trainView.setHeading(trainHeading(at: now), animated: false)
                }
                return view
            }
            if let place = annotation as? PlaceAnnotation {
                return mapView.dequeueReusableAnnotationView(withIdentifier: PlacePinView.reuseID, for: place)
            }
            if let tag = annotation as? StationTagAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: StationTagView.reuseID, for: tag)
                // A tag coming onto the screen with the map is already in place: no pop.
                if let tagView = view as? StationTagView { configure(tagView, for: tag.station, animated: false) }
                return view
            }
            guard let annotation = annotation as? StationAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: StationAnnotationView.reuseID, for: annotation)
            guard let stationView = view as? StationAnnotationView else { return view }
            configure(stationView, for: annotation.station, animated: false)
            return stationView
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let routeOverlay = overlay as? TrainRouteOverlay {
                let renderer = MKPolylineRenderer(polyline: routeOverlay)
                renderer.strokeColor = routeOverlay.isCasing ? UIColor.white.withAlphaComponent(0.9) : routeOverlay.color
                renderer.lineWidth = routeWidth(casing: routeOverlay.isCasing)
                renderer.lineCap = .round
                renderer.lineJoin = .round
                routeRenderers[ObjectIdentifier(routeOverlay)] = renderer
                return renderer
            }
            guard let track = overlay as? TrackPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: track)
            renderer.strokeColor = track.isCasing ? UIColor.white.withAlphaComponent(0.9) : track.color
            renderer.lineWidth = track.isCasing ? zoom.casingWidth : zoom.lineWidth
            renderer.lineCap = .round
            renderer.lineJoin = .round
            renderer.alpha = lineAlpha(track)
            renderers[ObjectIdentifier(track)] = renderer
            return renderer
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            self.userLocation = userLocation.location
            // The tags make way for your location as you move.
            placeNames(in: mapView)
            guard trip != nil else { return }
            let wasOnBoard = isOnBoard
            updateOnBoard(in: mapView, now: Date())
            // On board, the train follows you as soon as you move.
            if isOnBoard || wasOnBoard { moveTrain(in: mapView, now: Date()) }
        }

        @objc func userMovedMap(_ recognizer: UIGestureRecognizer) {
            controller?.userGesture(recognizer.state)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            controller?.checkPlacement(mapView)
            // (Where the map is doesn't move the tags; this only catches the map
            // getting its size.)
            placeNames(in: mapView)
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            setZoomRangeIfNeeded(mapView)
            // The train's pointer stays true as the map turns.
            if let train, let view = mapView.view(for: train) as? TrainAnnotationView {
                view.setMapHeading(mapView.camera.heading)
            }

            // Only re-render when the zoom crosses a step (and not back and forth as a
            // pinch hovers at one).
            let newZoom = MapZoom(span: mapView.region.span.latitudeDelta, keeping: zoom)
            guard newZoom != zoom else { return }
            zoom = newZoom
            // This step's tags, then this step's sizes: each tag changes once.
            placeNames(in: mapView)
            refreshStations(in: mapView)
            for marker in running.values {
                guard let view = mapView.view(for: marker) as? TrainAnnotationView, let trip = marker.running else { continue }
                view.configure(color: lineColor(trip.lineCode), animatesPointer: false, isOnBoard: false, scale: runningScale)
            }
            for renderer in renderers.values {
                guard let track = renderer.polyline as? TrackPolyline else { continue }
                renderer.lineWidth = track.isCasing ? zoom.casingWidth : zoom.lineWidth
                renderer.setNeedsDisplay()
            }
            for renderer in routeRenderers.values {
                guard let overlay = renderer.polyline as? TrainRouteOverlay else { continue }
                renderer.lineWidth = routeWidth(casing: overlay.isCasing)
                renderer.setNeedsDisplay()
            }
        }

        // MARK: Tracked train

        private var trip: TrackedTrip?
        private var train: TrainAnnotation?
        /// The stretch still to travel, from the last stop the train reached to
        /// your stop: its white casing and its line.
        private var route: [TrainRouteOverlay] = []
        /// The stop that stretch starts at (it's redrawn when the train reaches the next).
        private var routeStart: Int?
        private var routeRenderers: [ObjectIdentifier: MKPolylineRenderer] = [:]
        /// The trip's track from its first stop to your stop.
        private var fullRoute: [TrackGeometry.Point] = []
        /// Moves the trains every second.
        private var timer: Timer?
        private weak var trackedMap: MKMapView?
        /// The other trains in service around now (Show All Trains), by trip, from
        /// the timetable each minute: the timer puts each on the map as it sets off
        /// and takes it away a minute after it gets in.
        private var schedule: [String: ScheduleStore.RunningTrip] = [:]
        /// The ones on the map now, by trip.
        private var running: [String: TrainAnnotation] = [:]
        /// Trains just put on the map: they fade in when MapKit adds their view.
        private var appearing: [ObjectIdentifier: Date] = [:]
        /// Track between neighbouring stops, by line and stops, measured once.
        private var segments: [String: CommutePlanner.Path] = [:]
        private var userLocation: CLLocation?
        /// Your location and speed match the train's: you're on it.
        private var isOnBoard = false

        private var geometry: TrackGeometry { StartupStation.geometry }

        /// Shows the tracked train (or stops showing it) when the trip changes.
        func syncTrip(_ newTrip: TrackedTrip?, in mapView: MKMapView) {
            func identity(_ trip: TrackedTrip?) -> String? {
                trip.map { "\($0.tripNumber)|\($0.boardingCode)|\($0.startedAt.timeIntervalSince1970)" }
            }
            guard identity(newTrip) != identity(trip) else {
                trip = newTrip
                return
            }
            if let train { remove(train, from: mapView) }
            mapView.removeOverlays(route)
            drawn["tracked"] = nil
            trackedSpot = nil
            train = nil
            route = []
            routeStart = nil
            routeRenderers = [:]
            fullRoute = []
            trip = newTrip
            trackedMap = mapView
            setOnBoard(false, in: mapView)
            dimLines()
            // The tracked train isn't drawn twice.
            if let newTrip, let twin = running.first(where: { $0.value.running?.tripNumber == newTrip.tripNumber }) {
                running[twin.key] = nil
                remove(twin.value, from: mapView)
            }
            updateTimer()
            guard let newTrip else { return }

            fullRoute = geometry.route(line: newTrip.lineCode, stops: newTrip.stopCodes,
                                       from: 0, to: newTrip.destinationIndex)
            let now = Date()
            moveTrain(in: mapView, now: now)
            updateRoute(in: mapView, now: now)
        }

        /// Shows the other trains in service around now (Show All Trains), or none:
        /// trains taken off the list fade away.
        func syncRunning(_ trips: [ScheduleStore.RunningTrip], in mapView: MKMapView) {
            trackedMap = mapView
            updateTimer()
            let listed = Dictionary(trips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            guard Set(listed.keys) != Set(schedule.keys) else { return }
            for (key, marker) in running where listed[key] == nil {
                running[key] = nil
                remove(marker, from: mapView)
            }
            schedule = listed
            drawn = drawn.filter { $0.key == "tracked" || $0.key.hasPrefix("watch-") || listed[$0.key] != nil }
            spots = spots.filter { listed[$0.key] != nil }
            endedAt = endedAt.filter { listed[$0.key] != nil }
            moveRunning(in: mapView, now: Date())
            updateTimer()
        }

        /// Puts trains on the map, fading them in.
        private func appear(_ markers: [TrainAnnotation], in mapView: MKMapView) {
            let now = Date()
            appearing = appearing.filter { now.timeIntervalSince($0.value) < 5 }
            for marker in markers { appearing[ObjectIdentifier(marker)] = now }
            mapView.addAnnotations(markers)
        }

        /// Fades a train out, then takes it off the map.
        private func remove(_ marker: TrainAnnotation, from mapView: MKMapView) {
            appearing[ObjectIdentifier(marker)] = nil
            guard let view = mapView.view(for: marker) as? TrainAnnotationView, view.window != nil else {
                mapView.removeAnnotation(marker)
                return
            }
            view.fadeOut { [weak mapView] in
                mapView?.removeAnnotation(marker)
            }
        }

        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            for view in views {
                guard let marker = view.annotation as? TrainAnnotation,
                      let added = appearing.removeValue(forKey: ObjectIdentifier(marker)),
                      Date().timeIntervalSince(added) < 2
                else { continue }
                (view as? TrainAnnotationView)?.fadeIn()
            }
            keepOrder(in: mapView)
        }

        /// The timer runs once there's a map: it moves the trains on it, and works
        /// out how fast a train whose stops are open is going even when it isn't drawn.
        private func updateTimer() {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        @objc private func tick() {
            guard let mapView = trackedMap else { return }
            let now = Date()
            moveRunning(in: mapView, now: now)
            if trip != nil {
                moveTrain(in: mapView, now: now)
                updateRoute(in: mapView, now: now)
            }
            moveWatched(now: now)
            keepOrder(in: mapView)
        }

        /// The trains drawn this tick, by trip number (the tracked one too).
        private var drawnNumbers: Set<String> = []

        /// Trains whose stops are open but which the map doesn't draw: how fast
        /// they're going, worked out the same way as for those it does.
        private func moveWatched(now: Date) {
            let motion = TrainMotion.shared
            for (number, watched) in motion.watched where !drawnNumbers.contains(number) {
                let key = "watch-\(number)"
                guard let run = self.run(line: watched.line, codes: watched.codes) else { continue }
                let then = now.addingTimeInterval(-Self.replayDelay)
                let state = TrainState.locate(times: watched.times, now: then)
                let replay = replayed(number, on: run, at: now, times: watched.times)
                // In service: between its first stop and its last.
                let inService: Bool
                switch state {
                case .moving, .stopped:
                    inService = true
                case .waiting, .arrived, .unknown:
                    inService = replay.map { !($0.isAt && ($0.stop == 0 || $0.stop == run.codes.count - 1)) } ?? false
                }
                guard inService, let target = replay ?? run.position(of: state, times: watched.times) else {
                    drawn[key] = nil
                    motion.note(number, speed: nil, at: now)
                    continue
                }
                motion.note(number, speed: ease(key, toward: target, on: run, now: now).speed, at: now)
            }
            drawn = drawn.filter { !$0.key.hasPrefix("watch-") || motion.watched[String($0.key.dropFirst(6))] != nil }
        }

        /// The other trains: each one shows up (fading in) as it sets off, moves
        /// along its line (see `spot(for:at:)`), and fades away a minute after it gets
        /// to its last stop.
        private func moveRunning(in mapView: MKMapView, now: Date) {
            var added: [TrainAnnotation] = []
            drawnNumbers = Set(trip.map { [$0.tripNumber] } ?? [])
            for (key, scheduled) in schedule where scheduled.tripNumber != trip?.tripNumber {
                let spot = self.spot(for: scheduled, at: now)
                spots[key] = spot
                if let spot {
                    drawnNumbers.insert(scheduled.tripNumber)
                    TrainMotion.shared.note(scheduled.tripNumber, speed: spot.speed, at: now)
                }
                guard let marker = running[key] else {
                    if let spot {
                        let fresh = TrainAnnotation(coordinate: Self.coordinate(spot.point), running: scheduled)
                        running[key] = fresh
                        added.append(fresh)
                    }
                    continue
                }
                guard let spot else {
                    running[key] = nil
                    remove(marker, from: mapView)
                    continue
                }
                let coordinate = Self.coordinate(spot.point)
                UIView.animate(withDuration: 1, delay: 0,
                               options: [.curveLinear, .beginFromCurrentState, .allowUserInteraction]) {
                    marker.coordinate = coordinate
                }
                (mapView.view(for: marker) as? TrainAnnotationView)?.setHeading(spot.heading, animated: true)
            }
            if !added.isEmpty { appear(added, in: mapView) }
        }

        /// A train's place on the map: where it is, which way it's going, the last
        /// stop it reached and the one it's at or heading for, and how fast it's going.
        struct Spot {
            let point: TrackGeometry.Point
            let heading: Double?
            let reached: Int
            let next: Int
            /// Metres per second.
            let speed: Double
        }

        /// How far behind now the trains are drawn. GO reports each train about
        /// every 20 seconds, 5 to 15 seconds after the fact, so most of the time
        /// this is a guess from the latest report (see TrainReplay), which the
        /// drawing eases to (see `ease`) rather than jumping; a few seconds behind
        /// keeps the guesses short.
        static let replayDelay: TimeInterval = 5

        /// The other trains as last drawn, by trip (for their markers and taps).
        private var spots: [String: Spot] = [:]
        /// Each trip's run along its stops, measured once.
        private var runs: [String: TrainRun] = [:]
        /// Each train as last drawn along its run, by trip ("tracked" for the
        /// tracked one): how far along, how fast, and when.
        private var drawn: [String: (distance: Double, speed: Double, at: Date)] = [:]
        /// When each of the other trains was first drawn at the end of its run.
        private var endedAt: [String: Date] = [:]

        private func run(line: String, codes: [String]) -> TrainRun? {
            let key = "\(line)|" + codes.joined(separator: ",")
            if let cached = runs[key] { return cached }
            guard codes.count >= 2 else { return nil }
            let run = TrainRun(codes: codes) { a, b in self.segment(line, a, b) }
            runs[key] = run
            return run
        }

        /// Where a train should be drawn now along its run, by its live reports when
        /// it has recent ones (nil when they don't fit the run). The live list's other
        /// trains have none, so they aren't running.
        private func replayed(_ number: String, on run: TrainRun, at now: Date,
                              times: [Date?]) -> TrainReplay.Position? {
            let reports = LiveTrains.shared.history[number] ?? []
            guard let newest = reports.last,
                  now.timeIntervalSince(newest.time) < LiveFix.freshFor + Self.replayDelay
            else { return nil }
            return TrainReplay.position(of: reports, on: run, at: now.addingTimeInterval(-Self.replayDelay),
                                        times: times)
        }

        /// Where one of the other trains is drawn now: by its live reports when it
        /// has any, otherwise where the timetable puts it (both a few seconds behind
        /// now); moved there smoothly from where it was last drawn. On the map from a
        /// minute before it's due to set off until a minute after it gets in; nil otherwise.
        private func spot(for trip: ScheduleStore.RunningTrip, at now: Date) -> Spot? {
            let line = RailNetwork.shared.line(code: trip.lineCode)?.code ?? trip.lineCode
            guard trip.times.count == trip.pattern.count, let run = self.run(line: line, codes: trip.pattern) else {
                return forget(trip.id)
            }
            let times = trip.times.map { Optional($0) }
            var found = replayed(trip.tripNumber, on: run, at: now, times: times)
            if found == nil {
                // Missing from an up-to-date list of live trains: not running.
                if LiveTrains.shared.isCurrent(at: now), LiveTrains.shared.history[trip.tripNumber] == nil {
                    return forget(trip.id)
                }
                // On the same clock as the replays, so a train switching between the
                // two doesn't jump.
                let then = now.addingTimeInterval(-Self.replayDelay)
                let state = TrainState.locate(times: times, now: then)
                switch state {
                case .waiting, .unknown:
                    return forget(trip.id)
                case .arrived(let time) where then >= time.addingTimeInterval(TrainState.lingerAtEnd):
                    return forget(trip.id)
                default:
                    found = run.position(of: state, times: times)
                }
            }
            guard let target = found else { return forget(trip.id) }
            // Waiting at its first stop: on the map from a minute before it's due to leave.
            if target.isAt, target.stop == 0, let leaves = trip.times.first, now < leaves.addingTimeInterval(-60) {
                return forget(trip.id)
            }
            let shown = ease(trip.id, toward: target, on: run, now: now)
            // In at its last stop: there a minute, then gone.
            if shown.isAt, shown.stop == run.codes.count - 1 {
                let since = endedAt[trip.id] ?? now
                endedAt[trip.id] = since
                if now.timeIntervalSince(since) > TrainState.lingerAtEnd { return nil }
            }
            return spot(on: run, at: shown)
        }

        private func forget(_ key: String) -> Spot? {
            drawn[key] = nil
            return nil
        }

        /// Moves a train's drawing toward where it should be, gently: at that pace,
        /// closing any gap over a few seconds (no faster than it could slow down
        /// again without overshooting), speeding up and slowing down no harder than a
        /// train does, never going back, and never past the station it's heading for.
        /// Starts again there when it's far off, or wasn't drawn just now.
        private func ease(_ key: String, toward target: TrainReplay.Position, on run: TrainRun,
                          now: Date) -> TrainReplay.Position {
            let limit = run.starts.indices.contains(target.stop) ? run.starts[target.stop] : run.length
            if let last = drawn[key] {
                let dt = now.timeIntervalSince(last.at)
                if dt > 0, dt < 5, abs(target.distance - last.distance) < 2_000 {
                    let coasting = last.distance + last.speed * dt
                    let gap = target.distance - coasting
                    let correction = min(0.5 * abs(gap), (2 * abs(gap)).squareRoot())
                    // (Catching up no more than about a third faster than it's going, or
                    // braking gently to where it is when that's a stop just ahead; and
                    // no faster than GO's trains go, about 150 km/h, unless it really is:
                    // the trip's stops show this speed.)
                    let catchUp = max(target.speed + max(4, target.speed * 0.3), max(gap, 0).squareRoot())
                    let wanted = min(max(0, target.speed + (gap < 0 ? -correction : correction)),
                                     catchUp, max(42, target.speed))
                    var speed = max(0, last.speed + min(max(wanted - last.speed, -1.5 * dt), 1.5 * dt))
                    var distance = last.distance + (last.speed + speed) / 2 * dt
                    if distance >= limit {
                        distance = max(limit, last.distance)
                        speed = min(speed, target.speed)
                    }
                    drawn[key] = (distance, speed, now)
                    return TrainReplay.Position(distance: distance, speed: speed, stop: target.stop,
                                                isAt: target.isAt && abs(distance - target.distance) < 2)
                }
                if dt <= 0 {
                    return TrainReplay.Position(distance: last.distance, speed: last.speed, stop: target.stop,
                                                isAt: target.isAt && abs(last.distance - target.distance) < 2)
                }
            }
            drawn[key] = (target.distance, target.speed, now)
            return target
        }

        /// Where `position` is on the map.
        private func spot(on run: TrainRun, at position: TrainReplay.Position) -> Spot? {
            guard let placed = run.point(at: position.distance) else { return nil }
            let reached = position.isAt ? position.stop : max(position.stop - 1, 0)
            return Spot(point: placed.point, heading: placed.heading, reached: reached, next: position.stop,
                        speed: position.speed)
        }

        /// The track between two neighbouring stops, measured once.
        private func segment(_ line: String, _ a: String, _ b: String) -> CommutePlanner.Path? {
            let key = "\(line)|\(a)|\(b)"
            if let cached = segments[key] { return cached }
            let points = geometry.segment(line: line, from: a, to: b)
            guard points.count >= 2 else { return nil }
            let path = CommutePlanner.Path(points)
            segments[key] = path
            return path
        }

        /// The direction of travel at `along` metres into a stretch of track, across
        /// 50 m of it, in degrees clockwise from north.
        private static func heading(on path: CommutePlanner.Path, at along: Double) -> Double? {
            let length = path.cumulative[path.cumulative.count - 1]
            let a = path.point(at: max(0, min(along, length - 25)))
            let b = path.point(at: min(length, max(along, 25) + 25))
            guard a.x != b.x || a.y != b.y else { return nil }
            let degrees = atan2(b.x - a.x, b.y - a.y) * 180 / .pi
            return degrees < 0 ? degrees + 360 : degrees
        }

        /// The other trains shrink as the map zooms out, so the lines stay readable.
        private var runningScale: CGFloat {
            switch zoom {
            case .street, .city: return 0.85
            case .region: return 0.68
            case .network, .province: return 0.55
            }
        }

        /// The running train under a tap, and the stop it's heading for.
        private func runningTrain(at point: CGPoint, in mapView: MKMapView) -> (ScheduleStore.RunningTrip, Int)? {
            var best: (trip: ScheduleStore.RunningTrip, distance: CGFloat)?
            for marker in running.values {
                guard let trip = marker.running, let view = mapView.view(for: marker), !view.isHidden else { continue }
                let center = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: mapView)
                let distance = hypot(center.x - point.x, center.y - point.y)
                if distance <= 22 * runningScale + 6, distance < (best?.distance ?? .greatestFiniteMagnitude) {
                    best = (trip, distance)
                }
            }
            guard let best, let spot = spots[best.trip.id] else { return nil }
            return (best.trip, spot.next)
        }

        /// Keeps the markers stacked as their z-priorities say (MapKit doesn't always
        /// keep annotation views in that order): the other trains above the station
        /// dots, the stations' tags above those trains so no name is hidden, then the
        /// tracked train, a searched place, and your location above them all.
        private func keepOrder(in mapView: MKMapView) {
            func lift(_ annotation: MKAnnotation) {
                guard let view = mapView.view(for: annotation), !view.isHidden else { return }
                view.superview?.bringSubviewToFront(view)
            }
            for marker in running.values { lift(marker) }
            for tag in stationTags { lift(tag) }
            if let train { lift(train) }
            if let placePin { lift(placePin) }
            lift(mapView.userLocation)
        }

        /// The stretch still to travel is a little bolder than the line, with the
        /// same white edge.
        private func routeWidth(casing: Bool) -> CGFloat {
            let width = zoom.lineWidth + 2
            return casing ? width + (zoom.casingWidth - zoom.lineWidth) : width
        }

        /// Which way the train is going: yours when you're on it and moving,
        /// otherwise along its track.
        private func trainHeading(at now: Date) -> Double? {
            if isOnBoard, let course = userLocation?.course, course >= 0 { return course }
            return trackedSpot?.heading ?? trip?.heading(at: now, on: geometry)
        }

        /// How fast the tracked train goes, as it's drawn moving (as you go, when
        /// you're on it and the train is drawn with you), in metres per second. The
        /// trip's stops show it (TrainMotion).
        private func trainSpeed() -> Double? {
            if isOnBoard, let speed = userLocation?.speed, speed >= 0 { return speed }
            return trackedSpot?.speed
        }

        /// Whether the tracked train is moving where it's drawn.
        private func trainIsMoving(at now: Date) -> Bool {
            if let trackedSpot { return trackedSpot.speed > 0.3 }
            return trip?.state(at: now).isMoving ?? false
        }

        /// Where the tracked train is drawn now (see `updateTrackedSpot(at:)`).
        private var trackedSpot: Spot?

        /// Where the tracked train is drawn now: by its live reports when it has
        /// recent ones, otherwise where its times put it (both a few seconds behind
        /// now); moved there smoothly from where it was last drawn.
        private func updateTrackedSpot(at now: Date) {
            guard let trip else {
                trackedSpot = nil
                return
            }
            let line = RailNetwork.shared.line(code: trip.lineCode)?.code ?? trip.lineCode
            guard let run = self.run(line: line, codes: trip.stopCodes) else {
                trackedSpot = nil
                return
            }
            let times = trip.stops.map { $0.departed ?? $0.expected ?? $0.time }
            let replay = replayed(trip.tripNumber, on: run, at: now, times: times)
            // Its times on the same clock as the replay, so switching between the two doesn't jump.
            guard let target = replay ?? run.position(of: trip.state(at: now.addingTimeInterval(-Self.replayDelay)),
                                                      times: times)
            else {
                trackedSpot = nil
                return
            }
            let shown = ease("tracked", toward: target, on: run, now: now)
            trackedSpot = spot(on: run, at: shown)
            // How fast it's drawn going, for its stops to show (yours, when it's drawn
            // with you), while it's in service.
            let state = trip.state(at: now.addingTimeInterval(-Self.replayDelay))
            let inService: Bool
            switch state {
            case .moving, .stopped: inService = true
            case .waiting, .arrived, .unknown: inService = replay != nil && !shown.isAt
            }
            TrainMotion.shared.note(trip.tripNumber, speed: inService ? trainSpeed() : nil, at: now)
            #if DEBUG
            trace(trip.tripNumber, now: now, replayed: replay != nil, target: target, shown: shown)
            #endif
        }

        #if DEBUG
        /// Debug builds launched with `-traceTrains YES`: each time the tracked train
        /// is drawn, where it should be and where it's drawn, in Documents/train-trace.tsv
        /// (tools/trace_summary.py says how smoothly it moved).
        private static let traceFile: FileHandle? = {
            guard UserDefaults.standard.bool(forKey: "traceTrains"),
                  let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            else { return nil }
            let url = folder.appendingPathComponent("train-trace.tsv")
            let header = "time\tsource\ttarget\ttarget_speed\tdrawn\tdrawn_speed\treport_age\treports\tstop\n"
            FileManager.default.createFile(atPath: url.path, contents: Data(header.utf8))
            return try? FileHandle(forWritingTo: url)
        }()

        private func trace(_ number: String, now: Date, replayed: Bool, target: TrainReplay.Position,
                           shown: TrainReplay.Position) {
            guard let file = Self.traceFile else { return }
            let reports = LiveTrains.shared.history[number] ?? []
            let age = reports.last.map { now.timeIntervalSince($0.time) } ?? -1
            let fields: [String] = [
                String(format: "%.2f", now.timeIntervalSince1970), replayed ? "replay" : "times",
                String(format: "%.1f", target.distance), String(format: "%.2f", target.speed),
                String(format: "%.1f", shown.distance), String(format: "%.2f", shown.speed),
                String(format: "%.1f", age), "\(reports.count)", "\(target.stop)\(target.isAt ? "@" : ">")",
            ]
            _ = try? file.seekToEnd()
            try? file.write(contentsOf: Data((fields.joined(separator: "\t") + "\n").utf8))
        }
        #endif

        private static func coordinate(_ point: TrackGeometry.Point) -> CLLocationCoordinate2D {
            let coordinate = TrackGeometry.coordinate(point)
            return CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }

        private func lineColor(_ code: String) -> UIColor {
            let line = RailNetwork.shared.line(code: code)?.code ?? code
            return RailNetwork.shared.trackPaths.first { $0.lineCode == line }?.uiColor ?? .systemGray
        }

        /// While a trip is tracked, its line stands out: the others fade.
        private func lineAlpha(_ track: TrackPolyline) -> CGFloat {
            guard let trip else { return 1 }
            return track.lineCode == trip.lineCode ? 1 : 0.3
        }

        private func dimLines() {
            for renderer in renderers.values {
                guard let track = renderer.polyline as? TrackPolyline else { continue }
                let alpha = lineAlpha(track)
                guard renderer.alpha != alpha else { continue }
                renderer.alpha = alpha
                renderer.setNeedsDisplay()
            }
        }

        /// Where the train is now, along the track, as it's drawn.
        private func estimatedPoint(at now: Date) -> TrackGeometry.Point? {
            trackedSpot?.point ?? trip?.position(at: now, on: geometry)
        }

        /// Where to draw the train: with you when you're on it, otherwise where it
        /// is by its live reports or its times.
        private func trainPoint(at now: Date) -> TrackGeometry.Point? {
            if isOnBoard, let userLocation {
                return TrackGeometry.Point(latitude: userLocation.coordinate.latitude,
                                           longitude: userLocation.coordinate.longitude)
            }
            return estimatedPoint(at: now)
        }

        private func moveTrain(in mapView: MKMapView, now: Date) {
            guard let trip else { return }
            updateTrackedSpot(at: now)
            updateOnBoard(in: mapView, now: now)
            guard let point = trainPoint(at: now) else { return }
            let coordinate = Self.coordinate(point)
            if let train {
                UIView.animate(withDuration: 1, delay: 0,
                               options: [.curveLinear, .beginFromCurrentState, .allowUserInteraction]) {
                    train.coordinate = coordinate
                }
            } else {
                let marker = TrainAnnotation(coordinate: coordinate)
                train = marker
                appear([marker], in: mapView)
            }
            if let train, let view = mapView.view(for: train) as? TrainAnnotationView {
                view.configure(color: lineColor(trip.lineCode), animatesPointer: trainIsMoving(at: now), isOnBoard: isOnBoard)
                view.setHeading(trainHeading(at: now), animated: true)
            }
        }

        /// The stretch from the last stop the train reached to your stop, drawn again
        /// only when it reaches the next one: its ends sit under the station dots,
        /// and the train moves along it.
        private func updateRoute(in mapView: MKMapView, now: Date) {
            guard let trip else { return }
            // From the last stop the train has reached where it's drawn.
            let start = trackedSpot?.reached ?? trip.state(at: now).reached(stopCount: trip.stops.count)
            guard start != routeStart else { return }
            routeStart = start
            let old = route
            let points = start < trip.destinationIndex
                ? geometry.route(line: trip.lineCode, stops: trip.stopCodes, from: start, to: trip.destinationIndex)
                : []
            if points.count >= 2 {
                let coordinates = points.map { Self.coordinate($0) }
                route = [true, false].map { TrainRouteOverlay.make(coordinates, color: lineColor(trip.lineCode), casing: $0) }
                mapView.addOverlays(route, level: .aboveRoads)
            } else {
                route = []
            }
            guard !old.isEmpty else { return }
            // The old stretch goes once the new one has drawn, so the line doesn't blink.
            Task { [weak self, weak mapView] in
                try? await Task.sleep(for: .milliseconds(700))
                mapView?.removeOverlays(old)
                for overlay in old { self?.routeRenderers[ObjectIdentifier(overlay)] = nil }
            }
        }

        /// You're on the train when you're on its track, near where it should be, and
        /// moving like it (fast, its way). Once on, you stay on through station stops
        /// until you leave the track.
        private func updateOnBoard(in mapView: MKMapView, now: Date) {
            guard trip != nil, let location = userLocation, -location.timestamp.timeIntervalSinceNow < 30 else {
                setOnBoard(false, in: mapView)
                return
            }
            let user = TrackGeometry.Point(latitude: location.coordinate.latitude,
                                           longitude: location.coordinate.longitude)
            guard let hit = TrackGeometry.locate(user, on: fullRoute),
                  let estimate = estimatedPoint(at: now),
                  let train = TrackGeometry.locate(estimate, on: fullRoute)
            else {
                setOnBoard(false, in: mapView)
                return
            }
            let onTrack = hit.distance <= 250 + min(max(location.horizontalAccuracy, 0), 300)
            let gap = abs(hit.along - train.along)
            if isOnBoard {
                setOnBoard(onTrack && gap <= 8000, in: mapView)
                return
            }
            let speed = location.speed
            let moving = speed >= 5 && speed <= 60
            var aligned = true
            if location.course >= 0, let bearing = TrackGeometry.bearing(on: fullRoute, at: hit.along) {
                let difference = abs((location.course - bearing + 540).truncatingRemainder(dividingBy: 360) - 180)
                aligned = difference <= 60
            }
            setOnBoard(onTrack && gap <= 4000 && moving && aligned, in: mapView)
        }

        private func setOnBoard(_ value: Bool, in mapView: MKMapView) {
            if value != isOnBoard {
                isOnBoard = value
                if let train, let trip, let view = mapView.view(for: train) as? TrainAnnotationView {
                    view.configure(color: lineColor(trip.lineCode), animatesPointer: trainIsMoving(at: Date()), isOnBoard: value)
                }
            }
            mapView.view(for: mapView.userLocation)?.isHidden = isOnBoard
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
    private(set) var lineCode = ""

    static func make(_ path: TrackPath, casing: Bool) -> TrackPolyline {
        let polyline = TrackPolyline(coordinates: path.coordinates, count: path.coordinates.count)
        polyline.color = path.uiColor
        polyline.isCasing = casing
        polyline.lineCode = path.lineCode
        return polyline
    }
}

final class StationAnnotation: NSObject, MKAnnotation {
    let station: Station
    let coordinate: CLLocationCoordinate2D

    /// At `coordinate` when given: the station's place on its line.
    init(station: Station, coordinate: CLLocationCoordinate2D? = nil) {
        self.station = station
        self.coordinate = coordinate ?? station.coordinate
    }

    var title: String? { station.name }
}

/// Where a station's tag stands: on its dot, like the station's own annotation, but
/// a marker of its own so it can sit above the trains while the dot stays below them.
final class StationTagAnnotation: NSObject, MKAnnotation {
    let station: Station
    let coordinate: CLLocationCoordinate2D

    init(station: Station, coordinate: CLLocationCoordinate2D) {
        self.station = station
        self.coordinate = coordinate
    }
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
        // Above everything but your location.
        zPriority = MKAnnotationViewZPriority(rawValue: 995)
        animatesWhenAdded = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A station's dot, on its line. Its name is on a tag standing on the dot, a marker
/// of its own (`StationTagView`). Neither takes touches: the map handles every
/// gesture, and opens a station on a tap on its tag or near its dot.
final class StationAnnotationView: MKAnnotationView {
    static let reuseID = "station"
    private static let ink = UIColor(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1)
    /// Room for the biggest dot (the open station's), so a dot grows and shrinks
    /// about its centre.
    private static let side: CGFloat = 24

    private let dot = CAShapeLayer()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        isUserInteractionEnabled = false
        isEnabled = false
        canShowCallout = false
        displayPriority = .required
        collisionMode = .circle
        clipsToBounds = false
        backgroundColor = .clear
        bounds = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)

        dot.frame = bounds
        dot.fillColor = UIColor.white.cgColor
        dot.strokeColor = Self.ink.cgColor
        dot.shadowColor = UIColor.black.cgColor
        dot.shadowOffset = CGSize(width: 0, height: 0.5)
        layer.addSublayer(dot)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// `animated`: the dot grows or shrinks to its new size (zooming, or opening it).
    func configure(zoom: MapZoom, isSelected: Bool, role: StationRole, station: Station, animated: Bool) {
        isUserInteractionEnabled = false

        let size = isSelected ? min(22, max(12, zoom.dotSize + 7)) : zoom.dotSize
        let border = isSelected ? max(2.5, zoom.dotBorder + 1) : zoom.dotBorder
        let box = CGRect(x: (Self.side - size) / 2, y: (Self.side - size) / 2, width: size, height: size)

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(StationTagView.duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        dot.path = UIBezierPath(ovalIn: box.insetBy(dx: border / 2, dy: border / 2)).cgPath
        dot.lineWidth = border
        dot.shadowPath = UIBezierPath(ovalIn: box).cgPath
        dot.shadowOpacity = zoom <= .city ? 0.25 : 0.15
        dot.shadowRadius = zoom <= .city ? 1.5 : 0.8
        CATransaction.commit()

        // Below the trains (a train at a station covers its dot); the tags go above them.
        zPriority = MKAnnotationViewZPriority(rawValue: isSelected ? 700 : (role == .plain ? 500 : 600))
        accessibilityLabel = station.name
    }
}

/// A station's tag: a pin with its name, standing on the station's dot where
/// there's room (the map works out where, see `placeNames`). It sits above the
/// other trains, so a passing train never hides a name, and below the tracked one.
///
/// Every change animates: a tag pops up out of its dot and sinks back into it,
/// slides to its new place with its point staying on the dot, and takes on a new
/// look (zooming in or out, opening the station) or moves to the other side of
/// the dot in a crossfade. (Reduce Motion: fades only.)
final class StationTagView: MKAnnotationView {
    static let reuseID = "station-tag"
    /// How long the tags and dots take to change.
    static let duration: TimeInterval = 0.3
    /// How small a tag is as it pops up out of its dot, or sinks back into it.
    private static let popScale: CGFloat = 0.3

    /// What the tag shows, and where.
    private struct State: Equatable {
        var look: StationTag.Look
        var place: StationTagPlace
        /// The dot's radius: the point stands on its edge.
        var radius: CGFloat
    }

    /// A tag's point: filled from just inside the tag's edge (covering its border
    /// there) to the dot's edge, with the tag's border down its sides (on plain tags).
    private struct Point {
        let layer = CALayer()
        let fill = CAShapeLayer()
        let edge = CAShapeLayer()
        /// Hanging from the dot, below it, rather than standing on it.
        let up: Bool

        init(up: Bool) {
            self.up = up
            edge.fillColor = nil
            edge.lineWidth = 1
            layer.addSublayer(fill)
            layer.addSublayer(edge)
        }

        func shape(radius: CGFloat) {
            let sign: CGFloat = up ? 1 : -1
            let tip = CGPoint(x: 0, y: sign * radius)
            let tagEdge = sign * (radius + StationTag.pointLength)
            let filled = CGMutablePath()
            filled.move(to: CGPoint(x: -5.5, y: tagEdge + sign))
            filled.addLine(to: tip)
            filled.addLine(to: CGPoint(x: 5.5, y: tagEdge + sign))
            filled.closeSubpath()
            fill.path = filled
            // Its sides, from the tag's edge to the tip.
            let side = 5.5 * StationTag.pointLength / (StationTag.pointLength + 1)
            let sides = CGMutablePath()
            sides.move(to: CGPoint(x: -side, y: tagEdge))
            sides.addLine(to: tip)
            sides.addLine(to: CGPoint(x: side, y: tagEdge))
            edge.path = sides
        }

        func color(_ colors: StationTag.Colors, traits: UITraitCollection) {
            fill.fillColor = colors.fill.resolvedColor(with: traits).cgColor
            edge.strokeColor = (colors.border ?? .clear).resolvedColor(with: traits).cgColor
        }
    }

    /// Everything that pops up and sinks back together. (0, 0) is the dot's centre
    /// (and this view's), so it all grows out of the dot and shrinks back into it.
    private let content = UIView()
    /// The tag's body: its rounded shape, bullet or symbol, and the name.
    private let body = StationTag()
    /// The body's last look, fading out over the new one.
    private let ghost = StationTag()
    private let pointDown = Point(up: false)
    private let pointUp = Point(up: true)

    private var state: State?
    /// Counts changes, so an animation finishing late leaves a newer change be.
    private var generation = 0
    /// The tag is to pop up as soon as it's on screen.
    private var popsWhenShown = false

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        isUserInteractionEnabled = false
        isEnabled = false
        canShowCallout = false
        displayPriority = .required
        clipsToBounds = false
        backgroundColor = .clear
        // The dot under it already reads the station's name.
        isAccessibilityElement = false
        bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        isHidden = true

        content.bounds = CGRect(x: -1, y: -1, width: 2, height: 2)
        content.center = CGPoint(x: 1, y: 1)
        content.isUserInteractionEnabled = false
        addSubview(content)
        ghost.isHidden = true
        content.addSubview(ghost)
        content.addSubview(body)
        // The points over the body, so their fill covers its border where they meet.
        content.layer.addSublayer(pointDown.layer)
        content.layer.addSublayer(pointUp.layer)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: StationTagView, _: UITraitCollection) in
            view.colorPoints(animated: false)
        }
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        state = nil
        generation += 1
        popsWhenShown = false
        isHidden = true
        settle()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if popsWhenShown, window != nil { pop() }
    }

    /// The tag's body in `view`'s coordinates while it shows (not while it goes).
    func tagFrame(in view: UIView) -> CGRect? {
        guard state != nil, !isHidden else { return nil }
        return content.convert(body.frame, to: view)
    }

    /// Shows the tag at `place` (none: no room for it), changing smoothly from what
    /// shows now when `animated`. `dotSize`: the dot's size as drawn, so the tag's
    /// point stands on its edge.
    func configure(zoom: MapZoom, isSelected: Bool, role: StationRole, station: Station,
                   dotSize: CGFloat, place: StationTagPlace?, animated: Bool) {
        isUserInteractionEnabled = false
        zPriority = MKAnnotationViewZPriority(rawValue: isSelected ? 987 : (role == .plain ? 985 : 986))
        let style: StationTag.Style = switch role {
        case .home: .home
        case .work: .work
        case .plain: isSelected ? .open : .plain(Self.lineColor(of: station))
        }
        let look = StationTag.Look(name: station.name, font: Self.font(zoom: zoom, isSelected: isSelected),
                                   style: style, hasGlyph: role != .plain)
        let new = place.map { State(look: look, place: $0, radius: dotSize / 2) }
        guard new != state else { return }
        let old = state
        state = new
        generation += 1

        guard let new else {
            hide(animated: animated)
            return
        }
        if let old, !isHidden {
            change(from: old, to: new, animated: animated && window != nil)
        } else {
            appear(new, animated: animated)
        }
    }

    // MARK: Changes

    /// The tag pops up out of its dot (or just shows).
    private func appear(_ state: State, animated: Bool) {
        let wasHidden = isHidden
        dropGhost()
        body.layer.removeAllAnimations()
        UIView.performWithoutAnimation {
            body.look = state.look
            body.frame = Self.bodyFrame(for: state)
            body.alpha = 1
        }
        shapePoints(for: state, animated: false)
        isHidden = false
        guard animated else {
            popsWhenShown = false
            content.layer.removeAllAnimations()
            content.alpha = 1
            content.transform = .identity
            return
        }
        if wasHidden {
            content.alpha = 0
            content.transform = reduceMotion ? .identity : CGAffineTransform(scaleX: Self.popScale, y: Self.popScale)
        }
        if window == nil {
            popsWhenShown = true
        } else {
            pop()
        }
    }

    private func pop() {
        popsWhenShown = false
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.content.alpha = 1
            self.content.transform = .identity
        }
    }

    /// The tag sinks back into its dot (or just goes).
    private func hide(animated: Bool) {
        popsWhenShown = false
        guard animated, window != nil, !isHidden else {
            isHidden = true
            settle()
            return
        }
        let generation = self.generation
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseIn]) {
            self.content.alpha = 0
            if !self.reduceMotion {
                self.content.transform = CGAffineTransform(scaleX: Self.popScale, y: Self.popScale)
            }
        } completion: { _ in
            // Unless it's changed since (come back, say).
            guard generation == self.generation else { return }
            self.isHidden = true
            self.settle()
        }
    }

    /// From one place or look to another, while the tag shows.
    private func change(from old: State, to new: State, animated: Bool) {
        let frame = Self.bodyFrame(for: new)
        guard animated else {
            dropGhost()
            body.layer.removeAllAnimations()
            UIView.performWithoutAnimation {
                body.look = new.look
                body.frame = frame
                body.alpha = 1
            }
            shapePoints(for: new, animated: false)
            return
        }
        let flips = (old.place == .below) != (new.place == .below)
        if old.look == new.look, !flips, !reduceMotion {
            // The same tag somewhere else: it slides there, its point staying on the dot.
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.body.frame = frame
            }
        } else {
            // A new look, or the other side of the dot: the new tag fades in over the old.
            crossfade(to: new.look, frame: frame, sliding: !flips && !reduceMotion)
        }
        shapePoints(for: new, animated: true)
    }

    /// The old look (as it shows right now, mid-move say) fades out, sliding toward
    /// the new place when `sliding`, as the new one fades in there.
    private func crossfade(to look: StationTag.Look, frame: CGRect, sliding: Bool) {
        let shown = body.layer.presentation()
        UIView.performWithoutAnimation {
            ghost.layer.removeAllAnimations()
            ghost.look = body.look
            ghost.frame = shown?.frame ?? body.frame
            ghost.alpha = CGFloat(shown?.opacity ?? Float(body.alpha))
            ghost.isHidden = false
            body.layer.removeAllAnimations()
            body.look = look
            body.frame = frame
            body.alpha = 0
        }
        let generation = self.generation
        UIView.animate(withDuration: Self.duration, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            self.ghost.alpha = 0
            if sliding { self.ghost.center = CGPoint(x: frame.midX, y: frame.midY) }
            self.body.alpha = 1
        } completion: { _ in
            guard generation == self.generation else { return }
            self.ghost.isHidden = true
        }
    }

    /// Stops what's moving, leaving everything as it ends up.
    private func settle() {
        content.layer.removeAllAnimations()
        body.layer.removeAllAnimations()
        dropGhost()
        content.alpha = 1
        content.transform = .identity
        body.alpha = 1
    }

    private func dropGhost() {
        ghost.layer.removeAllAnimations()
        ghost.isHidden = true
    }

    /// The point on the tag's side of the dot, standing on its edge, in the tag's colours.
    private func shapePoints(for state: State, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(Self.duration)
        pointDown.shape(radius: state.radius)
        pointUp.shape(radius: state.radius)
        pointDown.layer.opacity = state.place == .below ? 0 : 1
        pointUp.layer.opacity = state.place == .below ? 1 : 0
        CATransaction.commit()
        colorPoints(animated: animated)
    }

    private func colorPoints(animated: Bool) {
        guard let state else { return }
        let colors = StationTag.colors(for: state.look.style, dark: traitCollection.userInterfaceStyle == .dark)
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(Self.duration)
        pointDown.color(colors, traits: traitCollection)
        pointUp.color(colors, traits: traitCollection)
        CATransaction.commit()
    }

    // MARK: Geometry and looks

    /// The tag's body (all but its point), around the dot's centre.
    private static func bodyFrame(for state: State) -> CGRect {
        let size = StationTag.size(name: state.look.name, font: state.look.font, hasGlyph: state.look.hasGlyph)
        let whole = rect(size: size, radius: state.radius, place: state.place)
        return CGRect(x: whole.minX, y: state.place == .below ? whole.minY + StationTag.pointLength : whole.minY,
                      width: whole.width, height: whole.height - StationTag.pointLength)
    }

    /// The station's line colour for its tag's bullet (the app's green at Union, where all meet).
    private static func lineColor(of station: Station) -> UIColor {
        if station.isUnion { return UIColor(named: "AccentColor") ?? .systemGreen }
        return station.lineCodes.first.flatMap { RailNetwork.shared.line(code: $0) }
            .map { UIColor(hexString: $0.hex) } ?? .systemGray
    }

    static func font(zoom: MapZoom, isSelected: Bool) -> UIFont {
        if isSelected { return .systemFont(ofSize: 14, weight: .bold) }
        switch zoom {
        case .street, .city: return .systemFont(ofSize: 13, weight: .semibold)
        case .region: return .systemFont(ofSize: 12.5, weight: .semibold)
        case .network, .province: return .systemFont(ofSize: 12, weight: .semibold)
        }
    }

    /// Where the whole tag goes (its body and point), relative to the dot's centre:
    /// above it (below it when it hangs), its point on the dot.
    static func rect(size: CGSize, radius: CGFloat, place: StationTagPlace) -> CGRect {
        let pointX: CGFloat = switch place {
        case .centre, .below: size.width / 2
        case .runningRight: min(size.width / 2, StationTag.pointInset)
        case .runningLeft: max(size.width / 2, size.width - StationTag.pointInset)
        }
        let y = place == .below ? radius : -radius - size.height
        return CGRect(x: -pointX, y: y, width: size.width, height: size.height)
    }
}

/// How a station's tag stands on its dot: centred over it, or running off to the
/// right or left of its point (where the room is). Where your location covers the
/// room above, it hangs centred below the dot instead, its point up.
enum StationTagPlace: CaseIterable {
    case centre, runningRight, runningLeft, below
}

/// A station's tag on the map, so it reads as something to tap: a rounded shape
/// with the station's name, standing on its dot on a small point (which
/// `StationTagView` draws, so it can stay on the dot as the tag moves). Home and
/// work are in their colours with a house or briefcase; the open station is the
/// map's ink colour turned round; the rest are in the map's own colours, with a
/// bullet in the line's colour.
final class StationTag: UIView {
    enum Style: Equatable {
        case plain(UIColor), open, home, work
    }

    /// What a tag shows.
    struct Look: Equatable {
        let name: String
        let font: UIFont
        let style: Style
        let hasGlyph: Bool
    }

    struct Colors {
        let fill: UIColor
        let text: UIColor
        let border: UIColor?
        let mark: UIColor
        let glyph: String?
    }

    static let pointLength: CGFloat = 6
    /// How far from the tag's end its point sits, when the tag runs off to one side.
    static let pointInset: CGFloat = 15
    private static let padding: CGFloat = 8
    private static let gap: CGFloat = 5

    var look: Look? {
        didSet { if look != oldValue { setNeedsDisplay() } }
    }

    /// The whole tag's size for a name: its body, and the point under it.
    static func size(name: String, font: UIFont, hasGlyph: Bool) -> CGSize {
        let text = (name as NSString).size(withAttributes: [.font: font])
        let mark = hasGlyph ? font.pointSize + 1 : 8
        let body = ceil(max(text.height, mark)) + 9
        return CGSize(width: ceil(text.width) + mark + gap + 2 * padding, height: body + pointLength)
    }

    static func colors(for style: Style, dark: Bool) -> Colors {
        switch style {
        case .plain(let line):
            return Colors(fill: dark ? UIColor(white: 0.13, alpha: 0.97) : UIColor(white: 1, alpha: 0.97),
                          text: dark ? .white : UIColor(white: 0.1, alpha: 1),
                          border: dark ? UIColor(white: 1, alpha: 0.22) : UIColor(white: 0, alpha: 0.12),
                          mark: line, glyph: nil)
        case .open:
            return Colors(fill: dark ? .white : UIColor(white: 0.1, alpha: 1),
                          text: dark ? UIColor(white: 0.08, alpha: 1) : .white,
                          border: nil, mark: UIColor(named: "AccentColor") ?? .systemGreen, glyph: nil)
        case .home:
            return Colors(fill: .systemBlue, text: .white, border: nil, mark: .white, glyph: "house.fill")
        case .work:
            return Colors(fill: .systemBrown, text: .white, border: nil, mark: .white, glyph: "briefcase.fill")
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 2.5
        updateShadow()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: StationTag, _: UITraitCollection) in
            view.setNeedsDisplay()
            view.updateShadow()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateShadow()
    }

    private func updateShadow() {
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).cgPath
        layer.shadowOpacity = traitCollection.userInterfaceStyle == .dark ? 0.55 : 0.28
    }

    override func draw(_ rect: CGRect) {
        guard let look else { return }
        let colors = Self.colors(for: look.style, dark: traitCollection.userInterfaceStyle == .dark)
        let body = bounds.insetBy(dx: 0.5, dy: 0.5)
        let rounded = UIBezierPath(roundedRect: body, cornerRadius: body.height / 2)
        colors.fill.setFill()
        rounded.fill()
        if let border = colors.border {
            border.setStroke()
            rounded.lineWidth = 1
            rounded.stroke()
        }

        let size = look.hasGlyph ? look.font.pointSize + 1 : 8
        var x = Self.padding
        if look.hasGlyph, let glyph = colors.glyph,
           let image = UIImage(systemName: glyph,
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: look.font.pointSize - 1, weight: .bold))?
               .withTintColor(colors.mark, renderingMode: .alwaysOriginal) {
            image.draw(at: CGPoint(x: x + (size - image.size.width) / 2, y: body.midY - image.size.height / 2))
        } else {
            // A bullet in the line's colour.
            let bullet = UIBezierPath(ovalIn: CGRect(x: x, y: body.midY - 4, width: 8, height: 8))
            colors.mark.setFill()
            bullet.fill()
        }
        x += size + Self.gap
        let label = look.name as NSString
        let height = label.size(withAttributes: [.font: look.font]).height
        label.draw(at: CGPoint(x: x, y: body.midY - height / 2),
                   withAttributes: [.font: look.font, .foregroundColor: colors.text])
    }
}
