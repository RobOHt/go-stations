import Observation
import SwiftUI
import UIKit

@main
struct DeparturesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if DebugScene.current == .activityGallery {
                TripActivityGallery()
            } else {
                RootView()
                    .environment(settings)
            }
            #else
            RootView()
                .environment(settings)
            #endif
        }
        // Ends the tracked train's Live Activity once it's in, when the app isn't
        // opened after the ride (scheduled by TripActivityController).
        .backgroundTask(.appRefresh(TripActivityController.refreshTaskID)) {
            await TripTracker.shared.backgroundRefresh()
        }
    }
}

/// Where to go when something outside the views asks: a tapped notification.
@MainActor
@Observable
final class AppRoute {
    static let shared = AppRoute()
    /// Open the trip card to this station (a missed train's notification)...
    var planTo: String?
    /// ...from this one, for trains leaving after this time (a cancelled
    /// connection's: where you change, once you get there).
    var planFrom: String?
    var planAfter: Date?
    /// Open this station's board (a cancelled train's notification).
    var board: String?

    /// The trip card to `code` (set last: it's what the map watches).
    func plan(to code: String, from origin: String? = nil, after: Date? = nil) {
        planFrom = origin
        planAfter = after
        planTo = code
    }
}

/// Portrait only, like the boards themselves.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Trip alerts show while the app is open, and getting to your station is
        // heard (it can wake the app to take back the reminder to set off).
        TripAlerts.shared.start()
        // A push token for the app itself, for the worker to wake it in the
        // background (to check you caught your train). No permission needed.
        application.registerForRemoteNotifications()
        #if DEBUG
        // The self-checks run first thing, before anything else on screen.
        if DebugScene.current == .selfCheck { Task { @MainActor in SelfCheck.run() } }
        #endif
        return true
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .portrait
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = TripActivityPush.hex(deviceToken)
        guard token != TripActivityPush.deviceToken else { return }
        TripActivityPush.deviceToken = token
        // The tracked trip's worker job gets it too.
        TripActivityController.shared.sync(TripTracker.shared.trip)
    }

    /// Woken by the worker a couple of minutes after your first train left where
    /// you get on (a silent push, with where the train was then): did you catch it?
    /// Or once your train is found cancelled: the next train, for its Live Activity.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        if userInfo["cancelled"] != nil {
            let cancelled = await TripTracker.shared.checkCancelled()
            // A moment for the Live Activity to take it, before iOS puts the app away again.
            if cancelled { try? await Task.sleep(for: .seconds(2)) }
            return cancelled ? .newData : .noData
        }
        guard let missed = userInfo["missed"] as? [String: Any] else { return .noData }
        var report: TrackedTrip.TrainReport?
        if let lat = (missed["lat"] as? NSNumber)?.doubleValue, let lon = (missed["lon"] as? NSNumber)?.doubleValue,
           let time = (missed["time"] as? NSNumber)?.doubleValue {
            report = TrackedTrip.TrainReport(latitude: lat, longitude: lon, time: Date(timeIntervalSince1970: time))
        }
        let left = (missed["left"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        // The train's latest report (bringing the tracked trip up to date too).
        await LiveTrains.shared.refresh()
        let stopped = await TripTracker.shared.checkMissed(report: report, left: left)
        // A moment for the Live Activity to end and the worker to hear, before iOS
        // puts the app away again.
        if stopped { try? await Task.sleep(for: .seconds(3)) }
        return stopped ? .newData : .noData
    }
}
