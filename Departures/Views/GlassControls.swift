import SwiftUI
import UIKit

// MARK: - Glass, and what stands in for it before iOS 26

/// How a piece of glass looks.
enum GlassLook {
    /// Plain glass, for a card or panel.
    case plain
    /// Glass that responds to touch, for a button.
    case interactive
    /// Touch-responsive glass in a colour, for a prominent button.
    case tinted(Color)

    @available(iOS 26.0, *)
    var glass: Glass {
        switch self {
        case .plain: .regular
        case .interactive: .regular.interactive()
        case .tinted(let color): .regular.tint(color).interactive()
        }
    }
}

/// What glass sits on, for its stand-in before iOS 26 (no Liquid Glass): over the
/// map it's frosted with a soft shadow, like iOS 18's floating map controls; on a
/// sheet it's a flat grey fill, like iOS 18's sheet buttons and cards.
enum GlassBackdrop {
    case map, sheet
}

extension EnvironmentValues {
    @Entry var glassBackdrop: GlassBackdrop = .map
}

extension View {
    /// Liquid Glass in `shape` behind this view; before iOS 26, its stand-in (see
    /// `GlassBackdrop`).
    func glass(_ look: GlassLook = .interactive, in shape: some Shape) -> some View {
        modifier(GlassBackground(look: look, shape: shape))
    }

    /// The soft edge where content scrolls under a top bar (iOS 26). Before iOS 26
    /// the bar has its own background instead.
    @ViewBuilder
    func softTopScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

private struct GlassBackground<S: Shape>: ViewModifier {
    let look: GlassLook
    let shape: S
    @Environment(\.glassBackdrop) private var backdrop

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(look.glass, in: shape)
        } else {
            content.background {
                switch (look, backdrop) {
                case (.tinted(let color), _):
                    shape.fill(color)
                case (.plain, .sheet):
                    shape.fill(Color(uiColor: .secondarySystemBackground))
                case (.interactive, .sheet):
                    shape.fill(Color(uiColor: .tertiarySystemFill))
                case (_, .map):
                    shape.fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
                }
            }
        }
    }
}

/// Glass shapes in here blend together where they come close, as one piece of
/// Liquid Glass (iOS 26). Before iOS 26 there's nothing to blend: just the content.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

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
        .glass(in: Capsule())
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
    /// The trip sheet keeps its Track button close under the header.
    static let tripBottom: CGFloat = 12
}

extension View {
    /// Pins `header` in a bar over the top of this scroll view, like a navigation
    /// bar: the content scrolls under it with the system's soft scroll edge.
    /// `bottomRoom` is the space under the header inside the bar; a taller bar
    /// means a taller soft edge.
    func pinnedHeader<Header: View>(bottomRoom: CGFloat = PinnedHeaderMetrics.bottom,
                                    @ViewBuilder _ header: () -> Header) -> some View {
        modifier(PinnedHeader(header: header()
            .padding(.leading, PinnedHeaderMetrics.leading)
            .padding(.trailing, PinnedHeaderMetrics.trailing)
            .padding(.top, PinnedHeaderMetrics.top)
            .padding(.bottom, bottomRoom)))
    }
}

/// See `pinnedHeader`. Before iOS 26 (no soft scroll edge) the bar is like a
/// navigation bar of then: clear at rest, frosted with a hairline below once the
/// content scrolls under it.
private struct PinnedHeader<Header: View>: ViewModifier {
    let header: Header
    @State private var scrolledUnder = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .scrollEdgeEffectStyle(.soft, for: .top)
                .safeAreaBar(edge: .top) { header }
        } else {
            content
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top > 1
                } action: { _, under in
                    scrolledUnder = under
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    header
                        .frame(maxWidth: .infinity)
                        .background {
                            Rectangle()
                                .fill(.bar)
                                .overlay(alignment: .bottom) { Divider() }
                                .ignoresSafeArea(edges: .top)
                                .opacity(scrolledUnder ? 1 : 0)
                        }
                        .animation(.easeOut(duration: 0.15), value: scrolledUnder)
                }
        }
    }
}

// MARK: - Pinned sheet bar at the bottom

extension View {
    /// Pins `bar` over the bottom of this scroll view, like a toolbar, where
    /// thumbs are: the content scrolls under it with the system's soft scroll
    /// edge, and the bar's glass buttons float over that.
    func pinnedBottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        modifier(PinnedBottomBar(bar: bar()
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 6)))
    }
}

/// See `pinnedBottomBar`. Before iOS 26 (no soft scroll edge) the bar is like a
/// toolbar of then: frosted, with a hairline above.
private struct PinnedBottomBar<Bar: View>: ViewModifier {
    let bar: Bar

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .safeAreaBar(edge: .bottom) { bar }
        } else {
            content
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    bar
                        .frame(maxWidth: .infinity)
                        .background {
                            Rectangle()
                                .fill(.bar)
                                .overlay(alignment: .top) { Divider() }
                                .ignoresSafeArea(edges: .bottom)
                        }
                }
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
        .glass(in: Circle())
        .accessibilityLabel("Close")
    }
}

// MARK: - Wrapping row

/// Lays its children out in a row, wrapping onto further lines when they run out
/// of room. Items on a line are centred vertically.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(for subviews: Subviews, maxWidth: CGFloat) -> [Line] {
        var lines: [Line] = [Line()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = lines[lines.count - 1].indices.isEmpty ? size.width : spacing + size.width
            if !lines[lines.count - 1].indices.isEmpty, lines[lines.count - 1].width + extra > maxWidth {
                lines.append(Line())
            }
            var line = lines[lines.count - 1]
            line.width += line.indices.isEmpty ? size.width : spacing + size.width
            line.height = max(line.height, size.height)
            line.indices.append(index)
            lines[lines.count - 1] = line
        }
        return lines.filter { !$0.indices.isEmpty }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(for: subviews, maxWidth: proposal.width ?? .infinity)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(for: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }
}
