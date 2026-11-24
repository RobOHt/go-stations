import SwiftUI
import UIKit

/// The train a board row was tapped on, and the station whose board it came from.
struct TripSelection: Identifiable {
    let row: BoardRow
    let station: Station
    /// Picked on that station's departure board, so it's where you get on: tracking
    /// it counts down to the train getting there first.
    var fromBoard = false

    var id: String { "\(row.id)@\(station.code)" }
}

/// Compass direction of a trip, the way GO names it.
enum TravelDirection {
    case north, south, east, west

    var label: String {
        switch self {
        case .north: return "Northbound"
        case .south: return "Southbound"
        case .east: return "Eastbound"
        case .west: return "Westbound"
        }
    }

    var symbol: String {
        switch self {
        case .north: return "arrow.up"
        case .south: return "arrow.down"
        case .east: return "arrow.right"
        case .west: return "arrow.left"
        }
    }

    var opposite: TravelDirection {
        switch self {
        case .north: return .south
        case .south: return .north
        case .east: return .west
        case .west: return .east
        }
    }

    /// Which way each line runs away from Union.
    private static let outbound: [String: TravelDirection] = [
        "LW": .west, "MI": .west, "KI": .west,
        "LE": .east,
        "BR": .north, "RH": .north, "ST": .north,
    ]

    /// Outbound when the trip ends farther from Union than it starts.
    static func of(lineCode: String, from first: Station, to last: Station, network: RailNetwork) -> TravelDirection? {
        guard let away = outbound[lineCode], let union = network.station("UN") else { return nil }
        let startDistance = first.location.distance(from: union.location)
        let endDistance = last.location.distance(from: union.location)
        return endDistance >= startDistance ? away : away.opposite
    }
}

/// Every stop of one train along a line in its colour, with chevrons flowing in the
/// direction of travel and a marker where the train is: as far along the track
/// between its stops as its GPS reports have it, gliding through them as on the
/// map; by its times only for want of a live position (see `trainPlace`). Tapping a
/// stop opens that station's board in another sheet, which can open another train,
/// and so on.
struct TripSheet: View {
    let selection: TripSelection

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var detail: TripDetail?
    @State private var openStation: Station?
    /// The trains after this one on the tracked trip, live when Metrolinx has them.
    @State private var onwardDetails: [String: TripDetail] = [:]
    /// What GO's feeds say about this train: cancelled, or where it won't stop
    /// (nil: it runs as planned).
    @State private var cancellation: CancelledTrains.Status?
    /// GO's service disruptions on its line, and its own alerts ("Signal issue
    /// near Port Credit GO").
    @State private var alerts: [StationAlert] = []
    /// Its stops along the track, for placing it among them by its GPS reports.
    @State private var run: TrainRun?
    /// Its reports as placed along that track (worked out once per report).
    @State private var placed = PlacedReports()
    #if DEBUG
    /// `-debugAlertDelay`: the train has jumped on, with the alerts coming in.
    @State private var debugJumped = false
    #endif

    private let network = RailNetwork.shared

    static let rowHeight: CGFloat = 56
    /// Horizontal centre of the line inside a stop row (padding + time column + spacing + half the dot column).
    static let lineX: CGFloat = 12 + 52 + 10 + 11

    private var row: BoardRow { selection.row }
    private var lineColor: Color { network.line(code: row.lineCode)?.color ?? .gray }

