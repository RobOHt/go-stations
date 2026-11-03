import SwiftUI
import UIKit

// MARK: - Grouped glass buttons

/// Icon buttons sharing one glass capsule, like the location and map-mode
/// controls in Apple Maps.
struct GlassButtonGroup<Content: View>: View {
    var axis: Axis = .vertical
    @ViewBuilder var content: Content

    var body: some View {
        Group {
            if axis == .vertical {
                VStack(spacing: 0) { content }
            } else {
                HStack(spacing: 0) { content }
            }
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

/// One icon in a `GlassButtonGroup`, or a lone round glass button. With `fill`,
/// the icon sits white on a solid circle of that colour (an "on" toggle).
struct GlassIcon: View {
    let systemName: String
    var color: Color = .primary
    var fill: Color? = nil
    var size: CGFloat = 48

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(fill == nil ? color : .white)
            .frame(width: size, height: size)
            .background {
                if let fill {
                    Circle().fill(fill).padding(4)
                }
            }
            .contentShape(Rectangle())
    }
}

// MARK: - Status bar blur

/// The soft blur under the status bar that system apps have at the top of the
/// screen: strongest at the very top, fading out just below the status bar.
/// Two masked material layers stack so the blur gets progressively stronger
/// towards the top edge.
struct StatusBarBlur: View {
    let statusBarHeight: CGFloat

    var body: some View {
        let height = statusBarHeight + 28
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask(fade(solidUntil: 0.25))
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask(fade(solidUntil: 0.0, endsAt: 0.6))
        }
        .frame(height: height)
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func fade(solidUntil solid: CGFloat, endsAt end: CGFloat = 1) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: solid),
                .init(color: .clear, location: end),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Display corner radius

/// Reports the radius of the screen's rounded corners, using public iOS 26 API:
/// a view in the screen corner whose corners are container-concentric resolves
/// to exactly the display's corner radius. Place it in the bottom-trailing
/// corner of a full-screen view, ignoring the safe area. Reports 0 if unknown.
struct DisplayCornerProbe: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onChange = onChange
    }

    final class ProbeView: UIView {
        var onChange: ((CGFloat) -> Void)?
        private var reported: CGFloat = -1

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            cornerConfiguration = .corners(radius: .containerConcentric(minimum: nil))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let window, bounds.width > 0 else { return }
            let radius = effectiveRadius(corner: .bottomRight)
            // Concentric: this corner's radius is the display's minus the gap to it.
            let frame = convert(bounds, to: window)
            let gap = max(window.bounds.maxX - frame.maxX, window.bounds.maxY - frame.maxY, 0)
            let display = radius > 1 ? radius + gap : 0
            guard abs(display - reported) > 0.5 else { return }
            reported = display
            let callback = onChange
            DispatchQueue.main.async { callback?(display) }
        }
    }
}
