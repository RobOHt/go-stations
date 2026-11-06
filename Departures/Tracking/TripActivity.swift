import ActivityKit
import SwiftUI
import WidgetKit

// The tracked train's Live Activity: what it carries and how it looks. The app
// starts and updates it (TripActivityController); the widget extension draws it
// with the views below. Both targets compile this file, and debug builds of the
// app draw the same views for screenshots (TripActivityGallery).

// MARK: - What it carries

struct TripActivityAttributes: ActivityAttributes {
    /// What changes while the train runs.
    struct ContentState: Codable, Hashable {
        /// When the train leaves your station (the live estimate when there is one).
        var departure: Date
        /// When it reaches your stop.
        var arrival: Date
        /// Whether it had left your station when the app last updated this. The
        /// activity also goes stale at `departure`, which flips it to the ride
        /// while the app isn't running.
        var hasDeparted: Bool
        /// Minutes late at the next of those two stops, from live times; nil when
        /// that isn't known.
        var minutesLate: Int?
        /// The platform at your station, when known.
        var platform: String?
    }

    /// The tracked train: its trip number and scheduled time.
    var tripID: String
    var tripNumber: String
    var lineCode: String
    /// The line's colour, as hex ("00853E").
    var lineColorHex: String
    /// Where you get on: the station the train was tracked from.
    var boardingName: String
    /// Where you get off: home or work if the train gets there, otherwise its last stop.
    var destinationName: String
    /// Where the train ends its run.
    var terminusName: String
    /// When tracking started: the start of the wait on the minimal view's ring.
    var trackedAt: Date
}

extension TripActivityAttributes {
    /// Tapping the Live Activity opens the tracked trip in the app.
    static let openURL = URL(string: "gostations://trip")!

    var lineColor: Color { Self.rgb(lineColorHex).color }

    /// The line's colour, lightened where it would be too dark to see on black
    /// (Barrie's navy, Lakeshore West's maroon, Stouffville's brown).
    var lineColorOnDark: Color {
        let rgb = Self.rgb(lineColorHex)
        guard rgb.luminance < 0.1 else { return rgb.color }
        return RGB(red: rgb.red + (1 - rgb.red) * 0.3,
                   green: rgb.green + (1 - rgb.green) * 0.3,
                   blue: rgb.blue + (1 - rgb.blue) * 0.3).color
    }

    private struct RGB {
        var red: Double
        var green: Double
        var blue: Double

        var color: Color { Color(red: red, green: green, blue: blue) }

        /// Relative luminance, as WCAG measures contrast.
        var luminance: Double {
            func linear(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
    }

    private static func rgb(_ hex: String) -> RGB {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), radix: 16) ?? 0x888888
        return RGB(red: Double((value >> 16) & 0xFF) / 255,
                   green: Double((value >> 8) & 0xFF) / 255,
                   blue: Double(value & 0xFF) / 255)
    }
}

extension TripActivityAttributes.ContentState {
    enum Phase: Equatable {
        /// Waiting for the train to leave your station.
        case departs
        /// On its way to your stop.
        case arrives
        /// At your stop.
        case arrived
    }

    func phase(at now: Date, isStale: Bool) -> Phase {
        if now >= arrival { return .arrived }
        if hasDeparted || isStale || now >= departure { return .arrives }
        return .departs
    }

    /// When the countdown runs out: the departure while you wait, then the arrival.
    func target(_ phase: Phase) -> Date {
        phase == .departs ? departure : arrival
    }
}

/// Clock times as on GO's boards: 24-hour, Toronto time.
enum TripActivityFormat {
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Toronto") ?? .current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func time(_ date: Date) -> String { clock.string(from: date) }
}

enum TripActivityLayout {
    /// The gap around the line's pill in the compact island: the same above,
    /// below and at the island's end, so the pill's round end is concentric with
    /// the island's.
    static let compactInset: Double = 5
}

// MARK: - Pieces

/// The line's code in white on a pill of the line's colour. In the island the
/// pill takes the island's own shape, inset (ContainerRelativeShape), so its
/// round end follows the island's curve.
struct TripLinePill<PillShape: Shape>: View {
    let code: String
    let color: Color
    let fontSize: CGFloat
    let shape: PillShape

