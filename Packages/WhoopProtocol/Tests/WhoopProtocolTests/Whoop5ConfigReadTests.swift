import XCTest
@testable import WhoopProtocol

/// 121/128 named reads (#40, C08 preparation). SYNTHETIC frames only: the layout is one external source's
/// description (fw 50.42.1.0); no strap reply has been captured.
final class Whoop5ConfigReadTests: XCTestCase {
    private let keyName = "sigproc_wear_detect"

    /// Full response frame through NOOP's own builder, then the app decoder (as the probe would see it).
    private func response(cmd: UInt8 = 121, result: UInt8, semantic: [UInt8]) throws -> Whoop5CommandResponse {
        try XCTUnwrap(Whoop5CommandResponse.decode(buildWhoop5Frame(payload: [36, 77, cmd, 201, result] + semantic)))
    }

    private func semantic(key: String? = nil, value: [UInt8]) -> [UInt8] {
        let k = key.map { Whoop5ConfigRead.keyField($0)! } ?? [UInt8](repeating: 0, count: 32)
        return [1] + k + value + [UInt8](repeating: 0, count: 32 - value.count)
    }

    // MARK: requests

    func testExactRequestBytesForTheFourC08Reads() throws {
        XCTAssertEqual(Whoop5ConfigRead.c08Keys.count, 4)
        for key in Whoop5ConfigRead.c08Keys {
            let p = try XCTUnwrap(Whoop5ConfigRead.requestPayload(key), key.name)
            XCTAssertEqual(p.count, 33)
            XCTAssertEqual(p[0], 1)
            XCTAssertEqual(Array(p[1...key.name.utf8.count]), Array(key.name.utf8))
            XCTAssertTrue(p[(1 + key.name.utf8.count)...].allSatisfy { $0 == 0 }, "NUL padding")
            let frame = buildWhoop5CommandFrame(seq: 200, command: key.command, data: p)
            XCTAssertEqual(frame.count, 48, "36-byte payload needs no padding: 8 header + 36 + 4 CRC")
            XCTAssertTrue(verifyFrame(frame, family: .whoop5).ok)
        }
        XCTAssertEqual(Whoop5ConfigRead.c08Keys.filter { $0.command == 128 }.map(\.name), ["disable_pip_r26_packets"])
        // Pinned bytes for review: 121 sigproc_wear_detect.
        let first = try XCTUnwrap(Whoop5ConfigRead.requestPayload(Whoop5ConfigRead.c08Keys[0]))
        XCTAssertEqual(first.map { String(format: "%02x", $0) }.joined(),
                       "01" + "73696770726f635f776561725f646574656374" + String(repeating: "00", count: 13))
    }

    func testInvalidNamesAndCommandsAreRefused() {
        XCTAssertNil(Whoop5ConfigRead.keyField(""))
        XCTAssertNil(Whoop5ConfigRead.keyField(String(repeating: "a", count: 32)), "no room for the NUL")
        XCTAssertNotNil(Whoop5ConfigRead.keyField(String(repeating: "a", count: 31)))
        XCTAssertNil(Whoop5ConfigRead.keyField("has space"))
        XCTAssertNil(Whoop5ConfigRead.keyField("wear\u{0}x"))
        XCTAssertNil(Whoop5ConfigRead.keyField("é"))
        XCTAssertNil(Whoop5ConfigRead.requestPayload(command: 120, name: keyName), "SET twin range")
        XCTAssertNil(Whoop5ConfigRead.requestPayload(command: 115, name: keyName))
    }

    // MARK: padding

    func testSixtyFiveByteBodyArrivesAsSixtySevenAndIsAccepted() throws {
        XCTAssertEqual(Whoop5ConfigRead.alignmentPadding(semanticBody: 65), 2)
        XCTAssertEqual(Whoop5ConfigRead.alignmentPadding(semanticBody: 28), 3, "pack info 151: 28 → 31 observed")
        let r = try response(result: 1, semantic: semantic(key: keyName, value: Array("1".utf8)))
        XCTAssertEqual(r.body.count, 67)
        let reply = Whoop5ConfigRead.classify(r, name: keyName)
        XCTAssertEqual(reply.outcome, .value("1"))
        XCTAssertEqual(reply.semanticBody.count, 65)
        XCTAssertEqual(reply.rawBody, r.body, "raw bytes kept for the capture")
    }

