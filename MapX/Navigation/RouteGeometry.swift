import MapKit
import CoreLocation
import Turf

struct RouteProgress {
    let remainingDistance: CLLocationDistance
    let distanceFromRoute: CLLocationDistance
    let distanceAlongRoute: CLLocationDistance
    let nextStepIndex: Int?
    let distanceToNextTurn: CLLocationDistance
}

/// Turf provides the nearest point on each segment; continuity bounds prevent
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
            let segmentMeters = start.distance(to: end)
            // Skip segments outside the plausible progress corridor.
            if let previousDistance,
               completed + segmentMeters < previousDistance - 45 ||
               completed > previousDistance + maximumAdvance {
                completed += segmentMeters
                continue
            }
            let segment = LineString([start.coordinate, end.coordinate])
            let nearest = segment.closestCoordinate(to: point.coordinate)
            let projected = nearest.map { MKMapPoint($0.coordinate) } ?? start
            let cross = point.distance(to: projected)
            let along = completed + min(segmentMeters, start.distance(to: projected))
            if let previousDistance, along >= previousDistance - 45,
               along <= previousDistance + maximumAdvance, cross < localDistance {
                localDistance = cross
                localProgress = along
            }
            if cross < bestDistance {
                bestDistance = cross
                bestProgress = along
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
