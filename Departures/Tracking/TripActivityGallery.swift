#if DEBUG
import SwiftUI

/// Debug builds only (`-debugScene activityGallery`): the Live Activity's views
/// drawn in the app, for screenshots, since the simulator can't be locked or its
/// island held open from a script. The black island shapes and the Lock Screen
/// card around them are approximations of the system's. The trips are made up.
/// With `-galleryLockScreen YES` the Lock Screen comes first, for a second screenshot;
/// with `-gallerySection journey` (or `journeyIsland`), a trip with a change at each
/// point of it, on the Lock Screen (or in the expanded island). Each Lock Screen
/// card says how tall it is: the system gives it at most 160 points.
struct TripActivityGallery: View {
    private typealias Snapshot = TripActivityAttributes.ContentState

    private let lockScreenFirst = UserDefaults.standard.bool(forKey: "galleryLockScreen")
    private let section = UserDefaults.standard.string(forKey: "gallerySection")

    private struct Sample {
        let attributes: TripActivityAttributes
        var state: Snapshot

        /// As the widget draws it: on a trip with changes, the train changed to.
        var drawn: TripActivityAttributes { attributes.current(state) }
    }

    private let now = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if section == "journey" {
                    journeyLockScreens
                } else if section == "journeyIsland" {
                    journeyIslands
                } else if lockScreenFirst {
                    lockScreens
                    island
                } else {
                    island
                    lockScreens
                }
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

