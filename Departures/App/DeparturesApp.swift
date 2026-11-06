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

/// Portrait only, like the boards themselves.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .portrait
    }
}
