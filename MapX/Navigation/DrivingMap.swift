import SwiftUI
import MapKit

/// The camera follows the annotation drawn by this map. GPS supplies only the travel angle.
struct DrivingMap: UIViewRepresentable {
    let route: MKRoute
    let destination: MKMapItem?
    let fix: CLLocation?
    let exploring: Bool
    let onExplore: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.overrideUserInterfaceStyle = .dark
        // Native following holds the user in view until the map delivers its first usable fix.
        map.setUserTrackingMode(.follow, animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let driver = context.coordinator
        driver.onExplore = onExplore
        if driver.line !== route.polyline {
            if let old = driver.line { map.removeOverlay(old) }
            driver.line = route.polyline
            map.addOverlay(route.polyline, level: .aboveRoads)
            if let pin = driver.pin { map.removeAnnotation(pin) }
            if let destination {
                let pin = MKPointAnnotation()
                pin.coordinate = destination.placemark.coordinate
                pin.title = destination.name
                driver.pin = pin
                map.addAnnotation(pin)
            }
        }
        if let fix { driver.course.update(fix); driver.speed = max(0, fix.speed) }
        if driver.exploring && !exploring { driver.lastCenter = nil }
        driver.exploring = exploring
        driver.follow(map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var line: MKPolyline?
        var pin: MKPointAnnotation?
        var course = DrivingCourse()
        var speed: CLLocationSpeed = 0
        var exploring = false
        var onExplore: (() -> Void)?
        var lastCenter: MKMapPoint?
        private var lastHeading: Double = 0
        private var lastDistance: CLLocationDistance = 700
        private var lastCameraUpdate = Date.distantPast
        private var manualGesture = false

        func follow(_ map: MKMapView) {
            let user = map.userLocation
            guard !exploring, !manualGesture, user.location != nil,
                  CLLocationCoordinate2DIsValid(user.coordinate) else { return }
            let point = MKMapPoint(user.coordinate)
            let heading = course.hasHeading ? course.degrees : map.camera.heading
            let desiredDistance = min(1100, max(350, 350 + speed * 22))
            let distance = lastCenter == nil ? desiredDistance : lastDistance + (desiredDistance - lastDistance) * 0.2
            let angle = abs((heading - lastHeading + 540).truncatingRemainder(dividingBy: 360) - 180)
            if let lastCenter {
                if Date().timeIntervalSince(lastCameraUpdate) < 0.25 { return }
                if lastCenter.distance(to: point) < 2, angle < 3, abs(distance - lastDistance) < 20 { return }
            }
            let animate = lastCenter != nil
            lastCenter = point
            lastHeading = heading
            lastDistance = distance
            lastCameraUpdate = Date()
            if map.userTrackingMode != .none { map.setUserTrackingMode(.none, animated: false) }
            let camera = MKMapCamera(lookingAtCenter: user.coordinate, fromDistance: distance,
                                     pitch: 35, heading: heading)
            map.setCamera(camera, animated: animate)
        }

        func mapView(_ map: MKMapView, didUpdate userLocation: MKUserLocation) { follow(map) }

        private func interacting(_ view: UIView) -> Bool {
            if (view.gestureRecognizers ?? []).contains(where: { $0.state == .began || $0.state == .changed }) {
                return true
            }
            return view.subviews.contains(where: interacting)
        }

        func mapView(_ map: MKMapView, regionWillChangeAnimated animated: Bool) {
            if interacting(map) {
                manualGesture = true
                DispatchQueue.main.async { [weak self] in self?.onExplore?() }
            }
        }

        func mapView(_ map: MKMapView, regionDidChangeAnimated animated: Bool) {
            if manualGesture {
                manualGesture = false
                onExplore?()
            }
        }

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.strokeColor = .systemBlue
            renderer.lineWidth = 7
            renderer.lineJoin = .round
            renderer.lineCap = .round
            return renderer
        }
    }
}
