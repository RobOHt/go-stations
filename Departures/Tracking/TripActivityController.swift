import ActivityKit
import BackgroundTasks
import Foundation
#if DEBUG
import UIKit
#endif

/// Keeps a Live Activity for the tracked trip: started when you track a train,
/// updated while the app runs (new times, the train reaching each stop), and
/// ended when you stop tracking or the train reaches your stop. In between its
/// countdown and stop strip run on their own, iOS draws it again when the train
/// reaches the stop it counts down to, and the worker pushes it an update at every
/// stop after that (TripActivityPush), so it keeps up while the app isn't running.
@MainActor
final class TripActivityController {
    static let shared = TripActivityController()

    /// How long the finished trip stays on the Lock Screen after the train gets in,
    /// at most: it goes when tracking ends (see `TrackedTrip.endsAt`).
    static let summaryTime: TimeInterval = 15 * 60
    /// The background refresh that ends the Live Activity when the app isn't
    /// opened after the train gets in (listed in Info.plist).
    nonisolated static let refreshTaskID = "com.robinzhong.Departures.trip"

    /// Each running activity's push token, by activity, once iOS hands it over.
    private var pushTokens: [String: Data] = [:]
    private var tokenWatchers: [String: Task<Void, Never>] = [:]
    /// What the worker was last told for each activity, so it's told only what's new.
    private var registered: [String: String] = [:]
    /// The activities the worker took on: it follows their trains (and says when
    /// one is cancelled).
    private var followed: Set<String> = []

    private init() {}

    private var activities: [Activity<TripActivityAttributes>] {
        Activity<TripActivityAttributes>.activities
    }

    /// Starts one for a newly tracked train, replacing any earlier one.
    func start(_ trip: TrackedTrip, now: Date = Date()) {
        endAll()
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              let attributes = Self.attributes(for: trip),
              let content = Self.content(for: trip, now: now)
        else { return }
        // With a push token for the worker's updates when the app can have one (it
        // can't before push is set up), otherwise without. If neither works, Live
        // Activities are off for the app or too many are running: tracking carries
        // on in the app without one.
        let activity = (try? Activity.request(attributes: attributes, content: content, pushType: .token))
            ?? (try? Activity.request(attributes: attributes, content: content, pushType: nil))
        if let activity { watchPushToken(of: activity) }
        scheduleRefresh(for: trip)
    }

    /// Brings the Live Activity in line with the tracked trip: new times, the
    /// train leaving your station, or, once it's in, its final state (which stays
    /// on the Lock Screen a while). Without a tracked trip, ends any still running.
    func sync(_ trip: TrackedTrip?, now: Date = Date()) {
        for activity in activities where activity.activityState == .active || activity.activityState == .stale {
            // (On a trip with changes, the first train's activity goes on with the next.)
            guard let trip, activity.attributes.tripID == trip.activityID,
                  let content = Self.content(for: trip, now: now)
            else {
                stopPushes(to: activity)
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
                continue
            }
            if trip.phase(at: now) == .arrived, !trip.hasOnward {
                stopPushes(to: activity)
                Task { await activity.end(content, dismissalPolicy: .after(Self.dismissal(of: trip, now: now))) }
                continue
            }
            // (The worker's revision count isn't a change.)
            var state = content.state
            state.revision = activity.content.state.revision
            if activity.content.state != state || activity.content.staleDate != content.staleDate {
                Task { await activity.update(ActivityContent(state: state, staleDate: content.staleDate)) }
            }
            // The worker's told whatever's new (times, a change of train, alerts on or off).
            if let token = pushTokens[activity.id] {
                registerPushes(token, trip: trip, attributes: activity.attributes, now: now, activityID: activity.id)
            }
            // After a relaunch: pick its push token up again.
            watchPushToken(of: activity)
        }
    }

