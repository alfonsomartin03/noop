import XCTest
import ZIPFoundation
@testable import StrandImport

final class ImportCoordinatorTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDownWithError() throws {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs.removeAll()
    }

    private func makeTempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("strandimport-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        return d
    }

    /// Build a zip from a set of (entryPath, fixtureName) pairs.
    private func makeZip(named: String, entries: [(String, String)]) throws -> URL {
        let dir = makeTempDir()
        let zipURL = dir.appendingPathComponent(named)
        let archive = try Archive(url: zipURL, accessMode: .create)
        for (entryPath, fixture) in entries {
            let data = Fixtures.data(fixture)
            try archive.addEntry(with: entryPath, type: .file,
                                 uncompressedSize: Int64(data.count)) { position, size in
                let start = data.startIndex + Int(position)
                let end = start + size
                return data.subdata(in: start..<end)
            }
        }
        return zipURL
    }

    // MARK: - Whoop zip (nested folder names)

    func testWhoopExportFromZipWithNestedFolder() throws {
        let zip = try makeZip(named: "my_whoop.zip", entries: [
            ("my_whoop_data_2024_01_05/physiological_cycles.csv", "physiological_cycles.csv"),
            ("my_whoop_data_2024_01_05/sleeps.csv", "sleeps.csv"),
            ("my_whoop_data_2024_01_05/workouts.csv", "workouts.csv"),
            ("my_whoop_data_2024_01_05/journal_entries.csv", "journal_entries.csv"),
        ])

        let result = try ImportCoordinator().importWhoopExport(from: zip)
        XCTAssertEqual(result.cycles.count, 2)
        XCTAssertEqual(result.sleeps.count, 2)
        XCTAssertEqual(result.workouts.count, 2)
        XCTAssertEqual(result.journal.count, 2)
        XCTAssertEqual(result.cycles[0].recoveryScore, 72)
    }

    // MARK: - Error handling

    func testMissingFileThrows() {
        let bogus = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).zip")
        XCTAssertThrowsError(try ImportCoordinator().importWhoopExport(from: bogus)) { err in
            XCTAssertTrue(err is ImportError)
        }
    }
}
