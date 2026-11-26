import Combine
import CoreLocation
import Foundation

/// Core Location lives independently of map rendering so GPS callbacks keep arriving
/// when the user locks the screen during an explicitly started navigation session.
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var location: CLLocation?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus

    /// Invoked for fresh navigation fixes, including background-delivered updates.
    /// Callers should hop to the main actor before updating SwiftUI-observable state.
    var onNavigationLocationUpdate: ((CLLocation) -> Void)?

    private let manager = CLLocationManager()
    private var navigating = false
    private var appIsForeground = true

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        manager.pausesLocationUpdatesAutomatically = true
        updateDelivery()
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse ||
        authorizationStatus == .authorizedAlways
    }

    func requestLocation() {
        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            updateDelivery()
        default:
            break
        }
    }

    func setNavigating(_ active: Bool, walking: Bool = false) {
        navigating = active
        manager.activityType = active && walking ? .fitness : .automotiveNavigation
        manager.desiredAccuracy = active ? kCLLocationAccuracyBestForNavigation : kCLLocationAccuracyBest
        manager.distanceFilter = active ? kCLDistanceFilterNone : 10
        manager.pausesLocationUpdatesAutomatically = !active
        // The Info.plist explicitly declares UIBackgroundModes/location. Enable this
        // *only* for a user-started trip, never just because the app was opened.
        manager.allowsBackgroundLocationUpdates = active && isAuthorized
        manager.showsBackgroundLocationIndicator = active
        updateDelivery()
    }

    func setAppForeground(_ foreground: Bool) {
        appIsForeground = foreground
        updateDelivery()
    }

    private func updateDelivery() {
        guard isAuthorized && (appIsForeground || navigating) else {
            manager.stopUpdatingLocation()
            return
        }
        manager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        manager.allowsBackgroundLocationUpdates = navigating && isAuthorized
        updateDelivery()
        if !isAuthorized { location = nil }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last,
              abs(latest.timestamp.timeIntervalSinceNow) < 20,
              latest.horizontalAccuracy >= 0,
              latest.horizontalAccuracy <= 150,
              location.map({ latest.timestamp > $0.timestamp }) ?? true else { return }
        location = latest
        if navigating {
            onNavigationLocationUpdate?(latest)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A temporarily missing GPS fix must not fabricate a new position.
    }
}
