import MapKit
import UIKit

// MARK: - Trains

/// A train on the map: the tracked one, or (with Show All Trains on) one of the
/// others running now. Its coordinate moves as the train does.
final class TrainAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    /// The other trains' timetable trip; nil for the tracked train.
    let running: ScheduleStore.RunningTrip?
    /// The train to scale where it is now (nil where it can't be laid along its
    /// track): drawn in place of the marker once the map is zoomed in far enough.
    var model: TrainModel?

    init(coordinate: CLLocationCoordinate2D, running: ScheduleStore.RunningTrip? = nil) {
        self.coordinate = coordinate
        self.running = running
    }
}

/// The train marker, as in the trip sheet: a train on a disc of the line's colour
/// in a white ring, with a white pointer on the ring showing which way it's going.
/// While the tracked train moves, its pointer pushes forward with copies of it
/// streaming ahead, and rings in the line's colour spread from the disc, so it
/// catches the eye. Ignores touches like the other markers; the map's tap handler
/// opens the trip.
final class TrainAnnotationView: MKAnnotationView {
    static let reuseID = "train"

    /// Everything, so the other trains can be drawn smaller than the tracked one.
    private let content = UIView()
    /// The train to scale, under the marker (see `layoutModel(in:)`).
    private let model = TrainModelView()
    /// The line's colour, for the tracked train's model.
    private var color: UIColor = .gray
    /// The marker makes way for the model when that's big enough to see as a train.
    private var markerHidden = false
    private let pointer = UIView()
    private let arrow = CAShapeLayer()
    /// Copies of the arrow that stream ahead of it, one after the other.
    private let echoes = [CAShapeLayer(), CAShapeLayer()]
    /// A ring in the line's colour that spreads from the disc and fades.
    private let ripple = CAShapeLayer()
    private let disc = UIView()
    private let glyph = UIImageView()

