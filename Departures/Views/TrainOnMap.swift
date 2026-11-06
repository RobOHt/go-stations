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
/// ring (grey while it waits or once it's done). When you're on board it also
/// carries your location's blue halo. Ignores touches like the other markers; the
/// map's tap handler opens the trip.
final class TrainAnnotationView: MKAnnotationView {
    static let reuseID = "train"

    private let halo = UIView()
    private let disc = UIView()
    private let glyph = UIImageView()

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
}

// MARK: - The stretch still to travel

/// The track from the train to your stop.
final class TrainRouteOverlay: MKPolyline {
    private(set) var color: UIColor = .gray

    static func make(_ coordinates: [CLLocationCoordinate2D], color: UIColor) -> TrainRouteOverlay {
        let overlay = TrainRouteOverlay(coordinates: coordinates, count: coordinates.count)
        overlay.color = color
        return overlay
    }
}

/// Draws the stretch still to travel a little wider than the line, with white
/// chevrons flowing toward your stop, like the trip sheet's line.
final class FlowingRouteRenderer: MKPolylineRenderer {
    /// How far the chevrons have flowed, in screen points (read while drawing,
    /// which MapKit does off the main thread).
    var phase: CGFloat {
        get { lock.lock(); defer { lock.unlock() }; return storedPhase }
        set { lock.lock(); storedPhase = newValue; lock.unlock() }
    }

    /// Screen points between chevrons.
    static let spacing: CGFloat = 18

    private let lock = NSLock()
    private var storedPhase: CGFloat = 0

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        super.draw(mapRect, zoomScale: zoomScale, in: context)

        let width = lineWidth
        guard width >= 6, polyline.pointCount >= 2 else { return }
        let unit = 1 / zoomScale  // renderer units per screen point
        let mapPoints = polyline.points()
        var points: [CGPoint] = []
        points.reserveCapacity(polyline.pointCount)
        for index in 0..<polyline.pointCount {
            points.append(point(for: mapPoints[index]))
        }

        let spacing = Self.spacing * unit
        let halfWidth = width * 0.3 * unit
        let depth = width * 0.22 * unit
        let clip = rect(for: mapRect).insetBy(dx: -width * unit, dy: -width * unit)
        var next = spacing - (phase.truncatingRemainder(dividingBy: Self.spacing) * unit)
        var travelled: CGFloat = 0
        let chevrons = CGMutablePath()

        for index in 0..<(points.count - 1) {
            let a = points[index], b = points[index + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0 else { continue }
            let ux = dx / length, uy = dy / length
            while next <= travelled + length {
                let along = next - travelled
                let center = CGPoint(x: a.x + ux * along, y: a.y + uy * along)
                if clip.contains(center) {
                    // A V pointing the way the train goes.
                    let tip = CGPoint(x: center.x + ux * depth, y: center.y + uy * depth)
                    let back = CGPoint(x: center.x - ux * depth, y: center.y - uy * depth)
                    chevrons.move(to: CGPoint(x: back.x - uy * halfWidth, y: back.y + ux * halfWidth))
                    chevrons.addLine(to: tip)
                    chevrons.addLine(to: CGPoint(x: back.x + uy * halfWidth, y: back.y - ux * halfWidth))
                }
                next += spacing
            }
            travelled += length
        }

        context.addPath(chevrons)
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.92).cgColor)
        context.setLineWidth(max(1.4, width * 0.2) * unit)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
    }
}
