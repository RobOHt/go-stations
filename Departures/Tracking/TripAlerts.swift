import CoreLocation
import Foundation
import UserNotifications

/// Alerts for the tracked trip, once you've said OK to them (the trip card asks
/// when you track a trip; trains tracked from a board get them once you have):
///
/// - 5 minutes before your train leaves, when you're not at the station yet. It's
///   taken back when you get there: iOS tells the app when you reach the station
///   (with Always location), even when it isn't running.
/// - 5 minutes before the train gets to where you change, and to your stop. The
///   worker sends these with the Live Activity, timed by where the train really
///   is; when it can't (no Live Activity, or no connection to it), they're
///   scheduled here by the times the app has.
///
/// And once its train is found cancelled (or not stopping where you get on or
/// off), unless you asked not to be notified about the trip: from the worker
/// with the Live Activity, or from here when the worker doesn't follow it.
@MainActor
final class TripAlerts: NSObject {
    static let shared = TripAlerts()

    /// How long before the train leaves, or gets to where you change or get off.
    static let lead: TimeInterval = 5 * 60
    /// This close to your station, you're there (no reminder to set off).
    static let nearStation: CLLocationDistance = 400
    /// Getting this close to it, you've got there (the reminder's taken back).
    static let stationRegion: CLLocationDistance = 300

    private static let allowedKey = "tripAlertsAllowed"
    private static let leaveID = "trip.leave"
    private static let missedID = "trip.missed"
    private static let cancelledID = "trip.cancelled"
    private static let legIDs = ["trip.leg.0", "trip.leg.1", "trip.leg.2"]

    private let center = UNUserNotificationCenter.current()
    /// Changes to the pending alerts go to the notification centre in turn, off the
    /// main thread: some of its calls wait on iOS's notification service, which
    /// can take a while (on a freshly started simulator, long enough to freeze the
    /// app at launch).
    private nonisolated static let changes = DispatchQueue(label: "TripAlerts.changes")
    private let manager = CLLocationManager()
    /// What's scheduled, so the same isn't scheduled again on every update.
    private var scheduled: String?
    /// Trips the worker sends the change and arrival alerts for, by Live Activity.
    private var workerSends: Set<String> = []
    /// Trips whose first station you've got to (by Live Activity): no reminder to set off.
    private var atStation: Set<String> = []

    private struct Alert {
        let id: String
        let date: Date
        let title: String
        let body: String
    }

    override private init() {
        super.init()
        manager.delegate = self
    }

    /// At launch: alerts show while the app is open, and getting to the station
    /// (when that's what woke the app) is heard.
    func start() {
        center.delegate = self
    }

    /// You've said OK to alerts before.
    var allowed: Bool { UserDefaults.standard.bool(forKey: Self.allowedKey) }

    func isOn(for trip: TrackedTrip) -> Bool { trip.alerts ?? allowed }

    /// OK to alerts: asks iOS to show them, and for Always location (so the
    /// reminder to set off goes away once you're at the station, app open or not).
    func requestPermission() async {
        UserDefaults.standard.set(true, forKey: Self.allowedKey)
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        let status = manager.authorizationStatus
        if status == .notDetermined || status == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
        scheduled = nil
        update(for: TripTracker.shared.trip)
    }

    /// The worker took the trip on with alerts: it sends the change and arrival
    /// ones (timed by the train), so they aren't scheduled here as well.
    func workerSendsAlerts(for activityID: String) {
        guard workerSends.insert(activityID).inserted else { return }
        scheduled = nil
        update(for: TripTracker.shared.trip)
    }

