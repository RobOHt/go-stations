import SwiftUI

/// Bottom left of the map while a trip is tracked: the line, and how long until
/// the train leaves your station (or reaches your stop). Opens the trip.
struct TrackedTripButton: View {
    let trip: TrackedTrip
    let action: () -> Void

    private let network = RailNetwork.shared

    var body: some View {
        Button(action: action) {
            TimelineView(.periodic(from: .now, by: 10)) { context in
                let text = lines(at: context.date)
                HStack(spacing: 9) {
                    LinePill(code: trip.lineCode)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(text.caption)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(text.value)
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(.primary)
                    }
                    .lineLimit(1)
                }
                .padding(.leading, LinePill.inset)
                .padding(.trailing, 16)
                .frame(height: LinePill.height + 2 * LinePill.inset)
                .frame(maxWidth: 240, alignment: .leading)
                .contentShape(Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Tracked train, line \(trip.lineCode). \(text.caption) \(text.value)")
            }
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityHint("Shows the train's stops")
    }

    private func name(_ code: String) -> String {
        network.station(code)?.name ?? code
    }

    private func lines(at now: Date) -> (caption: String, value: String) {
        switch trip.phase(at: now) {
        case .departs(let time):
            return ("Leaves \(name(trip.boardingCode))", Self.remaining(until: time, from: now))
        case .arrives(let time):
            return ("Arrives \(name(trip.destinationCode))", Self.remaining(until: time, from: now))
        case .arrived:
            return ("Arrived", name(trip.destinationCode))
        }
    }

    static func remaining(until time: Date, from now: Date) -> String {
        let minutes = Int((time.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        return "in \(minutes / 60) h \(minutes % 60) min"
    }
}

/// A line's code on a pill of its colour, sized to sit concentric inside a 48 pt
/// glass capsule.
struct LinePill: View {
    let code: String

    static let height: CGFloat = 36
    /// Gap to the capsule around it, the same all round so the curves are concentric.
    static let inset: CGFloat = 6

    var body: some View {
        Text(code)
            .font(.system(size: 15, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(minWidth: Self.height, minHeight: Self.height)
            .background(RailNetwork.shared.line(code: code)?.color ?? .gray, in: Capsule())
            .accessibilityLabel("Line \(code)")
    }
}
