import CoreLocation
import Foundation

struct DrivingCourse {
    private(set) var degrees: Double = 0
    private(set) var hasHeading = false
    private var anchor: CLLocation?
    private var timestamp = Date.distantPast

    mutating func update(_ fix: CLLocation, now: Date = Date()) {
        guard fix.timestamp > timestamp, abs(fix.timestamp.timeIntervalSince(now)) < 15,
              (0...65).contains(fix.horizontalAccuracy) else { return }
        timestamp = fix.timestamp
        if fix.speed >= 0, fix.speed < 0.7 {
            anchor = fix
            return
        }
        if fix.speed >= 0.7, (0..<360).contains(fix.course),
           fix.courseAccuracy < 0 || fix.courseAccuracy <= 45 {
            accept(fix.course)
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
        accept((bearing / radians + 360).truncatingRemainder(dividingBy: 360))
        anchor = fix
    }
    private mutating func accept(_ heading: Double) {
        guard heading.isFinite else { return }
        if !hasHeading { degrees = heading; hasHeading = true; return }
        let delta = (heading - degrees + 540).truncatingRemainder(dividingBy: 360) - 180
        if abs(delta) < 2 { return }
        let weight = abs(delta) > 45 ? 0.75 : 0.4
        degrees = (degrees + delta * weight + 360).truncatingRemainder(dividingBy: 360)
    }
}
