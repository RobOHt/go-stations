#if DEBUG
import Foundation

/// Debug builds only: launch straight into a state for simulator screenshots,
/// with `-debugScene <name>` as a launch argument (see the Screenshots workflow).
/// Home and work can be set the same way: `-homeStation OA -workStation UN`.
enum DebugScene: String {
    /// The map with the search field, no sheet.
    case map
    /// The search field active and empty: home and work listed above it.
    case searchFocused
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

    static var current: DebugScene? {
        UserDefaults.standard.string(forKey: "debugScene").flatMap(DebugScene.init(rawValue:))
    }
}
#endif
