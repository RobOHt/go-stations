#if DEBUG
import SwiftUI

/// Debug builds only (`-debugScene activityGallery`): the Live Activity's views
/// drawn in the app, for screenshots, since the simulator can't be locked or its
/// island held open from a script. The black island shapes and the Lock Screen
/// card around them are approximations of the system's.
struct TripActivityGallery: View {
    private typealias Snapshot = TripActivityAttributes.ContentState

    private let now = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                heading("Dynamic Island")
                compact(lakeshoreWest, waiting)
                compact(barrie, riding)
                compact(milton, waitingLong)
                compact(stouffville, arrived)
                HStack(spacing: 14) {
                    minimal(lakeshoreWest, waiting)
                    minimal(barrie, riding)
                    minimal(stouffville, arrived)
                    Text("Minimal, and the narrow island's leading view")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
                expanded(lakeshoreWest, waiting)
                    .padding(.top, 6)
                heading("Lock Screen")
                lockScreen(lakeshoreWest, waiting)
                    .environment(\.colorScheme, .light)
                lockScreen(barrie, riding)
                    .environment(\.colorScheme, .dark)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background {
            LinearGradient(colors: [Color(red: 0.36, green: 0.45, blue: 0.62), Color(red: 0.75, green: 0.55, blue: 0.48)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }

    // MARK: Samples (made-up trips)

    private func attributes(_ line: String, from: String, to: String, terminus: String) -> TripActivityAttributes {
        let network = RailNetwork.shared
        return TripActivityAttributes(
            tripID: "sample-\(line)", tripNumber: "1234", lineCode: line,
            lineColorHex: network.line(code: line)?.hex ?? "888888",
            boardingName: network.station(from)?.name ?? from,
            destinationName: network.station(to)?.name ?? to,
            terminusName: network.station(terminus)?.name ?? terminus,
            trackedAt: now.addingTimeInterval(-5 * 60))
    }

    private var lakeshoreWest: TripActivityAttributes { attributes("LW", from: "UN", to: "OA", terminus: "AL") }
    private var barrie: TripActivityAttributes { attributes("BR", from: "UN", to: "AU", terminus: "BA") }
    private var milton: TripActivityAttributes { attributes("MI", from: "UN", to: "ML", terminus: "ML") }
    private var stouffville: TripActivityAttributes { attributes("ST", from: "UN", to: "UI", terminus: "LI") }

    private var waiting: Snapshot {
        Snapshot(departure: now.addingTimeInterval(4 * 60 + 55), arrival: now.addingTimeInterval(36 * 60),
              hasDeparted: false, minutesLate: 0, platform: "9, 10")
    }

    private var waitingLong: Snapshot {
        Snapshot(departure: now.addingTimeInterval(72 * 60), arrival: now.addingTimeInterval(130 * 60),
              hasDeparted: false, minutesLate: nil, platform: nil)
    }

    private var riding: Snapshot {
        Snapshot(departure: now.addingTimeInterval(-6 * 60), arrival: now.addingTimeInterval(24 * 60),
              hasDeparted: true, minutesLate: 3, platform: "5")
    }

    private var arrived: Snapshot {
        Snapshot(departure: now.addingTimeInterval(-40 * 60), arrival: now.addingTimeInterval(-60),
              hasDeparted: true, minutesLate: 0, platform: nil)
    }

    // MARK: Frames

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .padding(.top, 8)
    }

    /// The compact island: leading view, the camera, trailing view.
    private func compact(_ attributes: TripActivityAttributes, _ state: Snapshot) -> some View {
        HStack(spacing: 0) {
            TripCompactLeading(attributes: attributes, state: state, isStale: false)
                .padding([.leading, .vertical], TripActivityLayout.compactInset)
                .padding(.trailing, 6)
            Color.clear
                .frame(width: 120)
            TripCompactTrailing(state: state, isStale: false)
                .padding(.leading, 6)
                .padding(.trailing, 14)
        }
        .frame(height: 36.67)
        .background(Color.black, in: Capsule())
        .containerShape(Capsule())
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity)
    }

    private func minimal(_ attributes: TripActivityAttributes, _ state: Snapshot) -> some View {
        TripMinimal(attributes: attributes, state: state, isStale: false)
            .frame(width: 36.67, height: 36.67)
            .background(Color.black, in: Circle())
            .environment(\.colorScheme, .dark)
    }

    /// The expanded island: pill and countdown beside the camera, where the train
    /// is going under it, your ride along the bottom.
    private func expanded(_ attributes: TripActivityAttributes, _ state: Snapshot) -> some View {
        VStack(spacing: 10) {
            ZStack(alignment: .top) {
                HStack(alignment: .top) {
                    TripExpandedLeading(attributes: attributes)
                    Spacer()
                    TripTimeBlock(state: state, isStale: false, fontSize: 24)
                }
                TripExpandedCenter(attributes: attributes, state: state, isStale: false)
                    .frame(width: 180)
                    .padding(.top, 42)
            }
            TripRouteProgress(attributes: attributes, state: state, onDark: true)
                .padding(.top, 6)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .overlay(alignment: .top) {
            Capsule()
                .fill(Color(white: 0.1))
                .frame(width: 120, height: 36)
                .padding(.top, 11)
        }
        .background(Color.black, in: RoundedRectangle(cornerRadius: 46, style: .continuous))
        .containerShape(RoundedRectangle(cornerRadius: 46, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private func lockScreen(_ attributes: TripActivityAttributes, _ state: Snapshot) -> some View {
        TripLockScreen(attributes: attributes, state: state, isStale: false)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
#endif
