import XCTest
import WhoopProtocol
import WhoopStore
@testable import NOOP

@MainActor
final class CollectorBatteryTests: XCTestCase {
    private final class SpyStore: StoreWriting {
        var inserted: [(streams: Streams, deviceId: String)] = []
        var shouldFail = false

        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            if shouldFail { throw CocoaError(.fileWriteUnknown) }
            inserted.append((streams, deviceId))
            return (0, 0, 0, streams.battery.count, 0, 0, 0, 0)
        }

        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
    }

    func testRecordBatteryStoresReadingAtCurrentTime() async {
        let spy = SpyStore()
        let collector = Collector(store: spy, deviceId: "dev1", now: { 1_000 })

        await collector.recordBattery(pct: 72)

        XCTAssertEqual(spy.inserted.count, 1)
        XCTAssertEqual(spy.inserted.first?.deviceId, "dev1")
        XCTAssertEqual(spy.inserted.first?.streams.battery, [BatterySample(ts: 1_000, soc: 72, mv: nil)])
    }

    func testRecordBatterySurvivesStoreFailure() async {
        let spy = SpyStore()
        spy.shouldFail = true
        let collector = Collector(store: spy, deviceId: "dev1", now: { 1_000 })

        await collector.recordBattery(pct: 72)

        XCTAssertTrue(spy.inserted.isEmpty)
    }
}
