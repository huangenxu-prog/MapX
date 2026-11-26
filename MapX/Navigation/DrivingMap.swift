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
        map.showsUserLocation = true
        map.overrideUserInterfaceStyle = .unspecified
        map.setUserTrackingMode(.none, animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let driver = context.coordinator
        driver.onExplore = onExplore
        map.overrideUserInterfaceStyle = context.environment.colorScheme == .dark ? .dark : .light
        if driver.currentRoute !== route {
            if let old = driver.line { map.removeOverlay(old) }
            driver.currentRoute = route
            let line = route.polyline
            driver.line = line
            map.addOverlay(line, level: .aboveRoads)
            map.setVisibleMapRect(line.boundingMapRect, edgePadding: UIEdgeInsets(top: 140, left: 40, bottom: 140, right: 40), animated: false)
            driver.lastCenter = nil
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
        driver.routeMatched = displayCoordinate != nil
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
        var currentRoute: MKRoute?
        var line: MKPolyline?
        var pin: MKPointAnnotation?
        var course = DrivingCourse()
        var speed: CLLocationSpeed = 0
        var walking = false
        var routeMatched = false
        private var position: MKPointAnnotation?

        func clearPosition(on map: MKMapView) {
            if let position { map.removeAnnotation(position) }
            position = nil
            map.showsUserLocation = true
        }

        func updatePosition(_ coordinate: CLLocationCoordinate2D, on map: MKMapView) {
            guard CLLocationCoordinate2DIsValid(coordinate) else { return }
            map.showsUserLocation = false
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
            let desiredDistance = walking ? 350.0 : min(1500, max(700, 700 + speed * 22))
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
            view.image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { _ in
                UIColor.white.setFill()
                UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 40, height: 40)).fill()
                UIColor.systemBlue.setFill()
                let arrow = UIBezierPath()
                arrow.move(to: CGPoint(x: 20, y: 5))
                arrow.addLine(to: CGPoint(x: 32, y: 32))
                arrow.addLine(to: CGPoint(x: 20, y: 26))
                arrow.addLine(to: CGPoint(x: 8, y: 32))
                arrow.close()
                arrow.fill()
            }.withRenderingMode(.alwaysOriginal)
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
