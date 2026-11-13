import CoreLocation
import Foundation

/// Where a trip planned from search goes: a station, or a place found on Apple
/// Maps (the trip then ends at the best station near it). Plain data, so the
/// search history can keep it.
struct PlanDestination: Hashable, Codable, Identifiable, Sendable {
    /// The station's code; nil for a place.
    var station: String?
    var name: String
    /// A place's address line ("" for a station).
    var subtitle: String
    var latitude: Double
    var longitude: Double

    var id: String {
        if let station { return "station-\(station)" }
        return "place-\(name)-\(String(format: "%.4f,%.4f", latitude, longitude))"
    }

    var isPlace: Bool { station == nil }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    init(station: Station) {
        self.station = station.code
        name = station.name
        subtitle = ""
        latitude = station.latitude
        longitude = station.longitude
    }

    init(place: SearchPlace) {
        station = nil
        name = place.name
        subtitle = place.subtitle
        latitude = place.coordinate.latitude
        longitude = place.coordinate.longitude
    }

    /// The place, as search pins it on the map.
    var place: SearchPlace? {
        guard isPlace else { return nil }
        return SearchPlace(name: name, subtitle: subtitle, coordinate: coordinate)
    }
}

/// A way to make a trip: one train, or a few with changes between them.
struct Journey: Identifiable, Hashable, Sendable {
    /// One train of it.
    struct Leg: Hashable, Sendable {
        let tripNumber: String
        /// The line, as riders know it.
        let lineCode: String
        /// The service day it runs on (yyyyMMdd).
        let serviceDay: String
        /// The train's whole run: its stops, and when it leaves each (at the last,
        /// when it gets in).
        let stops: [String]
        let times: [Date]
        /// Where you get on and off, in `stops`.
        let board: Int
        let alight: Int

        var boardCode: String { stops[board] }
        var alightCode: String { stops[alight] }
        var departure: Date { times[board] }
        var arrival: Date { times[alight] }
        /// The stops it makes between where you get on and where you get off.
        var stopsBetween: Int { max(0, alight - board - 1) }
        var terminusCode: String { stops[stops.count - 1] }
    }

    let legs: [Leg]
    /// The station it ends at, and the walk or ride from there to where you're
    /// going (a place; none for a station).
    let endStation: String
    let onwardMinutes: Int
    let onwardOnFoot: Bool

    var id: String {
        legs.map { "\($0.serviceDay)-\($0.tripNumber)-\($0.board)-\($0.alight)" }.joined(separator: "+")
    }

    var departure: Date { legs[0].departure }
    var arrival: Date { legs[legs.count - 1].arrival }
    /// When you'd be where you're going, after the walk or ride from the station.
    var arrivalThere: Date { arrival.addingTimeInterval(TimeInterval(onwardMinutes * 60)) }
    var changes: Int { legs.count - 1 }
    var originCode: String { legs[0].boardCode }
    /// Where you change trains, in order.
    var changeCodes: [String] { legs.dropLast().map(\.alightCode) }
    /// Every station it calls at that you're on the train for.
    var stationCodes: [String] {
        legs.flatMap { $0.stops[$0.board...$0.alight] }
    }
}

/// A planned trip: where from, how you'd get there, and the day's trains.
struct TripPlan: Sendable {
    /// Getting from where you are to the first station.
    struct Start: Sendable, Equatable {
        let station: String
        let minutes: Int
        let onFoot: Bool
    }

    /// How the station it starts from was picked.
    enum Origin: Sendable, Equatable {
        /// The one you'd get there soonest from, from where you are.
        case fastest
        /// Picked by hand.
        case chosen
        /// Without your location: home, work or Union.
        case saved
    }

    let destination: PlanDestination
    /// The station the trips start from (nil: none could be picked).
    let origin: String?
    let originKind: Origin
    /// Getting to `origin` from where you are, when that's known.
    let start: Start?
    /// The day's trips (today's from now on), by when they leave.
    let journeys: [Journey]
    /// The service day (yyyyMMdd), and whether it's today.
    let day: String
    let isToday: Bool
    /// Today, near enough to set off now: the trip you'd make in time, when it
    /// leaves soon enough to track.
    let recommended: Journey?
    /// When you could be at `origin`, setting off now.
    let readyAt: Date?
    /// You're there already (or a short walk away).
    let isThere: Bool
    /// The station it goes to is the nearest one to where you are: you'd go
    /// straight there, not by train from another.
    let isNearest: Bool
    /// No timetable to plan with.
    let noTimetable: Bool
}

/// Plans trips from search with `CommutePlanner`: from the station you'd get
/// there soonest from (or one you pick), to a station or the best station near a
/// place, the whole day's trains with their changes.
@MainActor
enum TripPlanner {
    /// Getting to the first station within this many minutes, you're near enough
    /// for the soonest trip you can make to be one you'd take now.
    static let reach = 60
    /// How long before it leaves a trip can be tracked (as a train can be, see
    /// `TripSheet.trackAhead`).
    static let trackAhead: TimeInterval = 4 * 3600
    /// A trip to a place ends at a station within a 15-minute walk of it, or
    /// otherwise at one of the closest few.
    static let placeStations = 3

