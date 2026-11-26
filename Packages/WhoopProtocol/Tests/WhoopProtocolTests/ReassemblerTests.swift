import XCTest
@testable import WhoopProtocol

final class ReassemblerTests: XCTestCase {
    // Build a real ~1928-byte type-43 frame from a 1917-byte synthetic payload so the
    // test is self-contained (no capture dependency): inner = 1917+3, length = 1924,
    // total = 1928. Reassembly must reproduce it exactly from 244-byte fragments.
    private func bigFrame() -> [UInt8] {
        let payload = (0..<1917).map { UInt8($0 & 0xFF) }
        return frameFromPayload(payload, type: 43, seq: 7, cmd: 0)
    }

    func testReassembleFromFragments() {
        let frame = bigFrame()
        XCTAssertEqual(frame.count, 1928)
        var fragments: [[UInt8]] = []
        var i = 0
        while i < frame.count {
            fragments.append(Array(frame[i..<min(i + 244, frame.count)]))
            i += 244
        }
        XCTAssertEqual(fragments.count, 8)
        // Only the first fragment carries the 0xAA SOF.
        XCTAssertEqual(fragments[0].first, 0xAA)
        for f in fragments.dropFirst() {
            XCTAssertNotEqual(f.first, 0xAA)
        }
        let r = Reassembler()
        var assembled: [[UInt8]] = []
        for f in fragments {
            assembled.append(contentsOf: r.feed(f))
        }
        XCTAssertEqual(assembled.count, 1)
        XCTAssertEqual(assembled[0], frame)
    }

    func testTwoFramesInOneFeed() {
        let a = frameFromPayload([0x01, 0x02], type: 40)
        let b = frameFromPayload([0x03, 0x04], type: 48)
        let r = Reassembler()
        let out = r.feed(a + b)
        XCTAssertEqual(out, [a, b])
    }

    // Bytes before the first 0xAA are discarded.
    func testLeadingGarbageIsSkipped() {
        let a = frameFromPayload([0x09], type: 40)
        let r = Reassembler()
        let out = r.feed([0x11, 0x22, 0x33] + a)
        XCTAssertEqual(out, [a])
    }

    func testPartialFrameWaitsForRest() {
        let a = frameFromPayload([0x01, 0x02, 0x03, 0x04], type: 40)
        let r = Reassembler()
        XCTAssertTrue(r.feed(Array(a[0..<5])).isEmpty)        // header + part
        XCTAssertEqual(r.feed(Array(a[5..<a.count])), [a])    // remainder completes it
    }
}

// 5.0 frames use a different length field and +8 total size.
final class ReassemblerWhoop5Tests: XCTestCase {
    func testWhoop5HelloSplitAcrossFragmentsReassembles() {
        let hello = DeviceFamily.whoop5ClientHello
        let r = Reassembler(family: .whoop5)
        XCTAssertTrue(r.feed(Array(hello[0..<5])).isEmpty)
        XCTAssertTrue(r.feed(Array(hello[5..<11])).isEmpty)
        let frames = r.feed(Array(hello[11...]))
        XCTAssertEqual(frames, [hello])
        XCTAssertTrue(verifyFrame(frames[0], family: .whoop5).ok)
    }

    func testWhoop5TwoBackToBackFrames() {
        let hello = DeviceFamily.whoop5ClientHello
        let r = Reassembler(family: .whoop5)
        XCTAssertEqual(r.feed(hello + hello), [hello, hello])
    }

    func testWhoop4DefaultUnchanged() {
        let f = frameFromPayload([1, 2, 3], type: 36)
        XCTAssertEqual(Reassembler().feed(f), [f])
    }
}

// The frame builder must reproduce the known-good captured hello byte-for-byte.
final class Whoop5CommandFramingTests: XCTestCase {
    func testBuilderReproducesStaticClientHello() {
        // payload of the Goose CLIENT_HELLO: type 35, seq 1, 0x91, 0x01 (already 4-byte aligned)
        XCTAssertEqual(buildWhoop5Frame(payload: [0x23, 0x01, 0x91, 0x01]), DeviceFamily.whoop5ClientHello)
    }

    func testCommandFramePadsAndVerifies() {
        let f = buildWhoop5CommandFrame(seq: 7, command: 11)          // [35,7,11] → padded to 4
        XCTAssertEqual(f.count, 8 + 4 + 4)
        let chk = verifyFrame(f, family: .whoop5)
        XCTAssertTrue(chk.ok)
        XCTAssertEqual(f[8], 35); XCTAssertEqual(f[9], 7); XCTAssertEqual(f[10], 11)
        XCTAssertEqual(parseFrame(f, family: .whoop5).seq, 7)
    }

