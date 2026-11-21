import CoreLocation
import Combine
import Foundation

/// Owns location authorization and updates. No background-location entitlement is requested.
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var location: CLLocation?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus

    private let manager = CLLocationManager()

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = true
        if isAuthorized {
            manager.startUpdatingLocation()
        }
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
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func setNavigating(_ navigating: Bool) {
        manager.desiredAccuracy = navigating ? kCLLocationAccuracyBestForNavigation : kCLLocationAccuracyBest
        manager.distanceFilter = navigating ? 5 : 10
        manager.pausesLocationUpdatesAutomatically = !navigating
        if isAuthorized {
            manager.startUpdatingLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if isAuthorized {
            manager.startUpdatingLocation()
        } else {
            location = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last,
              latest.horizontalAccuracy >= 0,
              latest.horizontalAccuracy <= 150 else { return }
        location = latest
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // The UI reacts to authorization status and missing GPS fixes.
    }
}
