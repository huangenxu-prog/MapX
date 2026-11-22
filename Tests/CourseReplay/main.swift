import CoreLocation
import Foundation

let start = Date()
var course = DrivingCourse()
func sample(_ seconds: Double, _ longitude: Double, _ heading: Double, _ speed: Double) {
    let time = start.addingTimeInterval(seconds)
    let fix = CLLocation(coordinate: .init(latitude: 30, longitude: longitude),
                         altitude: 0, horizontalAccuracy: 4, verticalAccuracy: 5,
                         course: heading, speed: speed, timestamp: time)
    course.update(fix, now: time)
}
sample(0, 120, 359, 12)
precondition(course.degrees == 359)
sample(1, 120, 1, 12)
precondition(course.degrees == 1)
sample(2, 120, 90, 8)
precondition(course.degrees == 90)
sample(3, 120, 220, 0)
precondition(course.degrees == 90)
sample(7, 119.9996, -1, 8)
precondition(abs(course.degrees - 270) < 1)