    var body: some View {
        Text(code)
            .font(.system(size: fontSize, weight: .heavy))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, fontSize * 0.6)
            .frame(maxHeight: .infinity)
            .background(color, in: shape)
            .accessibilityLabel("Line \(code)")
    }
}

/// Time left until `target`, counting down by itself while the app isn't running
/// (it stops at 0:00).
struct TripCountdown: View {
    let target: Date
    let fontSize: CGFloat
    let alignment: TextAlignment

    var body: some View {
        let now = Date()
        Text(timerInterval: min(now, target)...target, countsDown: true)
            .font(.system(size: fontSize, weight: .semibold))
            .monospacedDigit()
            .multilineTextAlignment(alignment)
            // A timer's text takes all the width it's offered (which would push the
            // island wide open), so give it about what its digits need.
            .frame(width: Self.width(until: target, from: now, fontSize: fontSize),
                   alignment: alignment == .trailing ? .trailing : .leading)
    }

    static func width(until target: Date, from now: Date, fontSize: CGFloat) -> CGFloat {
        let left = target.timeIntervalSince(now)
        let digits: CGFloat = left >= 3600 ? 5 : (left >= 600 ? 4 : 3)
        let colons: CGFloat = left >= 3600 ? 2 : 1
        return ceil(fontSize * (digits * 0.63 + colons * 0.33)) + 4
    }
}

/// The platform (while you wait) and whether the train's on time; the train's
/// number when neither is known.
struct TripStatusLine: View {
    let attributes: TripActivityAttributes
    let state: TripActivityAttributes.ContentState
    let phase: TripActivityAttributes.ContentState.Phase

    var body: some View {
        let platform = phase == .departs ? state.platform : nil
        let status = self.status
        HStack(spacing: 4) {
            if let platform {
                Text("Platform \(platform)")
            }
            if platform != nil, status != nil {
                Text("·")
                    .foregroundStyle(.secondary)
            }
            if let status {
                Text(status.text)
                    .foregroundStyle(status.color)
            }
            if platform == nil, status == nil {
                Text("Train \(attributes.tripNumber)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var status: (text: String, color: Color)? {
        guard phase != .arrived, let late = state.minutesLate else { return nil }
        return late >= 2 ? ("\(late) min late", .orange) : ("On time", .green)
    }
}

/// "Leaves in" or "Arrives in" over the countdown ("Arrived" over the time).
struct TripTimeBlock: View {
    let state: TripActivityAttributes.ContentState
    let isStale: Bool
    let fontSize: CGFloat

    var body: some View {
        let phase = state.phase(at: Date(), isStale: isStale)
        VStack(alignment: .trailing, spacing: 0) {
            Text(caption(phase))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if phase == .arrived {
                Text(TripActivityFormat.time(state.arrival))
                    .font(.system(size: fontSize, weight: .semibold))
                    .monospacedDigit()
            } else {
                TripCountdown(target: state.target(phase), fontSize: fontSize, alignment: .trailing)
            }
        }
        .lineLimit(1)
    }

    private func caption(_ phase: TripActivityAttributes.ContentState.Phase) -> String {
        switch phase {
        case .departs: return "Leaves in"
        case .arrives: return "Arrives in"
        case .arrived: return "Arrived"
        }
    }
}

/// Your station to your stop: a bar in the line's colour that fills during the
/// ride, with the two times.
struct TripRouteProgress: View {
    let attributes: TripActivityAttributes
    let state: TripActivityAttributes.ContentState
    let onDark: Bool

    var body: some View {
        VStack(spacing: 6) {
            ProgressView(timerInterval: state.departure...max(state.arrival, state.departure), countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .tint(onDark ? attributes.lineColorOnDark : attributes.lineColor)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(TripActivityFormat.time(state.departure))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .layoutPriority(1)
                Text(attributes.boardingName)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 10)
                Text(attributes.destinationName)
                    .foregroundStyle(.secondary)
                Text(TripActivityFormat.time(state.arrival))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .layoutPriority(1)
            }
            .font(.subheadline)
            .lineLimit(1)
        }
    }
}

// MARK: - Lock Screen

/// The Lock Screen (and the banner on iPhones without the Dynamic Island): the
/// line, where the train's going and how it's doing, the countdown, and your ride.
/// The background is the system's own.
struct TripLockScreen: View {
    let attributes: TripActivityAttributes
    let state: TripActivityAttributes.ContentState
    let isStale: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let phase = state.phase(at: Date(), isStale: isStale)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                TripLinePill(code: attributes.lineCode, color: attributes.lineColor, fontSize: 15, shape: Capsule())
                    .frame(height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("To \(attributes.terminusName)")
                        .font(.headline)
                    TripStatusLine(attributes: attributes, state: state, phase: phase)
                        .font(.subheadline.weight(.medium))
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                TripTimeBlock(state: state, isStale: isStale, fontSize: 26)
            }
            TripRouteProgress(attributes: attributes, state: state, onDark: colorScheme == .dark)
        }
        .padding(14)
    }
}