    /// The train's direction of travel, in degrees clockwise from north.
    private var heading: Double?
    /// The map's rotation, in degrees clockwise from north.
    private var mapHeading: Double = 0
    private var isAnimated = false

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 56, height: 56)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        canShowCallout = false
        displayPriority = .required
        // Taking part in collisions (as the station dots do) keeps it in their layer,
        // where its z-priority puts it above them; required, so nothing hides it.
        collisionMode = .circle
        // Above stations and pins, below your own location dot.
        zPriority = MKAnnotationViewZPriority(rawValue: 990)

        model.isHidden = true
        addSubview(model)

        content.frame = bounds
        content.isUserInteractionEnabled = false
        addSubview(content)

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        ripple.frame = bounds
        ripple.path = UIBezierPath(arcCenter: center, radius: 16, startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
        ripple.lineWidth = 2.5
        ripple.opacity = 0
        content.layer.addSublayer(ripple)

        // A small triangle above the disc, its base tucked under the ring; the view
        // turns to point the way the train goes.
        pointer.frame = bounds
        pointer.isHidden = true
        let shape = UIBezierPath()
        shape.move(to: CGPoint(x: center.x, y: center.y - 24.5))
        shape.addLine(to: CGPoint(x: center.x + 6.5, y: center.y - 13))
        shape.addLine(to: CGPoint(x: center.x - 6.5, y: center.y - 13))
        shape.close()
        for layer in echoes + [arrow] {
            layer.frame = pointer.bounds
            layer.path = shape.cgPath
            layer.fillColor = UIColor.white.cgColor
            layer.strokeColor = UIColor.white.cgColor
            layer.lineWidth = 1.5
            layer.lineJoin = .round
            pointer.layer.addSublayer(layer)
        }
        arrow.shadowColor = UIColor.black.cgColor
        arrow.shadowOpacity = 0.35
        arrow.shadowRadius = 2
        arrow.shadowOffset = CGSize(width: 0, height: 1)
        for echo in echoes { echo.opacity = 0 }
        content.addSubview(pointer)

        disc.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
        disc.center = center
        disc.layer.cornerRadius = 16
        disc.layer.borderColor = UIColor.white.cgColor
        disc.layer.borderWidth = 2.5
        disc.layer.shadowColor = UIColor.black.cgColor
        disc.layer.shadowOpacity = 0.35
        disc.layer.shadowRadius = 3
        disc.layer.shadowOffset = CGSize(width: 0, height: 1)
        content.addSubview(disc)

        glyph.image = UIImage(systemName: "tram.fill",
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold))
        glyph.tintColor = .white
        glyph.contentMode = .center
        glyph.frame = disc.bounds
        disc.addSubview(glyph)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The line's colour (always, waiting or not), whether the pointer moves (the
    /// tracked train, while it moves), and its size: the tracked train full size,
    /// the others a little smaller.
    func configure(color: UIColor, animatesPointer: Bool, scale: CGFloat = 1) {
        self.color = color
        disc.backgroundColor = color
        ripple.strokeColor = color.withAlphaComponent(0.9).cgColor
        ripple.fillColor = color.withAlphaComponent(0.18).cgColor
        if content.transform.a != scale {
            content.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
        if animatesPointer != isAnimated {
            isAnimated = animatesPointer
            updateMotion()
        }
        accessibilityLabel = "Train"
    }

    // MARK: Pointing the way

    /// Points the marker the way the train is going (hidden when that isn't known).
    func setHeading(_ degrees: Double?, animated: Bool) {
        heading = degrees
        updatePointer(animated: animated)
    }

    /// Keeps the pointer true as the map turns.
    func setMapHeading(_ degrees: Double) {
        guard degrees != mapHeading else { return }
        mapHeading = degrees
        updatePointer(animated: false)
    }

    /// The pointer's turn, in radians, kept unwrapped so it always turns the short way.
    private var angle: CGFloat = 0

    private func updatePointer(animated: Bool) {
        guard let heading else {
            pointer.isHidden = true
            return
        }
        let target = CGFloat((heading - mapHeading) * .pi / 180)
        var delta = (target - angle).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        // (Pointing that way already: nothing to turn, and a turn under way carries on.)
        if abs(delta) > 0.0005 || pointer.isHidden {
            let turned = angle + delta
            let layer = pointer.layer
            if animated, !pointer.isHidden {
                // One quick turn, with the marker's own slide to a new position.
                let animation = CABasicAnimation(keyPath: "transform.rotation.z")
                animation.fromValue = angle
                animation.toValue = turned
                animation.duration = 0.45
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(animation, forKey: "turn")
            } else {
                layer.removeAnimation(forKey: "turn")
            }
            layer.setValue(turned, forKeyPath: "transform.rotation.z")
            angle = turned
        }
        if pointer.isHidden {
            pointer.isHidden = false
            updateMotion()
        }
    }

    /// The tracked train, while it moves: the pointer pushes forward and back with
    /// two copies of it streaming ahead and fading, and rings spread from the disc.
    /// Still with Reduce Motion, while the train stands or waits, and for the other
    /// trains (so the tracked one stands out).
    private func updateMotion() {
        arrow.removeAnimation(forKey: "push")
        for echo in echoes {
            echo.removeAnimation(forKey: "stream")
            echo.opacity = 0
        }
        ripple.removeAnimation(forKey: "ripple")
        ripple.opacity = 0
        guard isAnimated, window != nil, !UIAccessibility.isReduceMotionEnabled else { return }

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 1.9
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.85
        fade.toValue = 0
        let ring = CAAnimationGroup()
        ring.animations = [grow, fade]
        ring.duration = 1.6
        ring.repeatCount = .infinity
        ring.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ripple.add(ring, forKey: "ripple")

        guard !pointer.isHidden else { return }
        let push = CABasicAnimation(keyPath: "transform.translation.y")
        push.fromValue = 0
        push.toValue = -4
        push.duration = 0.45
        push.autoreverses = true
        push.repeatCount = .infinity
        push.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        arrow.add(push, forKey: "push")

        for (index, echo) in echoes.enumerated() {
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.fromValue = -2
            slide.toValue = -15
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.9
            fade.toValue = 0
            let stream = CAAnimationGroup()
            stream.animations = [slide, fade]
            stream.duration = 0.9
            stream.beginTime = echo.convertTime(CACurrentMediaTime(), from: nil) + 0.45 * Double(index)
            stream.repeatCount = .infinity
            stream.timingFunction = CAMediaTimingFunction(name: .easeOut)
            echo.add(stream, forKey: "stream")
        }
    }

    /// Core Animation drops the animations when MapKit takes the view off screen.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { updateMotion() }
    }

    // MARK: The train to scale

    /// A model this many points long or longer is drawn...
    static let modelFrom: CGFloat = 26
    /// ...and from this long, it's drawn instead of the marker.
    static let modelOnlyFrom: CGFloat = 72

    /// Draws the train to scale (its annotation's `model`) as the map shows it
    /// now: where it is, how far the map is zoomed in, and how it's turned and
    /// tilted. Too small to make out, or with no model, just the marker.
    func layoutModel(in mapView: MKMapView) {
        guard let marker = annotation as? TrainAnnotation, let train = marker.model else {
            hideModel()
            return
        }
        let coordinate = marker.coordinate
        let anchor = mapView.convert(coordinate, toPointTo: mapView)
        // The map's scale and tilt where the train is, from where 20 m east and 20 m
        // north of it fall on the screen: across the screen a metre on the ground is
        // `scale` points whichever way it runs; up the screen it's shortened by the tilt.
        let here = TrackGeometry.point(.init(latitude: coordinate.latitude, longitude: coordinate.longitude))
        func screen(_ dx: Double, _ dy: Double) -> CGPoint {
            let moved = TrackGeometry.coordinate(.init(x: here.x + dx, y: here.y + dy))
            return mapView.convert(CLLocationCoordinate2D(latitude: moved.latitude, longitude: moved.longitude),
                                   toPointTo: mapView)
        }
        let east = screen(20, 0), north = screen(0, 20)
        let scale = hypot(east.x - anchor.x, north.x - anchor.x) / 20
        let length = CGFloat(train.length) * scale
        guard scale.isFinite, scale > 0, length >= Self.modelFrom else {
            hideModel()
            return
        }
        let shortened = min(hypot(east.y - anchor.y, north.y - anchor.y) / 20 / scale, 1)
        let tilt = (1 - shortened * shortened).squareRoot()

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        var projected: [TrainModelView.Projected] = []
        var box = CGRect.null
        for vehicle in train.vehicles {
            let ground = vehicle.outline.map { corner -> CGPoint in
                let point = mapView.convert(corner, toPointTo: mapView)
                return CGPoint(x: point.x - anchor.x + center.x, y: point.y - anchor.y + center.y)
            }
            let up = CGVector(dx: 0, dy: -CGFloat(vehicle.height) * scale * tilt)
            let shown = TrainModelView.Projected(kind: vehicle.kind, ground: ground, up: up, leadsAhead: vehicle.leadsAhead)
            for point in ground + shown.roof {
                box = box.union(CGRect(origin: point, size: .zero))
            }
            projected.append(shown)
        }
        guard !box.isNull, box.width.isFinite, box.height.isFinite else {
            hideModel()
            return
        }
        // Only as much of it as is on the screen (zoomed right in, a train runs far off it).
        let screen = CGRect(x: center.x - anchor.x, y: center.y - anchor.y,
                            width: mapView.bounds.width, height: mapView.bounds.height).insetBy(dx: -40, dy: -40)
        box = box.insetBy(dx: -4, dy: -4).intersection(screen).integral
        guard !box.isNull, !box.isEmpty else {
            hideModel()
            return
        }
        model.frame = box
        model.vehicles = projected.map { vehicle in
            let shift = { (point: CGPoint) in CGPoint(x: point.x - box.minX, y: point.y - box.minY) }
            return .init(kind: vehicle.kind, ground: vehicle.ground.map(shift), up: vehicle.up,
                         leadsAhead: vehicle.leadsAhead)
        }
        model.highlight = marker.running == nil ? color : nil
        model.isHidden = false
        setMarkerHidden(length >= Self.modelOnlyFrom)
    }

    /// Whether `point` (in `view`'s coordinates) is on the train's model, as drawn.
    func modelContains(_ point: CGPoint, from view: UIView) -> Bool {
        guard !model.isHidden else { return false }
        return model.contains(model.convert(point, from: view))
    }

    private func hideModel() {
        if !model.isHidden {
            model.isHidden = true
            model.vehicles = []
        }
        setMarkerHidden(false)
    }

    /// Hides the marker (its disc and pointer) while the model shows the train, and
    /// brings it back once the model is too small to make out.
    private func setMarkerHidden(_ hidden: Bool) {
        guard hidden != markerHidden else { return }
        markerHidden = hidden
        ripple.isHidden = hidden
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.disc.alpha = hidden ? 0 : 1
            self.pointer.alpha = hidden ? 0 : 1
        }
    }

    // MARK: Coming and going

    /// A train setting off (or just tracked) fades in.
    func fadeIn() {
        content.layer.removeAllAnimations()
        model.layer.removeAllAnimations()
        content.alpha = 0
        model.alpha = 0
        UIView.animate(withDuration: 0.6, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.content.alpha = 1
            self.model.alpha = 1
        }
    }

    /// A train leaving the map fades out, then `completion` takes it away.
    func fadeOut(completion: @escaping () -> Void) {
        UIView.animate(withDuration: 0.6, delay: 0, options: [.curveEaseIn, .beginFromCurrentState],
                       animations: {
                           self.content.alpha = 0
                           self.model.alpha = 0
                       },
                       completion: { _ in completion() })
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        content.layer.removeAllAnimations()
        content.alpha = 1
        model.layer.removeAllAnimations()
        model.alpha = 1
        model.isHidden = true
        model.vehicles = []
        markerHidden = false
        ripple.isHidden = false
        disc.alpha = 1
        pointer.alpha = 1
        heading = nil
        pointer.isHidden = true
        isAnimated = false
        updateMotion()
    }
}

