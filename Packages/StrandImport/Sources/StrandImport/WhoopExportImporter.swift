import Foundation
import ZIPFoundation

/// Parses a Whoop data export (CSV bundle) into normalized Swift models.
///
/// The parser is header-name-driven and tolerant: columns are matched by
/// normalized header name (not position), every column is optional, UTF-8 BOMs
/// are stripped, and missing files / columns degrade gracefully. The schema is
/// identical across Whoop 4 / 5 / MG, so a single parser covers all three.
///
/// Input may be a folder (possibly nested or renamed) or a `.zip`. CSVs are
/// located **by filename**, case-insensitively, anywhere in the tree.
public struct WhoopExportImporter {

    public init() {}

    // Recognised CSV filenames (lowercased).
    private static let cyclesName  = "physiological_cycles.csv"
    private static let sleepsName  = "sleeps.csv"
    private static let workoutsName = "workouts.csv"
    private static let journalName = "journal_entries.csv"

    // MARK: - Public entry point

    /// Import from a folder or a `.zip` URL, returning all normalized rows plus
    /// a summary.
    // Flow: find the CSVs (folder or zip) -> parse each into typed rows -> build a summary. Missing files simply yield empty arrays.
    public func `import`(from url: URL) throws -> WhoopImportResult {
        let csvData = try loadCSVData(from: url)

        var cycles: [WhoopCycleRow] = []
        var sleeps: [WhoopSleepRow] = []
        var workouts: [WhoopWorkoutRow] = []
        var journal: [WhoopJournalRow] = []

        if let data = csvData[Self.cyclesName] {
            cycles = parseCycles(CSVTable(data: data))
        }
        if let data = csvData[Self.sleepsName] {
            sleeps = parseSleeps(CSVTable(data: data))
        }
        if let data = csvData[Self.workoutsName] {
            workouts = parseWorkouts(CSVTable(data: data))
        }
        if let data = csvData[Self.journalName] {
            journal = parseJournal(CSVTable(data: data))
        }

        let summary = makeSummary(cycles: cycles, sleeps: sleeps, workouts: workouts, journal: journal)
        return WhoopImportResult(
            cycles: cycles, sleeps: sleeps, workouts: workouts, journal: journal, summary: summary
        )
    }

    // MARK: - Locate + load CSVs

    /// Return `[lowercasedFilename: rawData]` for every recognised CSV in the
    /// folder or zip at `url`.
    // Accepts a folder or a zip; a file with a different extension is tried as a zip before giving up.
    private func loadCSVData(from url: URL) throws -> [String: Data] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        guard exists else { throw ImportError.fileNotFound(url.path) }

        if isDir.boolValue {
            return try loadFromFolder(url)
        }