    var body: some View {
        let _ = PerfProbe.body("TripSheet")
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let fetched = detail {
                    // (The times ahead as late as it's running, where Metrolinx has none.)
                    let detail = shown(fetched, at: Date())
                    stopList(detail)
                    // On a trip with changes, the rest of it: where you change, and each
                    // train after this one to where you get off.
                    if let trip = plannedTrip, trip.hasOnward {
                        restOfTrip(trip)
                    }
                    sourceNote(detail)
                    alertList(detail)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        #if DEBUG
        // `-tripScrollToEnd YES`: at the end, for a screenshot of the rest of a trip.
        .defaultScrollAnchor(Self.debugAnchor)
        .defaultScrollAnchor(Self.debugAnchor, for: .sizeChanges)
        #endif
        // The train's line, terminus and close button stay pinned over the stops.
        .pinnedHeader(bottomRoom: PinnedHeaderMetrics.tripBottom) { header }
        .environment(\.glassBackdrop, .sheet)
        .task {
            detail = await BoardService.shared.tripDetail(for: row, from: selection.station)
            // Metrolinx's times again every half minute while the train runs: one held
            // somewhere gets later as it waits, and its times here with it.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let current = detail, current.source == .live,
                      isUnderway(shown(current, at: Date()), at: Date()) else { continue }
                let fresh = await BoardService.shared.tripDetail(for: row, from: selection.station)
                // (Never the timetable in place of live times when one fetch fails.)
                if fresh.source == .live, fresh.stops.map(\.code) == current.stops.map(\.code) {
                    detail = fresh
                }
            }
        }
        .task {
            #if DEBUG
            if let delay = DebugScene.alertDelay { try? await Task.sleep(for: .seconds(delay)) }
            #endif
            // GO's disruptions on its line: now, and every two minutes while it's open.
            while !Task.isCancelled {
                let fetched = await BoardService.shared.lineAlerts(for: row)
                #if DEBUG
                let fresh = DebugScene.tripAlert ? [Self.debugAlert(row)] + fetched : fetched
                // (The train jumping on in the same moment the alerts come in.)
                if DebugScene.alertDelay != nil { debugJumped = true }
                #else
                let fresh = fetched
                #endif
                if fresh != alerts { withAnimation(.snappy) { alerts = fresh } }
                try? await Task.sleep(for: .seconds(120))
            }
        }
        .onChange(of: detail?.stops.map { $0.expected ?? $0.time }) { _, times in
            // The map's train (and the speed above) by the new times.
            if let times { TrainMotion.shared.retime(row.tripNumber, times: times) }
        }
        .task(id: plannedTrip?.onward?.map(\.row.id)) {
            // The trains after this one, live when Metrolinx has them (platforms too).
            for leg in plannedTrip?.onward ?? [] where onwardDetails[leg.row.id] == nil {
                guard let station = network.station(leg.boardingCode) else { continue }
                onwardDetails[leg.row.id] = await BoardService.shared.tripDetail(for: leg.row, from: station)
            }
        }
        .task {
            // Where the train really is, while its stops are open (every 5 seconds, as
            // for the map: its marker here goes where each new report has it), and
            // every 15 seconds whether it's cancelled.
            var pass = 0
            while !Task.isCancelled {
                await LiveTrains.shared.refresh(maxAge: 4)
                if pass % 3 == 0 {
                    let status = await CancelledTrains.shared.list()?.status(of: row)
                    if status != cancellation { withAnimation(.snappy) { cancellation = status } }
                }
                pass += 1
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .task(id: detail?.stops.map(\.code)) {
            // How fast it's going, as the map draws it (which works it out even when it
            // doesn't draw it), while its stops are open.
            guard let detail else { return }
            let number = row.tripNumber
            let line = network.line(code: row.lineCode)?.code ?? row.lineCode
            let codes = detail.stops.map(\.code)
            // (And its stops along the track, for its marker among them: see `trainPlace`.)
            run = codes.count >= 2 ? TrainRun(line: line, codes: codes, geometry: StartupStation.geometry) : nil
            TrainMotion.shared.watch(number, line: line, codes: codes,
                                     times: detail.stops.map { $0.expected ?? $0.time })
            defer { TrainMotion.shared.unwatch(number) }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
        }
        .sheet(item: $openStation) { station in
            StationSheet(station: station)
                .environment(settings)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: Header

    private var terminus: String {
        if let last = detail?.stops.last, let station = network.station(last.code) { return station.name }
        return row.destination
    }

    /// "20:48 train from Kitchener": the train by when and where it starts its run,
    /// as GO calls its trains. A placeholder until its stops have loaded.
    private var origin: (text: String, isKnown: Bool) {
        if let first = detail?.stops.first, let time = first.time, let station = network.station(first.code) {
            return ("\(TorontoTime.hourMinute(time)) train from \(station.name)", true)
        }
        return ("\(TorontoTime.hourMinute(row.scheduled)) train from \(selection.station.name)", detail != nil)
    }

    private var direction: TravelDirection? {
        guard let stops = detail?.stops, let first = stops.first.flatMap({ network.station($0.code) }),
              let last = stops.last.flatMap({ network.station($0.code) }) else { return nil }
        return TravelDirection.of(lineCode: row.lineCode, from: first, to: last, network: network)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    LineBadge(code: row.lineCode)
                    Text(row.lineName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if row.isExpress {
                        Label("Express", systemImage: "bolt.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("To \(terminus)")
                    .font(.title2.bold())
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                // The direction, and beside it (or under it, when there's no room)
                // when and where the train starts.
                FlowLayout(spacing: 10, lineSpacing: 6) {
                    if let direction {
                        Label(direction.label, systemImage: direction.symbol)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(lineColor, in: Capsule())
                            .accessibilityLabel(direction.label)
                    }
                    // Running late: how late, beside which way it goes (anew with each
                    // live report, every 15 seconds while this is open).
                    if let minutes = minutesLate(at: Date()) {
                        LatePill(minutes: minutes)
                    }
                    Text(origin.text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .redacted(reason: origin.isKnown ? [] : .placeholder)
                    if detail != nil {
                        TrainSpeedLabel(number: row.tripNumber)
                    }
                }
                if isCancelledHere {
                    Label("Cancelled | Annulé", systemImage: "xmark.circle.fill")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.red)
                }
            }
            .padding(.top, PinnedHeaderMetrics.textTop)

            Spacer(minLength: 8)

            GlassCloseButton { dismiss() }
        }
    }

    /// Cancelled at the station it was opened from (as its board said, or GO's feeds now say).
    private var isCancelledHere: Bool {
        row.isCancelled || cancellation?.isCancelled(at: selection.station.code) == true
    }

    /// How late the train is running: by its latest live report, else Metrolinx's
    /// time at the first of its stops it hasn't left. Nil when it's on time (under
    /// two minutes late, as on the boards), not known, or in.
    private func minutesLate(at now: Date) -> Int? {
        #if DEBUG
        if let late = DebugScene.lateMinutes { return late }
        #endif
        guard let detail, detail.source == .live, !isCancelledHere else { return nil }
        let state = trainState(detail, at: now)
        if case .arrived = state { return nil }
        let late: TimeInterval
        if let delay = LiveTrains.shared.train(row.tripNumber, at: now)?.delay {
            late = delay
        } else if let next = detail.stops.first(where: { !state.hasPassed($0.index, stopCount: detail.stops.count) }),
                  let time = next.time, let expected = next.expected {
            late = expected.timeIntervalSince(time)
        } else {
            return nil
        }
        let minutes = Int((late / 60).rounded())
        return minutes >= 2 ? minutes : nil
    }

    /// Its stops with the times ahead as late as it's running where Metrolinx leaves
    /// them blank (the end of its run always; every stop once it's past the last one
    /// Metrolinx times): by its latest live report, else by tracking's. So a train
    /// 30 minutes late isn't shown in on time, and can be tracked to the end.
    private func shown(_ detail: TripDetail, at now: Date) -> TripDetail {
        let codes = detail.stops.map(\.code)
        var late: TimeInterval?
        var from: Int?
        if let tracked = tracker.trip, tracked.matches(row), tracked.stopCodes == codes {
            late = tracked.liveDelay
            from = tracked.live?.index
        }
        if let train = LiveTrains.shared.train(row.tripNumber, at: now), let fix = train.fix(in: codes) {
            late = train.delay ?? late
            from = fix.index
        }
        guard let from else { return detail }
        return TripDetail(stops: TripDetail.fillingDelay(detail.stops, late: late, from: from), source: detail.source)
    }

    /// What's holding things up on its line, while it's on its way or about to be:
    /// at the end, after its stops, as on a station's board.
    @ViewBuilder
    private func alertList(_ detail: TripDetail) -> some View {
        if !alerts.isEmpty, showsAlerts(detail, at: Date()) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(alerts) { alert in
                    AlertCard(alert: alert)
                }
            }
        }
    }

    /// The line's alerts are about now: only for a train leaving within a few hours or on its way.
    private func showsAlerts(_ detail: TripDetail, at now: Date) -> Bool {
        #if DEBUG
        if DebugScene.tripAlert { return true }
        #endif
        return isUnderway(detail, at: now)
    }

    /// Leaving within a few hours, or on its way: its times can still change.
    private func isUnderway(_ detail: TripDetail, at now: Date) -> Bool {
        guard row.expected.timeIntervalSince(now) < Self.trackAhead else { return false }
        if case .arrived = trainState(detail, at: now) { return false }
        return true
    }

    // MARK: Tracking

    private var tracker: TripTracker { .shared }

    /// Follows this train: on the map, bottom left, and in a Live Activity. A wide
    /// button above the stops, in the line's colour until it's on; tapping it again
    /// stops tracking.
    private var trackButton: some View {
        let tracking = tracker.isTracking(row)
        return Button {
            if tracking {
                tracker.stop()
            } else if let detail {
                tracker.track(selection, detail: shown(detail, at: Date()), home: settings.homeCode,
                              work: settings.workCode)
            }
        } label: {
            Label(tracking ? "Tracking" : "Track this train",
                  systemImage: tracking ? "checkmark" : "train.side.front.car")
                .font(.body.weight(.semibold))
                .foregroundStyle(tracking ? Color.primary : Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glass(tracking ? .interactive : .tinted(lineColor), in: Capsule())
        .animation(.smooth(duration: 0.25), value: tracking)
        .accessibilityHint(tracking ? "Stops following this train"
                                    : "Follows this train on the map and in a Live Activity")
    }

    /// How long before it leaves a train can be tracked: its Live Activity has to
    /// last until it gets in, and iOS keeps one up about eight hours.
    static let trackAhead: TimeInterval = 4 * 3600

    /// Only a train with times that hasn't finished its run, leaving within a few hours.
    private func canTrack(_ detail: TripDetail, at now: Date) -> Bool {
        guard detail.source != nil, row.expected.timeIntervalSince(now) < Self.trackAhead else { return false }
        if case .arrived = trainState(detail, at: now) { return false }
        return true
    }

    /// Where the train is: the tracked one as tracking follows it, any other by
    /// its times and latest live report.
    private func trainState(_ detail: TripDetail, at now: Date) -> TrainState {
        #if DEBUG
        if debugJumped { return .stopped(at: min(3, detail.stops.count - 1)) }
        #endif
        let codes = detail.stops.map(\.code)
        if let tracked = tracker.trip, tracked.matches(row), tracked.stopCodes == codes {
            return tracked.state(at: now)
        }
        return TrainState(stops: detail.stops, now: now, live: LiveTrains.shared.train(row.tripNumber)?.fix(in: codes))
    }

    /// Where the train's marker goes among its stops at `now`, by the map's rule.
    /// While the train has a live position, only its GPS reports place it: as far
    /// along the track between two stops as the map draws it, gliding through them
    /// (see TrainReplay). With none, where its times put it (`state`): the backup.
    /// Nowhere while the live positions are still on their way (the app has just
    /// opened or come back: by its times it would be put in one place, then moved),
    /// or for a train GO has cancelled.
    private func trainPlace(_ detail: TripDetail, state: TrainState, at now: Date) -> TrainPlace? {
        #if DEBUG
        if debugJumped { return TrainPlace(stops: Double(min(3, detail.stops.count - 1)), isLive: true) }
        #endif
        if let reports = LiveTrains.shared.reports(of: row.tripNumber, at: now) {
            // (Once its stops' track is measured, a moment after they load.)
            guard let run, run.codes == detail.stops.map(\.code), let track = placed.track(of: reports, on: run)
            else { return nil }
            let position = TrainReplay.position(on: track, of: run, at: now)
            return TrainPlace(stops: run.progress(at: position.distance), isLive: true)
        }
        guard !LiveTrains.shared.isPending(at: now), cancellation?.all != true,
              let stops = state.progress(stopCount: detail.stops.count)
        else { return nil }
        return TrainPlace(stops: stops, isLive: false)
    }

    // MARK: Stops

    private func stopList(_ detail: TripDetail) -> some View {
        let originIndex = detail.stops.firstIndex { $0.code == selection.station.code } ?? 0
        // On a trip from search, where you get off: to change to the next train, or there.
        let trip = plannedTrip
        let offIndex = trip.flatMap { trip in
            detail.stops.first { $0.index > originIndex && $0.code == trip.destinationCode }?.index
        }
        let offTag = trip?.hasOnward == true ? "Change" : "Your stop"
        return TimelineView(.periodic(from: .now, by: 10)) { context in
            let state = trainState(detail, at: context.date)
            VStack(alignment: .leading, spacing: 12) {
                if tracker.isTracking(row) || (canTrack(detail, at: context.date) && !isCancelledHere) {
                    trackButton
                    // On a trip with changes, its next train cancelled: a way round it.
                    if let trip, let next = trip.cancelledConnection {
                        ConnectionCancelledCard(trip: trip, next: next) {
                            TripPlanModel.planAnotherWay(around: trip)
                        }
                    }
                } else if detail.source != nil, row.expected.timeIntervalSince(context.date) > Self.trackAhead {
                    Label("You can track it from 4 hours before it leaves", systemImage: "clock")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ZStack(alignment: .topLeading) {
                    // (The line and the train on it, afresh every second: the train
                    // glides, as on the map.)
                    TimelineView(.periodic(from: .now, by: TrainGlide.period)) { moment in
                        let state = trainState(detail, at: moment.date)
                        TripLine(stopCount: detail.stops.count, state: state,
                                 place: trainPlace(detail, state: state, at: moment.date), color: lineColor)
                    }

                    VStack(spacing: 0) {
                        ForEach(detail.stops) { stop in
                            Button {
                                if let station = network.station(stop.code) { openStation = station }
                            } label: {
                                StopRow(
                                    stop: stop,
                                    name: network.station(stop.code)?.name ?? stop.code,
                                    role: role(for: stop.code),
                                    isOrigin: stop.index == originIndex,
                                    isEnd: stop.index == 0 || stop.index == detail.stops.count - 1,
                                    // Dimmed once the train has left it (all of them, the whole trip cancelled).
                                    isDimmed: state.hasPassed(stop.index, stopCount: detail.stops.count)
                                        || cancellation?.all == true,
                                    lineColor: lineColor,
                                    tag: stop.index == offIndex ? offTag : nil,
                                    isSkipped: cancellation?.skips.contains(stop.code) == true
                                )
                            }
                            .buttonStyle(StopRowButtonStyle())
                        }
                    }

                    TimelineView(.periodic(from: .now, by: TrainGlide.period)) { moment in
                        let state = trainState(detail, at: moment.date)
                        TrainMarkerLayer(stopCount: detail.stops.count, state: state,
                                         place: trainPlace(detail, state: state, at: moment.date), color: lineColor)
                    }
                }
                .padding(.vertical, 6)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }

    private func role(for code: String) -> StationRole {
        if code == settings.homeCode { return .home }
        if code == settings.workCode { return .work }
        return .plain
    }

    // MARK: The rest of the trip

    #if DEBUG
    private static var debugAnchor: UnitPoint? {
        UserDefaults.standard.bool(forKey: "tripScrollToEnd") ? .bottom : nil
    }

    /// A made-up disruption on the train's line (`-debugTripAlert YES`).
    private static func debugAlert(_ row: BoardRow) -> StationAlert {
        StationAlert(
            id: "debug",
            subjectEnglish: "\(row.lineName) - Signal issue, delays of up to 30 minutes",
            subjectFrench: "\(row.lineName) – Problème de signalisation, retards jusqu’à 30 minutes",
            body: "Repair personnel are working on the problem, but there will be delays, cancellations "
                + "and modifications until the situation is resolved."
        )
    }
    #endif

    /// The tracked trip, when this is its train and it's a trip from search (which
    /// can go on after this train, with changes).
    private var plannedTrip: TrackedTrip? {
        guard let trip = tracker.trip, trip.matches(row), trip.journeyKey != nil else { return nil }
        return trip
    }

    /// One train after this one: its stops from where you get on to where you get
    /// off, live when Metrolinx has them, else the timetable's; and which they are.
    private func stops(of leg: OnwardLeg) -> (stops: [TripDetail.Stop], isLive: Bool) {
        func part(_ stops: [TripDetail.Stop]) -> [TripDetail.Stop]? {
            guard let on = stops.firstIndex(where: { $0.code == leg.boardingCode }),
                  let off = stops.indices.first(where: { $0 > on && stops[$0].code == leg.destinationCode })
            else { return nil }
            return Array(stops[on...off])
        }
        if let live = onwardDetails[leg.row.id], live.source == .live, let stops = part(live.stops) {
            return (stops, true)
        }
        return (part(leg.stops) ?? [], false)
    }

    /// Where you change, and the train you change to, for each train after this one.
    private func restOfTrip(_ trip: TrackedTrip) -> some View {
        let legs = trip.onward ?? []
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(legs.enumerated()), id: \.offset) { index, leg in
                let part = stops(of: leg)
                // In where you change (as the train before is running), and away on this one.
                let inAt = index == 0 ? trip.arrival
                    : stops(of: legs[index - 1]).stops.last.flatMap { $0.expected ?? $0.time }
                let leaves = part.stops.first.flatMap { $0.expected ?? $0.time }
                ChangeRow(station: network.station(leg.boardingCode)?.name ?? leg.boardingCode,
                          wait: inAt.flatMap { inAt in leaves.map { $0.timeIntervalSince(inAt) } },
                          platform: part.stops.first?.platform, isCancelled: leg.cancelled != nil)
                if !part.stops.isEmpty {
                    OnwardLegCard(leg: leg, stops: part.stops, isLive: part.isLive,
                                  isLast: index == legs.count - 1, role: role(for:)) { code in
                        if let station = network.station(code) { openStation = station }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sourceNote(_ detail: TripDetail) -> some View {
        Group {
            switch detail.source {
            case .live:
                Label("Live times from Metrolinx", systemImage: "dot.radiowaves.left.and.right")
            case .schedule:
                Label("Scheduled times, not live", systemImage: "calendar")
            case nil:
                Label("Times aren't available for this train", systemImage: "questionmark.circle")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }
}

// MARK: - How late

/// "25 min late" ("1 h 10 min late"), in orange like the stops' late times.
private struct LatePill: View {
    let minutes: Int

    var body: some View {
        Label(Self.text(minutes), systemImage: "clock.badge.exclamationmark.fill")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Color.late)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.late.opacity(0.16), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Running \(minutes) minutes late")
    }

    static func text(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min late" : "\(minutes / 60) h \(minutes % 60) min late"
    }
}

extension Color {
    /// Late times and how late a train is: orange, a darker one on a light background
    /// so it reads there too.
    static let late = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemOrange : UIColor(red: 0.72, green: 0.34, blue: 0, alpha: 1)
    })
}

// MARK: - How fast

/// How fast the train is going, as the map draws it moving ("82 km/h"); nothing
/// while it isn't in service, or nothing says.
private struct TrainSpeedLabel: View {
    let number: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let speed = TrainMotion.shared.speed(of: number, at: context.date) {
                let kmh = Int((speed * 3.6).rounded())
                Label {
                    Text("\(kmh) km/h")
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(kmh)))
                } icon: {
                    Image(systemName: "speedometer")
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .animation(.smooth(duration: 0.4), value: kmh)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Speed \(kmh) kilometres per hour")
            }
        }
    }
}

// MARK: - Where the train is

extension TrainState {
    /// Where the train is, from its stops' times (when it was seen leaving and
    /// pulling in, live estimates, otherwise the timetable), and by its latest
    /// live report when there's a fresh one (see `adjusted(by:stopCount:now:)`).
    init(stops: [TripDetail.Stop], now: Date, live: LiveFix? = nil) {
        let timed = Self.locate(times: stops.map { $0.departed ?? $0.expected ?? $0.time },
                                arrivals: stops.map(\.arrived), now: now)
        self = timed.adjusted(by: live, stopCount: stops.count, now: now)
    }

    /// Where the train is when a fresh live report says otherwise than its times:
    /// standing at a station it was due to have left, or still on its way to one
    /// it was due at (most of the way there), or already away from one it was due
    /// to stand at.
    func adjusted(by fix: LiveFix?, stopCount: Int, now: Date) -> TrainState {
        guard let fix, fix.isFresh(at: now), stopCount >= 2, fix.index < stopCount else { return self }
        let last = stopCount - 1
        if fix.isAt {
            if fix.index == 0 {
                if case .waiting = self { return self }
                return .waiting(departs: now)
            }
            if fix.index == last {
                if case .arrived = self { return self }
                return .arrived(at: fix.time)
            }
            return .stopped(at: fix.index)
        }
        // On its way to stop `fix.index`, from the one before.
        guard fix.index > 0 else { return self }
        let from = fix.index - 1
        switch self {
        case .moving(let at, let fraction) where at == from:
            return .moving(from: from, fraction: min(max(fraction, 0.02), 0.97))
        case .moving(let at, _) where at > from:
            return .moving(from: from, fraction: 0.97)
        case .stopped(let at) where at > from:
            return .moving(from: from, fraction: 0.97)
        case .arrived:
            return .moving(from: from, fraction: 0.97)
        default:
            // Its times have it still back at (or before) the stop it has left.
            return .moving(from: from, fraction: 0.02)
        }
    }
}

/// Where a train's marker goes among its stops, and what puts it there.
struct TrainPlace: Equatable {
    /// In stops along the line (2.5: halfway from its third stop to its fourth).
    var stops: Double
    /// Its latest live report: not its times, for want of one.
    var isLive: Bool
}

/// How the train's marker, and the line's faded part behind it, follow the train:
/// worked out afresh every second, and gliding evenly from one second's place to
/// the next while the train carries on along its line, so it moves smoothly, as on
/// the map. In one quick step when it's put somewhere else: right after a new
/// report, to its live position from where its times had put it, or by new times.
/// Animated on their own, as where the train is changes: what moves the stops
/// themselves (alerts coming in above them) moves the line and the train with them,
/// never slowly after them.
enum TrainGlide {
    /// How often where the train is among its stops is worked out, in seconds.
    static let period: TimeInterval = 1

    /// Where something is shown along the line (a train's marker, the end of the
    /// faded part), in stops, and whether by the train's times.
    struct Along: Equatable {
        var stops: Double?
        var byTimes: Bool
    }

    /// From where it's `shown` to where it is now (`new`; `old`: as last worked out).
    static func animation(from shown: Double?, old: Along, new: Along, reduceMotion: Bool) -> Animation? {
        guard let shown, let stops = new.stops, !reduceMotion else { return nil }
        // Carrying on: a little further along, by the same thing as before.
        let carriesOn = old.byTimes == new.byTimes && stops >= shown && stops - shown <= 0.25
        return carriesOn ? .linear(duration: period) : .smooth(duration: 0.45)
    }
}

/// A train's reports as placed along its stops' track, kept from one second to the
/// next: worked out once per report. (Only ever used by the view that holds it.)
final class PlacedReports {
    private var newest: Date?
    private var codes: [String] = []
    private var track: TrainReplay.Track?

    func track(of reports: [LiveTrain], on run: TrainRun) -> TrainReplay.Track? {
        if let newest, newest == reports.last?.time, codes == run.codes { return track }
        track = TrainReplay.track(of: reports, on: run)
        newest = reports.last?.time
        codes = run.codes
        return track
    }
}

/// The continuous line behind the stop dots: faded where the train has already been,
/// full colour ahead of it, with white chevrons flowing toward the terminus while
/// the train is moving.
private struct TripLine: View {
    let stopCount: Int
    let state: TrainState
    /// Where the train's marker is (nil while there isn't one: see
    /// `TripSheet.trainPlace`).
    var place: TrainPlace? = nil
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the faded part ends, in stops along the line (see `TrainGlide`).
    @State private var shown: Double?

    /// How much of its run is done, in stops along the line: up to where the train's
    /// marker is; with none, up to the last stop it has left (as the stops are
    /// dimmed). None of it before it sets off, and all of it once it's in, wherever
    /// the train itself is then (coming in to its first stop, off to a yard).
    private var done: Double {
        switch state {
        case .waiting: return 0
        case .arrived: return Double(max(stopCount - 1, 0))
        case .moving, .stopped, .unknown: return place?.stops ?? Double(state.reached(stopCount: stopCount))
        }
    }

    var body: some View {
        let along = TrainGlide.Along(stops: done, byTimes: place?.isLive == false)
        TripLineDrawing(stopCount: stopCount, train: shown ?? done, isMoving: state.isMoving, color: color)
            .onAppear { shown = done }
            .onChange(of: along) { old, new in
                withAnimation(TrainGlide.animation(from: shown, old: old, new: new, reduceMotion: reduceMotion)) {
                    shown = new.stops ?? 0
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The line, faded up to `train` stops along it: animatable, so the faded part
/// glides with the train's marker.
private struct TripLineDrawing: View, Animatable {
    let stopCount: Int
    var train: Double
    let isMoving: Bool
    let color: Color

    var animatableData: Double {
        get { train }
        set { train = newValue }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let rowHeight = TripSheet.rowHeight
    private let lineX = TripSheet.lineX
    private let lineWidth: CGFloat = 8

    private func y(_ stops: Double) -> CGFloat { CGFloat(stops) * rowHeight + rowHeight / 2 }

    var body: some View {
        let top = y(0)
        let bottom = y(Double(max(stopCount - 1, 0)))
        let train = min(max(y(self.train), top), bottom)
        let animate = isMoving && !reduceMotion

        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animate)) { context in
            let spacing: CGFloat = 16
            let phase = animate
                ? CGFloat((context.date.timeIntervalSinceReferenceDate * 14).truncatingRemainder(dividingBy: Double(spacing)))
                : 0

            Canvas { canvas, _ in
                let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                if train > top {
                    var behind = Path()
                    behind.move(to: CGPoint(x: lineX, y: top))
                    behind.addLine(to: CGPoint(x: lineX, y: train))
                    canvas.stroke(behind, with: .color(color.opacity(0.3)), style: style)
                }
                if bottom > train {
                    var ahead = Path()
                    ahead.move(to: CGPoint(x: lineX, y: train))
                    ahead.addLine(to: CGPoint(x: lineX, y: bottom))
                    canvas.stroke(ahead, with: .color(color), style: style)
                }

                // Chevrons pointing down the list, the way the train is going.
                guard isMoving else { return }
                var chevrons = Path()
                var position = train + 16 + phase
                while position < bottom - 4 {
                    chevrons.move(to: CGPoint(x: lineX - 2.6, y: position - 1.6))
                    chevrons.addLine(to: CGPoint(x: lineX, y: position + 1.2))
                    chevrons.addLine(to: CGPoint(x: lineX + 2.6, y: position - 1.6))
                    position += spacing
                }
                canvas.stroke(chevrons, with: .color(.white.opacity(0.9)),
                              style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: bottom + rowHeight / 2)
    }
}

/// The train itself, drawn above the stop rows, where `place` has it (see
/// `TripSheet.trainPlace`): where its latest GPS report has it along the line, as
/// on the map, or for want of a live position, where its times put it.
private struct TrainMarkerLayer: View {
    let stopCount: Int
    let state: TrainState
    /// Where the train is (nil: not drawn).
    var place: TrainPlace? = nil
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the train's drawn, in stops along the line (see `TrainGlide`).
    @State private var shown: Double?

    var body: some View {
        let rowHeight = TripSheet.rowHeight
        let along = TrainGlide.Along(stops: place?.stops, byTimes: place?.isLive == false)
        ZStack(alignment: .topLeading) {
            Color.clear
            if place != nil, let shown {
                TrainMarker(color: color, isSleeping: state.isIdle, isMoving: state.isMoving)
                    .position(x: TripSheet.lineX, y: CGFloat(shown) * rowHeight + rowHeight / 2)
            }
        }
        .frame(height: CGFloat(stopCount) * rowHeight)
        .onAppear { shown = place?.stops }
        .onChange(of: along) { old, new in
            guard let stops = new.stops else {
                shown = nil
                return
            }
            withAnimation(TrainGlide.animation(from: shown, old: old, new: new, reduceMotion: reduceMotion)) {
                shown = stops
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct TrainMarker: View {
    let color: Color
    /// Waiting to depart, or done for the trip.
    let isSleeping: Bool
    /// Between stations (it pulses), not standing at one.
    let isMoving: Bool

    var body: some View {
        Image(systemName: "tram.fill")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(isSleeping ? Color.gray : color, in: Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
            .overlay(alignment: .topTrailing) {
                if isSleeping {
                    Image(systemName: "zzz")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.primary)
                        .padding(3)
                        .background(.background, in: Capsule())
                        .offset(x: 10, y: -8)
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .symbolEffect(.pulse, options: .repeating, isActive: isMoving)
    }
}

/// One stop: time, its dot on the line, the station name.
private struct StopRow: View {
    let stop: TripDetail.Stop
    let name: String
    let role: StationRole
    let isOrigin: Bool
    let isEnd: Bool
    let isDimmed: Bool
    let lineColor: Color
    /// A word beside the name: "Change" where you change trains, "Your stop".
    var tag: String? = nil
    /// GO says the train won't stop here.
    var isSkipped = false

    private var isDelayed: Bool {
        guard !isSkipped, let time = stop.time, let expected = stop.expected else { return false }
        return expected.timeIntervalSince(time) >= 120
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(stop.time.map(TorontoTime.hourMinute) ?? "")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .strikethrough(isDelayed || isSkipped)
                    // (Greyed where it won't stop, as on the rest of a row the train has left.)
                    .foregroundStyle(isDimmed ? HierarchicalShapeStyle.tertiary
                                              : isSkipped ? .secondary : .primary)
                if isDelayed, let expected = stop.expected {
                    Text(TorontoTime.hourMinute(expected))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(Color.late)
                }
            }
            .lineLimit(1)
            .frame(width: 52, alignment: .trailing)

            dot
                .frame(width: 22)

            HStack(spacing: 8) {
                if role != .plain {
                    Image(systemName: role.symbolName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(role == .home ? RoleColor.home : RoleColor.work, in: Circle())
                        .accessibilityLabel(role == .home ? "Home" : "Work")
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(role != .plain || isOrigin || tag != nil ? .body.weight(.bold) : .body)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if let tag {
                            Text(tag)
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(lineColor, in: Capsule())
                                .fixedSize()
                        }
                    }
                    if isSkipped {
                        Text("Not stopping | Ne s'arrête pas")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.red)
                    } else if let platform = stop.platform {
                        Text("Platform \(platform)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(isDimmed ? .tertiary : .primary)
        .padding(.horizontal, 12)
        .frame(height: TripSheet.rowHeight)
        .background(role != .plain ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
    }

    /// The line itself is drawn once behind all rows (TripLine); rows add the dots
    /// (a grey ring where the train won't stop).
    private var dot: some View {
        let size: CGFloat = isOrigin || isEnd ? 18 : 14
        let fill = isSkipped ? Color(uiColor: .systemBackground) : isOrigin ? lineColor : Color.white
        let ring = isSkipped ? Color.gray : isOrigin ? Color.white : lineColor
        return Circle()
            .fill(fill)
            .overlay(Circle().strokeBorder(ring, lineWidth: isOrigin && !isSkipped ? 3 : 3.5))
            .frame(width: size, height: size)
            .opacity(isDimmed && !isOrigin ? 0.55 : 1)
    }
}

// MARK: - The rest of a trip

/// Where you change trains: "Change at Union Station", how long you have, and
/// the platform the next train leaves from when that's known.
private struct ChangeRow: View {
    let station: String
    /// From getting in to the next train leaving (negative: it leaves first).
    let wait: TimeInterval?
    let platform: String?
    /// GO says the next train won't come for you: no change to make.
    var isCancelled = false

    private var waitText: (text: String, color: Color)? {
        if isCancelled { return ("Your next train is cancelled", .red) }
        guard let wait else { return nil }
        if wait < 0 { return ("It leaves before you get in", .red) }
        let minutes = Int((wait / 60).rounded(.down))
        return ("\(DurationText.text(minutes: minutes)) to change", minutes < 3 ? .orange : .secondary)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(.background.secondary, in: Circle())
                // Under the line of the trains' stops.
                .padding(.leading, TripSheet.lineX - 15)
            VStack(alignment: .leading, spacing: 2) {
                Text("Change at \(station)")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    if let waitText {
                        Text(waitText.text)
                            .foregroundStyle(waitText.color)
                    }
                    if waitText != nil, platform != nil, !isCancelled {
                        Text("·").foregroundStyle(.tertiary)
                    }
                    if let platform, !isCancelled {
                        Text("Platform \(platform)")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.footnote.weight(.medium))
            }
            .padding(.top, 5)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A train you'll change to: its line and where it goes, then its stops from
/// where you get on to where you get off, along its line in its colour.
private struct OnwardLegCard: View {
    let leg: OnwardLeg
    let stops: [TripDetail.Stop]
    let isLive: Bool
    /// The last train of the trip: its last stop here is where the trip ends.
    let isLast: Bool
    let role: (String) -> StationRole
    let open: (String) -> Void

    private let network = RailNetwork.shared

    var body: some View {
        let line = network.line(code: leg.row.lineCode)
        let color = line?.color ?? .gray
        let terminus = leg.stops.last.flatMap { network.station($0.code)?.name } ?? leg.row.destination
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    LineBadge(code: line?.code ?? leg.row.lineCode)
                    Text(line?.name ?? leg.row.lineName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if leg.cancelled != nil {
                        Label("Cancelled", systemImage: "xmark.circle.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.red)
                    } else if !isLive {
                        // Its times as planned, until Metrolinx has it live.
                        Label("Timetable", systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("To \(terminus)")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)
            stopList(color: color)
        }
        .padding(.bottom, 6)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func stopList(color: Color) -> some View {
        ZStack(alignment: .topLeading) {
            TripLine(stopCount: stops.count, state: .waiting(departs: stops.first?.time ?? .distantFuture),
                     color: color)
            VStack(spacing: 0) {
                ForEach(Array(stops.enumerated()), id: \.element.id) { position, stop in
                    Button {
                        open(stop.code)
                    } label: {
                        StopRow(
                            stop: stop,
                            name: network.station(stop.code)?.name ?? stop.code,
                            role: role(stop.code),
                            isOrigin: position == 0,
                            isEnd: position == stops.count - 1,
                            // Cancelled for you: all of it dimmed, struck through where it won't stop.
                            isDimmed: leg.cancelled != nil,
                            lineColor: color,
                            tag: position == stops.count - 1 ? (isLast ? "Your stop" : "Change") : nil,
                            isSkipped: leg.cancelled.map { $0.code == nil || $0.code == stop.code } ?? false
                        )
                    }
                    .buttonStyle(StopRowButtonStyle())
                }
            }
        }
    }
}

/// On a trip with changes, under the Tracking button once its next train is
/// cancelled: "Your 08:10 connection at Union is cancelled", why, and a way round
/// it (the trip card from where you change, for trains after you get there). The
/// card's corners run concentric with the button's round ends, as the trip
/// card's do.
private struct ConnectionCancelledCard: View {
    let trip: TrackedTrip
    let next: OnwardLeg
    let plan: () -> Void

    private let network = RailNetwork.shared

    var body: some View {
        let text = TripAlerts.connectionText(trip, back: false, network: network)
        let station = TripActivityController.shortName(network.station(next.boardingCode)?.name ?? next.boardingCode)
        VStack(alignment: .leading, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(text.title)
                        .font(.subheadline.weight(.semibold))
                    if let code = next.cancelled?.code {
                        Text("It won't stop at \(network.station(code)?.name ?? code).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            .padding(.horizontal, TripPlanSheet.textInset)
            Button(action: plan) {
                Label("Plan another way from \(station)", systemImage: "arrow.triangle.branch")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .frame(height: TripPlanSheet.buttonHeight)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glass(.tinted(.accentColor), in: Capsule())
            .accessibilityHint("Shows trains from \(station) after you get there")
        }
        .padding(TripPlanSheet.cardPadding)
        .background(.background.secondary,
                    in: RoundedRectangle(cornerRadius: TripPlanSheet.cardRadius, style: .continuous))
    }
}

private struct StopRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : Color.clear)
    }
}