// MARK: - The stretch still to travel

/// The track from the last stop the train reached to your stop, drawn a little
/// bolder than the line, with the same white edge (a white casing under the
/// line's colour).
final class TrainRouteOverlay: MKPolyline {
    private(set) var color: UIColor = .gray
    private(set) var isCasing = false

    static func make(_ coordinates: [CLLocationCoordinate2D], color: UIColor, casing: Bool) -> TrainRouteOverlay {
        let overlay = TrainRouteOverlay(coordinates: coordinates, count: coordinates.count)
        overlay.color = color
        overlay.isCasing = casing
        return overlay
    }
}

// MARK: - The train to scale

/// A train's vehicles on the map, to scale and along its track (bending with it
/// on a curve): each one's outline on the ground, as `TrainConsist` lays them out.
struct TrainModel {
    struct Vehicle {
        let kind: TrainConsist.Kind
        /// Its outline on the ground: down its left side from its end nearer the
        /// run's start to its other end (`sides` points), then back up its right.
        let outline: [CLLocationCoordinate2D]
        /// Its height above the rails, in metres.
        let height: Double
        /// The locomotive's or cab car's driving end is its end further along the run.
        let leadsAhead: Bool
    }

    /// Points down each side of a vehicle: its ends and its middle, so it bends
    /// with the track.
    static let sides = 3
    /// The gap left at each end of a vehicle, so the couplings show between them.
    static let gap = 0.45