        // A file — treat as zip if it has a zip extension or opens as an archive.
        if url.pathExtension.lowercased() == "zip" {
            return try loadFromZip(url)
        }
        // Try as a zip anyway; if that fails, it's not a supported input.
        if let z = try? loadFromZip(url) { return z }
        throw ImportError.notAZipOrFolder(url.path)
    }

    // Searches the whole tree by file name, so renamed or nested export folders still work.
    private func loadFromFolder(_ folder: URL) throws -> [String: Data] {
        let fm = FileManager.default
        var result: [String: Data] = [:]
        let wanted: Set<String> = [Self.cyclesName, Self.sleepsName, Self.workoutsName, Self.journalName]

        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ImportError.fileNotFound(folder.path)
        }

        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent.lowercased()
            guard wanted.contains(name), result[name] == nil else { continue }
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > Self.maxEntryBytes { continue }   // refuse an implausibly large CSV
            if let data = try? Data(contentsOf: fileURL) {
                result[name] = data
            }
        }
        return result
    }

    /// Per-CSV uncompressed ceiling. Real Whoop CSV bundles are a few MB; this guards against a
    /// zip-bomb where a tiny entry inflates to many GB and OOM-kills the app.
    private static let maxEntryBytes = 256 << 20   // 256 MB

    // Streams each entry with a running size budget and CRC check; bad or oversized entries are skipped, never half-imported.
    private func loadFromZip(_ zipURL: URL) throws -> [String: Data] {
        let archive: Archive
        do {
            archive = try Archive(url: zipURL, accessMode: .read)
        } catch {
            throw ImportError.notAZipOrFolder(zipURL.path)
        }

        var result: [String: Data] = [:]
        let wanted: Set<String> = [Self.cyclesName, Self.sleepsName, Self.workoutsName, Self.journalName]

        for entry in archive {
            guard entry.type == .file else { continue }
            let name = (entry.path as NSString).lastPathComponent.lowercased()
            guard wanted.contains(name), result[name] == nil else { continue }
            // Reject entries whose declared uncompressed size is implausible (zip-bomb guard)...
            let declared = Int(exactly: entry.uncompressedSize) ?? Int.max
            if declared > Self.maxEntryBytes { continue }
            var buffer = Data()
            var written = 0
            do {
                // extract() verifies CRC32 (skipCRC32 defaults to false) and throws on a
                // mismatch/truncation; the running budget also stops a lying ZIP64 header mid-stream.
                _ = try archive.extract(entry) { chunk in
                    written += chunk.count
                    if written > Self.maxEntryBytes { throw CancellationError() }
                    buffer.append(chunk)
                }
                if !buffer.isEmpty { result[name] = buffer }
            } catch {
                // Corrupt / truncated / oversized entry: skip rather than import partial data.
                continue
            }
        }
        return result
    }

    // MARK: - physiological_cycles.csv

    // Header-name driven: each field lists alternative column names to cope with differences between export versions.
    func parseCycles(_ table: CSVTable) -> [WhoopCycleRow] {
        var out: [WhoopCycleRow] = []
        out.reserveCapacity(table.rows.count)
        for row in table.rows {
            let tz = WhoopTime.tzOffsetMinutes(row.cell("cycle_timezone"))

            var r = WhoopCycleRow()
            r.tzOffsetMin = tz
            r.cycleStart = WhoopTime.parse(row.cell("cycle_start_time"), offsetMinutes: tz)
            r.cycleEnd   = WhoopTime.parse(row.cell("cycle_end_time"), offsetMinutes: tz)

            // Rows with no timestamp can't be placed on a day, so they are dropped.
            // Skip rows with no usable timestamp at all.
            if r.cycleStart == nil && r.cycleEnd == nil { continue }

            r.recoveryScore    = row.double("recovery_score_pct")
            r.restingHeartRate = row.double("resting_heart_rate_bpm", "resting_heart_rate")
            r.hrvMs            = row.double("heart_rate_variability_ms", "heart_rate_variability_rmssd_ms")
            r.skinTempCelsius  = row.double("skin_temp_celsius", "skin_temp_f")
            r.bloodOxygenPct   = row.double("blood_oxygen_pct", "blood_oxygen_pct_pct")
            r.dayStrain        = row.double("day_strain")
            r.energyKcal       = row.double("energy_burned_cal")  // CSV "(cal)" == kcal
            r.avgHeartRate     = row.double("average_hr_bpm", "average_heart_rate_bpm")
            r.maxHeartRate     = row.double("max_hr_bpm", "max_heart_rate_bpm")

            r.sleepOnset = WhoopTime.parse(row.cell("sleep_onset"), offsetMinutes: tz)
            r.wakeOnset  = WhoopTime.parse(row.cell("wake_onset"), offsetMinutes: tz)

            r.sleepPerformancePct = row.double("sleep_performance_pct")
            r.respiratoryRate     = row.double("respiratory_rate_rpm", "respiratory_rate")
            r.asleepDurationMin   = row.double("asleep_duration_min")
            r.inBedDurationMin    = row.double("in_bed_duration_min")
            r.lightSleepDurationMin = row.double("light_sleep_duration_min")
            r.deepSleepDurationMin  = row.double("deep_sws_duration_min", "deep_sleep_duration_min")
            r.remDurationMin        = row.double("rem_duration_min")
            r.awakeDurationMin      = row.double("awake_duration_min")
            r.sleepEfficiencyPct    = row.double("sleep_efficiency_pct")
            r.sleepConsistencyPct   = row.double("sleep_consistency_pct")
            r.sleepNeedMin          = row.double("sleep_need_min")
            r.sleepDebtMin          = row.double("sleep_debt_min")

            out.append(r)
        }
        return out
    }

    // MARK: - sleeps.csv

    func parseSleeps(_ table: CSVTable) -> [WhoopSleepRow] {
        var out: [WhoopSleepRow] = []
        out.reserveCapacity(table.rows.count)
        for row in table.rows {
            let tz = WhoopTime.tzOffsetMinutes(row.cell("cycle_timezone"))

            var r = WhoopSleepRow()
            r.tzOffsetMin = tz
            r.cycleStart = WhoopTime.parse(row.cell("cycle_start_time"), offsetMinutes: tz)
            r.sleepOnset = WhoopTime.parse(row.cell("sleep_onset"), offsetMinutes: tz)
            r.wakeOnset  = WhoopTime.parse(row.cell("wake_onset"), offsetMinutes: tz)

            if r.cycleStart == nil && r.sleepOnset == nil && r.wakeOnset == nil { continue }

            r.isNap = row.bool("nap") ?? false

            r.sleepPerformancePct = row.double("sleep_performance_pct")
            r.respiratoryRate     = row.double("respiratory_rate_rpm", "respiratory_rate")
            r.asleepDurationMin   = row.double("asleep_duration_min")
            r.inBedDurationMin    = row.double("in_bed_duration_min")
            r.lightSleepDurationMin = row.double("light_sleep_duration_min")
            r.deepSleepDurationMin  = row.double("deep_sws_duration_min", "deep_sleep_duration_min")
            r.remDurationMin        = row.double("rem_duration_min")
            r.awakeDurationMin      = row.double("awake_duration_min")
            r.sleepEfficiencyPct    = row.double("sleep_efficiency_pct")
            r.sleepConsistencyPct   = row.double("sleep_consistency_pct")
            r.sleepNeedMin          = row.double("sleep_need_min")
            r.sleepDebtMin          = row.double("sleep_debt_min")

            out.append(r)
        }
        return out
    }

    // MARK: - workouts.csv

    func parseWorkouts(_ table: CSVTable) -> [WhoopWorkoutRow] {
        var out: [WhoopWorkoutRow] = []
        out.reserveCapacity(table.rows.count)
        for row in table.rows {
            let tz = WhoopTime.tzOffsetMinutes(row.cell("cycle_timezone"))

            var r = WhoopWorkoutRow()
            r.tzOffsetMin = tz
            r.cycleStart   = WhoopTime.parse(row.cell("cycle_start_time"), offsetMinutes: tz)
            r.workoutStart = WhoopTime.parse(row.cell("workout_start_time"), offsetMinutes: tz)
            r.workoutEnd   = WhoopTime.parse(row.cell("workout_end_time"), offsetMinutes: tz)

            if r.workoutStart == nil && r.workoutEnd == nil && r.cycleStart == nil { continue }

            r.activityName   = row.cell("activity_name")
            r.activityStrain = row.double("activity_strain")
            r.energyKcal     = row.double("energy_burned_cal")  // CSV "(cal)" == kcal
            r.avgHeartRate   = row.double("average_hr_bpm", "average_heart_rate_bpm")
            r.maxHeartRate   = row.double("max_hr_bpm", "max_heart_rate_bpm")

            r.hrZone1Pct = row.double("hr_zone_1_pct", "zone_1_pct", "hr_zone_1_pct_pct")
            r.hrZone2Pct = row.double("hr_zone_2_pct", "zone_2_pct", "hr_zone_2_pct_pct")
            r.hrZone3Pct = row.double("hr_zone_3_pct", "zone_3_pct", "hr_zone_3_pct_pct")
            r.hrZone4Pct = row.double("hr_zone_4_pct", "zone_4_pct", "hr_zone_4_pct_pct")
            r.hrZone5Pct = row.double("hr_zone_5_pct", "zone_5_pct", "hr_zone_5_pct_pct")

            // Optional GPS / distance / altitude columns.
            r.distanceMeters       = row.double("distance_meters", "distance_meter")
            r.altitudeGainMeters   = row.double("altitude_gain_meters", "altitude_gain_meter")
            r.altitudeChangeMeters = row.double("altitude_change_meters", "altitude_change_meter")

            out.append(r)
        }
        return out
    }

    // MARK: - journal_entries.csv

    // A journal row is only kept if it has a question, answer or notes.
    func parseJournal(_ table: CSVTable) -> [WhoopJournalRow] {
        var out: [WhoopJournalRow] = []
        out.reserveCapacity(table.rows.count)
        for row in table.rows {
            let tz = WhoopTime.tzOffsetMinutes(row.cell("cycle_timezone"))

            var r = WhoopJournalRow()
            r.tzOffsetMin = tz
            r.cycleStart = WhoopTime.parse(row.cell("cycle_start_time"), offsetMinutes: tz)
            r.question = row.cell("question_text", "question")
            r.answer   = row.cell("answered_yes_no", "answer", "answer_text")
            r.notes    = row.cell("notes")

            // A journal row is only meaningful if it has a question.
            if r.question == nil && r.answer == nil && r.notes == nil { continue }
            out.append(r)
        }
        return out
    }

    // MARK: - Summary

    // Counts and date span shown to the user after the import.
    private func makeSummary(
        cycles: [WhoopCycleRow],
        sleeps: [WhoopSleepRow],
        workouts: [WhoopWorkoutRow],
        journal: [WhoopJournalRow]
    ) -> ImportSummary {
        var dates: [Date] = []
        dates.append(contentsOf: cycles.compactMap { $0.cycleStart })
        dates.append(contentsOf: sleeps.compactMap { $0.sleepOnset ?? $0.cycleStart })
        dates.append(contentsOf: workouts.compactMap { $0.workoutStart ?? $0.cycleStart })
        dates.append(contentsOf: journal.compactMap { $0.cycleStart })

        let count = cycles.count + sleeps.count + workouts.count + journal.count
        return ImportSummary(
            sourceKind: .whoopExport,
            recordCount: count,
            earliest: dates.min(),
            latest: dates.max(),
            countsByCategory: [
                "cycles": cycles.count,
                "sleeps": sleeps.count,
                "workouts": workouts.count,
                "journal": journal.count,
            ]
        )
    }
}
