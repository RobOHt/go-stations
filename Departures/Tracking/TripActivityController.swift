import ActivityKit
import BackgroundTasks
import Foundation
#if DEBUG
import UIKit
#endif

/// Keeps a Live Activity for the tracked trip: started when you track a train,
/// updated while the app runs (new times, the train reaching each stop), and
/// ended when you stop tracking or the train reaches your stop. In between its
/// countdown and stop strip run on their own, and iOS draws it again when the
/// train reaches the stop it counts down to. (Moving on past more stops than
/// that without the app needs push updates from a server.)
@MainActor
final class TripActivityController {
    static let shared = TripActivityController()

    /// How long the finished trip stays on the Lock Screen after the train gets in,
    /// at most: it goes when tracking ends (see `TrackedTrip.endsAt`).
    static let summaryTime: TimeInterval = 15 * 60
    /// The background refresh that ends the Live Activity when the app isn't
    /// opened after the train gets in (listed in Info.plist).
    nonisolated static let refreshTaskID = "com.robinzhong.Departures.trip"

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
        do {
            _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
        } catch {
            // Live Activities are off for the app, or too many are running: tracking
            // carries on in the app without one.
        }
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
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
                continue
            }
            if trip.phase(at: now) == .arrived {
                let summary = (trip.arrival ?? now).addingTimeInterval(Self.summaryTime)
                let gone = min(trip.endsAt ?? summary, summary)
                Task { await activity.end(content, dismissalPolicy: .after(gone)) }
            } else if activity.content.state != content.state || activity.content.staleDate != content.staleDate {
                Task { await activity.update(content) }
            }
        }
    }

    /// Ends every one at once (you stopped tracking, or tracked another train).
    func endAll() {
        for activity in activities {
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