    @ViewBuilder private var island: some View {
        heading("Dynamic Island")
        compact(approaching)
        compact(riding)
        compact(leavingLater)
        compact(arrived)
        HStack(spacing: 14) {
            minimal(approaching)
            minimal(riding)
            minimal(arrived)
            Text("Minimal, and the narrow island's leading view")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
        expanded(riding)
            .padding(.top, 6)
        expanded(approaching)
        expanded(changed)
    }

    /// A trip with a change, at each point of it.
    @ViewBuilder private var journeyLockScreens: some View {
        heading("A trip with a change, on the Lock Screen")
        lockScreen(changingApproach)
            .environment(\.colorScheme, .light)
        lockScreen(changing)
            .environment(\.colorScheme, .dark)
        lockScreen(changingRiding)
            .environment(\.colorScheme, .light)
        lockScreen(changed)
            .environment(\.colorScheme, .dark)
        lockScreen(changedRiding)
            .environment(\.colorScheme, .light)
    }

    @ViewBuilder private var journeyIslands: some View {
        heading("A trip with a change, in the island")
        expanded(changingApproach)
        expanded(changingRiding)
        expanded(changed)
        expanded(changedRiding)
    }

    @ViewBuilder private var lockScreens: some View {
        heading("Lock Screen")
        lockScreen(approaching)
            .environment(\.colorScheme, .light)
        lockScreen(riding)
            .environment(\.colorScheme, .dark)
        lockScreen(standing)
            .environment(\.colorScheme, .light)
        lockScreen(leavingLater)
            .environment(\.colorScheme, .dark)
    }

    // MARK: Samples (made-up trips)

    /// A trip along `codes`, leaving each stop `minutes` from now, boarded at
    /// `boarding` and ridden to `destination`.
    private func sample(_ line: String, _ codes: [String], minutes: [Double],
                        boarding: String, destination: String, fromBoard: Bool) -> Sample {
        let network = RailNetwork.shared
        func name(_ code: String) -> String { network.station(code)?.name ?? code }
        let times = minutes.map { now.addingTimeInterval($0 * 60) }
        let start = codes.firstIndex(of: boarding) ?? 0
        let end = codes.firstIndex(of: destination) ?? codes.count - 1
        var direction: String?
        if let first = codes.first.flatMap(network.station), let last = codes.last.flatMap(network.station) {
            direction = TravelDirection.of(lineCode: line, from: first, to: last, network: network)?.label.lowercased()
        }
        let attributes = TripActivityAttributes(
            tripID: "sample-\(line)", tripNumber: "1234", lineCode: line,
            lineColorHex: network.line(code: line)?.hex ?? "888888",
            boardingName: name(boarding), destinationName: name(destination),
            terminusName: name(codes.last ?? destination),
            trackedAt: now.addingTimeInterval(-5 * 60),
            lineName: network.line(code: line)?.name, direction: direction, boardingTime: times[start])
        let state = Snapshot(
            departure: times[start], arrival: times[end], hasDeparted: now >= times[start],
            minutesLate: nil, platform: nil,
            stops: zip(codes, times).map {
                TripActivityAttributes.Stop(name: TripActivityController.shortName(name($0.0)), time: $0.1)
            },
            boardingIndex: start, destinationIndex: end, awaitsTrain: fromBoard)
        return Sample(attributes: attributes, state: state)
    }

    /// Tracked from Pickering's board, the train two stops away.
    private var approaching: Sample {
        sample("LE", ["OS", "WH", "AJ", "PIN", "RO", "GU", "EG", "SC", "DA", "UN"],
               minutes: [-8, -2, 3, 7, 11, 15, 18, 21, 26, 33],
               boarding: "PIN", destination: "UN", fromBoard: true)
    }

    /// Picked on the map, between Oakville and Clarkson.
    private var riding: Sample {
        sample("LW", ["AL", "BU", "AP", "BO", "OA", "CL", "PO", "LO", "MI", "EX", "UN"],
               minutes: [-20, -15, -10, -6, -2, 2.5, 6, 10, 13, 17, 22],
               boarding: "OA", destination: "UN", fromBoard: false)
    }

    /// Standing at Rutherford, on the way to Aurora.
    private var standing: Sample {
        sample("BR", ["UN", "DW", "RU", "MP", "KC", "AU", "NE", "EA", "BD", "BA", "AD"],
               minutes: [-22, -10, 0.5, 5, 12, 20, 26, 31, 38, 46, 50],
               boarding: "UN", destination: "AU", fromBoard: false)
    }

    /// Tracked from Union's board, more than an hour before it leaves.
    private var leavingLater: Sample {
        sample("MI", ["UN", "KP", "DI", "CO", "ER", "SR", "ME", "LS", "ML"],
               minutes: [72, 86, 91, 96, 101, 106, 111, 115, 121],
               boarding: "UN", destination: "ML", fromBoard: true)
    }

    /// A trip with a change, on its first train: Oakville to Union, then the
    /// Lakeshore East to Danforth.
    private var changing: Sample {
        var trip = sample("LW", ["AL", "BU", "AP", "BO", "OA", "CL", "PO", "LO", "MI", "EX", "UN"],
                          minutes: [-30, -25, -20, -16, -12, -8, -4, 0.5, 4, 8, 13],
                          boarding: "OA", destination: "UN", fromBoard: false)
        trip.state.change = TripActivityAttributes.Change(
            station: "Union", lineCode: "LE", lineColorHex: RailNetwork.shared.line(code: "LE")?.hex ?? "FF0D00",
            lineName: "Lakeshore East", departure: now.addingTimeInterval(19 * 60),
            terminusName: "Oshawa", destinationName: "Danforth")
        return trip
    }

    /// The same trip before the first train gets to Oakville: tracked from its
    /// board, so it counts down to the train getting there.
    private var changingApproach: Sample {
        var trip = sample("LW", ["AL", "BU", "AP", "BO", "OA", "CL", "PO", "LO", "MI", "EX", "UN"],
                          minutes: [-10, -5, 0, 4, 9, 13, 17, 21, 25, 29, 34],
                          boarding: "OA", destination: "UN", fromBoard: true)
        trip.state.change = changingState.change
        return trip
    }

    /// Nearly at Union, where you change.
    private var changingRiding: Sample {
        var trip = sample("LW", ["AL", "BU", "AP", "BO", "OA", "CL", "PO", "LO", "MI", "EX", "UN"],
                          minutes: [-45, -40, -35, -31, -27, -23, -19, -15, -11, -3, 4],
                          boarding: "OA", destination: "UN", fromBoard: false)
        trip.state.change = changingState.change
        return trip
    }

    private var changingState: Snapshot { changing.state }

    /// On the second train, on its way to Danforth.
    private var changedRiding: Sample {
        var trip = changed
        let second = sample("LE", ["UN", "DA", "SC", "EG", "GU", "RO", "PIN", "AJ", "WH", "OS"],
                            minutes: [-6, 3, 7, 11, 15, 18, 23, 27, 32, 38],
                            boarding: "UN", destination: "DA", fromBoard: false)
        let leg = trip.state.leg
        trip.state = second.state
        trip.state.leg = leg
        return trip
    }

    /// The same trip at Union, waiting for the Lakeshore East train: the activity
    /// started for the first train shows the second.
    private var changed: Sample {
        let first = changing
        let second = sample("LE", ["UN", "DA", "SC", "EG", "GU", "RO", "PIN", "AJ", "WH", "OS"],
                            minutes: [5, 13, 17, 21, 25, 28, 33, 37, 42, 48],
                            boarding: "UN", destination: "DA", fromBoard: true)
        var state = second.state
        let next = second.attributes
        state.leg = TripActivityAttributes.Leg(
            tripNumber: next.tripNumber, lineCode: next.lineCode, lineColorHex: next.lineColorHex,
            lineName: next.lineName, direction: next.direction, boardingName: next.boardingName,
            destinationName: next.destinationName, terminusName: next.terminusName,
            boardingTime: next.boardingTime, since: now.addingTimeInterval(-60))
        return Sample(attributes: first.attributes, state: state)
    }

    /// In at Unionville a minute ago.
    private var arrived: Sample {
        sample("ST", ["UN", "KE", "AG", "MK", "UI", "CE", "MR", "MJ", "ST", "LI"],
               minutes: [-40, -30, -25, -20, 0, 3, 7, 12, 18, 22],
               boarding: "UN", destination: "UI", fromBoard: false)
    }

    // MARK: Frames

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .padding(.top, 8)
    }

