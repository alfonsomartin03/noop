import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// Task A: persistence for the 4 type-47 biometric streams (spo2/skinTemp/resp/gravity).
/// Real V24 values used so the round-trip mirrors the on-device decode.
final class BiometricStreamTests: XCTestCase {
    private func bioStreams() -> Streams {
        Streams(
            hr: [HRSample(ts: 1700000000, bpm: 63)],
            spo2: [SpO2Sample(ts: 1700000000, red: 18000, ir: 17000)],
            skinTemp: [SkinTempSample(ts: 1700000000, raw: 900)],
            resp: [RespSample(ts: 1700000000, raw: 3000)],
            gravity: [GravitySample(ts: 1700000000, x: 0.05, y: 0.10, z: 0.993734)])
    }

    // MARK: - v3 migration

    func testV3CreatesBiometricTables() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["spo2Sample", "skinTempSample", "respSample", "gravitySample"] {
            XCTAssertTrue(tables.contains(t), "missing table \(t)")
        }
    }

    func testV3PrimaryKeysAreDeviceIdTs() async throws {
        let store = try await WhoopStore.inMemory()
        for t in ["spo2Sample", "skinTempSample", "respSample", "gravitySample"] {
            let cols = try await store.primaryKeyColumns(t)
            XCTAssertEqual(cols, ["deviceId", "ts"], "PK mismatch for \(t)")
        }
    }

    func testV3AppliesOnTopOfV1V2() async throws {
        // Building from a fresh DB runs v1 → v2 → v3 in order; assert old + new coexist.
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["device", "hrSample", "rrInterval", "event", "battery", "rawBatch",
                  "cursors", "spo2Sample", "skinTempSample", "respSample", "gravitySample"] {
            XCTAssertTrue(tables.contains(t), "missing table \(t)")
        }
    }

    // MARK: - insert

    func testInsertReturnsBiometricCounts() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        let n = try await store.insert(bioStreams(), deviceId: "dev1")
        XCTAssertEqual(n.hr, 1)
        XCTAssertEqual(n.spo2, 1)
        XCTAssertEqual(n.skinTemp, 1)
        XCTAssertEqual(n.resp, 1)
        XCTAssertEqual(n.gravity, 1)
    }

    func testInsertBiometricIsIdempotent() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        _ = try await store.insert(bioStreams(), deviceId: "dev1")
        let second = try await store.insert(bioStreams(), deviceId: "dev1")
        XCTAssertEqual(second.spo2, 0)
        XCTAssertEqual(second.skinTemp, 0)
        XCTAssertEqual(second.resp, 0)
        XCTAssertEqual(second.gravity, 0)
    }

    func testBackwardCompatHrRrOnly() async throws {
        // A Streams with no biometric arrays still inserts cleanly; new counts are 0.
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        let n = try await store.insert(
            Streams(hr: [HRSample(ts: 100, bpm: 60)],
                    rr: [RRInterval(ts: 100, rrMs: 800)]),
            deviceId: "dev1")
        XCTAssertEqual(n.hr, 1)
        XCTAssertEqual(n.rr, 1)
        XCTAssertEqual(n.spo2, 0)
        XCTAssertEqual(n.skinTemp, 0)
        XCTAssertEqual(n.resp, 0)
        XCTAssertEqual(n.gravity, 0)
    }

    // MARK: - reads

    func testBiometricReadsRoundTrip() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        try await store.upsertDevice(id: "other", mac: nil, name: nil)
        _ = try await store.insert(bioStreams(), deviceId: "dev1")
        // Decoy on another device — must never appear in dev1 reads.
        _ = try await store.insert(bioStreams(), deviceId: "other")

        let from = 0, to = 2_000_000_000, lim = 100
        let spo2 = try await store.spo2Samples(deviceId: "dev1", from: from, to: to, limit: lim)
        XCTAssertEqual(spo2, [SpO2Sample(ts: 1700000000, red: 18000, ir: 17000)])

        let skin = try await store.skinTempSamples(deviceId: "dev1", from: from, to: to, limit: lim)
        XCTAssertEqual(skin, [SkinTempSample(ts: 1700000000, raw: 900)])

        let resp = try await store.respSamples(deviceId: "dev1", from: from, to: to, limit: lim)
        XCTAssertEqual(resp, [RespSample(ts: 1700000000, raw: 3000)])

        let grav = try await store.gravitySamples(deviceId: "dev1", from: from, to: to, limit: lim)
        XCTAssertEqual(grav, [GravitySample(ts: 1700000000, x: 0.05, y: 0.10, z: 0.993734)])
    }

    func testBiometricReadsRespectRangeAndScope() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        _ = try await store.insert(
            Streams(spo2: [SpO2Sample(ts: 100, red: 1, ir: 2),
                           SpO2Sample(ts: 200, red: 3, ir: 4),
                           SpO2Sample(ts: 300, red: 5, ir: 6)]),
            deviceId: "dev1")
        let windowed = try await store.spo2Samples(deviceId: "dev1", from: 150, to: 250, limit: 100)
        XCTAssertEqual(windowed, [SpO2Sample(ts: 200, red: 3, ir: 4)])  // inclusive
        let limited = try await store.spo2Samples(deviceId: "dev1", from: 0, to: 1000, limit: 2)
        XCTAssertEqual(limited.count, 2)
        XCTAssertEqual(limited.first?.ts, 100)
    }
}

/// v18: skin-temperature samples carry their unit, so 5.0 1/100 °C values never mix with 4.0 ADC counts.
final class SkinTempUnitTests: XCTestCase {
    func testExistingRowsBecomeRawADCAfterV18() throws {
        let q = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(q, upTo: "v17")
        try q.write { db in
            try db.execute(sql: "INSERT INTO skinTempSample (deviceId, ts, raw) VALUES ('d', 100, 900)")
        }
        try migrator.migrate(q)
        let unit = try q.read { db in try String.fetchOne(db, sql: "SELECT unit FROM skinTempSample WHERE ts = 100") }
        XCTAssertEqual(unit, "raw_adc")
    }

    func testUnitRoundTripsAndOnlyCentiCelsiusConvertsToCelsius() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        _ = try await store.insert(Streams(skinTemp: [
            SkinTempSample(ts: 1_700_000_000, raw: 900),                                   // 4.0 ADC counts
            SkinTempSample(ts: 1_700_000_001, raw: 3508, unit: Whoop5HistoricalRecord.skinTempUnit),
        ]), deviceId: "dev1")
        let rows = try await store.skinTempSamples(deviceId: "dev1", from: 0, to: 2_000_000_000, limit: 10)
        XCTAssertEqual(rows.map(\.unit), ["raw_adc", "centi_celsius"])
        XCTAssertNil(rows[0].celsius, "no verified conversion for 4.0 ADC counts")
        XCTAssertEqual(try XCTUnwrap(rows[1].celsius), 35.08, accuracy: 1e-9)
    }
}
