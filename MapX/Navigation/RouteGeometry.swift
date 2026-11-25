import MapKit
import CoreLocation

struct RouteProgress {
    let remainingDistance: CLLocationDistance
    let distanceFromRoute: CLLocationDistance
    let distanceAlongRoute: CLLocationDistance
    let nextStepIndex: Int?
    let distanceToNextTurn: CLLocationDistance
}

/// Polyline measurements are performed in map coordinates and converted to meters.
/// This is an approximation, not lane-level or road-elevation matching.
enum RouteGeometry {
    static func progress(on route: MKRoute, location: CLLocation, previousDistance: CLLocationDistance? = nil, maximumAdvance: CLLocationDistance = 100) -> RouteProgress {
        let current = MKMapPoint(location.coordinate)
        let matching = project(current, on: route.polyline, previousDistance: previousDistance, maximumAdvance: maximumAdvance)
        let traveled = matching.alongMeters
        let remaining = max(0, route.distance - traveled)

        var nextStep: Int?
        var turnDistance = remaining
        var stepStart: Double = 0
        for (index, step) in route.steps.enumerated() {
            defer { stepStart += step.distance }
            if stepStart > traveled + 3, !step.instructions.isEmpty {
                nextStep = index
                turnDistance = stepStart - traveled
                break
            }
        }

        return RouteProgress(
            remainingDistance: remaining,
            distanceFromRoute: matching.distanceMeters,
            distanceAlongRoute: traveled,
            nextStepIndex: nextStep,
            distanceToNextTurn: turnDistance
        )
    }

    private static func project(_ point: MKMapPoint, on line: MKPolyline, previousDistance: CLLocationDistance?, maximumAdvance: CLLocationDistance)
        -> (alongMeters: Double, distanceMeters: Double) {
        let points = line.points()
        guard line.pointCount > 0 else {
            return (0, .infinity)
        }
        guard line.pointCount > 1 else {
            return (0, point.distance(to: points[0]))
        }

        var bestDistance = Double.infinity
        var bestProgress: Double = 0
        var localDistance = Double.infinity
        var localProgress: Double = 0
        var completed: Double = 0

        for index in 0..<(line.pointCount - 1) {
            let start = points[index]
            let end = points[index + 1]
            let dx = end.x - start.x
            let dy = end.y - start.y
            let squared = dx * dx + dy * dy
            let fraction = squared > 0
                ? max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / squared))
                : 0
            let projected = MKMapPoint(x: start.x + fraction * dx,
                                       y: start.y + fraction * dy)
            let cross = point.distance(to: projected)
            let segmentMeters = start.distance(to: end)
            let along = completed + fraction * segmentMeters
            if let previousDistance, along >= previousDistance - 45,
               along <= previousDistance + maximumAdvance, cross < localDistance {
                localDistance = cross
                localProgress = along
            }
            if cross < bestDistance {
                bestDistance = cross
                bestProgress = completed + fraction * segmentMeters
            }
            completed += segmentMeters
        }
        // Prefer continuity at crossings and parallel sections. If no plausible
        // local match exists, retain progress and report distance to the local corridor.
        if let previousDistance {
            if localDistance.isFinite { return (localProgress, localDistance) }
            return (previousDistance, .infinity)
        }
        return (bestProgress, bestDistance)
    }
}