    func testCommandFrameWithDataRoundTripsThroughReassembler() {
        let f = buildWhoop5CommandFrame(seq: 1, command: 3, data: [1])
        XCTAssertTrue(verifyFrame(f, family: .whoop5).ok)
        XCTAssertEqual(Reassembler(family: .whoop5).feed(f), [f])
    }
}

final class Whoop5RealtimeTests: XCTestCase {
    func testDecodesHypothesisLayout() {
        // [type 40][kind 0x02][ts u32][sub u16][hr][rrn][rr u16 x2] = 14 bytes, padded to 16 by the builder
        let payload: [UInt8] = [40, 0x02, 0x41, 0xBA, 0xE8, 0x6A, 0x00, 0x80, 72, 2, 0x20, 0x03, 0x2A, 0x03]  // ts 2026-11-02
        let f = buildWhoop5Frame(payload: payload)
        let r = decodeWhoop5Realtime(f)
        XCTAssertEqual(r?.heartRate, 72)
        XCTAssertEqual(r?.timestamp, 1_793_636_929)
        XCTAssertEqual(r?.subseconds, 0x8000)
        XCTAssertEqual(r?.rr, [800, 810])
        XCTAssertEqual(r?.rrTruncated, false)
    }

    // #39: synthetic boundary cases; they prove the parser's bounds, not that the strap sends such packets.
    private let ts: [UInt8] = [0x41, 0xBA, 0xE8, 0x6A]   // 2026-11-02, plausible
    private func frame(_ payload: [UInt8]) -> [UInt8] { buildWhoop5Frame(payload: payload) }

    func testShortPrefixIsRejectedNeverReadFromTheCRC() {
        // 8 payload bytes: type, kind, ts, then nothing for subsec/HR/count. CRC verifies; HR must not come from the trailer.
        let f = frame([40, 0x02] + ts + [0, 0])
        XCTAssertTrue(verifyFrame(f, family: .whoop5).ok)
        XCTAssertNil(decodeWhoop5Realtime(f))
        // 9 bytes are padded to 12 and the length field counts the padding: the missing count byte reads as a padding
        // zero (indistinguishable at this layer). The HR byte is genuinely in the payload, so HR is kept with no R-R.
        let nine = decodeWhoop5Realtime(frame([40, 0x02] + ts + [0, 0, 70]))
        XCTAssertEqual(nine?.heartRate, 70)
        XCTAssertEqual(nine?.rr, [])
        XCTAssertNil(decodeWhoop5Realtime(Array(f.prefix(8))), "header only")
    }

    func testCountOverrunKeepsHeartRateAndFlagsTruncation() throws {
        // HR 60, declared 255 intervals, one zero word present (the reviewer's reproducer).
        let r = try XCTUnwrap(decodeWhoop5Realtime(frame([40, 0x02] + ts + [0, 0, 60, 255, 0, 0])))
        XCTAssertEqual(r.heartRate, 60)
        XCTAssertEqual(r.rr, [])
        XCTAssertTrue(r.rrTruncated)
        // Two declared, one present, payload ends exactly there (no padding): the second word would be the CRC trailer.
        let one = try XCTUnwrap(decodeWhoop5Realtime(frame([40, 0x02] + ts + [0, 0, 61, 2, 0x20, 0x03])))
        XCTAssertTrue(one.rrTruncated, "intervals are never read from the CRC trailer")
    }

    func testZeroWordsTrailingPaddingAndCountZero() throws {
        let zero = try XCTUnwrap(decodeWhoop5Realtime(frame([40, 0x02] + ts + [0, 0, 62, 2, 0, 0, 0x20, 0x03])))
        XCTAssertEqual(zero.rr, [800], "zero words are dropped, real ones kept")
        XCTAssertFalse(zero.rrTruncated)
        let padded = try XCTUnwrap(decodeWhoop5Realtime(frame([40, 0x02] + ts + [0, 0, 63, 1, 0x20, 0x03] + [UInt8](repeating: 0xEE, count: 6))))
        XCTAssertEqual(padded.rr, [800], "bytes after the declared words are ignored")
        let none = try XCTUnwrap(decodeWhoop5Realtime(frame([40, 0x02] + ts + [0, 0, 64, 0])))
        XCTAssertEqual(none.heartRate, 64, "a well-formed packet with no intervals keeps its BPM")
        XCTAssertEqual(none.rr, [])
        XCTAssertFalse(none.rrTruncated)
    }

