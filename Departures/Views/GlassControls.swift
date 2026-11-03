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

// MARK: - Pinned sheet header

/// Spacing for a sheet's pinned header. The text sits further in from the
/// sheet's rounded top corners than the buttons do.
enum PinnedHeaderMetrics {
    static let leading: CGFloat = 24
    static let trailing: CGFloat = 16
    static let top: CGFloat = 20
    /// Extra room for the text above the buttons' top edge.
    static let textTop: CGFloat = 6
    /// Room below the header, so the soft scroll edge under the bar covers all
    /// of the header before it fades out.
    static let bottom: CGFloat = 20
}

extension View {
    /// Pins `header` in a bar over the top of this scroll view, like a navigation
    /// bar: the content scrolls under it with the system's soft scroll edge.
    func pinnedHeader<Header: View>(@ViewBuilder _ header: () -> Header) -> some View {
        let content = header()
        return self
            .scrollEdgeEffectStyle(.soft, for: .top)
            .safeAreaBar(edge: .top) {
                content
                    .padding(.leading, PinnedHeaderMetrics.leading)
                    .padding(.trailing, PinnedHeaderMetrics.trailing)
                    .padding(.top, PinnedHeaderMetrics.top)
                    .padding(.bottom, PinnedHeaderMetrics.bottom)
            }
    }
}

/// A lone round glass close button, matching the grouped glass buttons.
struct GlassCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GlassIcon(systemName: "xmark")
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("Close")
    }
}

// MARK: - Status bar blur

/// The soft blur under the status bar that system apps have at the top of the
/// screen: a material that fades out just below the status bar.
struct StatusBarBlur: View {
    let statusBarHeight: CGFloat

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .mask(fade(solidUntil: 0.3))
            .frame(height: statusBarHeight + 28)
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func fade(solidUntil solid: CGFloat) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: solid),
                .init(color: .clear, location: 1),
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
