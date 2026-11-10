import SwiftUI
import UIKit

/// A blur of what's behind, from none at the top to `radius` at the bottom, with no
/// tint: the map keeps its own colours, only softer, like the system's own edge
/// blurs. (A material can't do that: every material lays a tint over its blur,
/// grey-white in dark mode, which shows over a dark map, #19.)
///
/// iOS draws this blur itself at the edges of scroll views, but offers nothing for
/// it anywhere else. So it's made the way the system makes its own, and the way the
/// usual open-source versions do (Janum Trivedi's VariableBlurView, nikstar's
/// VariableBlur, Tim Oliver's BlurUIKit): Core Animation's variable blur filter on
/// the backdrop layer of a `UIVisualEffectView`, in place of UIKit's blur and colour
/// filters, with UIKit's tint views hidden. The filter isn't public API, so where an
/// iOS doesn't offer it, nothing is drawn: never UIKit's tinted material.
struct ProgressiveBlur: UIViewRepresentable {
    /// The blur radius at its strongest, in points.
    var radius: CGFloat
    /// How far down, as a fraction of the height, it gets to `radius`; it stays
    /// there below that.
    var fullAt: CGFloat = 1

    func makeUIView(context: Context) -> ProgressiveBlurView {
        ProgressiveBlurView()
    }

    func updateUIView(_ view: ProgressiveBlurView, context: Context) {
        view.radius = radius
        view.fullAt = fullAt
    }
}

final class ProgressiveBlurView: UIView {
    var radius: CGFloat = 0 {
        didSet { if radius != oldValue { setNeedsLayout() } }
    }
    var fullAt: CGFloat = 1 {
        didSet { if fullAt != oldValue { setNeedsLayout() } }
    }

    private let effectView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    /// The filter on the backdrop, while it's ours. UIKit puts its own filters back
    /// when the appearance changes, which releases ours.
    private weak var installed: NSObject?
    private var installedLook: Look?

    private struct Look: Equatable {
        let radius: CGFloat
        let fullAt: CGFloat
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        effectView.isUserInteractionEnabled = false
        effectView.isHidden = true  // until the blur is on it
        addSubview(effectView)
        // UIKit rebuilds its effect when the appearance changes, putting its own
        // filters and tint back: then put the blur back.
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self,
                                 UITraitDisplayScale.self]) { (view: ProgressiveBlurView, _: UITraitCollection) in
            view.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        effectView.frame = bounds
        guard window != nil else { return }
        let look = Look(radius: radius, fullAt: fullAt)
        if let installed, installedLook == look,
           Self.backdrop(of: effectView)?.layer.filters?.first as? NSObject === installed {
            Self.hideTint(of: effectView)  // in case UIKit showed it again
        } else {
            installed = Self.install(on: effectView, radius: radius, fullAt: fullAt)
            installedLook = look
        }
        effectView.isHidden = installed == nil
    }

    // MARK: The blur

    /// Puts the variable blur on `view`'s backdrop in place of UIKit's filters and
    /// hides UIKit's tint. Returns the filter, or nil (changing nothing) where iOS
    /// doesn't offer it.
    @discardableResult
    static func install(on view: UIVisualEffectView, radius: CGFloat, fullAt: CGFloat) -> NSObject? {
        guard let backdrop = backdrop(of: view), let filter = makeFilter?("variableBlur"),
              let mask = mask(fullAt: fullAt) else { return nil }
        // The mask's alpha says how much of the radius, pixel by pixel.
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(mask, forKey: "inputMaskImage")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        backdrop.layer.filters = [filter]
        // What's behind, at full resolution: at the top it's barely blurred, where
        // UIKit's lower resolution for its own blur would show.
        backdrop.layer.setValue(1.0, forKey: "scale")
        hideTint(of: view)
        return filter
    }

    /// Hides everything UIKit draws over the backdrop: its tint, and the overlays
    /// some materials add.
    static func hideTint(of view: UIVisualEffectView) {
        let backdrop = backdrop(of: view)
        for subview in view.subviews where subview !== backdrop && subview !== view.contentView {
            subview.isHidden = true
        }
    }

    /// The view whose layer captures and filters what's behind.
    static func backdrop(of view: UIVisualEffectView) -> UIView? {
        view.subviews.first { subview in
            NSStringFromClass(type(of: subview)).localizedCaseInsensitiveContains("backdrop")
                || NSStringFromClass(type(of: subview.layer)).localizedCaseInsensitiveContains("backdrop")
        }
    }

    /// Makes a Core Animation filter by name. Its class isn't public, but UIKit's own
    /// blur has an instance of it, whose class makes others; nil if not.
    static let makeFilter: ((String) -> NSObject?)? = {
        let probe = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
        guard let sample = ProgressiveBlurView.backdrop(of: probe)?.layer.filters?.first as? NSObject else {
            return nil
        }
        let filterClass = type(of: sample)
        let selector = NSSelectorFromString(["Type:", "With", "filter"].reversed().joined())
        guard filterClass.responds(to: selector) else { return nil }
        return { name in
            (filterClass as AnyObject).perform(selector, with: name)?.takeUnretainedValue() as? NSObject
        }
    }()

    private static var masks: [CGFloat: CGImage] = [:]

    /// A strip, top to bottom, clear to opaque: eased in from the top, opaque from
    /// `fullAt` down. The filter stretches it over the view.
    static func mask(fullAt: CGFloat) -> CGImage? {
        if let mask = masks[fullAt] { return mask }
        let rows = 256
        guard let context = CGContext(data: nil, width: 1, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let full = min(max(fullAt, 0.01), 1)
        for row in 0..<rows {
            let along = min(CGFloat(row) / CGFloat(rows - 1) / full, 1)
            let alpha = (1 - cos(.pi * along)) / 2
            let pixel = row * context.bytesPerRow
            pixels[pixel] = 0
            pixels[pixel + 1] = 0
            pixels[pixel + 2] = 0
            pixels[pixel + 3] = UInt8((alpha * 255).rounded())
        }
        let mask = context.makeImage()
        masks[fullAt] = mask
        return mask
    }
}
