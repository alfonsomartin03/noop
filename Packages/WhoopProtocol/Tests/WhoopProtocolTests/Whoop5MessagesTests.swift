import XCTest
@testable import WhoopProtocol

/// Typed WHOOP 5.0 decoders against frames captured from the owner's strap (fw 50.43.1.0).
final class Whoop5MessagesTests: XCTestCase {
    private static let frames: [String: [UInt8]] = {
        let url = Bundle.module.url(forResource: "whoop5_frames", withExtension: "json")!
        let list = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: String]]
        var out: [String: [UInt8]] = [:]
        for f in list { out[f["name"]!] = hexBytes(f["hex"]!) }
        return out
    }()
    private func frame(_ n: String) -> [UInt8] { Self.frames[n]! }

    private func response(_ n: String) throws -> Whoop5CommandResponse {
        try XCTUnwrap(Whoop5CommandResponse.decode(frame(n)), n)
    }

    // MARK: responses

    func testResultCodes() throws {
        XCTAssertEqual(try response("rx_get_data_range_pending").result, .pending)
        XCTAssertFalse(try response("rx_get_data_range_pending").isFinal)
        XCTAssertEqual(try response("rx_report_version_info_unsupported").result, .unsupported)
        XCTAssertEqual(try response("rx_get_battery_pack_info_failure").result, .failure)
        let ok = try response("rx_get_clock_success")
        XCTAssertEqual(ok.result, .success)
        XCTAssertEqual(ok.command, 11)
        XCTAssertEqual(ok.appSeq, 201)
        XCTAssertEqual(ok.strapSeq, 76)
    }

    func testCorruptResponseRejected() {
        var f = frame("rx_get_clock_success"); f[13] ^= 0xFF
        XCTAssertNil(Whoop5CommandResponse.decode(f))
    }

    func testClock() throws {
        let c = try Whoop5Clock.decode(response("rx_get_clock_success")).get()
        XCTAssertEqual(c.unix, 1_793_636_096)
        XCTAssertLessThan(c.subseconds, 32768)
        XCTAssertEqual(Whoop5Clock.decode(try response("rx_get_data_range_success")), .failure(.wrongCommand(34)))
    }

    func testBattery() throws {
        XCTAssertEqual(whoop5BatteryPercent(try response("rx_get_battery_level_success")), 20)
        XCTAssertNil(whoop5BatteryPercent(try response("rx_get_clock_success")))
    }

    // MARK: data range

    func testDataRangeFields() throws {
        let r = try Whoop5DataRange.decode(response("rx_get_data_range_success")).get()
        XCTAssertEqual(r.trimPage, 104_038)        // = last ack sent before E02
        XCTAssertEqual(r.trimBlock, 15)
        XCTAssertEqual(r.oldestUnix, 1_791_749_559)
        XCTAssertEqual(r.lastSyncedUnix, 1_793_635_031)   // 10:57:11, the previous pull's last record
        XCTAssertEqual(r.newestUnix, 1_793_636_085)       // 11:14:45, ≈ strap clock at the request
        XCTAssertLessThan(r.lastSyncedUnix, r.newestUnix)
    }

    func testDataRangePendingIsNotARange() throws {
        XCTAssertEqual(Whoop5DataRange.decode(try response("rx_get_data_range_pending")), .failure(.notSuccess(.pending)))
    }

    func testDataRangeTruncatedAndImplausible() throws {
        let r = try response("rx_get_data_range_success")
        let short = Whoop5CommandResponse(command: 34, appSeq: 1, strapSeq: 1, result: .success, body: Array(r.body.prefix(40)))
        XCTAssertEqual(Whoop5DataRange.decode(short), .failure(.truncated(need: 65, have: 40)))
        var body = r.body; body[57] = 0; body[58] = 0; body[59] = 0; body[60] = 0
        let zero = Whoop5CommandResponse(command: 34, appSeq: 1, strapSeq: 1, result: .success, body: body)
        guard case .failure(.implausible) = Whoop5DataRange.decode(zero) else { return XCTFail("zero newest accepted") }
        let other = Whoop5CommandResponse(command: 11, appSeq: 1, strapSeq: 1, result: .success, body: r.body)
        XCTAssertEqual(Whoop5DataRange.decode(other), .failure(.wrongCommand(11)))
    }

    // MARK: history metadata

    func testHistoryEnd() throws {
        let m = try XCTUnwrap(Whoop5HistoryMeta.decode(frame("rx_history_end_app_log")))
        guard case .end(_, let endData) = m else { return XCTFail("not END") }
        XCTAssertEqual(endData, hexBytes("c58601000f000000"))
        XCTAssertEqual(m.trimPosition?.page, 0x186C5)
        XCTAssertEqual(m.trimPosition?.block, 15)
        guard case .start = try XCTUnwrap(Whoop5HistoryMeta.decode(frame("rx_history_start"))) else { return XCTFail("not START") }
    }

    // MARK: events

    func testEventsDecodeWithConsistentLength() throws {
        let cases: [(String, Whoop5EventKind, Int)] = [
            ("rx_strap_condition_report", .strapConditionReport, 12),
            ("rx_ble_connection_down", .connectionDown, 0),
            ("rx_ble_connection_up", .connectionUp, 0),
            ("rx_event110", .unknown(110), 8),
            ("rx_event120", .unknown(120), 32),
            ("rx_event123", .unknown(123), 8),
        ]
        for (name, kind, len) in cases {
            let e = try Whoop5Event.decode(frame(name)).get()
            XCTAssertEqual(e.kind, kind, name)
            XCTAssertEqual(e.body.count, len, name)
            XCTAssertTrue(isPlausibleUnix(e.unix), name)
        }
    }

    func testBatteryEventLayout() throws {
        // Event 3 body captured 2026-11-02 11:47 (2A19 read 20 % at the time).
        let body = hexBytes("02c80000007a0e00000000371001001301000000")
        var p: [UInt8] = [48, 1, 3, 0, 0x40, 0xB6, 0xE8, 0x6A, 0x47, 0x61, UInt8(body.count), 0]
        p += body
        let e = try Whoop5Event.decode(buildWhoop5Frame(payload: p)).get()
        XCTAssertEqual(e.kind, .batteryLevel)
        let b = try XCTUnwrap(e.batteryCandidate)
        XCTAssertEqual(b.socPercent, 20.0)
        XCTAssertEqual(b.millivolts, 3706)
        XCTAssertFalse(b.charging)
        // Captured 2026-11-09 while charging on the pack (32.6 %, 3920 mV): byte 9 = 1.
        let chg = hexBytes("0246010000500f000001002b1202001001000000")
        var q: [UInt8] = [48, 1, 3, 0, 0x40, 0xB6, 0xE8, 0x6A, 0x47, 0x61, UInt8(chg.count), 0]
        q += chg
        let c = try XCTUnwrap(try Whoop5Event.decode(buildWhoop5Frame(payload: q)).get().batteryCandidate)
        XCTAssertEqual(c.socPercent, 32.6)
        XCTAssertEqual(c.millivolts, 3920)
        XCTAssertTrue(c.charging)
        XCTAssertEqual(Whoop5EventKind(33), .realtimeHROn)
        XCTAssertEqual(Whoop5EventKind(34), .realtimeHROff)
    }

    // MARK: alarms / haptics (live H02–H07 frames)

    func testAlarmIdZeroRejectedIdOneAccepted() throws {
        let bad = try response("rx_cmd66_res0_h02")
        XCTAssertEqual(bad.result, .failure)
        XCTAssertEqual(Whoop5Alarm.status(bad), .invalidAlarmID)
        let ok = try response("rx_cmd66_res1_h02b")
        XCTAssertEqual(ok.result, .success)
        XCTAssertEqual(Whoop5Alarm.status(ok), .validPattern)
    }

    func testAlarmReadbackAndEmptySlot() throws {
        XCTAssertEqual(Whoop5Alarm.storedTime(try response("rx_cmd67_res1_h02b")), 1_793_643_447)
        XCTAssertNil(Whoop5Alarm.storedTime(try response("rx_cmd67_res0_h05")))
    }

    func testRunAlarmAndBuzzPlay() throws {
        XCTAssertEqual(Whoop5Alarm.status(try response("rx_cmd68_res1_h02b")), .successfulPlay)
        XCTAssertEqual(Whoop5Alarm.status(try response("rx_cmd19_res1_h07")), .successfulPlay)
        XCTAssertEqual(try response("rx_cmd69_res1_h05").result, .success)
    }

    func testLiveAlarmEvents() throws {
        XCTAssertEqual(try Whoop5Event.decode(frame("rx_live_event56_h02b")).get().kind, .alarmSet)
        XCTAssertEqual(try Whoop5Event.decode(frame("rx_live_event58_h02b")).get().kind, .appAlarmExecuted)
        XCTAssertEqual(try Whoop5Event.decode(frame("rx_live_event60_h07")).get().kind, .hapticsFired)
        XCTAssertEqual(try Whoop5Event.decode(frame("rx_live_event14_h02b")).get().kind, .doubleTap)
        let term = try Whoop5Event.decode(frame("rx_live_event100_h02b")).get()
        XCTAssertEqual(term.kind, .hapticsTerminated)
        XCTAssertEqual(term.body[1], 2)          // user terminated
        XCTAssertEqual(try Whoop5Event.decode(frame("rx_live_event100_h07")).get().body[1], 0)   // expired
    }

    func testAlarmPayloadsMatchWhatTheStrapAccepted() {
        // The accepted H02b SET frame (seq 202): rebuilt byte for byte from the typed builder.
        let f = buildWhoop5CommandFrame(seq: 202, command: 66, data: Whoop5Alarm.setPayload(strapSeconds: 1_793_643_447))
        XCTAssertEqual(f, hexBytes("aa011c000001e38123ca420401b7d3e86a00002f980000000000000000071e00625d8a8d"))
    }

    func testUnknownEventKeepsBody() throws {
        let e = try Whoop5Event.decode(frame("rx_event120")).get()
        XCTAssertEqual(e.number, 120)
        XCTAssertEqual(e.kind.name, "EVENT_120")
        XCTAssertFalse(e.body.isEmpty)
    }

    func testEventTruncatedBodyRejected() throws {
        // Rebuild an event whose declared body length runs past the payload.
        var p = Array(try XCTUnwrap(whoop5Payload(frame("rx_event110"))))
        p[10] = 0xF0
        let f = buildWhoop5Frame(payload: p)
        guard case .failure(.truncated) = Whoop5Event.decode(f) else { return XCTFail("overlong body accepted") }
        XCTAssertEqual(Whoop5Event.decode(frame("rx_get_clock_success")), .failure(.wrongType(36)))
    }

    // MARK: realtime

    func testRealtimeLayout() throws {
        // Synthetic frame in the E04 layout (real frames are biometric and not committed).
        let ts = 1_793_636_929
        let payload: [UInt8] = [40, 0x02, UInt8(ts & 0xFF), UInt8(ts >> 8 & 0xFF), UInt8(ts >> 16 & 0xFF), UInt8(ts >> 24 & 0xFF),
                                0x47, 0x41, 69, 0] + [UInt8](repeating: 0, count: 8) + [1, 0]
        let rt = try XCTUnwrap(decodeWhoop5Realtime(buildWhoop5Frame(payload: payload)))
        XCTAssertEqual(rt.timestamp, UInt32(ts))
        XCTAssertEqual(rt.heartRate, 69)
        XCTAssertEqual(rt.rr, [])
        var bad = payload; bad[2...5] = [0, 0, 0, 0]
        XCTAssertNil(decodeWhoop5Realtime(buildWhoop5Frame(payload: bad)), "implausible timestamp accepted")
    }
}

func hexBytes(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}
