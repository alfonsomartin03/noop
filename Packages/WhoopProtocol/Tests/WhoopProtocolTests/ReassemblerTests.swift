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
        // [type 40][seq][ts u32][sub u16][hr][rrn][rr u16 x2] = 14 bytes, padded to 16 by the builder
        let payload: [UInt8] = [40, 9, 0x10, 0x27, 0, 0, 0x00, 0x80, 72, 2, 0x20, 0x03, 0x2A, 0x03]
        let f = buildWhoop5Frame(payload: payload)
        let r = decodeWhoop5Realtime(f)
        XCTAssertEqual(r?.heartRate, 72)
        XCTAssertEqual(r?.timestamp, 10000)
        XCTAssertEqual(r?.subseconds, 0x8000)
        XCTAssertEqual(r?.rr, [800, 810])
    }

    func testRejectsOtherTypesAndBadCRC() {
        XCTAssertNil(decodeWhoop5Realtime(buildWhoop5CommandFrame(seq: 1, command: 11)))
        var f = buildWhoop5Frame(payload: [40, 1, 0, 0, 0, 0, 0, 0, 70, 0, 0, 0])
        f[16] ^= 0xFF   // corrupt a payload byte → CRC32 fails
        XCTAssertNil(decodeWhoop5Realtime(f))
    }
}

final class Whoop5HistoricalTests: XCTestCase {
    private func record(ts: UInt32, hr: UInt8, rr: [UInt16], g: (Float, Float, Float)) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 112)
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

    func testDropsImplausibleGravityButKeepsHeartRate() throws {
        let r = try XCTUnwrap(decodeWhoop5Historical(record(ts: 1_791_574_000, hr: 60, rr: [900], g: (9, 9, 9))))
        XCTAssertNil(r.gravity)
        XCTAssertEqual(r.heartRate, 60)
    }
}
