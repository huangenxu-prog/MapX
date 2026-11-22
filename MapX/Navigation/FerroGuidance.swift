import FerrostarCore
import FerrostarCoreFFI
import MapKit

/// Converts Apple's per-maneuver geometries once, when a trip starts or is rerouted.
final class FerroGuidance {
    enum Event {
        case join(Double)
        case offRoute
        case navigating(remaining: Double, turn: Double, instruction: String, step: Int)
        case complete
    }

    private let engine: FerrostarCoreFFI.NavigationSession
    private var state: NavState?
    private var joined = false

    convenience init?(apple: MKRoute) {
        let segments = apple.steps.compactMap { step -> RouteStep? in
            guard step.polyline.pointCount >= 2, step.distance > 0 else { return nil }
            let points = step.polyline.points()
            let shape = (0..<step.polyline.pointCount).map { GeographicCoordinate(cl: points[$0].coordinate) }
            return Self.segment(shape, distance: step.distance, instruction: step.instructions,
                                duration: apple.expectedTravelTime * step.distance / max(1, apple.distance))
        }
        self.init(segments: segments)
    }

    static func segment(_ geometry: [GeographicCoordinate], distance: Double,
                        instruction: String, duration: Double) -> RouteStep {
        RouteStep(geometry: geometry, distance: distance, duration: duration, roadName: nil,
                  exits: [], instruction: instruction, visualInstructions: [], spokenInstructions: [],
                  annotations: nil, incidents: [], drivingSide: nil, roundaboutExitNumber: nil)
    }

    init?(segments: [RouteStep]) {
        let points = segments.flatMap(\.geometry)
        guard let start = points.first, let end = points.last else { return nil }
        let lat = points.map(\.lat), lon = points.map(\.lng)
        let bounds = BoundingBox(sw: .init(lat: lat.min()!, lng: lon.min()!),
                                 ne: .init(lat: lat.max()!, lng: lon.max()!))
        let route = Route(geometry: points, bbox: bounds, distance: segments.reduce(0) { $0 + $1.distance },
                          waypoints: [Waypoint(coordinate: start, kind: .break), Waypoint(coordinate: end, kind: .break)],
                          steps: segments)
        let config = NavigationControllerConfig(waypointAdvance: .waypointWithinRange(35),
            stepAdvanceCondition: stepAdvanceDistanceEntryAndExit(distanceToEndOfStep: 30,
                distanceAfterEndOfStep: 5, minimumHorizontalAccuracy: 35),
            arrivalStepAdvanceCondition: stepAdvanceDistanceToEndOfStep(distance: 25, minimumHorizontalAccuracy: 35),
            routeDeviationTracking: .staticThreshold(minimumHorizontalAccuracy: 65, maxAcceptableDeviation: 50),
            snappedLocationCourseFiltering: .snapToRoute)
        engine = createNavigationSession(route: route, config: config, observers: [])
    }

    func update(_ fix: CLLocation) -> Event {
        let location = UserLocation(clLocation: fix)
        let next = state.map { engine.updateUserLocation(location: location, state: $0) }
            ?? engine.getInitialState(location: location)
        state = next
        switch next.tripState {
        case let .navigating(_, _, _, steps, _, progress, _, deviation, _, _, _):
            if case let .deviation(.completelyOffRoute(distance)) = deviation {
                return joined ? .offRoute : .join(distance)
            }
            joined = true
            let text = steps.dropFirst().first?.instruction ?? ""
            return .navigating(remaining: progress.distanceRemaining, turn: progress.distanceToNextManeuver,
                               instruction: text.isEmpty ? "沿路线继续行驶" : text, step: steps.count)
        case .complete: return .complete
        case .idle: return .offRoute
        }
    }
}