    /// Whether the worker follows the trip's Live Activity: it then says when the
    /// train is cancelled, with the activity.
    func workerFollows(_ trip: TrackedTrip) -> Bool {
        activities.contains { activity in
            activity.attributes.tripID == trip.activityID && followed.contains(activity.id)
                && (activity.activityState == .active || activity.activityState == .stale)
        }
    }

    /// Whether the trip's Live Activity says its train is cancelled (as the worker
    /// pushed it, when the app didn't know).
    func showsCancelled(_ trip: TrackedTrip) -> Bool {
        activities.contains { $0.attributes.tripID == trip.activityID && $0.content.state.cancelled != nil }
    }

    /// Ends every one at once (you stopped tracking, or tracked another train).
    func endAll() {
        for activity in activities {
            stopPushes(to: activity)
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskID)
    }

    /// Asks iOS to wake the app a little after the train is due at your stop, to
    /// end the Live Activity there if the app hasn't been opened by then (and on a
    /// trip from search, first a little after the first train leaves). (iOS picks
    /// the moment; it may be a while later, or not at all.)
    func scheduleRefresh(for trip: TrackedTrip, now: Date = Date()) {
        guard let arrival = trip.arrival else { return }
        var earliest = arrival.addingTimeInterval(60)
        // A trip from search: first, a few minutes after its first train leaves,
        // whether it left without you (TripTracker.checkMissed).
        if trip.journeyKey != nil, (trip.legIndex ?? 0) == 0, let departure = trip.departure {
            let check = departure.addingTimeInterval(TrackedTrip.missedAfter + 60)
            if check > now { earliest = min(earliest, check) }
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = earliest
        try? BGTaskScheduler.shared.submit(request)
    }

    /// When the finished trip leaves the Lock Screen.
    private static func dismissal(of trip: TrackedTrip, now: Date) -> Date {
        let summary = (trip.arrival ?? now).addingTimeInterval(summaryTime)
        return min(trip.endsAt ?? summary, summary)
    }

    // MARK: Push updates

    /// Hands the activity's push token to the worker whenever iOS issues one.
    private func watchPushToken(of activity: Activity<TripActivityAttributes>) {
        guard tokenWatchers[activity.id] == nil else { return }
        tokenWatchers[activity.id] = Task { [weak self] in
            for await token in activity.pushTokenUpdates {
                guard let self else { return }
                self.pushTokens[activity.id] = token
                if let trip = TripTracker.shared.trip, activity.attributes.tripID == trip.activityID {
                    self.registerPushes(token, trip: trip, attributes: activity.attributes, now: Date(),
                                        activityID: activity.id)
                }
            }
        }
    }

    /// Tells the worker what the activity shows and when to push it an update: as
    /// the train reaches each stop on the way to yours and as it leaves it, and once
    /// it's at yours, the end (which stays on the Lock Screen until `dismissal(of:now:)`).
    /// With the trip's stops and train, it follows the train itself while it runs,
    /// and pushes when it pulls in at a stop or leaves one. Only when something in
    /// that has changed since the worker was last told.
    private func registerPushes(_ token: Data, trip: TrackedTrip, attributes: TripActivityAttributes, now: Date,
                                activityID: String) {
        // This train, then on a trip with changes each one after it, as it'll be
        // once you've changed to it.
        let schedules = trip.legsFromHere().compactMap { Self.schedule(for: $0, attributes: attributes, now: now) }
        guard let first = schedules.first, first.trip.tripNumber == trip.tripNumber else { return }
        let alerts = TripAlerts.shared.isOn(for: trip)
        // The app's own token, to wake it: on the first train of a trip from search,
        // to check you're on it; and when the train is cancelled, to find the next.
        let device = TripActivityPush.deviceToken
        let missedCheck = trip.journeyKey != nil && (trip.legIndex ?? 0) == 0 && device != nil
        let job = TripActivityPush.Job(
            token: TripActivityPush.hex(token),
            environment: TripActivityPush.environment,
            state: first.leg.state,
            times: first.leg.times,
            end: first.leg.end,
            dismissal: first.leg.dismissal,
            live: first.leg.live,
            alerts: alerts,
            quiet: trip.alerts == false,
            told: trip.cancelled?.told == true,
            legs: schedules.dropFirst().map { $0.leg },
            device: device,
            missedCheck: missedCheck
        )
        // To the minute: the worker follows the train itself in between. (With
        // whether it's cancelled, and the next train, as the activity shows them.)
        func minute(_ number: Double) -> Int { Int(number / 60) }
        let cancelled = first.leg.state.cancelled.map { shown -> String in
            let next = shown.next.map { minute($0.timeIntervalSince1970) } ?? 0
            return "\(shown.index ?? -1)@\(next)"
        }
        let key = ([job.token, "\(alerts)", "\(job.quiet)", "\(job.told)", job.device ?? "-", cancelled ?? "-"]
                   + schedules.flatMap { schedule -> [String] in
            let leg = schedule.leg
            return [schedule.trip.tripNumber, "\(schedule.trip.boardingIndex)-\(schedule.trip.destinationIndex)",
                    schedule.trip.stopCodes.joined()]
                + (leg.times + [leg.end, leg.dismissal]).map { "\(minute($0))" }
        }).joined(separator: "|")
        guard registered[activityID] != key else { return }
        registered[activityID] = key
        let journey = trip.activityID
        Task {
            let accepted = await TripActivityPush.send(job)
            if accepted { followed.insert(activityID) }
            // The worker sends the change and arrival alerts with the Live Activity.
            if accepted, alerts { TripAlerts.shared.workerSendsAlerts(for: journey) }
        }
    }

    /// What the worker is told about one train of a trip: what the activity shows
    /// for it, when to push it updates (as the train reaches each stop on the way to
    /// yours and leaves it), when it's over (at your stop, which stays on the Lock
    /// Screen until `dismissal(of:now:)`; on a trip with changes, where the next
    /// train takes over), and its train and stops, for the worker to follow it.
    private static func schedule(for trip: TrackedTrip, attributes: TripActivityAttributes,
                                 now: Date) -> (trip: TrackedTrip, leg: TripActivityPush.Leg)? {
        guard let content = content(for: trip, now: now, followingLive: false) else { return nil }
        let schedule = TripActivityTrip(attributes.current(content.state), content.state)
        guard let end = schedule.arrival(at: schedule.destination), end > now else { return nil }
        var moments: Set<Date> = []
        for index in 0..<schedule.destination {
            if let arrives = schedule.arrival(at: index) { moments.insert(arrives) }
            if let leaves = schedule.stops[index].time { moments.insert(leaves) }
        }
        let times = moments.filter { $0 > now && $0 < end }.sorted()
        let leg = TripActivityPush.Leg(
            state: content.state,
            times: times.map(TripActivityTime.number),
            end: TripActivityTime.number(end),
            dismissal: TripActivityTime.number(dismissal(of: trip, now: now)),
            live: TripActivityPush.Live(trip: trip.tripNumber, codes: trip.stopCodes,
                                        scheduled: trip.stops.map { $0.time.map(TripActivityTime.number) })
        )
        return (trip, leg)
    }

    private func stopPushes(to activity: Activity<TripActivityAttributes>) {
        registered[activity.id] = nil
        followed.remove(activity.id)
        tokenWatchers.removeValue(forKey: activity.id)?.cancel()
        if let token = pushTokens.removeValue(forKey: activity.id) {
            Task { await TripActivityPush.forget(token) }
        }
    }

    // MARK: What it shows

    static func attributes(for trip: TrackedTrip) -> TripActivityAttributes? {
        let network = RailNetwork.shared
        guard let line = network.line(code: trip.lineCode), let last = trip.stops.last else { return nil }
        func name(_ code: String) -> String { network.station(code)?.name ?? code }
        var direction: String?
        if let first = trip.stops.first.flatMap({ network.station($0.code) }), let end = network.station(last.code) {
            direction = TravelDirection.of(lineCode: line.code, from: first, to: end, network: network)?.label.lowercased()
        }
        return TripActivityAttributes(
            tripID: trip.activityID,
            tripNumber: trip.tripNumber,
            lineCode: line.code,
            lineColorHex: line.hex,
            boardingName: name(trip.boardingCode),
            destinationName: name(trip.destinationCode),
            terminusName: name(last.code),
            trackedAt: trip.startedAt,
            lineName: line.name,
            direction: direction,
            boardingTime: trip.stops[trip.boardingIndex].time ?? trip.row.scheduled
        )
    }

    /// The times, delay and platform as of `now`, and every stop with its times,
    /// so the Live Activity can show where the train is whenever it's drawn. Goes
    /// stale when the train reaches the stop its countdown runs to, so iOS draws
    /// it again then (with the next one) even if the app isn't running. Following
    /// the train's live reports (see `stopTimes(for:now:)`) unless told not to.
    static func content(for trip: TrackedTrip, now: Date,
                        followingLive: Bool = true) -> ActivityContent<TripActivityAttributes.ContentState>? {
        guard let attributes = attributes(for: trip) else { return nil }
        let seen: (times: [Date?], arrivals: [Date?]) = followingLive
            ? stopTimes(for: trip, now: now)
            : (times: trip.stops.map { $0.departed ?? $0.expected ?? $0.time }, arrivals: trip.stops.map(\.arrived))
        let times = seen.times
        let arrivals = seen.arrivals
        guard let departure = times[trip.boardingIndex] ?? trip.departure,
              let due = arrivals[trip.destinationIndex] ?? times[trip.destinationIndex] ?? trip.arrival
        else { return nil }
        let arrival = max(due, departure.addingTimeInterval(60))
        let hasDeparted = now >= departure || (trip.live?.index ?? 0) > trip.boardingIndex
        let next = trip.stops[hasDeparted ? trip.destinationIndex : trip.boardingIndex]
        var minutesLate: Int?
        if let delay = trip.liveDelay, trip.live?.isFresh(at: now) == true {
            minutesLate = max(0, Int((delay / 60).rounded()))
        } else if trip.source == .live, let time = next.time, let expected = next.expected {
            minutesLate = max(0, Int((expected.timeIntervalSince(time) / 60).rounded()))
        }
        let network = RailNetwork.shared
        let state = TripActivityAttributes.ContentState(
            departure: departure,
            arrival: arrival,
            hasDeparted: hasDeparted,
            minutesLate: minutesLate,
            platform: trip.stops[trip.boardingIndex].platform ?? trip.row.platform,
            stops: trip.stops.enumerated().map { index, stop in
                TripActivityAttributes.Stop(name: shortName(network.station(stop.code)?.name ?? stop.code),
                                            time: times[index], arrives: arrivals[index])
            },
            boardingIndex: trip.boardingIndex,
            destinationIndex: trip.destinationIndex,
            awaitsTrain: trip.hasStartingStop,
            leg: trip.journeyID == nil ? nil : leg(for: attributes, since: trip.legStartedAt),
            change: change(after: trip),
            cancelled: cancellation(of: trip)
        )
        // (Cancelled, it doesn't change until it ends.)
        if state.cancelled != nil { return ActivityContent(state: state, staleDate: trip.endsAt) }
        let target = TripActivityTrip(attributes, state).moment(at: now).target
        return ActivityContent(state: state, staleDate: target.flatMap { $0 > now ? $0 : nil })
    }

    /// A cancelled train, as its activity shows it: where it won't stop, and the
    /// next train from your station once the app has found it.
    static func cancellation(of trip: TrackedTrip) -> TripActivityAttributes.Cancellation? {
        guard let cancelled = trip.cancelled else { return nil }
        let index = trip.cancelledIndex
        let station = index.flatMap { RailNetwork.shared.station(trip.stops[$0].code)?.name }
        return TripActivityAttributes.Cancellation(index: index, station: station.map(shortName),
                                                   next: cancelled.next?.scheduled)
    }

    /// A train changed to, on a trip with changes: what the activity (started for
    /// the first train) shows in place of its own attributes.
    private static func leg(for attributes: TripActivityAttributes, since: Date?) -> TripActivityAttributes.Leg {
        TripActivityAttributes.Leg(tripNumber: attributes.tripNumber, lineCode: attributes.lineCode,
                                   lineColorHex: attributes.lineColorHex, lineName: attributes.lineName,
                                   direction: attributes.direction, boardingName: attributes.boardingName,
                                   destinationName: attributes.destinationName, terminusName: attributes.terminusName,
                                   boardingTime: attributes.boardingTime, since: since)
    }

    /// Where you change after this train, and the train you change to.
    static func change(after trip: TrackedTrip) -> TripActivityAttributes.Change? {
        guard let next = trip.onward?.first else { return nil }
        let network = RailNetwork.shared
        let line = network.line(code: next.row.lineCode)
        let codes = next.stops.map(\.code)
        let departure = codes.firstIndex(of: next.boardingCode).flatMap { next.stops[$0].expected ?? next.stops[$0].time }
        func name(_ code: String) -> String { shortName(network.station(code)?.name ?? code) }
        return TripActivityAttributes.Change(
            station: name(trip.destinationCode),
            lineCode: line?.code ?? next.row.lineCode,
            lineColorHex: line?.hex ?? "888888",
            lineName: line?.name,
            departure: departure ?? next.row.scheduled,
            terminusName: name(codes.last ?? next.destinationCode),
            destinationName: name(next.destinationCode)
        )
    }

    /// Each stop's times for the Live Activity: when the train leaves it and,
    /// where known, pulls in, from what tracking has seen and its live times. With
    /// a fresh live report, a train standing at a station is taken to stay a little
    /// longer than its time says (until the next report, or iOS draws it as gone),
    /// and one late for its next stop is due there any moment; the stops after
    /// are as late. (The worker does the same in its push updates.)
    static func stopTimes(for trip: TrackedTrip, now: Date) -> (times: [Date?], arrivals: [Date?]) {
        var times = trip.stops.map { $0.departed ?? $0.expected ?? $0.time }
        var arrivals = trip.stops.map(\.arrived)
        guard let fix = trip.live, fix.isFresh(at: now), times.indices.contains(fix.index) else { return (times, arrivals) }
        let k = fix.index
        // Behind it: gone by when it was seen.
        for index in 0..<k {
            if let time = times[index], time > fix.time { times[index] = fix.time }
            if let time = arrivals[index], time > fix.time { arrivals[index] = fix.time }
        }
        func delay(from index: Int, by seconds: TimeInterval) {
            guard seconds > 0 else { return }
            for later in index..<times.count {
                times[later] = times[later]?.addingTimeInterval(seconds)
                if later > index { arrivals[later] = arrivals[later]?.addingTimeInterval(seconds) }
            }
        }
        if fix.isAt {
            guard k < times.count - 1 else { return (times, arrivals) }
            let hold = max(fix.time.addingTimeInterval(60), now.addingTimeInterval(15))
            if let leaves = times[k], leaves < hold { delay(from: k, by: hold.timeIntervalSince(leaves)) }
        } else if k > 0, arrivals[k] == nil, let due = TrainState.arrival(at: k, times: times),
                  due < now.addingTimeInterval(10) {
            let comes = max(fix.time.addingTimeInterval(50), now.addingTimeInterval(15))
            delay(from: k, by: comes.timeIntervalSince(due))
            arrivals[k] = comes
        }
        return (times, arrivals)
    }

    /// Station names short enough for the stop strip.
    static func shortName(_ name: String) -> String {
        let short = [
            "Union Station": "Union",
            "Brampton Innovation District": "Brampton",
            "Durham College Oshawa": "Durham College",
            "Hamilton GO Centre": "Hamilton",
            "Allandale Waterfront": "Allandale",
            "Guelph Central": "Guelph",
        ]
        return short[name] ?? name
    }

    #if DEBUG
    /// For the simulator screenshots: a few seconds after the app goes to the
    /// background, update the Live Activity with an alert, which shows the
    /// expanded island for a moment.
    func alertForScreenshot() {
        let task = UIApplication.shared.beginBackgroundTask()
        Task {
            try? await Task.sleep(for: .seconds(4))
            if let activity = activities.first {
                let alert = AlertConfiguration(title: "Your train", body: "Tracking it", sound: .default)
                await activity.update(activity.content, alertConfiguration: alert)
            }
            UIApplication.shared.endBackgroundTask(task)
        }
    }
    #endif
}

/// The worker's push updates for the Live Activity (worker/src/index.js). It gets
/// the activity's push token, what the activity shows, and when the train reaches
/// each stop; at each of those times Apple's push service hands the activity an
/// update, so iOS draws it again with the next stop while the app isn't running.
/// The worker forgets it all once the trip's over. Best effort: without it the
/// activity still moves on once by itself, and whenever the app runs.
enum TripActivityPush {
    struct Job: Encodable {
        let token: String
        let environment: String
        let state: TripActivityAttributes.ContentState
        /// When to push an update, in seconds since 1970.
        let times: [Double]
        /// When to end the activity, and when it then leaves the Lock Screen.
        let end: Double
        let dismissal: Double
        /// The trip's train and stops, for the worker to follow it live.
        let live: Live?
        /// Alert 5 minutes before the train gets to where you change or get off.
        let alerts: Bool
        /// You asked not to be notified about this trip: not even when its train
        /// is cancelled (the Live Activity still says so).
        let quiet: Bool
        /// The app has told you the train is cancelled: the worker needn't.
        let told: Bool
        /// On a trip with changes, the trains after this one: the same for each.
        let legs: [Leg]
        /// The app's own push token: on the first train of a trip from search
        /// (`missedCheck`), the worker wakes the app with it a couple of minutes
        /// after the train leaves where you get on, to check you're on it (#16);
        /// and when the train is found cancelled, for the app to find the next one.
        let device: String?
        let missedCheck: Bool
    }