// MARK: - Dynamic Island

/// Left of the camera: the line's pill, snug in the island's round end.
struct TripCompactLeading: View {
    let attributes: TripActivityAttributes
    let state: TripActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if #available(iOS 27.0, *) {
            TripLimitedWidthAware {
                TripMinimal(attributes: attributes, state: state, isStale: isStale)
            } regular: {
                pill
            }
        } else {
            pill
        }
    }

    private var pill: some View {
        TripLinePill(code: attributes.lineCode, color: attributes.lineColor, fontSize: 14,
                     shape: ContainerRelativeShape())
    }
}

/// Right of the camera: time left until the train leaves your station or, once
/// it has, until it reaches your stop.
struct TripCompactTrailing: View {
    let state: TripActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if #available(iOS 27.0, *) {
            TripLimitedWidthAware {
                // No room for the time: the system hides an empty trailing view.
                EmptyView()
            } regular: {
                countdown
            }
        } else {
            countdown
        }
    }

    @ViewBuilder private var countdown: some View {
        let now = Date()
        let phase = state.phase(at: now, isStale: isStale)
        if phase == .arrived {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .accessibilityLabel("Arrived")
        } else {
            let target = state.target(phase)
            TripCountdown(target: target, fontSize: target.timeIntervalSince(now) >= 3600 ? 12.5 : 15,
                          alignment: .leading)
                .foregroundStyle(.white)
        }
    }
}

/// When other Live Activities share the island (and in a narrow island): the
/// line's code on its colour, in a ring that fills as the wait, then the ride,
/// goes by. Fits a 28-point circle.
struct TripMinimal: View {
    let attributes: TripActivityAttributes
    let state: TripActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let phase = state.phase(at: Date(), isStale: isStale)
        ZStack {
            ProgressView(timerInterval: interval(phase), countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.circular)
            .tint(attributes.lineColorOnDark)
            Text(attributes.lineCode)
                .font(.system(size: 9.5, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(attributes.lineColor, in: Circle())
        }
        .frame(width: 28, height: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Line \(attributes.lineCode)")
    }

    private func interval(_ phase: TripActivityAttributes.ContentState.Phase) -> ClosedRange<Date> {
        switch phase {
        case .departs:
            return min(attributes.trackedAt, state.departure)...state.departure
        case .arrives, .arrived:
            return state.departure...max(state.arrival, state.departure)
        }
    }
}

/// Expanded, left of the camera: the line's pill in the island's corner.
struct TripExpandedLeading: View {
    let attributes: TripActivityAttributes

    var body: some View {
        TripLinePill(code: attributes.lineCode, color: attributes.lineColor, fontSize: 16,
                     shape: ContainerRelativeShape())
            .frame(height: 36)
    }
}

/// Expanded, under the camera: where the train's going, and how it's doing.
struct TripExpandedCenter: View {
    let attributes: TripActivityAttributes
    let state: TripActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let phase = state.phase(at: Date(), isStale: isStale)
        VStack(spacing: 2) {
            Text("To \(attributes.terminusName)")
                .font(.headline)
            TripStatusLine(attributes: attributes, state: state, phase: phase)
                .font(.subheadline.weight(.medium))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

/// Picks `limited` when the Dynamic Island is narrower than usual (iPhone in
/// landscape, or some iPhones running more than one Live Activity), where the
/// compact views have to fit a 28-point circle.
@available(iOS 27.0, *)
struct TripLimitedWidthAware<Limited: View, Regular: View>: View {
    @Environment(\.isDynamicIslandLimitedInWidth) var isLimited
    @ViewBuilder let limited: Limited
    @ViewBuilder let regular: Regular

    var body: some View {
        if isLimited {
            limited
        } else {
            regular
        }
    }
}