    let vehicles: [Vehicle]
    /// The whole train's length, in metres.
    let length: Double

    /// `consist`'s vehicles with its locomotive centred `anchor` metres along `run`.
    /// Nil where the run has no track to lay them along.
    init?(consist: TrainConsist, anchor: Double, on run: TrainRun) {
        var vehicles: [Vehicle] = []
        let half = TrainConsist.width / 2
        for vehicle in consist.vehicles(at: anchor) {
            let from = vehicle.from + Self.gap, to = vehicle.to - Self.gap
            var left: [CLLocationCoordinate2D] = []
            var right: [CLLocationCoordinate2D] = []
            for step in 0..<Self.sides {
                let along = from + (to - from) * Double(step) / Double(Self.sides - 1)
                guard let placed = run.point(at: along) else { return nil }
                // Its own heading, or failing that the way the run goes across it.
                var heading = placed.heading
                if heading == nil, let a = run.point(at: from)?.point, let b = run.point(at: to)?.point,
                   a.x != b.x || a.y != b.y {
                    heading = atan2(b.x - a.x, b.y - a.y) * 180 / .pi
                }
                guard let heading else { return nil }
                let radians = heading * .pi / 180
                // To the right of the way the run goes: east and north.
                let rx = cos(radians), ry = -sin(radians)
                let p = placed.point
                left.append(Self.coordinate(.init(x: p.x - rx * half, y: p.y - ry * half)))
                right.append(Self.coordinate(.init(x: p.x + rx * half, y: p.y + ry * half)))
            }
            let height = vehicle.kind == .locomotive ? TrainConsist.locomotiveHeight : TrainConsist.coachHeight
            vehicles.append(Vehicle(kind: vehicle.kind, outline: left + right.reversed(), height: height,
                                    leadsAhead: vehicle.leadsAhead))
        }
        self.vehicles = vehicles
        length = consist.length
    }

