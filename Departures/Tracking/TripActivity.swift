import ActivityKit
import SwiftUI
import WidgetKit

// The tracked train's Live Activity: what it carries and how it looks, and where
// a train is along its stops. The app starts and updates it (TripActivityController);
// the widget extension draws it with the views below. Both targets compile this
// file, and debug builds of the app draw the same views for screenshots
// (TripActivityGallery).
//
// The views work everything out from the stops' times when they're drawn, and
// their countdowns and bars run on the system's clock, so they keep going while
// the app isn't running. iOS draws them again when the app updates the activity,
// and once more at its stale date: when the train reaches the stop it counts down to.

// MARK: - Where a train is

/// Where the train should be right now, worked out from its stop times
/// (live estimates when there are any, otherwise the timetable).
enum TrainState {
    /// Hasn't left its first stop yet.
    case waiting(departs: Date)
    /// Between two stops; `fraction` of the way from `from` to `from + 1`.
    case moving(from: Int, fraction: Double)
    /// Standing at a station along the way.
    case stopped(at: Int)
    /// Reached its last stop.
    case arrived(at: Date)
    /// Not enough times to tell.
    case unknown

    /// How long a train stands at each station along the way. GO's times are one
    /// per stop (when it leaves), with nothing on how long it stops, so take a
    /// minute: it pulls in a minute before it leaves (or halfway, on a short hop).
    static let dwell: TimeInterval = 60

    /// When the train pulls in at stop `index`: a minute before it leaves (or
    /// halfway from the stop before, on a short hop). At its first stop, when it
    /// leaves; at its last, its time there.
    static func arrival(at index: Int, times: [Date?]) -> Date? {
        guard times.indices.contains(index), let time = times[index] else { return nil }
        guard index > 0, index < times.count - 1 else { return time }
        let previous = times[index - 1] ?? time
        return time.addingTimeInterval(-min(dwell, max(0, time.timeIntervalSince(previous)) / 2))
    }

    /// Where a train is at `now`, from when it leaves each of its stops (nil where
    /// that isn't known; the last stop's time is when it gets there).
    static func locate(times: [Date?], now: Date) -> TrainState {
        guard let first = times.first ?? nil, let last = times.last ?? nil else { return .unknown }
        if now < first { return .waiting(departs: first) }
        if now >= last { return .arrived(at: last) }
        for index in 0..<(times.count - 1) {
            guard let start = times[index], let end = times[index + 1], now >= start, now < end else { continue }
            let stand = index + 1 == times.count - 1 ? 0 : min(dwell, end.timeIntervalSince(start) / 2)
            let arrives = end.addingTimeInterval(-stand)
            if now >= arrives { return .stopped(at: index + 1) }
            let run = arrives.timeIntervalSince(start)
            return .moving(from: index, fraction: run > 0 ? now.timeIntervalSince(start) / run : 0)
        }
        return .unknown
    }

    /// Position along the list, in stops (0 = first stop).
    func progress(stopCount: Int) -> Double? {
        switch self {
        case .waiting: return 0
        case .moving(let from, let fraction): return Double(from) + fraction
        case .stopped(let at): return Double(at)
        case .arrived: return Double(max(stopCount - 1, 0))
        case .unknown: return nil
        }
    }

    /// Whether the train has already left this stop.
    func hasPassed(_ index: Int, stopCount: Int) -> Bool {
        switch self {
        case .waiting, .unknown: return false
        case .moving(let from, _): return index <= from
        case .stopped(let at): return index < at
        case .arrived: return index < stopCount - 1
        }
    }

    /// The last stop the train has reached: the one it's at, or the one it last left.
    func reached(stopCount: Int) -> Int {
        switch self {
        case .waiting, .unknown: return 0
        case .moving(let from, _): return from
        case .stopped(let at): return at
        case .arrived: return max(stopCount - 1, 0)
        }
    }

    var isMoving: Bool {
        if case .moving = self { return true }
        return false
    }

