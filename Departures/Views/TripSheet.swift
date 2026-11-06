import SwiftUI

/// The train a board row was tapped on, and the station whose board it came from.
struct TripSelection: Identifiable {
    let row: BoardRow
    let station: Station

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
/// direction of travel and a marker where the train should be now. Tapping a stop
/// opens that station's board in another sheet, which can open another train, and so on.
struct TripSheet: View {
    let selection: TripSelection

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var detail: TripDetail?
    @State private var openStation: Station?

    private let network = RailNetwork.shared

    static let rowHeight: CGFloat = 56
    /// Horizontal centre of the line inside a stop row (padding + time column + spacing + half the dot column).
    static let lineX: CGFloat = 12 + 52 + 10 + 11

    private var row: BoardRow { selection.row }
    private var lineColor: Color { network.line(code: row.lineCode)?.color ?? .gray }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let detail {
                    stopList(detail)
                    sourceNote(detail)
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
        // The train's line, terminus and close button stay pinned over the stops.
        .pinnedHeader(bottomRoom: PinnedHeaderMetrics.tripBottom) { header }
        .task {
            detail = await BoardService.shared.tripDetail(for: row, from: selection.station)
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
                if let direction {
                    Label(direction.label, systemImage: direction.symbol)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(lineColor, in: Capsule())
                        .accessibilityLabel(direction.label)
                }
                Text(origin.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .redacted(reason: origin.isKnown ? [] : .placeholder)
                if row.isCancelled {
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
                tracker.track(selection, detail: detail, home: settings.homeCode, work: settings.workCode)
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
        .glassEffect(tracking ? .regular.interactive() : .regular.tint(lineColor).interactive(), in: Capsule())
        .animation(.smooth(duration: 0.25), value: tracking)
        .accessibilityHint(tracking ? "Stops following this train"
                                    : "Follows this train on the map and in a Live Activity")
    }

    /// Only a train with times that hasn't finished its run.
    private func canTrack(_ detail: TripDetail, at now: Date) -> Bool {
        guard detail.source != nil else { return false }
        if case .arrived = TrainState(stops: detail.stops, now: now) { return false }
        return true
    }

    // MARK: Stops

    private func stopList(_ detail: TripDetail) -> some View {
        let originIndex = detail.stops.firstIndex { $0.code == selection.station.code } ?? 0
        return TimelineView(.periodic(from: .now, by: 10)) { context in
            let state = TrainState(stops: detail.stops, now: context.date)
            VStack(alignment: .leading, spacing: 12) {
                if tracker.isTracking(row) || canTrack(detail, at: context.date) {
                    trackButton
                }

                ZStack(alignment: .topLeading) {
                    TripLine(stopCount: detail.stops.count, state: state, color: lineColor)

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
                                    // Dimmed once the train has left it.
                                    isDimmed: state.hasPassed(stop.index, stopCount: detail.stops.count),
                                    lineColor: lineColor
                                )
                            }
                            .buttonStyle(StopRowButtonStyle())
                        }
                    }

                    TrainMarkerLayer(stopCount: detail.stops.count, state: state, color: lineColor)
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

// MARK: - Where the train is

/// Where the train should be right now, worked out from its stop times
/// (live estimates when there are any, otherwise the timetable).
enum TrainState {
    /// Hasn't left its first stop yet.
    case waiting(departs: Date)
    /// Between two stops; `fraction` of the way from `from` to `from + 1`.
    case moving(from: Int, fraction: Double)
    /// Reached its last stop.
    case arrived(at: Date)
    /// Not enough times to tell.
    case unknown

    init(stops: [TripDetail.Stop], now: Date) {
        let times = stops.map { $0.expected ?? $0.time }
        guard let first = times.first ?? nil, let last = times.last ?? nil else {
            self = .unknown
            return
        }
        if now < first {
            self = .waiting(departs: first)
            return
        }
        if now >= last {
            self = .arrived(at: last)
            return
        }
        for index in 0..<(times.count - 1) {
            guard let start = times[index], let end = times[index + 1], now >= start, now < end else { continue }
            let fraction = end > start ? now.timeIntervalSince(start) / end.timeIntervalSince(start) : 0
            self = .moving(from: index, fraction: fraction)
            return
        }
        self = .unknown
    }

    /// Position along the list, in stops (0 = first stop).
    func progress(stopCount: Int) -> Double? {
        switch self {
        case .waiting: return 0
        case .moving(let from, let fraction): return Double(from) + fraction
        case .arrived: return Double(max(stopCount - 1, 0))
        case .unknown: return nil
        }
    }

    /// Whether the train has already left this stop.
    func hasPassed(_ index: Int, stopCount: Int) -> Bool {
        switch self {
        case .waiting, .unknown: return false
        case .moving(let from, _): return index <= from
        case .arrived: return index < stopCount - 1
        }
    }

    var isMoving: Bool {
        if case .moving = self { return true }
        return false
    }
}

/// The continuous line behind the stop dots: faded where the train has already been,
/// full colour ahead of it, with white chevrons flowing toward the terminus while
/// the train is moving.
private struct TripLine: View {
    let stopCount: Int
    let state: TrainState
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let rowHeight = TripSheet.rowHeight
    private let lineX = TripSheet.lineX
    private let lineWidth: CGFloat = 8

    private func y(_ stops: Double) -> CGFloat { CGFloat(stops) * rowHeight + rowHeight / 2 }

    var body: some View {
        let top = y(0)
        let bottom = y(Double(max(stopCount - 1, 0)))
        let train = min(max(y(state.progress(stopCount: stopCount) ?? 0), top), bottom)
        let animate = state.isMoving && !reduceMotion

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
                guard state.isMoving else { return }
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
        .animation(.linear(duration: 10), value: train)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The train itself, drawn above the stop rows.
private struct TrainMarkerLayer: View {
    let stopCount: Int
    let state: TrainState
    let color: Color

    var body: some View {
        let rowHeight = TripSheet.rowHeight
        ZStack(alignment: .topLeading) {
            Color.clear
            if let progress = state.progress(stopCount: stopCount) {
                TrainMarker(color: color, isSleeping: !state.isMoving)
                    .position(x: TripSheet.lineX, y: CGFloat(progress) * rowHeight + rowHeight / 2)
                    .animation(.linear(duration: 10), value: progress)
            }
        }
        .frame(height: CGFloat(stopCount) * rowHeight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct TrainMarker: View {
    let color: Color
    /// Waiting to depart, or done for the trip.
    let isSleeping: Bool

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
            .symbolEffect(.pulse, options: .repeating, isActive: !isSleeping)
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

    private var isDelayed: Bool {
        guard let time = stop.time, let expected = stop.expected else { return false }
        return expected.timeIntervalSince(time) >= 120
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(stop.time.map(TorontoTime.hourMinute) ?? "")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .strikethrough(isDelayed)
                if isDelayed, let expected = stop.expected {
                    Text(TorontoTime.hourMinute(expected))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.orange)
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
                    Text(name)
                        .font(role != .plain || isOrigin ? .body.weight(.bold) : .body)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let platform = stop.platform {
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

    /// The line itself is drawn once behind all rows (TripLine); rows add the dots.
    private var dot: some View {
        let size: CGFloat = isOrigin || isEnd ? 18 : 14
        return Circle()
            .fill(isOrigin ? lineColor : Color.white)
            .overlay(Circle().strokeBorder(isOrigin ? Color.white : lineColor, lineWidth: isOrigin ? 3 : 3.5))
            .frame(width: size, height: size)
            .opacity(isDimmed && !isOrigin ? 0.55 : 1)
    }
}

private struct StopRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : Color.clear)
    }
}