    /// Schedules the tracked trip's alerts afresh (when anything in them changed),
    /// or clears them when there's no trip or no alerts for it.
    func update(for trip: TrackedTrip?, now: Date = Date()) {
        var alerts: [Alert] = []
        var station: Station?
        if let trip, isOn(for: trip) { (alerts, station) = plan(for: trip, now: now) }
        let key = (alerts.map { "\($0.id)@\(Int($0.date.timeIntervalSince1970 / 60))|\($0.title)" }
                   + [station?.code ?? "-"]).joined(separator: ";")
        guard key != scheduled else { return }
        scheduled = key
        let requests = alerts.map { alert -> UNNotificationRequest in
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, alert.date.timeIntervalSince(now)),
                                                            repeats: false)
            return UNNotificationRequest(identifier: alert.id, content: content, trigger: trigger)
        }
        Self.change(removing: [Self.leaveID] + Self.legIDs, adding: requests)
        watch(station)
    }

    /// Takes back the pending alerts `ids`, then adds `requests` (see `changes`);
    /// `done` once iOS has them.
    private nonisolated static func change(removing ids: [String], adding requests: [UNNotificationRequest] = [],
                                           done: (@Sendable () -> Void)? = nil) {
        changes.async {
            let center = UNUserNotificationCenter.current()
            if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
            let added = DispatchGroup()
            for request in requests {
                added.enter()
                center.add(request) { _ in added.leave() }
            }
            if let done { added.notify(queue: changes) { done() } }
        }
    }

    /// The alerts a trip gets from here, and the station to watch for you getting to.
    private func plan(for trip: TrackedTrip, now: Date) -> ([Alert], Station?) {
        // Cancelled: nothing to set off for, or get off at.
        guard trip.cancelled == nil else { return ([], nil) }
        let network = RailNetwork.shared
        func name(_ code: String) -> String { network.station(code)?.name ?? code }
        var alerts: [Alert] = []
        var watched: Station?

        // Setting off: before the first train (later ones you're on your way to).
        if (trip.legIndex ?? 0) == 0, !atStation.contains(trip.activityID),
           let departure = trip.departure, departure.addingTimeInterval(-Self.lead) > now,
           let station = network.station(trip.boardingCode), !isNear(station) {
            // Which way it goes, as its Live Activity says it.
            let shown = TripActivityController.attributes(for: trip)
            alerts.append(Alert(
                id: Self.leaveID,
                date: departure.addingTimeInterval(-Self.lead),
                title: "Your train leaves in 5 min",
                body: Self.leaveBody(time: departure, line: network.line(code: trip.lineCode)?.name ?? trip.lineCode,
                                     from: station.name, direction: shown?.direction,
                                     terminus: shown?.terminusName)
            ))
            watched = station
        }

        // Changing, and getting off: unless the worker sends them.
        if !workerSends.contains(trip.activityID) {
            for (index, leg) in trip.legsFromHere().prefix(Self.legIDs.count).enumerated() {
                guard let arrival = leg.arrival, arrival.addingTimeInterval(-Self.lead) > now else { continue }
                let stop = name(leg.destinationCode)
                if let change = TripActivityController.change(after: leg) {
                    let line = change.lineName.map { "\($0) line" } ?? "\(change.lineCode) line"
                    alerts.append(Alert(
                        id: Self.legIDs[index],
                        date: arrival.addingTimeInterval(-Self.lead),
                        title: "Change at \(stop) in 5 min",
                        body: "Then the \(TorontoTime.hourMinute(change.departure)) \(line) train to \(change.terminusName)."
                    ))
                } else {
                    alerts.append(Alert(
                        id: Self.legIDs[index],
                        date: arrival.addingTimeInterval(-Self.lead),
                        title: "\(stop) in 5 min",
                        body: "Your stop is coming up. Get ready to get off."
                    ))
                }
            }
        }
        return (alerts, watched)
    }

    /// The reminder to set off: "The 12:06 Lakeshore West line train from
    /// Port Credit, eastbound to Union Station." Which way it goes when that's
    /// known (as its Live Activity has it), and where to when that is.
    static func leaveBody(time: Date, line: String, from station: String, direction: String?,
                          terminus: String?) -> String {
        let train = "The \(TorontoTime.hourMinute(time)) \(line) line train from \(station)"
        // (Not "to" the station it leaves from, at the end of its run.)
        guard let terminus, terminus != station else { return train + "." }
        guard let direction, !direction.isEmpty else { return "\(train) to \(terminus)." }
        return "\(train), \(direction) to \(terminus)."
    }

    /// The first train left without you (see `TripTracker.checkMissed`): "You
    /// missed the 12:06 to Union Station. Open GO Stations to plan another trip
    /// to Danforth." Tapping it opens the trip card there. Only with alerts on
    /// for the trip.
    func missed(_ trip: TrackedTrip) async {
        guard isOn(for: trip) else { return }
        let network = RailNetwork.shared
        let content = UNMutableNotificationContent()
        content.title = Self.missedTitle(time: trip.departure ?? trip.row.scheduled,
                                         terminus: TripActivityController.attributes(for: trip)?.terminusName)
        let destination = network.station(trip.finalDestinationCode)?.name ?? trip.finalDestinationCode
        content.body = "Open GO Stations to plan another trip to \(destination)."
        content.sound = .default
        content.userInfo = [planToKey: trip.finalDestinationCode]
        let request = UNNotificationRequest(identifier: Self.missedID, content: content, trigger: nil)
        // Woken in the background to find this out, the app may not get long after:
        // done once iOS has it.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Self.change(removing: [], adding: [request]) { done.resume() }
        }
    }

    /// The tracked train is cancelled, or not stopping where you get on or off
    /// (`back`: running after all): "Your 07:40 train is cancelled. It won't stop
    /// at Oakville. The next train to Union Station leaves at 08:10." Tapping it
    /// opens your station's board (on a trip from search, the trip card to where
    /// you're going). Not when you asked not to be notified about the trip.
    func cancelled(_ trip: TrackedTrip, back: Bool = false) async {
        guard trip.alerts != false else { return }
        let network = RailNetwork.shared
        let content = UNMutableNotificationContent()
        let text = Self.cancelledText(trip, back: back, network: network)
        content.title = text.title
        content.body = text.body
        content.sound = .default
        if trip.journeyKey != nil {
            content.userInfo = [planToKey: trip.finalDestinationCode]
        } else if !trip.hasLeftBoarding {
            content.userInfo = [boardKey: trip.boardingCode]
        }
        let request = UNNotificationRequest(identifier: Self.cancelledID, content: content, trigger: nil)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Self.change(removing: [], adding: [request]) { done.resume() }
        }
    }

    /// What `cancelled(_:back:)` says.
    static func cancelledText(_ trip: TrackedTrip, back: Bool, network: RailNetwork) -> (title: String, body: String) {
        func name(_ code: String) -> String { network.station(code)?.name ?? code }
        let time = trip.stops.indices.contains(trip.boardingIndex) ? trip.stops[trip.boardingIndex].time : nil
        let train = "Your \(TorontoTime.hourMinute(time ?? trip.row.scheduled)) train"
        if back { return ("\(train) is running after all", "It's no longer listed as cancelled.") }
        var title = "\(train) is cancelled"
        var body: [String] = []
        if let code = trip.cancelled?.code {
            if code == trip.boardingCode, !trip.hasLeftBoarding {
                body.append("It won't stop at \(name(code)).")
            } else {
                title = "\(train) won't stop at \(name(code))"
            }
        }
        if let next = trip.cancelled?.next {
            body.append("The next train to \(name(trip.destinationCode)) leaves at \(TorontoTime.hourMinute(next.scheduled)).")
        } else if trip.journeyKey != nil {
            body.append("Open GO Stations to plan another trip to \(name(trip.finalDestinationCode)).")
        } else {
            body.append("Open GO Stations to find another train.")
        }
        return (title, body.joined(separator: " "))
    }

    /// "You missed the 12:06 to Union Station", or without where it goes.
    static func missedTitle(time: Date, terminus: String?) -> String {
        let train = "You missed the \(TorontoTime.hourMinute(time))"
        return terminus.map { "\(train) to \($0)" } ?? "\(train) train"
    }

    /// You're at (or by) the station now, as far as the last fix says.
    private func isNear(_ station: Station) -> Bool {
        var location = manager.location
        #if DEBUG
        if let fixed = DebugScene.fixedLocation { location = fixed }
        #endif
        guard let location, -location.timestamp.timeIntervalSinceNow < 10 * 60 else { return false }
        return location.distance(from: station.location) <= Self.nearStation
    }

    // MARK: Getting to the station

    /// Watches for you getting to `station` (none: stops watching). Only with
    /// Always location: iOS then tells the app even when it isn't running.
    private func watch(_ station: Station?) {
        for region in manager.monitoredRegions where region.identifier == boardingRegionID {
            manager.stopMonitoring(for: region)
        }
        guard let station, manager.authorizationStatus == .authorizedAlways,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let region = CLCircularRegion(center: station.coordinate, radius: Self.stationRegion,
                                      identifier: boardingRegionID)
        region.notifyOnEntry = true
        region.notifyOnExit = false
        manager.startMonitoring(for: region)
    }

    /// At the station: no reminder to set off.
    private func reachedStation() {
        guard let trip = TripTracker.shared.trip else { return }
        atStation.insert(trip.activityID)
        Self.change(removing: [Self.leaveID])
        scheduled = nil
        update(for: trip)
    }
}

/// The region around the station you're setting off from.
private let boardingRegionID = "trip.boarding"
/// In a notification: the station to plan another trip to, when it's tapped.
private let planToKey = "planTo"
/// In a notification: the station whose board to open, when it's tapped.
private let boardKey = "board"

extension TripAlerts: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier == boardingRegionID else { return }
        Task { @MainActor in self.reachedStation() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState,
                                     for region: CLRegion) {
        guard state == .inside, region.identifier == boardingRegionID else { return }
        Task { @MainActor in self.reachedStation() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.scheduled = nil
            self.update(for: TripTracker.shared.trip)
        }
    }
}

extension TripAlerts: UNUserNotificationCenterDelegate {
    /// Shown while the app is open too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// Tapped: a missed train's opens the trip card, to plan another trip; a
    /// cancelled train's, your station's board (or the trip card).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let code = info[boardKey] as? String {
            await MainActor.run { AppRoute.shared.board = code }
            return
        }
        guard let code = info[planToKey] as? String else { return }
        await MainActor.run { AppRoute.shared.planTo = code }
    }
}