    /// Waiting to start, or done: not in service.
    var isIdle: Bool {
        switch self {
        case .waiting, .arrived, .unknown: return true
        case .moving, .stopped: return false
        }
    }
}

// MARK: - What it carries

struct TripActivityAttributes: ActivityAttributes {
    /// What changes while the train runs.
    struct ContentState: Codable, Hashable {
        /// When the train leaves your station (the live estimate when there is one).
        var departure: Date
        /// When it reaches your stop.
        var arrival: Date
        /// Whether it had left your station when the app last updated this.
        var hasDeparted: Bool
        /// Minutes late at the next of those two stops, from live times; nil when
        /// that isn't known.
        var minutesLate: Int?
        /// The platform at your station, when known.
        var platform: String?
        /// The train's stops in order, with when it leaves each (at the last, when
        /// it gets in). Nil from builds before the stop strip, which carried only
        /// the two times above.
        var stops: [Stop]? = nil
        /// Where you get on and where you get off, in `stops`.
        var boardingIndex: Int? = nil
        var destinationIndex: Int? = nil
        /// Tracked from your station's board: until the train gets there, the
        /// countdown is to it.
        var awaitsTrain: Bool? = nil
    }

    /// One of the train's stops.
    struct Stop: Codable, Hashable {
        /// Short enough for the strip: "Union" for Union Station.
        var name: String
        /// When the train leaves it (at its last stop, when it gets in); nil when
        /// that isn't known.
        var time: Date?
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
    /// The line's name ("Kitchener"); nil from earlier builds.
    var lineName: String? = nil
    /// Which way the train runs ("eastbound").
    var direction: String? = nil
    /// When it's due to leave your station, as on its board: "your 20:48 train".
    var boardingTime: Date? = nil
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

    func color(onDark: Bool) -> Color { onDark ? lineColorOnDark : lineColor }

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

// MARK: - The trip, as the views see it

/// The tracked trip as the views use it: its stops, and where you get on and off.
/// (A Live Activity started by an earlier build has only your station and your stop.)
struct TripActivityTrip {
    typealias Stop = TripActivityAttributes.Stop

    let stops: [Stop]
    let boarding: Int
    let destination: Int
    /// Tracked from your station's board: the countdown is to the train getting there first.
    let awaitsTrain: Bool

    init(_ attributes: TripActivityAttributes, _ state: TripActivityAttributes.ContentState) {
        if let stops = state.stops, stops.count >= 2 {
            self.stops = stops
            let last = stops.count - 1
            boarding = min(max(state.boardingIndex ?? 0, 0), last)
            destination = min(max(state.destinationIndex ?? last, boarding), last)
        } else {
            stops = [Stop(name: attributes.boardingName, time: state.departure),
                     Stop(name: attributes.destinationName, time: state.arrival)]
            boarding = 0
            destination = 1
        }
        awaitsTrain = state.awaitsTrain ?? false
    }

    var times: [Date?] { stops.map(\.time) }

    /// When the train pulls in at a stop.
    func arrival(at index: Int) -> Date? {
        TrainState.arrival(at: index, times: times)
    }

    /// What's happening at `now`, and what the countdown runs to.
    func moment(at now: Date) -> TripMoment {
        let train = TrainState.locate(times: times, now: now)
        let reached = train.reached(stopCount: stops.count)
        if let end = arrival(at: destination), now >= end {
            return TripMoment(kind: .arrived, train: train, next: destination, target: end,
                              reached: max(reached, destination))
        }
        if awaitsTrain, let comes = arrival(at: boarding), now < comes {
            return TripMoment(kind: .approaching, train: train, next: boarding, target: comes, reached: reached)
        }
        switch train {
        case .waiting(let departs):
            return TripMoment(kind: .waiting, train: train, next: 0, target: departs, reached: 0)
        case .moving(let from, _):
            return TripMoment(kind: .riding, train: train, next: from + 1, target: arrival(at: from + 1), reached: from)
        case .stopped(let at):
            // Standing at a station: the countdown is already to the one after.
            let next = min(at + 1, stops.count - 1)
            return TripMoment(kind: .riding, train: train, next: next, target: arrival(at: next), reached: at)
        case .arrived(let time):
            return TripMoment(kind: .arrived, train: train, next: stops.count - 1, target: time, reached: reached)
        case .unknown:
            return TripMoment(kind: .riding, train: train, next: nil, target: nil, reached: 0)
        }
    }