    func testUnknownKindIsRejected() {
        XCTAssertNil(decodeWhoop5Realtime(frame([40, 9] + ts + [0, 0, 70, 0])), "only kind 0x02 is a confirmed layout")
        XCTAssertNotNil(decodeWhoop5Realtime(frame([40, 0x02] + ts + [0, 0, 70, 0])))
    }

    func testRejectsOtherTypesAndBadCRC() {
        XCTAssertNil(decodeWhoop5Realtime(buildWhoop5CommandFrame(seq: 1, command: 11)))
        var f = buildWhoop5Frame(payload: [40, 1, 0, 0, 0, 0, 0, 0, 70, 0, 0, 0])
        f[16] ^= 0xFF   // corrupt a payload byte → CRC32 fails
        XCTAssertNil(decodeWhoop5Realtime(f))
    }
}

// Checks the decoded stored-record layout and its sanity filters.
final class Whoop5HistoricalTests: XCTestCase {
    private func record(ts: UInt32, hr: UInt8, rr: [UInt16], g: (Float, Float, Float), skin: UInt16 = 0,
                        steps: UInt16 = 0, activity: UInt8 = 0) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 112)
        p[65] = UInt8(skin & 0xFF); p[66] = UInt8(skin >> 8)
        p[49] = UInt8(steps & 0xFF); p[50] = UInt8(steps >> 8); p[55] = activity
        p[0] = 47; p[1] = 0x12
        for i in 0..<4 { p[7 + i] = UInt8((ts >> (8 * UInt32(i))) & 0xFF) }
        p[14] = hr; p[15] = UInt8(rr.count)
        for (i, v) in rr.enumerated() { p[16 + 2 * i] = UInt8(v & 0xFF); p[17 + 2 * i] = UInt8(v >> 8) }
        for (k, val) in [g.0, g.1, g.2].enumerated() {
            let b = val.bitPattern
            for i in 0..<4 { p[37 + 4 * k + i] = UInt8((b >> (8 * UInt32(i))) & 0xFF) }
        }
        return buildWhoop5Frame(payload: p)
    }

    func testDecodesVerifiedLayout() throws {
        let f = record(ts: 1_791_574_000, hr: 73, rr: [774, 829], g: (-0.47, 0.48, 0.74))
        XCTAssertEqual(f.count, 124)
        let r = try XCTUnwrap(decodeWhoop5Historical(f))
        XCTAssertEqual(r.timestamp, 1_791_574_000)
        XCTAssertEqual(r.heartRate, 73)
        XCTAssertEqual(r.rr, [774, 829])
        XCTAssertEqual(try XCTUnwrap(r.gravity).z, 0.74, accuracy: 0.001)
    }

    func testRejectsWrongVersionBadCRCAndImplausibleTime() {
        var f = record(ts: 1_791_574_000, hr: 70, rr: [], g: (0, 0, 1))
        f[9] = 0x13   // different record version → unverified, must not decode
        XCTAssertNil(decodeWhoop5Historical(f))
        var g = record(ts: 1_791_574_000, hr: 70, rr: [], g: (0, 0, 1)); g[30] ^= 0xFF
        XCTAssertNil(decodeWhoop5Historical(g))
        XCTAssertNil(decodeWhoop5Historical(record(ts: 5, hr: 70, rr: [], g: (0, 0, 1))))
    }

    func testDecodesSkinTemperatureInCentiCelsius() throws {
        let r = try XCTUnwrap(decodeWhoop5Historical(record(ts: 1_791_574_000, hr: 58, rr: [], g: (0, 0, 1), skin: 3508)))
        XCTAssertEqual(r.skinTempCentiC, 3508)                     // 35.08 °C
        XCTAssertEqual(r.heartRate, 58)
        XCTAssertEqual(Whoop5HistoricalRecord.skinTempUnit, "centi_celsius")
    }

    func testImplausibleSkinTemperatureIsMissingNotZero() throws {
        for raw: UInt16 in [0, 499, 4501, 0xFFFF] {
            let r = try XCTUnwrap(decodeWhoop5Historical(record(ts: 1_791_574_000, hr: 60, rr: [], g: (0, 0, 1), skin: raw)))
            XCTAssertNil(r.skinTempCentiC, "raw \(raw)")
            XCTAssertEqual(r.heartRate, 60, "other fields still decode")
        }
        for raw: UInt16 in [500, 4500] {
            XCTAssertEqual(decodeWhoop5Historical(record(ts: 1_791_574_000, hr: 60, rr: [], g: (0, 0, 1), skin: raw))?.skinTempCentiC, Int(raw))
        }
    }

    func testDecodesStepCounterAndActivityCode() throws {
        let r = try XCTUnwrap(decodeWhoop5Historical(record(ts: 1_791_574_000, hr: 92, rr: [], g: (0, 0, 1), steps: 7452, activity: 1)))
        XCTAssertEqual(r.stepCounter, 7452)
        XCTAssertEqual(r.activity, 1)
        XCTAssertEqual(r.heartRate, 92)
    }

    func testStepChangePointsAndWindowCounting() {
        func s(_ ts: Int, _ c: Int, _ a: Int = 0) -> StepCounterSample { StepCounterSample(ts: ts, counter: c, activity: a) }
        // Every second for 10 s: still, then walking (+6, +1, +2), then still again; duplicate second ignored.
        let raw = [s(0, 100), s(1, 100), s(2, 100, 1), s(3, 106, 1), s(4, 107, 1), s(5, 109, 1),
                   s(6, 109), s(7, 109), s(8, 109), s(9, 109)].shuffled() + [s(3, 999, 1)]
        // Conflicting duplicate comes last: the first input reading at that second must win.
        XCTAssertEqual(StepCounterSample.changePoints([s(3, 999, 1), s(3, 106, 1)]), [s(3, 999, 1)])
        let cp = StepCounterSample.changePoints(raw)
        XCTAssertEqual(cp, [s(0, 100), s(2, 100, 1), s(3, 106, 1), s(4, 107, 1), s(5, 109, 1), s(6, 109)])
        let w = StepCounterSample.window(cp, from: 1, to: 10)
        XCTAssertEqual(w, .init(steps: 9, resets: 0, hasStartReference: true, activityOneSeconds: 4, activityTwoSeconds: 0,
                                unknownSeconds: 0, spanSeconds: 9))
        XCTAssertEqual(w.syncedSeconds, 9)
        XCTAssertEqual(StepCounterSample.window(cp, from: 3, to: 5).steps, 1, "increase at `from` belongs before the window")
        XCTAssertFalse(StepCounterSample.window(cp, from: -5, to: 10).hasStartReference)
        // A drop is a reset: never negative, never the old total; the post-reset value is steps since the reset.
        let reset = StepCounterSample.window([s(0, 10_000), s(5, 10_010), s(6, 3), s(9, 8)], from: 0, to: 10)
        XCTAssertEqual(reset.steps, 10 + 3 + 5)
        XCTAssertEqual(reset.resets, 1)
    }

    func testRunningTimeAndClippingAtTheEndOfKnownData() {
        func s(_ ts: Int, _ c: Int, _ a: Int) -> StepCounterSample { StepCounterSample(ts: ts, counter: c, activity: a) }
        // Walk 100 s, run 60 s, still; the day runs to 1000 but data is known only to 300.
        let rows = [s(0, 0, 0), s(100, 0, 1), s(200, 150, 2), s(260, 320, 0)]
        let w = StepCounterSample.window(rows, from: 0, to: 1000, until: 300)
        XCTAssertEqual(w.steps, 320)
        XCTAssertEqual(w.activityOneSeconds, 100)
        XCTAssertEqual(w.activityTwoSeconds, 60)
        // Still running at the last sync: running time stops at the end of known data, never at the end of the day.
        let open = StepCounterSample.window(Array(rows.prefix(3)), from: 0, to: 1000, until: 230)
        XCTAssertEqual(open.activityTwoSeconds, 30)
    }

    func testActivityStopsAtInteriorGapsAndGapsMakeTheCountAtLeast() {
        func s(_ ts: Int, _ c: Int, _ a: Int) -> StepCounterSample { StepCounterSample(ts: ts, counter: c, activity: a) }
        XCTAssertEqual(StepCounterSample.knownRuns([5, 3, 4, 4, 9, 10]), [3..<6, 9..<11])
        // Walking starts at 100; records for 150..<450 never synced; the next change point (still) is at 500.
        let rows = [s(0, 0, 0), s(100, 0, 1), s(500, 400, 0)]
        let known = StepCounterSample.knownRuns(Array(0..<150) + Array(450..<600))
        let gap = StepCounterSample.window(rows, from: 0, to: 600, until: 600, known: known)
        XCTAssertEqual(gap.activityOneSeconds, 50 + 50, "only synced seconds count: 100..<150 and 450..<500, not the gap")
        XCTAssertEqual(gap.unknownSeconds, 300)
        XCTAssertEqual(gap.spanSeconds, 600)
        XCTAssertEqual(gap.syncedSeconds, 300, "walking + running never exceed synced time")
        XCTAssertEqual(gap.steps, 400, "increases across a gap are still real steps")
        XCTAssertFalse(gap.isComplete, "a reset hidden in the gap could lose steps: the count is at least 400")
        // Without `known` the old assumption (continuous between change points) is kept; fully synced data agrees with it.
        XCTAssertEqual(StepCounterSample.window(rows, from: 0, to: 600, until: 600).activityOneSeconds, 400)
        let full = StepCounterSample.window(rows, from: 0, to: 600, until: 600, known: StepCounterSample.knownRuns(Array(0..<600)))
        XCTAssertEqual(full.activityOneSeconds, 400)
        XCTAssertEqual(full.unknownSeconds, 0)
        XCTAssertTrue(full.isComplete)
        // An older row is a reference only if `from` itself synced: across a gap it could carry another day's steps.
        let late = [s(-7200, 5_000, 0), s(1200, 5_900, 0), s(1300, 6_000, 0)]
        let noRef = StepCounterSample.window(late, from: 0, to: 2000, until: 2000,
                                             known: StepCounterSample.knownRuns(Array(1200..<2000)))
        XCTAssertFalse(noRef.hasStartReference)
        XCTAssertEqual(noRef.steps, 100, "the 900 before the first synced row may belong to yesterday")
        XCTAssertEqual(StepCounterSample.window(late, from: 0, to: 2000, until: 2000,
                                                known: StepCounterSample.knownRuns(Array(-7200..<2000))).steps, 1_000)
        // Time past the end of known data is not "unknown inside the window": it is clipped, as before.
        let clipped = StepCounterSample.window(rows, from: 0, to: 1000, until: 600, known: known)
        XCTAssertEqual(clipped.unknownSeconds, 300)
        XCTAssertEqual(clipped.spanSeconds, 600, "the span stops at the end of known data, never at the end of the day")
    }

    func testDropsImplausibleGravityButKeepsHeartRate() throws {
        let r = try XCTUnwrap(decodeWhoop5Historical(record(ts: 1_791_574_000, hr: 60, rr: [900], g: (9, 9, 9))))
        XCTAssertNil(r.gravity)
        XCTAssertEqual(r.heartRate, 60)
    }
}

