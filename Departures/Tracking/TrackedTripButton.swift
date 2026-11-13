import SwiftUI

/// Bottom left of the map while a trip is tracked: the line's pill and
/// "Tracking" ("Cancelled", in red, once its train is; "Connection cancelled",
/// once the next one is on a trip with changes). Opens the trip and goes to the
/// train on the map. (VoiceOver also hears when the train leaves your station or
/// reaches your stop.)
struct TrackedTripButton: View {
    let trip: TrackedTrip
    let action: () -> Void

    private let network = RailNetwork.shared

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                LinePill(code: trip.lineCode)
                Text(trip.cancelled != nil ? "Cancelled" : trip.cancelledConnection != nil ? "Connection cancelled" : "Tracking")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(trip.cancelled != nil || trip.cancelledConnection != nil ? AnyShapeStyle(.red)
                                                                                             : AnyShapeStyle(.primary))
                    .lineLimit(1)
            }
            .padding(.leading, LinePill.inset)
            .padding(.trailing, 16)
            .frame(height: LinePill.height + 2 * LinePill.inset)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glass(in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tracking line \(trip.lineCode). \(status(at: Date()))")
        .accessibilityHint(trip.cancelled != nil && !trip.hasLeftBoarding ? "Shows where to find another train"
                                                                           : "Shows the train's stops and where it is")
    }

    private func name(_ code: String) -> String {
        network.station(code)?.name ?? code
    }

    private func status(at now: Date) -> String {
        if trip.cancelled != nil {
            return "Cancelled" + (trip.cancelledIndex.map { ". It won't stop at \(name(trip.stops[$0].code))" } ?? "")
        }
        // (The next train cancelled, then how this one's getting on.)
        let connection = trip.cancelledConnection != nil
            ? TripAlerts.connectionText(trip, back: false, network: network).title + ". " : ""
        return connection + phaseStatus(at: now)
    }

    private func phaseStatus(at now: Date) -> String {
        switch trip.phase(at: now) {
        case .departs(let time):
            return "Leaves \(name(trip.boardingCode)) \(Self.remaining(until: time, from: now))"
        case .arrives(let time):
            return "Arrives at \(name(trip.destinationCode)) \(Self.remaining(until: time, from: now))"
        case .arrived:
            return "Arrived at \(name(trip.destinationCode))"
        }
    }

    static func remaining(until time: Date, from now: Date) -> String {
        let minutes = Int((time.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        if minutes % 60 == 0 { return "in \(minutes / 60) h" }
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