    /// The stop the strip ends at: your stop, or your station while the train's
    /// on its way to it.
    func focus(_ moment: TripMoment) -> Int {
        moment.kind == .approaching ? boarding : destination
    }

    /// The stops the strip shows: the one the train last reached and the one
    /// before, then the next ones up to the focus (the last few left out when
    /// they don't fit), with stops it has passed filling any room left.
    func strip(for moment: TripMoment, count: Int = 5) -> [Int] {
        let last = stops.count - 1
        let reached = min(max(moment.reached, 0), last)
        let end = min(max(focus(moment), reached + 1), last)
        var ahead = reached < end ? Array((reached + 1)...end) : []
        let room = count - min(reached + 1, 2)
        if ahead.count > room {
            ahead = Array(ahead.prefix(max(room - 1, 1))) + [end]
        }
        let behind = min(reached + 1, count - ahead.count)
        return Array((reached - behind + 1)...reached) + ahead
    }
}

/// What the Live Activity shows at one moment.
struct TripMoment {
    enum Kind {
        /// Tracked from your station's board, and the train isn't there yet.
        case approaching
        /// Hasn't left its first stop.
        case waiting
        /// On its way: between stops, or standing at one.
        case riding
        /// At your stop (or the end of its run).
        case arrived
    }

    let kind: Kind
    let train: TrainState
    /// The stop the countdown runs to: your station while you wait for the train,
    /// otherwise the next one.
    let next: Int?
    /// When the countdown runs out (when the train gets there); at your stop,
    /// when it got there.
    let target: Date?
    /// The last stop the train has reached (it's there, or past it).
    let reached: Int
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

/// Under "To Union Station": the next stop ("Next stop: Port Credit"), your
/// station while the train's on its way there ("Your 20:48 from Bramalea"), or
/// where it got in.
struct TripNextLine: View {
    let attributes: TripActivityAttributes
    let trip: TripActivityTrip
    let moment: TripMoment

    var body: some View {
        line.lineLimit(1)
    }

    private var line: Text {
        func name(_ index: Int?) -> String {
            index.map { trip.stops[$0].name } ?? attributes.terminusName
        }
        let plain: (String) -> Text = { Text($0).foregroundStyle(.secondary) }
        let bold: (String) -> Text = { Text($0).fontWeight(.semibold).foregroundStyle(.primary) }
        switch moment.kind {
        case .approaching:
            let time = attributes.boardingTime ?? trip.stops[trip.boarding].time
            return plain(time.map { "Your \(TripActivityFormat.time($0)) from " } ?? "Your train from ")
                + bold(trip.stops[trip.boarding].name)
        case .waiting:
            return plain("Waiting at ") + bold(name(0))
        case .riding:
            return plain("Next stop: ") + bold(name(moment.next))
        case .arrived:
            return plain("Arrived at ") + bold(name(moment.next))
        }
    }
}

/// The countdown with what it counts down to over it: "Arrives in" (at the next
/// stop, or at your station while you wait for the train) or "Leaves in" (a train
/// that hasn't set off); "Arrived" over the time once it's at your stop.
struct TripTimeBlock: View {
    let trip: TripActivityTrip
    let moment: TripMoment
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(caption)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if moment.kind == .arrived {
                Text(moment.target.map(TripActivityFormat.time) ?? "")
                    .font(.system(size: fontSize, weight: .semibold))
                    .monospacedDigit()
            } else if let target = moment.target {
                TripCountdown(target: target, fontSize: fontSize, alignment: .trailing)
            }
        }
        .lineLimit(1)
    }

