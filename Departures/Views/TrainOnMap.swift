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
/// While the tracked train moves, its pointer nudges forward and a fainter copy of
/// it slides ahead and fades, so the direction catches the eye. When you're on board
/// it also carries your location's blue halo. Ignores touches like the other
/// markers; the map's tap handler opens the trip.
final class TrainAnnotationView: MKAnnotationView {
    static let reuseID = "train"

    /// Everything, so the other trains can be drawn smaller than the tracked one.
    private let content = UIView()
    private let halo = UIView()
    private let pointer = UIView()
    private let arrow = CAShapeLayer()
    private let echo = CAShapeLayer()
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

        // A small triangle above the disc, its base tucked under the ring; the view
        // turns to point the way the train goes.
        pointer.frame = bounds
        pointer.isHidden = true
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let shape = UIBezierPath()
        shape.move(to: CGPoint(x: center.x, y: center.y - 24.5))
        shape.addLine(to: CGPoint(x: center.x + 6.5, y: center.y - 13))
        shape.addLine(to: CGPoint(x: center.x - 6.5, y: center.y - 13))
        shape.close()
        for layer in [echo, arrow] {
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
        echo.opacity = 0
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

    /// The tracked train, while it moves: the pointer nudges forward and back, and
    /// a fainter copy of it slides ahead and fades out. Still with Reduce Motion,
    /// while the train waits, and for the other trains (so the tracked one stands out).
    private func updateMotion() {
        arrow.removeAnimation(forKey: "nudge")
        echo.removeAnimation(forKey: "wake")
        echo.opacity = 0
        guard isAnimated, window != nil, !pointer.isHidden, !UIAccessibility.isReduceMotionEnabled else { return }

        let nudge = CABasicAnimation(keyPath: "transform.translation.y")
        nudge.fromValue = 0
        nudge.toValue = -2.5
        nudge.duration = 0.6
        nudge.autoreverses = true
        nudge.repeatCount = .infinity
        nudge.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        arrow.add(nudge, forKey: "nudge")

        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = 0
        slide.toValue = -9
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.75
        fade.toValue = 0
        let wake = CAAnimationGroup()
        wake.animations = [slide, fade]
        wake.duration = 1.2
        wake.repeatCount = .infinity
        wake.timingFunction = CAMediaTimingFunction(name: .easeOut)
        echo.add(wake, forKey: "wake")
    }

    /// Core Animation drops the animations when MapKit takes the view off screen.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { updateMotion() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        heading = nil
        pointer.isHidden = true
        isAnimated = false
        updateMotion()
    }
}

// MARK: - The stretch still to travel

/// The track from the train to your stop, drawn a little bolder than the line,
/// with the same white edge (a white casing under the line's colour).
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
