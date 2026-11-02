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
}
