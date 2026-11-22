import XCTest
import CoreLocation
import FerrostarCoreFFI
@testable import MapX

final class GuidanceReplay: XCTestCase {
    func testJoinTurnAndDeviation() throws {
        let a = GeographicCoordinate(lat: 30, lng: 120)
        let b = GeographicCoordinate(lat: 30.002, lng: 120)
        let c = GeographicCoordinate(lat: 30.002, lng: 120.003)
        let engine = try XCTUnwrap(FerroGuidance(segments: [
            FerroGuidance.segment([a,b], distance: 222, instruction: "直行", duration: 20),
            FerroGuidance.segment([b,c], distance: 289, instruction: "右转", duration: 30)
        ]))
        func fix(_ lat: Double, _ lon: Double) -> FerroGuidance.Event {
            engine.update(CLLocation(coordinate: .init(latitude: lat, longitude: lon),
                altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                course: 0, speed: 8, timestamp: Date()))
        }
        guard case .join = fix(30,119.998) else { return XCTFail("off-route start") }
        guard case let .navigating(_, turn, instruction, _) = fix(30.001,120)
        else { return XCTFail("did not join") }
        XCTAssertEqual(instruction,"右转")
        XCTAssertEqual(turn,111,accuracy: 8)
        _ = fix(30.00195,120)
        _ = fix(30.002,120)
        _ = fix(30.002,120.0002)
        guard case let .navigating(_, _, _, steps) = fix(30.002,120.0005)
        else { return XCTFail("did not follow turn") }
        XCTAssertEqual(steps,1)
        guard case .offRoute = fix(30.004,120.0005) else { return XCTFail("missed deviation") }
    }
}