    private var caption: String {
        switch moment.kind {
        case .approaching: return trip.boarding == 0 ? "Leaves in" : "Arrives in"
        case .waiting: return "Leaves in"
        case .riding: return "Arrives in"
        case .arrived: return "Arrived"
        }
    }
}

/// Tracked from your station's board, before the train gets there: "Your
/// Kitchener line 20:48 eastbound train to Union Station will arrive in 17
/// minutes", the line's name in its colour, and the minutes counting down.
struct TripApproachSentence: View {
    let attributes: TripActivityAttributes
    let trip: TripActivityTrip
    let moment: TripMoment
    let onDark: Bool

    var body: some View {
        sentence
            .font(.system(size: 15))
            .lineLimit(3)
            .minimumScaleFactor(0.85)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var sentence: Text {
        let line = attributes.lineName.map { "\($0) line" } ?? "\(attributes.lineCode) line"
        let time = (attributes.boardingTime ?? trip.stops[trip.boarding].time).map(TripActivityFormat.time)
        let direction = attributes.direction.map { " \($0)" } ?? ""
        // At its first stop the train is already in: what matters is when it leaves.
        let verb = trip.boarding == 0 ? " will leave " : " will arrive "
        var text = Text("Your ")
            + Text(line).fontWeight(.bold).foregroundStyle(attributes.color(onDark: onDark))
        if let time {
            text = text + Text(" ") + Text(time).fontWeight(.bold).monospacedDigit()
        }
        text = text + Text("\(direction) train to ") + Text(attributes.terminusName).fontWeight(.bold)
        guard let target = moment.target else { return text }
        return text + Text(verb)
            + Text(.currentDate, format: .reference(to: target, allowedFields: [.hour, .minute]))
                .fontWeight(.bold)
    }
}

// MARK: - The stop strip

/// A few stops either side of the train, as in the trip view but across: the line
/// with the stops on it, filling in the line's colour as the train goes (on the
/// system's clock, so it keeps up while the app isn't running), and each stop's
/// name and time under it. It ends at your stop (or your station, while the train
/// is on its way there), drawn bigger; stops left out before it are small dots.
struct TripStopStrip: View {
    let trip: TripActivityTrip
    let moment: TripMoment
    let color: Color
    /// Smaller, one line per name: the expanded Dynamic Island.
    var compact = false

