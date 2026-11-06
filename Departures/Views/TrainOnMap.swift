import MapKit
import UIKit

// MARK: - Trains

/// A train on the map: the tracked one, or (with Show All Trains on) one of the
/// others running now. Its coordinate moves as the train does.
final class TrainAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    /// The other trains' timetable trip; nil for the tracked train.
    let running: ScheduleStore.RunningTrip?

    init(coordinate: CLLocationCoordinate2D, running: ScheduleStore.RunningTrip? = nil) {
        self.coordinate = coordinate
        self.running = running
    }
}

/// The train marker, as in the trip sheet: a train on a disc of the line's colour
/// in a white ring, with a white pointer on the ring showing which way it's going.
/// While the tracked train moves, its pointer pushes forward with copies of it
/// streaming ahead, and rings in the line's colour spread from the disc, so it
/// catches the eye. When you're on board it carries your location's blue halo
/// instead of the rings. Ignores touches like the other markers; the map's tap
/// handler opens the trip.
final class TrainAnnotationView: MKAnnotationView {
    static let reuseID = "train"

    /// Everything, so the other trains can be drawn smaller than the tracked one.
    private let content = UIView()
    private let halo = UIView()
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

        content.frame = bounds
        content.isUserInteractionEnabled = false
        addSubview(content)

        halo.frame = bounds
        halo.layer.cornerRadius = bounds.width / 2
        halo.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.22)
        halo.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.5).cgColor
        halo.layer.borderWidth = 1
        halo.isHidden = true
        content.addSubview(halo)

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
    /// tracked train, while it moves), whether you're on it, and its size: the
    /// tracked train full size, the others a little smaller.
    func configure(color: UIColor, animatesPointer: Bool, isOnBoard: Bool, scale: CGFloat = 1) {
        disc.backgroundColor = color
        ripple.strokeColor = color.withAlphaComponent(0.9).cgColor
        ripple.fillColor = color.withAlphaComponent(0.18).cgColor
        if content.transform.a != scale {
            content.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
        if isOnBoard != !halo.isHidden {
            halo.isHidden = !isOnBoard
            halo.layer.removeAllAnimations()
            if isOnBoard {
                let pulse = CABasicAnimation(keyPath: "transform.scale")
                pulse.fromValue = 0.8
                pulse.toValue = 1.1
                pulse.duration = 1.4
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                halo.layer.add(pulse, forKey: "pulse")
            }
            updateMotion()
        }
        if animatesPointer != isAnimated {
            isAnimated = animatesPointer
            updateMotion()
        }
        accessibilityLabel = isOnBoard ? "Your train" : "Train"
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
        let turned = angle + delta
        let layer = pointer.layer
        if animated, !pointer.isHidden {
            // Over the second until the next update, like the marker's own movement.
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = angle
            animation.toValue = turned
            animation.duration = 1
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(animation, forKey: "turn")
        } else {
            layer.removeAnimation(forKey: "turn")
        }
        layer.setValue(turned, forKeyPath: "transform.rotation.z")
        angle = turned
        if pointer.isHidden {
            pointer.isHidden = false
            updateMotion()
        }
    }

    /// The tracked train, while it moves: the pointer pushes forward and back with
    /// two copies of it streaming ahead and fading, and (unless you're on board,
    /// where your halo pulses) rings spread from the disc. Still with Reduce
    /// Motion, while the train stands or waits, and for the other trains (so the
    /// tracked one stands out).
    private func updateMotion() {
        arrow.removeAnimation(forKey: "push")
        for echo in echoes {
            echo.removeAnimation(forKey: "stream")
            echo.opacity = 0
        }
        ripple.removeAnimation(forKey: "ripple")
        ripple.opacity = 0
        guard isAnimated, window != nil, !UIAccessibility.isReduceMotionEnabled else { return }

        if halo.isHidden {
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
        }

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

    // MARK: Coming and going

    /// A train setting off (or just tracked) fades in.
    func fadeIn() {
        content.layer.removeAllAnimations()
        content.alpha = 0
        UIView.animate(withDuration: 0.6, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.content.alpha = 1
        }
    }

    /// A train leaving the map fades out, then `completion` takes it away.
    func fadeOut(completion: @escaping () -> Void) {
        UIView.animate(withDuration: 0.6, delay: 0, options: [.curveEaseIn, .beginFromCurrentState],
                       animations: { self.content.alpha = 0 },
                       completion: { _ in completion() })
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        content.layer.removeAllAnimations()
        content.alpha = 1
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
