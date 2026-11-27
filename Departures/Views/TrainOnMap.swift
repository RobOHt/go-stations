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
    /// The train at its true length, as a pill along its track (see `layoutModel(in:)`).
    private let model = TrainPillView()
    /// The line's colour.
    private var color: UIColor = .gray
    /// The marker makes way for the pill when that's big enough to see as a train.
    private var markerHidden = false
    /// Holds the marker (`content`), so it can shrink away and fade as the pill
    /// grows out of it.
    private let markerHolder = UIView()
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

        model.frame = bounds
        addSubview(model)

        markerHolder.frame = bounds
        markerHolder.isUserInteractionEnabled = false
        addSubview(markerHolder)
        content.frame = bounds
        content.isUserInteractionEnabled = false
        markerHolder.addSubview(content)

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

    /// A train this many points long or longer on the screen is drawn as its pill,
    /// in place of the marker.
    static let pillFrom: CGFloat = 44

    /// Draws the train as its pill (its annotation's `model`) as the map shows it
    /// now: where it is, how far the map is zoomed in, and how it's turned and
    /// tilted. Too small to make out, or with no model, it's the marker instead.
    ///
    /// The pill grows out of the marker along the track, and shrinks back into it
    /// as the map zooms out (at once with `animated` false, as for a train coming
    /// onto the screen).
    func layoutModel(in mapView: MKMapView, animated: Bool = true) {
        guard let marker = annotation as? TrainAnnotation, let train = marker.model else {
            hideModel(animated: animated)
            return
        }
        let coordinate = marker.coordinate
        let anchor = mapView.convert(coordinate, toPointTo: mapView)
        // Points per metre where the train is: where 20 m east and 20 m north of it
        // fall on the screen (across the screen, a metre is the same whichever way
        // it runs, however the map is turned or tilted).
        let here = TrackGeometry.point(.init(latitude: coordinate.latitude, longitude: coordinate.longitude))
        func screen(_ dx: Double, _ dy: Double) -> CGPoint {
            let moved = TrackGeometry.coordinate(.init(x: here.x + dx, y: here.y + dy))
            return mapView.convert(CLLocationCoordinate2D(latitude: moved.latitude, longitude: moved.longitude),
                                   toPointTo: mapView)
        }
        let east = screen(20, 0), north = screen(0, 20)
        let scale = hypot(east.x - anchor.x, north.x - anchor.x) / 20
        guard scale.isFinite, scale > 0 else {
            hideModel(animated: animated)
            return
        }
        let shows = CGFloat(train.length) * scale >= Self.pillFrom
        // Too small to show and not on its way out: nothing to lay out.
        guard shows || model.isShown || model.isLeaving else {
            hideModel(animated: animated)
            return
        }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        func local(_ point: CLLocationCoordinate2D) -> CGPoint {
            let onMap = mapView.convert(point, toPointTo: mapView)
            return CGPoint(x: onMap.x - anchor.x + center.x, y: onMap.y - anchor.y + center.y)
        }
        // The joints show while the coaches are far enough apart to tell.
        let showsJoints = CGFloat(TrainConsist.coachLength) * scale >= TrainPillView.jointsFrom
        model.show(line: train.line.map(local), joints: train.joints.map(local), around: center, color: color)
        model.setJointsShown(showsJoints, animated: animated)
        model.setShown(shows, animated: animated)
        setMarkerHidden(shows, animated: animated)
    }

    /// Whether `point` (in `view`'s coordinates) is on the train's pill, as drawn.
    func modelContains(_ point: CGPoint, from view: UIView) -> Bool {
        guard model.isShown else { return false }
        return model.contains(model.convert(point, from: view))
    }

    /// Whether the train is on the move: the arrow at the front of its pill pushes
    /// forward while it is.
    func setMoving(_ moving: Bool) {
        model.isMoving = moving
    }

    private func hideModel(animated: Bool) {
        model.setShown(false, animated: animated)
        setMarkerHidden(false, animated: animated)
    }

    /// The marker shrinks and fades as the pill grows out of it, and comes back
    /// as the pill shrinks into it.
    private func setMarkerHidden(_ hidden: Bool, animated: Bool) {
        guard hidden != markerHidden else { return }
        markerHidden = hidden
        let change = {
            self.markerHolder.alpha = hidden ? 0 : 1
            self.markerHolder.transform = hidden ? CGAffineTransform(scaleX: 0.5, y: 0.5) : .identity
        }
        if animated, window != nil {
            UIView.animate(withDuration: TrainPillView.duration, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut],
                           animations: change)
        } else {
            markerHolder.layer.removeAllAnimations()
            change()
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
        model.alpha = 1
        model.setShown(false, animated: false)
        model.clear()
        model.isMoving = false
        markerHidden = false
        markerHolder.layer.removeAllAnimations()
        markerHolder.alpha = 1
        markerHolder.transform = .identity
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

// MARK: - The train at its true length

/// Where a train's pill goes on the map: down the middle of its track from its
/// back to its front (the way it's going), bending with the track, and where its
/// vehicles meet, as `TrainConsist` lays them out.
struct TrainModel {
    /// Its centreline, from its back to its front.
    let line: [CLLocationCoordinate2D]
    /// Where one vehicle meets the next.
    let joints: [CLLocationCoordinate2D]
    /// The whole train's length, in metres.
    let length: Double

    /// Points along the centreline at most this many metres apart.
    static let step = 8.0

    /// `consist` with its locomotive centred `anchor` metres along `run`. Nil where
    /// the run has no track to lay it along.
    init?(consist: TrainConsist, anchor: Double, on run: TrainRun) {
        let vehicles = consist.vehicles(at: anchor)
        guard let back = vehicles.map(\.from).min(), let front = vehicles.map(\.to).max(), front > back else { return nil }
        let count = max(Int(((front - back) / Self.step).rounded(.up)), 1)
        var samples: [TrackGeometry.Point] = []
        for index in 0...count {
            guard let placed = run.point(at: back + (front - back) * Double(index) / Double(count)) else { return nil }
            samples.append(placed.point)
        }
        let points = Self.forwardOnly(samples)
        guard points.count >= 2 else { return nil }
        // The joints, spaced along the pill as the vehicles are along the train.
        var lengths: [Double] = [0]
        for index in 1..<points.count {
            lengths.append(lengths[index - 1] + hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y))
        }
        let total = lengths[lengths.count - 1]
        var ends = Set(vehicles.flatMap { [$0.from, $0.to] }.map { ($0 * 100).rounded() / 100 })
        ends.remove((back * 100).rounded() / 100)
        ends.remove((front * 100).rounded() / 100)
        joints = ends.sorted().map { end in
            let along = (end - back) / (front - back) * total
            var index = 1
            while index < lengths.count - 1, lengths[index] < along { index += 1 }
            let span = lengths[index] - lengths[index - 1]
            let t = span > 0 ? (along - lengths[index - 1]) / span : 0
            let a = points[index - 1], b = points[index]
            return Self.coordinate(.init(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        line = points.map(Self.coordinate)
        length = consist.length
    }

    /// `points` (back to front) without the stretches where they turn back on
    /// themselves: GO's track shapes zigzag here and there (just east of Kitchener,
    /// for one), which a train's length laid along them would fold over. A point is
    /// kept only while it carries on the way the train was going.
    static func forwardOnly(_ points: [TrackGeometry.Point]) -> [TrackGeometry.Point] {
        guard var last = points.first, let end = points.last else { return [] }
        var kept = [last]
        // To start with, the way from its back to its front.
        let chord = hypot(end.x - last.x, end.y - last.y)
        var direction: (x: Double, y: Double)? = chord > 0 ? ((end.x - last.x) / chord, (end.y - last.y) / chord) : nil
        for point in points.dropFirst() {
            let dx = point.x - last.x, dy = point.y - last.y
            let size = hypot(dx, dy)
            guard size > 0.5 else { continue }
            let unit = (x: dx / size, y: dy / size)
            // More than 60° off the way it was going: a turn back, not a curve.
            if let direction, unit.x * direction.x + unit.y * direction.y < 0.5 { continue }
            kept.append(point)
            direction = unit
            last = point
        }
        return kept
    }

    private static func coordinate(_ point: TrackGeometry.Point) -> CLLocationCoordinate2D {
        let coordinate = TrackGeometry.coordinate(point)
        return CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

/// A train drawn at its true length: a pill in its line's colour with a white
/// casing, laid along its track. Zoomed in far enough, white dots mark the joints
/// between its vehicles. At its front, the marker's white arrow points the way it
/// goes, and while it moves, pushes forward with two copies streaming ahead (still
/// with Reduce Motion).
final class TrainPillView: UIView {
    /// The pill's width, in points (its casing adds to it).
    static let width: CGFloat = 14
    static let casingWidth: CGFloat = 19
    /// The dots at the joints show once a coach is this many points long.
    static let jointsFrom: CGFloat = 13

    /// How long the pill takes to grow out of the marker or shrink into it.
    static let duration: TimeInterval = 0.3

    /// Everything, faded in and out together.
    private let group = CALayer()
    private let casing = CAShapeLayer()
    private let body = CAShapeLayer()
    private let dots = CAShapeLayer()
    /// How far along the pill (0 its back, 1 its front) the marker sits: the pill
    /// grows out from there, and shrinks back to it.
    private var anchor: CGFloat = 0.5
    /// Showing the train (or growing to), rather than shrunk into the marker.
    private(set) var isShown = false
    /// Shrinking into the marker, until it's done.
    private(set) var isLeaving = false
    private var jointsShown = false
    /// The arrow at the front, turned the way the train goes.
    private let tip = CALayer()
    private let arrow = CAShapeLayer()
    private let echoes = [CAShapeLayer(), CAShapeLayer()]
    /// The casing's outline, for taps.
    private var outline: CGPath?

    var isMoving = false {
        didSet { if isMoving != oldValue { updateMotion() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        layer.addSublayer(group)
        group.opacity = 0
        for line in [casing, body] {
            line.fillColor = nil
            line.lineCap = .round
            line.lineJoin = .round
            line.strokeStart = 0.5
            line.strokeEnd = 0.5
            group.addSublayer(line)
        }
        casing.strokeColor = UIColor.white.cgColor
        casing.lineWidth = Self.casingWidth
        casing.shadowColor = UIColor.black.cgColor
        casing.shadowOpacity = 0.3
        casing.shadowRadius = 2
        casing.shadowOffset = CGSize(width: 0, height: 1)
        body.lineWidth = Self.width
        dots.fillColor = UIColor.white.cgColor
        dots.opacity = 0
        group.addSublayer(dots)

        // The marker's arrow, pointing up from the tip layer's middle: turned to
        // point the way the train goes, its base just clear of the pill's front.
        tip.bounds = CGRect(x: 0, y: 0, width: 30, height: 30)
        let shape = UIBezierPath()
        shape.move(to: CGPoint(x: 15, y: 15 - 11.5))
        shape.addLine(to: CGPoint(x: 15 + 6.5, y: 15))
        shape.addLine(to: CGPoint(x: 15 - 6.5, y: 15))
        shape.close()
        for layer in echoes + [arrow] {
            layer.frame = tip.bounds
            layer.path = shape.cgPath
            layer.fillColor = UIColor.white.cgColor
            layer.strokeColor = UIColor.white.cgColor
            layer.lineWidth = 1.5
            layer.lineJoin = .round
            tip.addSublayer(layer)
        }
        arrow.shadowColor = UIColor.black.cgColor
        arrow.shadowOpacity = 0.35
        arrow.shadowRadius = 2
        arrow.shadowOffset = CGSize(width: 0, height: 1)
        for echo in echoes { echo.opacity = 0 }
        group.addSublayer(tip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Lays the pill along `line` (back to front, in this view's coordinates),
    /// with dots at `joints`, growing from and shrinking to where it passes
    /// `around` (the marker).
    func show(line: [CGPoint], joints: [CGPoint], around: CGPoint, color: UIColor) {
        guard line.count >= 2 else {
            clear()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = UIBezierPath()
        path.move(to: line[0])
        for point in line.dropFirst() { path.addLine(to: point) }
        // Where along it the marker is: the nearest of its points, by length.
        var lengths: [CGFloat] = [0]
        for index in 1..<line.count {
            lengths.append(lengths[index - 1] + hypot(line[index].x - line[index - 1].x, line[index].y - line[index - 1].y))
        }
        if let nearest = line.indices.min(by: {
            hypot(line[$0].x - around.x, line[$0].y - around.y) < hypot(line[$1].x - around.x, line[$1].y - around.y)
        }), let total = lengths.last, total > 0 {
            anchor = lengths[nearest] / total
        }
        casing.path = path.cgPath
        body.path = path.cgPath
        body.strokeColor = color.cgColor
        let dotPath = UIBezierPath()
        for joint in joints {
            dotPath.append(UIBezierPath(ovalIn: CGRect(x: joint.x - 2, y: joint.y - 2, width: 4, height: 4)))
        }
        dots.path = dotPath.cgPath
        outline = path.cgPath.copy(strokingWithWidth: Self.casingWidth + 8, lineCap: .round, lineJoin: .round,
                                    miterLimit: 10)

        // The arrow: just ahead of the front, the way the last stretch of the pill runs.
        let front = line[line.count - 1]
        var from = line[line.count - 2]
        for point in line.reversed() where hypot(front.x - point.x, front.y - point.y) >= 6 {
            from = point
            break
        }
        let dx = front.x - from.x, dy = front.y - from.y
        let size = hypot(dx, dy)
        if size > 0 {
            let ux = dx / size, uy = dy / size
            let ahead = Self.casingWidth / 2 + 1
            tip.position = CGPoint(x: front.x + ux * ahead, y: front.y + uy * ahead)
            tip.setAffineTransform(CGAffineTransform(rotationAngle: atan2(ux, -uy)))
            tip.isHidden = false
        } else {
            tip.isHidden = true
        }
        CATransaction.commit()
    }

    /// Grows the pill out of the marker (`shown`), or shrinks it back into it, with
    /// the whole of it fading in or out as it goes.
    func setShown(_ shown: Bool, animated: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        let start: CGFloat = shown ? 0 : anchor, end: CGFloat = shown ? 1 : anchor
        let opacity: Float = shown ? 1 : 0
        let animates = animated && window != nil
        isLeaving = !shown && animates
        // From where it is now, as drawn (a change of mind halfway turns it round);
        // out of sight, from the marker.
        let outOfSight = (group.presentation() ?? group).opacity == 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isLeaving {
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, !self.isShown else { return }
                self.isLeaving = false
            }
        }
        func animate(_ layer: CALayer, _ key: String, from: Any, to: Any) {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = Self.duration
            animation.timingFunction = CAMediaTimingFunction(name: shown ? .easeOut : .easeIn)
            layer.add(animation, forKey: key)
        }
        for line in [casing, body] {
            if animates {
                let now = line.presentation() ?? line
                animate(line, "strokeStart", from: outOfSight ? anchor : now.strokeStart, to: start)
                animate(line, "strokeEnd", from: outOfSight ? anchor : now.strokeEnd, to: end)
            } else {
                line.removeAllAnimations()
            }
            line.strokeStart = start
            line.strokeEnd = end
        }
        if animates {
            animate(group, "opacity", from: (group.presentation() ?? group).opacity, to: opacity)
            // The arrow comes in once the pill has nearly reached the front, and goes first.
            let arrive = CABasicAnimation(keyPath: "opacity")
            arrive.fromValue = 0
            arrive.toValue = 1
            arrive.duration = shown ? Self.duration * 0.4 : Self.duration * 0.3
            arrive.beginTime = tip.convertTime(CACurrentMediaTime(), from: nil) + (shown ? Self.duration * 0.7 : 0)
            arrive.fillMode = .both
            if !shown {
                (arrive.fromValue, arrive.toValue) = (1, 0)
                // Gone until the pill next grows (which replaces this).
                arrive.isRemovedOnCompletion = false
            }
            tip.add(arrive, forKey: "opacity")
        } else {
            group.removeAllAnimations()
            tip.removeAnimation(forKey: "opacity")
        }
        group.opacity = opacity
        CATransaction.commit()
    }

    /// Fades the dots at the joints in or out.
    func setJointsShown(_ shown: Bool, animated: Bool) {
        guard shown != jointsShown else { return }
        jointsShown = shown
        CATransaction.begin()
        CATransaction.setDisableActions(!(animated && window != nil))
        CATransaction.setAnimationDuration(0.25)
        dots.opacity = shown ? 1 : 0
        CATransaction.commit()
    }

    func clear() {
        casing.path = nil
        body.path = nil
        dots.path = nil
        outline = nil
        tip.isHidden = true
    }

    /// Whether `point` (in this view's coordinates) is on the pill.
    func contains(_ point: CGPoint) -> Bool {
        outline?.contains(point) ?? false
    }

    /// While the train moves, the arrow pushes forward and back with two copies of
    /// it streaming ahead and fading, as on the marker.
    private func updateMotion() {
        arrow.removeAnimation(forKey: "push")
        for echo in echoes {
            echo.removeAnimation(forKey: "stream")
            echo.opacity = 0
        }
        guard isMoving, window != nil, !UIAccessibility.isReduceMotionEnabled else { return }
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

    /// Core Animation drops the animations when the view leaves the screen.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { updateMotion() }
    }
}
