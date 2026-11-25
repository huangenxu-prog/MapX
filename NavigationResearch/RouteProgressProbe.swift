import Foundation
import CoreLocation
import MapboxDirections
import MapboxCoreNavigation

// Synthetic test only: never passed to a live navigation session.
enum RouteProgressProbe {
    static func makeFixture() throws -> Route {
        let a = CLLocationCoordinate2D(latitude: 30, longitude: 120)
        let b = CLLocationCoordinate2D(latitude: 30.001, longitude: 120)
        let options = RouteOptions(coordinates: [a,b])
        options.includesSteps = true
        options.shapeFormat = .geoJSON
        let geometry: [String: Any] = [
            "type": "LineString",
            "coordinates": [[a.longitude,a.latitude],[b.longitude,b.latitude]]
        ]
        let step: [String: Any] = [
            "name": "", "mode": "driving", "distance": 111.0, "duration": 30.0,
            "geometry": geometry,
            "maneuver": ["type": "depart", "location": [a.longitude,a.latitude], "instruction": "Test only"]
        ]
        let leg: [String: Any] = ["summary": "", "distance": 111.0, "duration": 30.0, "steps": [step]]
        let json: [String: Any] = ["distance": 111.0, "duration": 30.0, "geometry": geometry, "legs": [leg]]
        return Route(json: json, waypoints: options.waypoints, options: options)
    }
}
