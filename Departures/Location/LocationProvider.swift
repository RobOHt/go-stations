import CoreLocation

/// One-shot "where am I" with a short timeout. Uses a recent cached fix when available
/// so opening the app feels instant.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<CLLocation?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var isDenied: Bool {
        let status = manager.authorizationStatus
        return status == .denied || status == .restricted
    }

    private var isAuthorized: Bool {
        let status = manager.authorizationStatus
        return status == .authorizedWhenInUse || status == .authorizedAlways
    }

    func currentLocation(maxAge: TimeInterval = 120, timeout: TimeInterval = 8) async -> CLLocation? {
        if let cached = manager.location, -cached.timestamp.timeIntervalSinceNow < maxAge {
            return cached
        }
        if isDenied { return nil }

        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if isAuthorized {
                manager.requestLocation()
            } else {
                manager.requestWhenInUseAuthorization()
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.finish(with: self?.manager.location)
            }
        }
    }

    private func finish(with location: CLLocation?) {
        guard !waiters.isEmpty else { return }
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: location) }
    }

    private func authorizationChanged() {
        guard !waiters.isEmpty else { return }
        if isAuthorized {
            manager.requestLocation()
        } else if isDenied {
            finish(with: nil)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in self.finish(with: location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(with: nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.authorizationChanged() }
    }
}
