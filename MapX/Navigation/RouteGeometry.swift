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
    static func progress(on route: MKRoute, location: CLLocation) -> RouteProgress {
        let current = MKMapPoint(location.coordinate)
        let matching = project(current, on: route.polyline)
        let traveled = matching.alongMeters
        let remaining = max(0, route.distance - traveled)

        var nextStep: Int?
        var turnDistance = remaining
        for (index, step) in route.steps.enumerated() {
            guard !step.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  step.polyline.pointCount > 0 else { continue }
            let endpoint = step.polyline.points()[step.polyline.pointCount - 1]
            let endProgress = project(endpoint, on: route.polyline).alongMeters
            if endProgress > traveled + 12 {
                nextStep = index
                turnDistance = max(0, endProgress - traveled)
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

    private static func project(_ point: MKMapPoint, on line: MKPolyline)
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
            if cross < bestDistance {
                bestDistance = cross
                bestProgress = completed + fraction * segmentMeters
            }
            completed += segmentMeters
        }
        return (bestProgress, bestDistance)
    }
}

/// Only explicit text in an alternative route can support a requested road-level switch.
/// Absence of a bridge reference does not establish that a road is at ground level.
enum RoadLevel: String, CaseIterable {
    case upper = "桥上"
    case lower = "桥下"
}

enum RoadLevelEvidence {
    static func matches(_ route: MKRoute, level: RoadLevel) -> Bool {
        let text = ([route.name] + route.steps.map(\.instructions)).joined(separator: " ").lowercased()
        switch level {
        case .upper:
            return ["上高架", "高架桥", "桥面", "elevated", "viaduct", "flyover"].contains(where: text.contains)
        case .lower:
            return ["桥下", "地面道路", "地面辅路", "underpass", "surface road"].contains(where: text.contains)
        }
    }
}
