import CoreLocation
import Foundation

struct DrivingCourse {
    private(set) var degrees: Double = 0
    private var anchor: CLLocation?
    private var timestamp = Date.distantPast

    mutating func update(_ fix: CLLocation, now: Date = Date()) {
        guard fix.timestamp > timestamp, abs(fix.timestamp.timeIntervalSince(now)) < 15,
              (0...65).contains(fix.horizontalAccuracy) else { return }
        timestamp = fix.timestamp
        if fix.speed >= 0, fix.speed < 1.5 {
            anchor = fix
            return
        }
        if fix.speed >= 1.5, (0..<360).contains(fix.course),
           fix.courseAccuracy < 0 || fix.courseAccuracy <= 45 {
            degrees = fix.course
            anchor = fix
            return
        }
        guard let start = anchor, fix.timestamp.timeIntervalSince(start.timestamp) < 20 else {
            anchor = fix
            return
        }
        guard fix.distance(from: start) >= max(12, start.horizontalAccuracy + fix.horizontalAccuracy)
        else { return }
        let radians = Double.pi / 180
        let a = start.coordinate.latitude * radians
        let b = fix.coordinate.latitude * radians
        let delta = (fix.coordinate.longitude - start.coordinate.longitude) * radians
        let bearing = atan2(sin(delta) * cos(b), cos(a) * sin(b) - sin(a) * cos(b) * cos(delta))
        degrees = (bearing / radians + 360).truncatingRemainder(dividingBy: 360)
        anchor = fix
    }
}