    private static var cached: (generated: String, planner: CommutePlanner)?

    /// The planner on the timetable in use, set up once per timetable.
    private static func planner() async -> CommutePlanner? {
        guard let timetable = await ScheduleStore.shared.commuteTimetable() else { return nil }
        if let saved = cached, saved.generated == timetable.generated { return saved.planner }
        let network = StartupStation.network
        let planner = await Task.detached(priority: .userInitiated) {
            CommutePlanner(network: network, timetable: timetable)
        }.value
        cached = (timetable.generated, planner)
        return planner
    }

    /// Plans a trip to `destination`: from `origin`, or with none the station you'd
    /// get there soonest from where you are (`location`); on `day` (midnight), or
    /// with none today from `now`. `after`: today, you get to `origin` on another
    /// train then (one whose connection is cancelled), so its trains from then on,
    /// with time to change.
    static func plan(to destination: PlanDestination, from origin: String?, on day: Date?,
                     location: CLLocation?, home: String?, work: String?, now: Date,
                     after: Date? = nil) async -> TripPlan {
        let targets = Self.targets(for: destination)
        let targetCodes = Set(targets.map(\.station))
        let todayKey = CommutePlanner.Clock.at(now)?.day ?? TorontoTime.dateWire(now)
        let dayKey = day.map(TorontoTime.dateWire).flatMap { $0 > todayKey ? $0 : nil } ?? todayKey
        let isToday = dayKey == todayKey
        // From where you change (`after`: once you get there, on the train before):
        // trains leaving once there's time to change, and no getting there from here.
        let arriving: Int? = isToday && origin != nil ? after.flatMap { after in
            CommutePlanner.Clock.start(of: dayKey).map { Int((after.timeIntervalSince($0) / 60).rounded(.up)) }
        } : nil
        let user: CommutePlanner.Point? = location.flatMap { location in
            guard RailNetwork.isInServiceArea(location.coordinate) else { return nil }
            return CommutePlanner.Point(latitude: location.coordinate.latitude,
                                        longitude: location.coordinate.longitude)
        }
        // Within a short walk of where you're going: you're there.
        let isThere = origin == nil && user.map { user in
            let there = CommutePlanner.Point(latitude: destination.latitude, longitude: destination.longitude)
            return CommutePlanner.distance(user, there) <= CommutePlanner.walkRadius
        } == true
        let saved = [home, work, "UN"].compactMap { $0 }
            .first { !targetCodes.contains($0) && RailNetwork.shared.station($0) != nil }

        var isNearest = false
        func empty(origin: String?, kind: TripPlan.Origin, noTimetable: Bool = false) -> TripPlan {
            TripPlan(destination: destination, origin: origin, originKind: kind, start: nil, journeys: [],
                     day: dayKey, isToday: isToday, recommended: nil, readyAt: nil, isThere: isThere,
                     isNearest: isNearest, noTimetable: noTimetable)
        }
        guard let planner = await Self.planner() else {
            return empty(origin: origin ?? saved, kind: .saved, noTimetable: true)
        }
        if isThere { return empty(origin: nil, kind: .fastest) }
        if let station = destination.station, let user {
            isNearest = planner.accessOptions(from: user).first?.station == station
        }

        let reach = Self.reach
        // Today: round the trains GO says are cancelled, or won't stop where you'd get on or off.
        let cancelled = isToday ? await CancelledTrains.shared.list(maxAge: 60) : nil
        let result = await Task.detached(priority: .userInitiated) {
            () -> (origin: String?, kind: TripPlan.Origin, start: CommutePlanner.Access?,
                   itineraries: [CommutePlanner.Itinerary], view: CommutePlanner.View, nowMinute: Int)? in
            // The whole day's trips, from now on today; the start picked as at 08:00
            // on another day.
            guard let clock = isToday ? CommutePlanner.Clock.at(now) : CommutePlanner.Clock.on(day: dayKey, minute: 8 * 60)
            else { return nil }
            var view = planner.view(day: dayKey, shifts: clock.shifts)
            if let cancelled { view.close(cancelled) }
            var start: CommutePlanner.Access?
            var picked = origin
            var kind = TripPlan.Origin.chosen
            if let origin {
                start = arriving == nil ? user.flatMap { planner.access(from: $0, to: origin) } : nil
            } else if let user {
                kind = .fastest
                let options = planner.accessOptions(from: user, avoiding: targetCodes)
                if let best = planner.fastest(from: options, to: targets, at: clock.now, in: view) {
                    start = best.access
                } else {
                    start = options.first
                }
                picked = start?.station
            } else {
                kind = .saved
                picked = saved
            }
            guard let first = picked, !targetCodes.contains(first) else {
                return (picked, kind, start, [], view, clock.now)
            }
            let leaving = max(clock.now, arriving.map { $0 + CommutePlanner.minTransfer } ?? clock.now)
            let itineraries = planner.trips(from: first, to: targets, leaving: isToday ? leaving : 4 * 60,
                                            until: 28 * 60, in: view)
            return (first, kind, start, itineraries, view, clock.now)
        }.value
        guard let found = result, let dayStart = CommutePlanner.Clock.start(of: dayKey) else {
            return empty(origin: origin ?? saved, kind: origin == nil ? .saved : .chosen)
        }

        let journeys = found.itineraries.map { Journey($0, in: found.view, dayStart: dayStart) }
        let start = found.start.map {
            TripPlan.Start(station: $0.station, minutes: max(1, Int($0.minutes.rounded(.up))), onFoot: $0.onFoot)
        }
        // Near enough to set off now: the first trip you'd make in time (the list
        // only keeps trips that beat every later one, so it's also the soonest there).
        var recommended: Journey?
        var readyAt: Date?
        if isToday, let start, start.minutes <= reach {
            let ready = found.nowMinute + start.minutes
            readyAt = dayStart.addingTimeInterval(TimeInterval(ready * 60))
            if let index = found.itineraries.firstIndex(where: { $0.departure >= ready }),
               journeys[index].departure.timeIntervalSince(now) <= trackAhead {
                recommended = journeys[index]
            }
        }
        return TripPlan(destination: destination, origin: found.origin, originKind: found.kind, start: start,
                        journeys: journeys, day: dayKey, isToday: isToday, recommended: recommended,
                        readyAt: readyAt, isThere: false, isNearest: isNearest, noTimetable: false)
    }

