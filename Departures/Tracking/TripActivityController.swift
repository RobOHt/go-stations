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
            guard let trip, activity.attributes.tripID == trip.row.id,
                  let content = Self.content(for: trip, now: now)
            else {
                stopPushes(to: activity)
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
                continue
            }
            if trip.phase(at: now) == .arrived {
                stopPushes(to: activity)
                Task { await activity.end(content, dismissalPolicy: .after(Self.dismissal(of: trip, now: now))) }
                continue
            }
            // (The worker's revision count isn't a change.)
            var state = content.state
            state.revision = activity.content.state.revision
            if activity.content.state != state || activity.content.staleDate != content.staleDate {
                Task { await activity.update(ActivityContent(state: state, staleDate: content.staleDate)) }
                if let token = pushTokens[activity.id] {
                    registerPushes(token, trip: trip, attributes: activity.attributes, now: now)
                }
            }
            // After a relaunch: pick its push token up again.
            watchPushToken(of: activity)
        }
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
    /// end the Live Activity there if the app hasn't been opened by then. (iOS
    /// picks the moment; it may be a while later, or not at all.)
    func scheduleRefresh(for trip: TrackedTrip) {
        guard let arrival = trip.arrival else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = arrival.addingTimeInterval(60)
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
                if let trip = TripTracker.shared.trip, activity.attributes.tripID == trip.row.id {
                    self.registerPushes(token, trip: trip, attributes: activity.attributes, now: Date())
                }
            }
        }
    }

    /// Tells the worker what the activity shows and when to push it an update: as
    /// the train reaches each stop on the way to yours, and once it's there, the
    /// end (which stays on the Lock Screen until `dismissal(of:now:)`).
    private func registerPushes(_ token: Data, trip: TrackedTrip, attributes: TripActivityAttributes, now: Date) {
        guard let content = Self.content(for: trip, now: now) else { return }
        let schedule = TripActivityTrip(attributes, content.state)
        guard let end = schedule.arrival(at: schedule.destination), end > now else { return }
        let times = (0..<schedule.destination).compactMap { schedule.arrival(at: $0) }.filter { $0 > now && $0 < end }
        let job = TripActivityPush.Job(
            token: TripActivityPush.hex(token),
            environment: TripActivityPush.environment,
            state: content.state,
            times: times.map(TripActivityTime.number),
            end: TripActivityTime.number(end),
            dismissal: TripActivityTime.number(Self.dismissal(of: trip, now: now))
        )
        Task { await TripActivityPush.send(job) }
    }

    private func stopPushes(to activity: Activity<TripActivityAttributes>) {
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
            tripID: trip.row.id,
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

    /// The times, delay and platform as of `now`, and every stop with its time,
    /// so the Live Activity can show where the train is whenever it's drawn. Goes
    /// stale when the train reaches the stop its countdown runs to, so iOS draws
    /// it again then (with the next one) even if the app isn't running.
    static func content(for trip: TrackedTrip, now: Date) -> ActivityContent<TripActivityAttributes.ContentState>? {
        guard let departure = trip.departure, let due = trip.arrival, let attributes = attributes(for: trip) else {
            return nil
        }
        let arrival = max(due, departure.addingTimeInterval(60))
        let hasDeparted = now >= departure
        let next = trip.stops[hasDeparted ? trip.destinationIndex : trip.boardingIndex]
        var minutesLate: Int?
        if trip.source == .live, let time = next.time, let expected = next.expected {
            minutesLate = max(0, Int((expected.timeIntervalSince(time) / 60).rounded()))
        }
        let network = RailNetwork.shared
        let state = TripActivityAttributes.ContentState(
            departure: departure,
            arrival: arrival,
            hasDeparted: hasDeparted,
            minutesLate: minutesLate,
            platform: trip.stops[trip.boardingIndex].platform ?? trip.row.platform,
            stops: trip.stops.map { stop in
                TripActivityAttributes.Stop(name: shortName(network.station(stop.code)?.name ?? stop.code),
                                            time: stop.expected ?? stop.time)
            },
            boardingIndex: trip.boardingIndex,
            destinationIndex: trip.destinationIndex,
            awaitsTrain: trip.hasStartingStop
        )
        let target = TripActivityTrip(attributes, state).moment(at: now).target
        return ActivityContent(state: state, staleDate: target.flatMap { $0 > now ? $0 : nil })
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
    }

    /// Which of Apple's push servers the app's tokens belong to.
    #if DEBUG
    static let environment = "development"
    #else
    static let environment = "production"
    #endif

    static func send(_ job: Job) async {
        await post("/activity", body: job)
    }

    static func forget(_ token: Data) async {
        await post("/activity/end", body: ["token": hex(token)])
    }

    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    private static func post<Body: Encodable>(_ path: String, body: Body) async {
        guard let url = URL(string: ProxyConfig.baseURL + path), let data = try? JSONEncoder().encode(body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = 15
        _ = try? await URLSession.shared.data(for: request)
    }
}