    private static func coordinate(_ point: TrackGeometry.Point) -> CLLocationCoordinate2D {
        let coordinate = TrackGeometry.coordinate(point)
        return CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

/// A train drawn to scale on the map, as a model: each vehicle a box standing on
/// its outline, as tall as the real thing, seen as the map's camera sees it (from
/// straight above, just their roofs; with the map tilted, their sides too). In
/// GO's colours: the locomotive green, the BiLevel coaches white with their green
/// band and two decks of windows, the cab car's driving end glazed.
final class TrainModelView: UIView {
    /// A vehicle as the camera sees it, in this view's coordinates.
    struct Projected {
        let kind: TrainConsist.Kind
        /// Its outline on the ground.
        let ground: [CGPoint]
        /// The screen offset from the ground up to its roof.
        let up: CGVector
        let leadsAhead: Bool

        var roof: [CGPoint] { ground.map { CGPoint(x: $0.x + up.dx, y: $0.y + up.dy) } }
        var middleY: CGFloat { ground.map(\.y).reduce(0, +) / CGFloat(max(ground.count, 1)) }
    }

    var vehicles: [Projected] = [] {
        didSet { setNeedsDisplay() }
    }
    /// The tracked train's roofs are outlined in its line's colour.
    var highlight: UIColor? {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Whether `point` (in this view's coordinates) is on the train: on a roof or a side.
    func contains(_ point: CGPoint) -> Bool {
        vehicles.contains { vehicle in
            Self.path(vehicle.roof).contains(point) || Self.path(vehicle.ground).contains(point)
        }
    }

    // MARK: Colours

    private static let coachBody = UIColor(red: 0.91, green: 0.92, blue: 0.93, alpha: 1)
    private static let coachRoof = UIColor(red: 0.76, green: 0.78, blue: 0.80, alpha: 1)
    private static let goGreen = UIColor(red: 0.00, green: 0.47, blue: 0.24, alpha: 1)
    private static let locomotiveRoof = UIColor(red: 0.12, green: 0.36, blue: 0.22, alpha: 1)
    private static let glass = UIColor(red: 0.13, green: 0.15, blue: 0.17, alpha: 1)
    private static let edge = UIColor(red: 0.25, green: 0.27, blue: 0.29, alpha: 0.85)

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), !vehicles.isEmpty else { return }
        context.setLineJoin(.round)
        // The farthest vehicle first, so the nearer ones stand in front of it.
        let ordered = vehicles.sorted { $0.middleY < $1.middleY }

        // Their shadows on the ground.
        context.saveGState()
        context.translateBy(x: 0.8, y: 1.2)
        UIColor.black.withAlphaComponent(0.28).setFill()
        for vehicle in ordered { Self.path(vehicle.ground).fill() }
        context.restoreGState()

        for vehicle in ordered { drawVehicle(vehicle) }
    }

    private func drawVehicle(_ vehicle: Projected) {
        let ground = vehicle.ground
        let count = ground.count
        let sides = TrainModel.sides
        let isLocomotive = vehicle.kind == .locomotive
        let body = isLocomotive ? Self.goGreen : Self.coachBody
        let center = CGPoint(x: ground.map(\.x).reduce(0, +) / CGFloat(count),
                             y: ground.map(\.y).reduce(0, +) / CGFloat(count))

        // Its walls, the far ones first: each edge of its outline, up to the roof.
        let tall = hypot(vehicle.up.dx, vehicle.up.dy) > 0.4
        if tall {
            let walls = (0..<count).sorted { a, b in
                (ground[a].y + ground[(a + 1) % count].y) < (ground[b].y + ground[(b + 1) % count].y)
            }
            for index in walls {
                let a = ground[index], b = ground[(index + 1) % count]
                let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                // The walls facing the camera (below the vehicle's middle on screen) in
                // full light, the others in shade.
                let facing = middle.y >= center.y
                let isSide = index != sides - 1 && index != count - 1
                // Which end this is: the "to" end (further along the run) or the "from".
                let isAheadEnd = index == sides - 1
                let isDrivingEnd = !isSide && vehicle.kind != .coach && isAheadEnd == vehicle.leadsAhead
                fill(quad(a, b, 0, 1, up: vehicle.up), body.shaded(facing ? 1 : 0.72))
                if isSide {
                    if isLocomotive {
                        // A white stripe along its flank.
                        fill(quad(a, b, 0.55, 0.66, up: vehicle.up, inset: 0.04), UIColor.white.shaded(facing ? 0.95 : 0.7))
                    } else {
                        // The green band along the bottom, and the two decks of windows.
                        fill(quad(a, b, 0.02, 0.24, up: vehicle.up), Self.goGreen.shaded(facing ? 1 : 0.72))
                        fill(quad(a, b, 0.32, 0.46, up: vehicle.up, inset: 0.09), Self.glass)
                        fill(quad(a, b, 0.60, 0.76, up: vehicle.up, inset: 0.09), Self.glass)
                    }
                } else if isDrivingEnd {
                    fill(quad(a, b, 0.58, 0.84, up: vehicle.up, inset: 0.14), Self.glass)
                    if !isLocomotive {
                        fill(quad(a, b, 0.02, 0.30, up: vehicle.up), Self.goGreen.shaded(facing ? 1 : 0.72))
                    }
                }
                Self.edge.setStroke()
                let outline = quad(a, b, 0, 1, up: vehicle.up)
                outline.lineWidth = 0.4
                outline.stroke()
            }
        }

        // Its roof.
        let roof = vehicle.roof
        let roofPath = Self.path(roof)
        (isLocomotive ? Self.locomotiveRoof : Self.coachRoof).setFill()
        roofPath.fill()
        // A ridge down the middle of it, and the driving end's windscreen seen from above.
        let leftRoof = Array(roof[0..<sides]), rightRoof = Array(roof[sides..<count].reversed())
        let ridge = UIBezierPath()
        for step in 0..<sides {
            let point = CGPoint(x: (leftRoof[step].x + rightRoof[step].x) / 2, y: (leftRoof[step].y + rightRoof[step].y) / 2)
            step == 0 ? ridge.move(to: point) : ridge.addLine(to: point)
        }
        UIColor.black.withAlphaComponent(0.12).setStroke()
        ridge.lineWidth = max(0.5, min(hypot(leftRoof[0].x - rightRoof[0].x, leftRoof[0].y - rightRoof[0].y) * 0.18, 2))
        ridge.stroke()
        if vehicle.kind != .coach {
            // The last tenth of it at the driving end.
            let end = vehicle.leadsAhead ? sides - 1 : 0
            let inner = vehicle.leadsAhead ? sides - 2 : 1
            func toward(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
                CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            let t: CGFloat = 0.2
            let cab = Self.path([leftRoof[end], rightRoof[end],
                                 toward(rightRoof[end], rightRoof[inner], t), toward(leftRoof[end], leftRoof[inner], t)])
            Self.glass.withAlphaComponent(isLocomotive ? 0.55 : 0.4).setFill()
            cab.fill()
        }
        if let highlight {
            highlight.setStroke()
            roofPath.lineWidth = 1.6
        } else {
            Self.edge.setStroke()
            roofPath.lineWidth = 0.5
        }
        roofPath.stroke()
    }

    /// A band up a wall from ground edge `a`–`b`: from `low` to `high` of the
    /// way up, cut short by `inset` of its length at each end.
    private func quad(_ a: CGPoint, _ b: CGPoint, _ low: CGFloat, _ high: CGFloat, up: CGVector,
                      inset: CGFloat = 0) -> UIBezierPath {
        let p = CGPoint(x: a.x + (b.x - a.x) * inset, y: a.y + (b.y - a.y) * inset)
        let q = CGPoint(x: b.x + (a.x - b.x) * inset, y: b.y + (a.y - b.y) * inset)
        func lift(_ point: CGPoint, _ by: CGFloat) -> CGPoint {
            CGPoint(x: point.x + up.dx * by, y: point.y + up.dy * by)
        }
        return Self.path([lift(p, low), lift(q, low), lift(q, high), lift(p, high)])
    }

    private func fill(_ path: UIBezierPath, _ color: UIColor) {
        color.setFill()
        path.fill()
    }

    private static func path(_ points: [CGPoint]) -> UIBezierPath {
        let path = UIBezierPath()
        for (index, point) in points.enumerated() {
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.close()
        return path
    }
}

private extension UIColor {
    /// This colour, darker by `light` (1: as it is).
    func shaded(_ light: CGFloat) -> UIColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return self }
        return UIColor(red: red * light, green: green * light, blue: blue * light, alpha: alpha)
    }
}
