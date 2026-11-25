import CoreLocation
import MapKit
import Foundation

/// A loss-aware intermediate model. Does not manufacture maneuver types,
/// road levels, per-step ETAs, intersection topology or lane instructions.
struct AppleRouteSnapshot {
    struct Step {
        let coordinates: [CLLocationCoordinate2D]
        let distance: CLLocationDistance
        let instruction: String
    }
    let coordinates: [CLLocationCoordinate2D]
    let distance: CLLocationDistance
    let expectedTravelTime: TimeInterval
    let steps: [Step]

    enum AdapterError: Error {
        case invalidGeometry
        case invalidMetrics
        case missingSteps
    }

    init(route: MKRoute) throws {
        try self.init(coordinates: Self.coordinates(route.polyline),
                      distance: route.distance,
                      expectedTravelTime: route.expectedTravelTime,
                      steps: route.steps.map {
                          Step(coordinates: Self.coordinates($0.polyline),
                               distance: $0.distance, instruction: $0.instructions)
                      })
    }

    init(coordinates: [CLLocationCoordinate2D], distance: CLLocationDistance,
         expectedTravelTime: TimeInterval, steps: [Step]) throws {
        guard coordinates.count >= 2,
              coordinates.allSatisfy({ CLLocationCoordinate2DIsValid($0) }) else {
            throw AdapterError.invalidGeometry
        }
        guard distance.isFinite, distance > 0,
              expectedTravelTime.isFinite, expectedTravelTime > 0 else {
            throw AdapterError.invalidMetrics
        }
        guard !steps.isEmpty else { throw AdapterError.missingSteps }
        for step in steps {
            guard step.distance.isFinite, step.distance >= 0 else {
                throw AdapterError.invalidMetrics
            }
            guard step.coordinates.allSatisfy({ CLLocationCoordinate2DIsValid($0) }),
                  step.distance == 0 || step.coordinates.count >= 2 else {
                throw AdapterError.invalidGeometry
            }
        }
        self.coordinates = coordinates
        self.distance = distance
        self.expectedTravelTime = expectedTravelTime
        self.steps = steps
    }

    private static func coordinates(_ line: MKPolyline) -> [CLLocationCoordinate2D] {
        guard line.pointCount > 0 else { return [] }
        return (0..<line.pointCount).map { line.points()[$0].coordinate }
    }
}
