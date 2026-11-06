import MapKit
import UIKit

// MARK: - The tracked train

/// The tracked train on the map. Its coordinate moves as the train does.
final class TrainAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }
}

/// The train marker, as in the trip sheet: a train in the line's colour on a white
/// ring (grey while it waits or once it's done), with a small white pointer on the
/// ring showing which way it's going. When you're on board it also carries your
/// location's blue halo. Ignores touches like the other markers; the map's tap
/// handler opens the trip.
final class TrainAnnotationView: MKAnnotationView {
    static let reuseID = "train"

    private let halo = UIView()
    private let pointer = UIView()
    private let disc = UIView()
    private let glyph = UIImageView()

    /// The train's direction of travel, in degrees clockwise from north.
    private var heading: Double?
    /// The map's rotation, in degrees clockwise from north.
    private var mapHeading: Double = 0

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 56, height: 56)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        canShowCallout = false
        displayPriority = .required
        collisionMode = .none
        // Above stations and pins, below your own location dot.
        zPriority = MKAnnotationViewZPriority(rawValue: 990)

        halo.frame = bounds
        halo.layer.cornerRadius = bounds.width / 2
        halo.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.22)
        halo.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.5).cgColor
        halo.layer.borderWidth = 1
        halo.isHidden = true
        addSubview(halo)

        // A small triangle above the disc, its base tucked under the ring; the view
        // turns to point the way the train goes.
        pointer.frame = bounds
        pointer.isHidden = true
        let triangle = CAShapeLayer()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let shape = UIBezierPath()
        shape.move(to: CGPoint(x: center.x, y: center.y - 23))
        shape.addLine(to: CGPoint(x: center.x + 5.5, y: center.y - 13))
        shape.addLine(to: CGPoint(x: center.x - 5.5, y: center.y - 13))
        shape.close()
        triangle.path = shape.cgPath
        triangle.fillColor = UIColor.white.cgColor
        triangle.strokeColor = UIColor.white.cgColor
        triangle.lineWidth = 1.5
        triangle.lineJoin = .round
        triangle.shadowColor = UIColor.black.cgColor
        triangle.shadowOpacity = 0.35
        triangle.shadowRadius = 2
        triangle.shadowOffset = CGSize(width: 0, height: 1)
        pointer.layer.addSublayer(triangle)
        addSubview(pointer)

        disc.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
        disc.center = CGPoint(x: bounds.midX, y: bounds.midY)
        disc.layer.cornerRadius = 16
        disc.layer.borderColor = UIColor.white.cgColor
        disc.layer.borderWidth = 2.5
        disc.layer.shadowColor = UIColor.black.cgColor
        disc.layer.shadowOpacity = 0.35
        disc.layer.shadowRadius = 3
        disc.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(disc)

        glyph.image = UIImage(systemName: "tram.fill",
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold))
        glyph.tintColor = .white
        glyph.contentMode = .center
        glyph.frame = disc.bounds
        disc.addSubview(glyph)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(color: UIColor, isMoving: Bool, isOnBoard: Bool) {
        disc.backgroundColor = isMoving || isOnBoard ? color : .systemGray
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
        accessibilityLabel = isOnBoard ? "Your train" : "Tracked train"
    }

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
        pointer.isHidden = false
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
