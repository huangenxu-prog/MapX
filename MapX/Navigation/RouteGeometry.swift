import MapKit
import CoreLocation

struct RouteProgress {
    let remainingDistance: CLLocationDistance
    let distanceFromRoute: CLLocationDistance
    let distanceAlongRoute: CLLocationDistance
    let nextStepIndex: Int?
    let distanceToNextTurn: CLLocationDistance
    let matchedCoordinate: CLLocationCoordinate2D?
}

/// MapKit-native projection keeps all matching calculations in one coordinate space; continuity bounds prevent
/// jumps at crossings. This is not lane-level or road-elevation matching.
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
            distanceToNextTurn: turnDistance,
            matchedCoordinate: matching.coordinate
        )
    }

    private static func project(_ point: MKMapPoint, on line: MKPolyline, previousDistance: CLLocationDistance?, maximumAdvance: CLLocationDistance)
        -> (alongMeters: Double, distanceMeters: Double, coordinate: CLLocationCoordinate2D?) {
        let points = line.points()
        guard line.pointCount > 0 else {
            return (0, .infinity, nil)
        }
        guard line.pointCount > 1 else {
            return (0, point.distance(to: points[0]), points[0].coordinate)
        }

        var bestDistance = Double.infinity
        var bestProgress: Double = 0
        var bestCoordinate: CLLocationCoordinate2D?
        var localCoordinate: CLLocationCoordinate2D?
        var localDistance = Double.infinity
        var localProgress: Double = 0
        var completed: Double = 0

        for index in 0..<(line.pointCount - 1) {
            let start = points[index]
            let end = points[index + 1]
            let segmentMeters = start.distance(to: end)
            // Skip segments outside the plausible progress corridor.
            if let previousDistance,
               completed + segmentMeters < previousDistance - 45 ||
               completed > previousDistance + maximumAdvance {
                completed += segmentMeters
                continue
            }
            let lower = max(0, (previousDistance ?? completed) - 45 - completed)
            let upper = min(segmentMeters, (previousDistance.map { $0 + maximumAdvance } ?? (completed + segmentMeters)) - completed)
            guard upper >= lower, segmentMeters > 0 else { completed += segmentMeters; continue }
            let dx = end.x - start.x
            let dy = end.y - start.y
            let squared = dx * dx + dy * dy
            guard squared > 0 else { completed += segmentMeters; continue }
            let rawFraction = ((point.x - start.x) * dx + (point.y - start.y) * dy) / squared
            let offset = min(upper, max(lower, rawFraction * segmentMeters))
            let fraction = offset / segmentMeters
            let projected = MKMapPoint(x: start.x + (end.x - start.x) * fraction,
                                       y: start.y + (end.y - start.y) * fraction)
            let cross = point.distance(to: projected)
            let along = completed + offset
            if let previousDistance, along >= previousDistance - 45,
               along <= previousDistance + maximumAdvance, cross < localDistance {
                localDistance = cross
                localProgress = along
                localCoordinate = projected.coordinate
            }
            if cross < bestDistance {
                bestDistance = cross
                bestProgress = along
                bestCoordinate = projected.coordinate
            }
            completed += segmentMeters
        }
        // Prefer continuity at crossings and parallel sections. If no plausible
        // local match exists, retain progress and report distance to the local corridor.
        if let previousDistance {
            if localDistance.isFinite { return (localProgress, localDistance, localCoordinate) }
            return (previousDistance, .infinity, nil)
        }
        return (bestProgress, bestDistance, bestCoordinate)
    }
}
