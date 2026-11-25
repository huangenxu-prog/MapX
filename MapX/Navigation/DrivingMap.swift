import SwiftUI
import MapKit

/// The navigation marker and camera share one display coordinate; raw GPS remains independent.
struct DrivingMap: UIViewRepresentable {
    let route: MKRoute
    let destination: MKMapItem?
    let fix: CLLocation?
    let displayCoordinate: CLLocationCoordinate2D?
    let walking: Bool
    let exploring: Bool
    let onExplore: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = false
        map.overrideUserInterfaceStyle = .unspecified
        map.setUserTrackingMode(.none, animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let driver = context.coordinator
        driver.onExplore = onExplore
        map.overrideUserInterfaceStyle = context.environment.colorScheme == .dark ? .dark : .light
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
        driver.walking = walking
        if let fix, CLLocationCoordinate2DIsValid(fix.coordinate),
           fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 65,
           abs(fix.timestamp.timeIntervalSinceNow) < 20 {
            driver.course.update(fix)
            driver.speed = max(0, fix.speed)
            driver.updatePosition(displayCoordinate ?? fix.coordinate, on: map)
        }
        if driver.exploring && !exploring { driver.lastCenter = nil }
        driver.exploring = exploring
        driver.follow(map)
        driver.updateMarkerHeading(on: map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var line: MKPolyline?
        var pin: MKPointAnnotation?
        var course = DrivingCourse()
        var speed: CLLocationSpeed = 0
        var walking = false
        private var position: MKPointAnnotation?

        func updatePosition(_ coordinate: CLLocationCoordinate2D, on map: MKMapView) {
            guard CLLocationCoordinate2DIsValid(coordinate) else { return }
            if let position {
                position.coordinate = coordinate
            } else {
                let marker = MKPointAnnotation()
                marker.coordinate = coordinate
                position = marker
                map.addAnnotation(marker)
            }
        }
        func updateMarkerHeading(on map: MKMapView) {
            guard let position, let view = map.view(for: position) else { return }
            let bearing = course.hasHeading ? course.degrees : map.camera.heading
            let angle = (bearing - map.camera.heading) * .pi / 180
            view.transform = CGAffineTransform(rotationAngle: CGFloat(angle))
        }
        var exploring = false
        var onExplore: (() -> Void)?
        var lastCenter: MKMapPoint?
        private var lastHeading: Double = 0
        private var lastDistance: CLLocationDistance = 700
        private var lastCameraUpdate = Date.distantPast
        private var manualGesture = false

        func follow(_ map: MKMapView) {
            guard !exploring, !manualGesture, let position else { return }
            let point = MKMapPoint(position.coordinate)
            let heading = course.hasHeading ? course.degrees : map.camera.heading
            let desiredDistance = walking ? 220.0 : min(1100, max(350, 350 + speed * 22))
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
            let camera = MKMapCamera(lookingAtCenter: position.coordinate, fromDistance: distance,
                                     pitch: walking ? 0 : 35, heading: heading)
            map.setCamera(camera, animated: animate)
        }

        func mapViewDidChangeVisibleRegion(_ map: MKMapView) {
            updateMarkerHeading(on: map)
        }

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let position, annotation === position else { return nil }
            let view = map.dequeueReusableAnnotationView(withIdentifier: "navigation-position") ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "navigation-position")
            view.annotation = annotation
            view.image = UIImage(systemName: "location.north.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 32, weight: .bold))?.withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
            view.canShowCallout = false
            view.displayPriority = .required
            return view
        }

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
            updateMarkerHeading(on: map)
            if manualGesture {
                manualGesture = false
                DispatchQueue.main.async { [weak self] in self?.onExplore?() }
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