    func testUnpaddedBodyAlsoAcceptedButOtherLengthsStop() {
        let s = semantic(key: keyName, value: Array("2".utf8))
        let bare = Whoop5CommandResponse(command: 121, appSeq: 1, strapSeq: 1, result: .success, body: s)
        XCTAssertEqual(Whoop5ConfigRead.classify(bare, name: keyName).outcome, .value("2"))
        for extra in [[0], [0, 0, 0], [0, 0, 0, 0]] as [[UInt8]] {
            let r = Whoop5CommandResponse(command: 121, appSeq: 1, strapSeq: 1, result: .success, body: s + extra)
            guard case .unexpected = Whoop5ConfigRead.classify(r, name: keyName).outcome else {
                return XCTFail("\(extra.count) padding bytes must stop")
            }
        }
        let short = Whoop5CommandResponse(command: 121, appSeq: 1, strapSeq: 1, result: .success, body: Array(s.prefix(64)))
        guard case .unexpected = Whoop5ConfigRead.classify(short, name: keyName).outcome else { return XCTFail("short") }
        let dirty = Whoop5CommandResponse(command: 121, appSeq: 1, strapSeq: 1, result: .success, body: s + [0, 7])
        XCTAssertEqual(Whoop5ConfigRead.classify(dirty, name: keyName).outcome, .unexpected("non-zero transport padding"))
    }

    // MARK: outcomes

    func testDecimalValues() throws {
        for v in ["0", "1", "2", "4096", "12.5"] {
            let r = try response(result: 1, semantic: semantic(key: keyName, value: Array(v.utf8)))
            XCTAssertEqual(Whoop5ConfigRead.classify(r, name: keyName).outcome, .value(v))
        }
        for v in ["-1", "1.25", ".5", "1.", "0x10", "on"] {
            let r = try response(result: 1, semantic: semantic(key: keyName, value: Array(v.utf8)))
            XCTAssertEqual(Whoop5ConfigRead.classify(r, name: keyName).outcome, .unexpected("value is not decimal text"), v)
        }
    }

    func testZeroValueFieldIsAFallbackNotAReadingOfZero() throws {
        let r = try response(result: 1, semantic: semantic(key: keyName, value: []))
        XCTAssertEqual(Whoop5ConfigRead.classify(r, name: keyName).outcome, .zeroFallback)
    }

    func testFailureShapes() throws {
        let unknown = try response(result: 0, semantic: semantic(key: keyName, value: []))
        XCTAssertEqual(Whoop5ConfigRead.classify(unknown, name: keyName).outcome, .keyUnknownOrUnreadable)
        let rev = try response(result: 0, semantic: semantic(key: nil, value: []))
        XCTAssertEqual(Whoop5ConfigRead.classify(rev, name: keyName).outcome, .revisionRejected)
        let odd = try response(result: 0, semantic: semantic(key: keyName, value: Array("1".utf8)))
        XCTAssertEqual(Whoop5ConfigRead.classify(odd, name: keyName).outcome, .unexpected("FAILURE with a non-zero value"))
    }

    func testUnsupportedAndPendingNeedNoBody() throws {
        let u = try response(result: 3, semantic: [0, 0, 0])
        XCTAssertEqual(Whoop5ConfigRead.classify(u, name: keyName).outcome, .unsupported)
        let p = try response(cmd: 128, result: 2, semantic: [])
        XCTAssertEqual(Whoop5ConfigRead.classify(p, name: "disable_pip_r26_packets").outcome, .pending)
        let other = try response(result: 9, semantic: [])
        XCTAssertEqual(Whoop5ConfigRead.classify(other, name: keyName).outcome, .unexpected("result 9"))
    }

    func testStopConditions() throws {
        let other = try response(result: 1, semantic: semantic(key: "cont_collection_mode", value: Array("1".utf8)))
        XCTAssertEqual(Whoop5ConfigRead.classify(other, name: keyName).outcome, .unexpected("key echo differs"))
        var s = semantic(key: keyName, value: Array("1".utf8)); s[0] = 2
        XCTAssertEqual(Whoop5ConfigRead.classify(try response(result: 1, semantic: s), name: keyName).outcome, .unexpected("revision 2"))
        var full = semantic(key: keyName, value: []); for i in 33..<65 { full[i] = 0x31 }
        XCTAssertEqual(Whoop5ConfigRead.classify(try response(result: 1, semantic: full), name: keyName).outcome,
                       .unexpected("value not NUL-terminated"))
        var tail = semantic(key: keyName, value: Array("1".utf8)); tail[40] = 0x35
        XCTAssertEqual(Whoop5ConfigRead.classify(try response(result: 1, semantic: tail), name: keyName).outcome,
                       .unexpected("bytes after the value's NUL"))
        let wrong = Whoop5CommandResponse(command: 151, appSeq: 1, strapSeq: 1, result: .success, body: [])
        XCTAssertEqual(Whoop5ConfigRead.classify(wrong, name: keyName).outcome, .unexpected("command 151 is not 121/128"))
    }
}
