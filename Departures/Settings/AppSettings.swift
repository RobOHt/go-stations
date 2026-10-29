import Foundation
import Observation
import Security

/// Home/work stations sync through iCloud key-value storage; the API key lives in
/// the (iCloud-synced) Keychain. No accounts, no database.
@MainActor
@Observable
final class AppSettings {
    private(set) var homeCode: String?
    private(set) var workCode: String?
    private(set) var apiKey: String

    private enum Key {
        static let home = "homeStation"
        static let work = "workStation"
    }

    private let cloud = NSUbiquitousKeyValueStore.default
    private let local = UserDefaults.standard

    init() {
        cloud.synchronize()
        homeCode = cloud.string(forKey: Key.home) ?? local.string(forKey: Key.home)
        workCode = cloud.string(forKey: Key.work) ?? local.string(forKey: Key.work)
        apiKey = Keychain.readAPIKey() ?? ""
    }

    var hasAPIKey: Bool { !apiKey.isEmpty }

    func setHome(_ code: String?) {
        homeCode = code
        store(code, forKey: Key.home)
    }

    func setWork(_ code: String?) {
        workCode = code
        store(code, forKey: Key.work)
    }

    func setAPIKey(_ key: String) {
        let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned != apiKey else { return }
        apiKey = cleaned
        Keychain.saveAPIKey(cleaned)
    }

    /// Picks up changes made on another device (call when the app becomes active).
    func reloadFromCloud() {
        cloud.synchronize()
        let home = cloud.string(forKey: Key.home) ?? local.string(forKey: Key.home)
        let work = cloud.string(forKey: Key.work) ?? local.string(forKey: Key.work)
        if home != homeCode { homeCode = home }
        if work != workCode { workCode = work }
        if apiKey.isEmpty, let key = Keychain.readAPIKey(), !key.isEmpty { apiKey = key }
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

/// Minimal Keychain wrapper. Items are synchronizable, so the key follows you
/// to your other devices through iCloud Keychain.
enum Keychain {
    private static let service = "Departures.MetrolinxAPIKey"
    private static let account = "default"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
    }

    static func readAPIKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveAPIKey(_ value: String) {
        SecItemDelete(baseQuery as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = baseQuery
        attributes[kSecAttrSynchronizable as String] = kCFBooleanTrue
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