    var body: some View {
        let shown = trip.strip(for: moment)
        let focus = trip.focus(moment)
        VStack(spacing: compact ? 3 : 5) {
            TripStripTrack(trip: trip, shown: shown, focus: focus, color: color, compact: compact)
                .frame(height: 14)
            HStack(alignment: .top, spacing: 0) {
                ForEach(shown, id: \.self) { index in
                    label(index, isFocus: index == focus)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shown.map { index in
            let stop = trip.stops[index]
            return stop.time.map { "\(stop.name) \(TripActivityFormat.time($0))" } ?? stop.name
        }.joined(separator: ", "))
    }

    private func label(_ index: Int, isFocus: Bool) -> some View {
        let stop = trip.stops[index]
        let passed = moment.train.hasPassed(index, stopCount: trip.stops.count)
        return VStack(spacing: 0) {
            Text(stop.name)
                .font(.system(size: compact ? 11 : 12, weight: isFocus ? .bold : .semibold))
                .lineLimit(compact ? 1 : 2)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.center)
            if let time = stop.time {
                Text(TripActivityFormat.time(time))
                    .font(.system(size: compact ? 10.5 : 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(passed ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
        .padding(.horizontal, 1)
    }
}

/// The strip's line: a bar between each pair of neighbouring stops that fills from
/// when the train leaves one to when it pulls in at the next, the stops' dots on top.
private struct TripStripTrack: View {
    let trip: TripActivityTrip
    let shown: [Int]
    let focus: Int
    let color: Color
    let compact: Bool

    private struct Piece: Identifiable {
        let id: Int
        let x: CGFloat
        let length: CGFloat
        let start: Date
        let end: Date
    }

    var body: some View {
        GeometryReader { proxy in
            let column = proxy.size.width / CGFloat(max(shown.count, 1))
            let y = proxy.size.height / 2
            let layout = pieces(column: column)
            ZStack(alignment: .topLeading) {
                ForEach(layout.pieces) { piece in
                    ProgressView(timerInterval: piece.start...piece.end, countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    .progressViewStyle(.linear)
                    .tint(color)
                    .frame(width: max(piece.length, 1))
                    .position(x: piece.x + piece.length / 2, y: y)
                }
                ForEach(layout.minor, id: \.self) { x in
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().strokeBorder(color, lineWidth: 1.5))
                        .frame(width: 6, height: 6)
                        .position(x: x, y: y)
                }
                ForEach(Array(shown.enumerated()), id: \.offset) { position, index in
                    dot(isFocus: index == focus)
                        .position(x: column * (CGFloat(position) + 0.5), y: y)
                }
            }
        }
    }

    private func dot(isFocus: Bool) -> some View {
        let size: CGFloat = isFocus ? (compact ? 12 : 14) : (compact ? 9 : 10)
        return Circle()
            .fill(isFocus ? color : Color.white)
            .overlay(Circle().strokeBorder(isFocus ? Color.white : color, lineWidth: isFocus ? 2.5 : 2.2))
            .frame(width: size, height: size)
    }

    /// The bars, and where the left-out stops sit between them. Half a bar leads in
    /// from the stop before the first one shown, and half leads on to the one after
    /// the last.
    private func pieces(column: CGFloat) -> (pieces: [Piece], minor: [CGFloat]) {
        let times = trip.times
        var pieces: [Piece] = []
        var minor: [CGFloat] = []
        func add(_ x: CGFloat, _ length: CGFloat, _ start: Date?, _ end: Date?) {
            guard let start, let end else { return }
            pieces.append(Piece(id: pieces.count, x: x, length: length, start: start,
                                end: max(end, start.addingTimeInterval(1))))
        }
        func middle(_ a: Date?, _ b: Date?) -> Date? {
            guard let a, let b else { return nil }
            return a.addingTimeInterval(b.timeIntervalSince(a) / 2)
        }
        if let first = shown.first, first > 0 {
            let arrives = trip.arrival(at: first)
            add(0, column / 2, middle(times[first - 1], arrives), arrives)
        }
        for (position, pair) in zip(shown, shown.dropFirst()).enumerated() {
            let hops = pair.1 - pair.0
            guard hops > 0 else { continue }
            let start = column * (CGFloat(position) + 0.5)
            let step = column / CGFloat(hops)
            for hop in 0..<hops {
                let stop = pair.0 + hop
                add(start + step * CGFloat(hop), step, times[stop], trip.arrival(at: stop + 1))
                if hop > 0 { minor.append(start + step * CGFloat(hop)) }
            }
        }
        if let last = shown.last, last < trip.stops.count - 1 {
            add(column * (CGFloat(shown.count) - 0.5), column / 2,
                times[last], middle(times[last], trip.arrival(at: last + 1)))
        }
        return (pieces, minor)
    }
}

// MARK: - Lock Screen

/// The Lock Screen (and the banner on iPhones without the Dynamic Island): the
/// line, where the train's going, the countdown to its next stop, and the stops
/// around it. Tracked from your station's board, until the train gets there: when
/// your train will arrive, in a sentence. The background is the system's own.
struct TripLockScreen: View {
    let attributes: TripActivityAttributes
    let state: TripActivityAttributes.ContentState
    let isStale: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let trip = TripActivityTrip(attributes, state)
        let moment = trip.moment(at: Date())
        let onDark = colorScheme == .dark
        VStack(alignment: .leading, spacing: 12) {
            if moment.kind == .approaching {
                HStack(alignment: .center, spacing: 10) {
                    TripLinePill(code: attributes.lineCode, color: attributes.lineColor, fontSize: 15, shape: Capsule())
                        .frame(height: 32)
                    TripApproachSentence(attributes: attributes, trip: trip, moment: moment, onDark: onDark)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(alignment: .center, spacing: 10) {
                    TripLinePill(code: attributes.lineCode, color: attributes.lineColor, fontSize: 15, shape: Capsule())
                        .frame(height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("To \(attributes.terminusName)")
                            .font(.headline)
                            .lineLimit(1)
                        TripNextLine(attributes: attributes, trip: trip, moment: moment)
                            .font(.subheadline)
                    }
                    Spacer(minLength: 8)
                    TripTimeBlock(trip: trip, moment: moment, fontSize: 26)
                }
            }
            TripStopStrip(trip: trip, moment: moment, color: attributes.color(onDark: onDark))
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

/// Right of the camera: time left until the train reaches its next stop (or your
/// station, while you wait for it there); a tick once it's at your stop.
struct TripCompactTrailing: View {
    let attributes: TripActivityAttributes
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
        let moment = TripActivityTrip(attributes, state).moment(at: now)
        if moment.kind == .arrived {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .accessibilityLabel("Arrived")
        } else if let target = moment.target {
            TripCountdown(target: target, fontSize: target.timeIntervalSince(now) >= 3600 ? 12.5 : 15,
                          alignment: .leading)
                .foregroundStyle(.white)
        }
    }
}

/// When other Live Activities share the island (and in a narrow island): the
/// line's code on its colour, in a ring that fills as the train nears the stop
/// the countdown runs to. Fits a 28-point circle.
struct TripMinimal: View {
    let attributes: TripActivityAttributes
    let state: TripActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let now = Date()
        let trip = TripActivityTrip(attributes, state)
        let moment = trip.moment(at: now)
        ZStack {
            ProgressView(timerInterval: interval(trip, moment, now: now), countsDown: false) {
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

    /// From when the wait (or the run to the next stop) began to when it ends.
    private func interval(_ trip: TripActivityTrip, _ moment: TripMoment, now: Date) -> ClosedRange<Date> {
        let end = moment.target ?? now
        let start: Date
        switch moment.kind {
        case .approaching, .waiting: start = attributes.trackedAt
        case .riding: start = trip.times[moment.reached] ?? attributes.trackedAt
        case .arrived: start = end.addingTimeInterval(-1)
        }
        return min(start, end)...end
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

/// Expanded, right of the camera: the countdown.
struct TripExpandedTrailing: View {
    let attributes: TripActivityAttributes
    let state: TripActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let trip = TripActivityTrip(attributes, state)
        TripTimeBlock(trip: trip, moment: trip.moment(at: Date()), fontSize: 24)
    }
}

/// Expanded, under the camera: where the train's going, and its next stop (or
/// your train, while it's on its way to you).
struct TripExpandedCenter: View {
    let attributes: TripActivityAttributes
    let state: TripActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let trip = TripActivityTrip(attributes, state)
        VStack(spacing: 2) {
            Text("To \(attributes.terminusName)")
                .font(.headline)
                .lineLimit(1)
            TripNextLine(attributes: attributes, trip: trip, moment: trip.moment(at: Date()))
                .font(.subheadline)
        }
        .minimumScaleFactor(0.8)
    }
}

/// Expanded, along the bottom: the stops around the train.
struct TripExpandedBottom: View {
    let attributes: TripActivityAttributes
    let state: TripActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let trip = TripActivityTrip(attributes, state)
        TripStopStrip(trip: trip, moment: trip.moment(at: Date()), color: attributes.lineColorOnDark, compact: true)
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