    /// One train of a trip with changes, for after the one before gets in.
    struct Leg: Encodable {
        let state: TripActivityAttributes.ContentState
        let times: [Double]
        let end: Double
        let dismissal: Double
        let live: Live?
    }

    /// The trip's number, and each of `state.stops`' code and planned departure.
    struct Live: Encodable {
        let trip: String
        let codes: [String]
        let scheduled: [Double?]
    }

    /// Which of Apple's push servers the app's tokens belong to.
    #if DEBUG
    static let environment = "development"
    #else
    static let environment = "production"
    #endif

    /// The app's push token (for the worker to wake it in the background), once
    /// iOS has given one. Kept across launches.
    static var deviceToken: String? {
        get { UserDefaults.standard.string(forKey: "pushDeviceToken") }
        set { UserDefaults.standard.set(newValue, forKey: "pushDeviceToken") }
    }

    /// True when the worker took it on.
    @discardableResult
    static func send(_ job: Job) async -> Bool {
        await post("/activity", body: job)
    }

    static func forget(_ token: Data) async {
        await post("/activity/end", body: ["token": hex(token)])
    }

    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private static func post<Body: Encodable>(_ path: String, body: Body) async -> Bool {
        guard let url = URL(string: ProxyConfig.baseURL + path), let data = try? JSONEncoder().encode(body) else {
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = 15
        guard let result = try? await URLSession.shared.data(for: request) else { return false }
        return (200..<300).contains((result.1 as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
