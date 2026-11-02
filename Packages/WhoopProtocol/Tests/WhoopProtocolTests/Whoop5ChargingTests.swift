import XCTest
@testable import WhoopProtocol

final class Whoop5ChargingTests: XCTestCase {
    func testChargingEventsMapToState() {
        XCTAssertEqual(Whoop5Charging.signal(Whoop5EventKind(7)), true)
        XCTAssertEqual(Whoop5Charging.signal(Whoop5EventKind(8)), false)
        XCTAssertEqual(Whoop5Charging.signal(Whoop5EventKind(21)), true)
        XCTAssertEqual(Whoop5Charging.signal(Whoop5EventKind(22)), false)
        // Battery level and every other event say nothing about charging.
        XCTAssertNil(Whoop5Charging.signal(Whoop5EventKind(3)))
        XCTAssertNil(Whoop5Charging.signal(Whoop5EventKind(29)))
        XCTAssertEqual(Whoop5EventKind(21).name, "BATTERY_PACK_CONNECTED")
    }

    func testPackInfoReply() {
        // E02 capture with no pack attached: result FAILURE, body 01 + 30 zero bytes.
        XCTAssertEqual(Whoop5Charging.packAttached(command: 151, result: .failure, body: [1] + Array(repeating: 0, count: 30)), false)
        XCTAssertEqual(Whoop5Charging.packAttached(command: 151, result: .success, body: [1, 42, 0, 7]), true)
        // Anything else is not an answer: pending, unsupported, an unexpected failure body, or another command.
        XCTAssertNil(Whoop5Charging.packAttached(command: 151, result: .pending, body: []))
        XCTAssertNil(Whoop5Charging.packAttached(command: 151, result: .unsupported, body: []))
        XCTAssertNil(Whoop5Charging.packAttached(command: 151, result: .failure, body: [1, 9]))
        XCTAssertNil(Whoop5Charging.packAttached(command: 26, result: .success, body: [55]))
    }
}
