import XCTest
@testable import NOOP

final class RawHistoryArchiveTests: XCTestCase {
    func testAppendsDurablyAndKeepsEveryFrame() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RawHistoryArchive(directory: dir)
        let day = Date(timeIntervalSince1970: 1_793_640_000)
        let a: [UInt8] = [0xAA, 0x01, 0x04, 0x00, 0x01, 0x00, 0, 0, 47, 0x1A, 1, 2]
        try archive.append([a], receivedAt: day)
        try archive.append([a, a], receivedAt: day)          // second call appends, never truncates
        try archive.append([], receivedAt: day)              // no-op
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, 1)
        let text = try String(contentsOf: dir.appendingPathComponent(files[0]), encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("\"version\":26"))
        XCTAssertTrue(lines[0].contains("aa010400010000002f1a0102"))
    }

    func testUnwritableDirectoryThrows() {
        let archive = RawHistoryArchive(directory: URL(fileURLWithPath: "/dev/null/nope"))
        XCTAssertThrowsError(try archive.append([[0xAA]]))
    }

    func testProvenanceAndRecordTimesAreWrittenPerLine() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RawHistoryArchive(directory: dir)
        let a: [UInt8] = [0xAA, 0x01, 0x04, 0x00, 0x01, 0x00, 0, 0, 47, 0x12, 1, 2]
        let p = RawHistoryArchive.Provenance(capture: "r18-test", firmware: "50.43.1.0", hardware: "WG50_r52")
        let bytes = try archive.append([a, a], receivedAt: Date(timeIntervalSince1970: 1_793_640_000),
                                       recordTimes: [1_793_639_000, nil], provenance: p)
        let file = try FileManager.default.contentsOfDirectory(atPath: dir.path)[0]
        let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
        XCTAssertEqual(bytes, text.utf8.count)
        let lines = text.split(separator: "\n").map { try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(lines[0]["ts"] as? Int, 1_793_639_000)
        XCTAssertNil(lines[1]["ts"])                                  // unknown record time: omitted, never 0
        for l in lines {
            XCTAssertEqual(l["capture"] as? String, "r18-test")
            XCTAssertEqual(l["fw"] as? String, "50.43.1.0")
            XCTAssertEqual(l["hw"] as? String, "WG50_r52")
            XCTAssertEqual(l["version"] as? Int, 0x12)
            XCTAssertEqual(l["hex"] as? String, "aa010400010000002f120102")
        }
    }

    func testResearchCaptureIsBoundedInTimeAndSize() {
        let t0 = Date(timeIntervalSince1970: 1_793_640_000)
        let c = ResearchCapture.start(now: t0, duration: 30 * 86_400)
        XCTAssertEqual(c.until.timeIntervalSince(t0), ResearchCapture.maxDuration)   // clamped to 7 days
        XCTAssertTrue(c.isActive(at: t0))
        XCTAssertTrue(c.isActive(at: t0.addingTimeInterval(ResearchCapture.maxDuration - 1)))
        XCTAssertFalse(c.isActive(at: t0.addingTimeInterval(ResearchCapture.maxDuration)))
        XCTAssertFalse(c.isActive(at: t0.addingTimeInterval(-1)))
        var full = c
        full.bytesWritten = ResearchCapture.maxBytes - 10
        XCTAssertTrue(full.isActive(at: t0))
        XCTAssertTrue(full.wouldExceed(11))
        XCTAssertFalse(full.wouldExceed(10))
        var stopped = c
        stopped.stoppedReason = "stopped by you"
        XCTAssertFalse(stopped.isActive(at: t0))
    }

    func testResearchCaptureRoundTripsThroughDefaults() throws {
        let suite = "noop.test.research.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertNil(ResearchCapture.load(d))
        var c = ResearchCapture.start(now: Date(timeIntervalSince1970: 1_793_640_000))
        c.bytesWritten = 1234
        c.save(d)
        XCTAssertEqual(ResearchCapture.load(d), c)
        XCTAssertTrue(c.id.hasPrefix("r18-"))
        ResearchCapture.clear(d)
        XCTAssertNil(ResearchCapture.load(d))
    }

    func testResearchFilterKeepsDistinctFramesThatShareARecordTime() {
        var f = ResearchFrameFilter()
        // Two different type-47 frames carrying the same record time: both are evidence and both must be kept.
        let a: [UInt8] = [0xAA, 0x01, 0x04, 0x00, 0x01, 0x00, 0, 0, 47, 0x12, 0x10, 0x20, 0x30, 0x40, 1]
        var b = a; b[14] = 2
        XCTAssertTrue(f.admit(a))
        XCTAssertTrue(f.admit(b), "same timestamp, different bytes: kept")
        XCTAssertFalse(f.admit(a), "an exact repeat (re-sent chunk) is dropped")
        var next = ResearchFrameFilter()
        XCTAssertTrue(next.admit(a), "a new pull starts empty")
    }
}
