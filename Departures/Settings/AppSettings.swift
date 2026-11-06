import Foundation
import Observation

/// Home/work stations, synced through iCloud key-value storage, and the map's
/// options (on this device only). No accounts, no database.
@MainActor
@Observable
final class AppSettings {
    private(set) var homeCode: String?
    private(set) var workCode: String?
    /// Every train running now on the map, not just the tracked one.
    private(set) var showsAllTrains = false

    private enum Key {
        static let home = "homeStation"
        static let work = "workStation"
        static let allTrains = "showsAllTrains"
    }

    private let cloud = NSUbiquitousKeyValueStore.default
    private let local = UserDefaults.standard
    @ObservationIgnored private var cloudObserver: (any NSObjectProtocol)?

    init() {
        cloud.synchronize()
        homeCode = Self.stored(Key.home, cloud: cloud, local: local)
        workCode = Self.stored(Key.work, cloud: cloud, local: local)
        showsAllTrains = local.bool(forKey: Key.allTrains)

        // Home/work changed on another device.
        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadFromCloud() }
        }
    }

    /// iCloud is the source of truth when it's available, so a station cleared on one
    /// device stays cleared everywhere. Local storage is only the fallback without iCloud.
    private static func stored(_ key: String, cloud: NSUbiquitousKeyValueStore, local: UserDefaults) -> String? {
        if FileManager.default.ubiquityIdentityToken != nil {
            return cloud.string(forKey: key)
        }
        return local.string(forKey: key)
    }

    func setHome(_ code: String?) {
        homeCode = code
        store(code, forKey: Key.home)
    }

    func setWork(_ code: String?) {
        workCode = code
        store(code, forKey: Key.work)
    }

    func setShowsAllTrains(_ value: Bool) {
        showsAllTrains = value
        local.set(value, forKey: Key.allTrains)
    }

    /// Picks up changes made on another device (call when the app becomes active).
    func reloadFromCloud() {
        cloud.synchronize()
        let home = Self.stored(Key.home, cloud: cloud, local: local)
        let work = Self.stored(Key.work, cloud: cloud, local: local)
        if home != homeCode { homeCode = home }
        if work != workCode { workCode = work }
    }

    private func store(_ value: String?, forKey key: String) {
        if let value {
            cloud.set(value, forKey: key)
            local.set(value, forKey: key)
        } else {
            cloud.removeObject(forKey: key)
            local.removeObject(forKey: key)
        }
        cloud.synchronize()
    }
}