/// #39 live R-R evidence tally (synthetic packets).
final class Whoop5RealtimeTallyTests: XCTestCase {
    private func rt(_ t: UInt32, rr: [Int] = [], truncated: Bool = false) -> Whoop5Realtime {
        Whoop5Realtime(timestamp: t, subseconds: 0, heartRate: 60, rr: rr, rrTruncated: truncated)
    }

    func testCountsPacketsIntervalsTruncationAndLengths() {
        var t = Whoop5RealtimeTally()
        t.add(rt(1_795_000_000), frameLength: 32)
        t.add(rt(1_795_000_001, rr: [1000]), frameLength: 32)
        t.add(rt(1_795_000_002, rr: [990, 1010]), frameLength: 36)
        t.add(rt(1_795_000_003, truncated: true), frameLength: 32)
        XCTAssertEqual(t.packets, 4)
        XCTAssertEqual(t.withIntervals, 2)
        XCTAssertEqual(t.words, 3)
        XCTAssertEqual(t.maxCount, 2)
        XCTAssertEqual(t.truncated, 1)
        XCTAssertEqual(t.frameLengths, [32: 3, 36: 1])
        XCTAssertEqual(t.summary, "Live R-R: 4 packet(s) over 4 s; 2 with intervals (3 word(s), max 2/packet); 1 truncated; lengths 32 B×3, 36 B×1")
        XCTAssertFalse(t.summary.contains("1000"), "interval values never reach the log")
    }

    func testSessionBoundaries() {
        var t = Whoop5RealtimeTally()
        XCTAssertFalse(t.startsNewSession(rt(100)), "first packet")
        t.add(rt(1_795_000_000), frameLength: 32)
        XCTAssertFalse(t.startsNewSession(rt(1_795_000_010)), "10-s gap is the same stream")
        XCTAssertTrue(t.startsNewSession(rt(1_795_000_011)))
        XCTAssertTrue(t.startsNewSession(rt(1_794_999_999)), "clock went back (e.g. after SET_CLOCK)")
        XCTAssertEqual(Whoop5RealtimeTally().summary, "Live R-R: 0 packet(s) over 0 s; 0 with intervals (0 word(s), max 0/packet); 0 truncated; lengths -")
    }
}
