import XCTest
import CoreBluetooth
@testable import NOOP

final class BluetoothChoiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "BluetoothChoiceTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testChoiceRoundTripsAndDefaultsToUndecided() {
        XCTAssertEqual(BluetoothChoice.stored(defaults), .undecided)
        BluetoothChoice.store(.declined, defaults)
        XCTAssertEqual(BluetoothChoice.stored(defaults), .declined)
        BluetoothChoice.store(.allowed, defaults)
        XCTAssertEqual(BluetoothChoice.stored(defaults), .allowed)
    }

    func testSystemAnswerMapsToChoiceOnlyOnceGiven() {
        XCTAssertEqual(BluetoothChoice.from(.allowedAlways), .allowed)
        XCTAssertEqual(BluetoothChoice.from(.denied), .declined)
        XCTAssertEqual(BluetoothChoice.from(.restricted), .declined)
        // Not asked yet (or reset by a rebuild): keep whatever was remembered.
        XCTAssertNil(BluetoothChoice.from(.notDetermined))
    }

    func testRememberedDeclineSuppressesStartupUnlessSystemNowAllows() {
        // A rebuilt app reads as notDetermined; a remembered decline must not raise the prompt again.
        XCTAssertFalse(BluetoothChoice.shouldStartBluetooth(stored: .declined, authorization: .notDetermined))
        XCTAssertFalse(BluetoothChoice.shouldStartBluetooth(stored: .declined, authorization: .denied))
        // Allowed later in System Settings: honour it.
        XCTAssertTrue(BluetoothChoice.shouldStartBluetooth(stored: .declined, authorization: .allowedAlways))
        XCTAssertTrue(BluetoothChoice.shouldStartBluetooth(stored: .undecided, authorization: .notDetermined))
        XCTAssertTrue(BluetoothChoice.shouldStartBluetooth(stored: .allowed, authorization: .notDetermined))
    }

    func testReconnectIntervalIsFifteenMinutes() {
        XCTAssertEqual(BluetoothChoice.reconnectIntervalSeconds, 900)
    }

    func testIdleSilenceDoesNotBounceTheLink() {
        // Observed: an idle, discharging strap is silent for minutes; a 120 s limit reconnected it every ~2.5 min.
        XCTAssertFalse(BLEManager.linkLooksStalled(silence: 150, expectingStream: false))
        XCTAssertFalse(BLEManager.linkLooksStalled(silence: 900, expectingStream: false))   // one pull interval
        XCTAssertTrue(BLEManager.linkLooksStalled(silence: 1_201, expectingStream: false))  // a pull drew no reply
        // A realtime stream that stops for 2 min is still a stall.
        XCTAssertFalse(BLEManager.linkLooksStalled(silence: 60, expectingStream: true))
        XCTAssertTrue(BLEManager.linkLooksStalled(silence: 121, expectingStream: true))
    }
}