    /// Where a trip to `destination` can end: the station itself, or for a place
    /// the stations within a 15-minute walk of it, or else the closest few (the
    /// last bit by car or bus, estimated), each with the minutes from it.
    static func targets(for destination: PlanDestination) -> [CommutePlanner.Target] {
        if let station = destination.station { return [CommutePlanner.Target(station: station)] }
        let there = CommutePlanner.Point(latitude: destination.latitude, longitude: destination.longitude)
        var seen: Set<String> = []
        let ranked = RailNetwork.shared.stations
            .filter { seen.insert($0.code).inserted }
            .map { station in
                (code: station.code,
                 metres: CommutePlanner.distance(there, CommutePlanner.Point(latitude: station.latitude,
                                                                            longitude: station.longitude)))
            }
            .sorted { $0.metres < $1.metres }
        let walkable = ranked.filter { $0.metres <= CommutePlanner.walkOptions }
        if !walkable.isEmpty {
            return walkable.map {
                CommutePlanner.Target(station: $0.code, minutes: CommutePlanner.walkMinutes($0.metres), onFoot: true)
            }
        }
        return ranked.prefix(placeStations).map {
            CommutePlanner.Target(station: $0.code, minutes: CommutePlanner.driveMinutes($0.metres), onFoot: false)
        }
    }

    // MARK: Tracking a planned trip

    /// A leg's train as a row on the board of the station you get on at.
    static func row(for leg: Journey.Leg) -> BoardRow? {
        let trip = ScheduleStore.RunningTrip(tripNumber: leg.tripNumber, lineCode: leg.lineCode, pattern: leg.stops,
                                             times: leg.times, serviceDay: leg.serviceDay)
        return BoardService.row(for: trip, at: leg.board)
    }

    /// A leg's train's stops and times, from the timetable.
    static func detail(for leg: Journey.Leg) -> TripDetail {
        TripDetail(stops: leg.stops.enumerated().map { index, code in
            TripDetail.Stop(index: index, code: code, time: leg.times[index], expected: nil, platform: nil)
        }, source: .schedule)
    }
}

extension Journey {
    /// A trip the planner found, its times as dates.
    init(_ itinerary: CommutePlanner.Itinerary, in view: CommutePlanner.View, dayStart: Date) {
        legs = itinerary.legs.map { hop in
            let trip = view.trips[hop.trip]
            return Leg(tripNumber: trip.number,
                       lineCode: trip.line,
                       serviceDay: trip.day,
                       stops: trip.stops,
                       times: trip.times.map { dayStart.addingTimeInterval(TimeInterval($0 * 60)) },
                       board: hop.board,
                       alight: hop.alight)
        }
        endStation = itinerary.target.station
        onwardMinutes = itinerary.target.minutes > 0 ? max(1, Int(itinerary.target.minutes.rounded(.up))) : 0
        onwardOnFoot = itinerary.target.onFoot
    }
}

/// "6 min", "1 h", "1 h 12 min".
enum DurationText {
    static func text(minutes: Int) -> String {
        let minutes = max(0, minutes)
        if minutes < 60 { return "\(minutes) min" }
        if minutes % 60 == 0 { return "\(minutes / 60) h" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    static func text(from start: Date, to end: Date) -> String {
        text(minutes: Int((end.timeIntervalSince(start) / 60).rounded()))
    }
}