    /// The compact island: leading view, the camera, trailing view.
    private func compact(_ sample: Sample) -> some View {
        HStack(spacing: 0) {
            TripCompactLeading(attributes: sample.drawn, state: sample.state, isStale: false)
                .padding([.leading, .vertical], TripActivityLayout.compactInset)
                .padding(.trailing, 6)
            Color.clear
                .frame(width: 120)
            TripCompactTrailing(attributes: sample.drawn, state: sample.state, isStale: false)
                .padding(.leading, 6)
                .padding(.trailing, 14)
        }
        .frame(height: 36.67)
        .background(Color.black, in: Capsule())
        .containerShape(Capsule())
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity)
    }

    private func minimal(_ sample: Sample) -> some View {
        TripMinimal(attributes: sample.drawn, state: sample.state, isStale: false)
            .frame(width: 36.67, height: 36.67)
            .background(Color.black, in: Circle())
            .environment(\.colorScheme, .dark)
    }

    /// The expanded island: pill and countdown beside the camera, where the train
    /// is going under it, the stops around it along the bottom.
    private func expanded(_ sample: Sample) -> some View {
        // (Measured: the island too has 160 pt.)
        MeasuredCard(limit: 160) { expandedContent(sample) }
    }

    private func expandedContent(_ sample: Sample) -> some View {
        VStack(spacing: 10) {
            ZStack(alignment: .top) {
                HStack(alignment: .top) {
                    TripExpandedLeading(attributes: sample.drawn)
                    Spacer()
                    TripExpandedTrailing(attributes: sample.drawn, state: sample.state, isStale: false)
                }
                TripExpandedCenter(attributes: sample.drawn, state: sample.state, isStale: false)
                    .frame(width: 180)
                    .padding(.top, 42)
            }
            TripExpandedBottom(attributes: sample.drawn, state: sample.state, isStale: false)
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

    private func lockScreen(_ sample: Sample) -> some View {
        MeasuredCard(limit: 160) {
            TripLockScreen(attributes: sample.drawn, state: sample.state, isStale: false)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// A card that says how tall its content is, in red when that's over `limit`.
private struct MeasuredCard<Content: View>: View {
    let limit: CGFloat
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .overlay(alignment: .topTrailing) {
                Text("\(Int(height.rounded())) pt")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(height > limit ? Color.red : Color.green.opacity(0.8), in: Capsule())
                    .offset(x: 4, y: -6)
            }
    }
}
#endif
