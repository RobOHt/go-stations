#if DEBUG
import CoreLocation
import Foundation

/// Debug builds only: launch straight into a state for simulator screenshots,
/// with `-debugScene <name>` as a launch argument (see the Screenshots workflow).
/// Home and work can be set the same way: `-homeStation OA -workStation UN`.
enum DebugScene: String {
    /// The map with the search field, no sheet.
    case map
    /// The search field active and empty: home and work listed above it.
    case searchFocused
    /// The empty search opened, then the map tapped: the search should close.
    case searchTapAway
    /// Typing: station matches and place suggestions.
    case searchTyping
    /// A place picked: its pin and the closest stations by car.
    case place
    /// Union's board at half height.
    case station
    /// Union's board at full height.
    case stationLarge
    /// Union's board, then its first train's stops.
    case trip
    /// Union's board at full height, scrolled so trains pass under the pinned
    /// header: shows whether the simulator draws scroll edge effects at all.
    case stationScrolled
    /// Union's board, then its home button tapped. With home set elsewhere
    /// (`-homeStation OA`), it asks to replace it.
    case homeDialog
    /// Union's board, then its work button tapped. With Union as work
    /// (`-workStation UN`), it asks to remove it.
    case workDialog
    /// Union's board with the trains that already left shown above.
    case stationEarlier

    static var current: DebugScene? {
        UserDefaults.standard.string(forKey: "debugScene").flatMap(DebugScene.init(rawValue:))
    }

    /// `-debugNow 2026-11-10T07:30:00-05:00`: the time the app goes by.
    static let fixedNow: Date? = UserDefaults.standard.string(forKey: "debugNow")
        .flatMap { ISO8601DateFormatter().date(from: $0) }

    /// `-debugLocation 43.6453,-79.3806[,accuracy]`: where the app thinks you are.
    static var fixedLocation: CLLocation? {
        guard let text = UserDefaults.standard.string(forKey: "debugLocation") else { return nil }
        let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 2 else { return nil }
        return CLLocation(coordinate: CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]),
                          altitude: 0, horizontalAccuracy: parts.count > 2 ? parts[2] : 10,
                          verticalAccuracy: -1, timestamp: Date())
    }

    /// Where the start-up choice is written, for the simulator check to read
    /// (Documents/startup-choice.txt in the app's container).
    static func record(_ choice: CommutePlanner.Choice?) {
        let line = "\(choice?.station ?? "none") \(choice?.reason.rawValue ?? "none")\n"
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? line.write(to: directory.appendingPathComponent("startup-choice.txt"), atomically: true, encoding: .utf8)
    }
}

#endif
