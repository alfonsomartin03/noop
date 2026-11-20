import Foundation

// MARK: - Source provenance

/// Where a normalized row originated. Mirrors the `dataSource.kind` provenance
/// described in the Strand design spec (§5).
// The kinds of file the app can import.
public enum DataSourceKind: String, Sendable, Codable, Equatable, CaseIterable {
    case whoopExport
}

// MARK: - Whoop daily cycle (physiological_cycles.csv)

/// One row of `physiological_cycles.csv` — Whoop's master daily summary.
///
/// All durations are stored in **minutes** as they appear in the CSV. Energy is
/// stored in **kcal** (Whoop's CSV `(cal)` is actually kcal). Timestamps are the
/// raw `YYYY-MM-DD HH:MM:SS` strings parsed against `cycleTimezone` into UTC
/// `Date`s, with the offset preserved in `tzOffsetMin`.
// One physiological cycle (a day) from the WHOOP export; nearly every field is optional because exports have gaps.
public struct WhoopCycleRow: Sendable, Equatable {
    /// Cycle start (UTC). The primary key for a Whoop day.
    public var cycleStart: Date?
    public var cycleEnd: Date?
    /// Original `Cycle timezone` offset in minutes (e.g. `+01:00` → 60).
    public var tzOffsetMin: Int

    public var recoveryScore: Double?
    public var restingHeartRate: Double?
    public var hrvMs: Double?
    public var skinTempCelsius: Double?
    public var bloodOxygenPct: Double?
    public var dayStrain: Double?
    public var energyKcal: Double?
    public var avgHeartRate: Double?
    public var maxHeartRate: Double?

    public var sleepOnset: Date?
    public var wakeOnset: Date?
    public var sleepPerformancePct: Double?
    public var respiratoryRate: Double?
    public var asleepDurationMin: Double?
    public var inBedDurationMin: Double?
    public var lightSleepDurationMin: Double?
    public var deepSleepDurationMin: Double?
    public var remDurationMin: Double?
    public var awakeDurationMin: Double?
    public var sleepEfficiencyPct: Double?
    public var sleepConsistencyPct: Double?
    public var sleepNeedMin: Double?
    public var sleepDebtMin: Double?

    public init() {
        self.cycleStart = nil
        self.cycleEnd = nil
        self.tzOffsetMin = 0
    }
}

// MARK: - Whoop sleep (sleeps.csv)

/// One row of `sleeps.csv` — per sleep or nap. Adds the `Nap` boolean over the
/// daily cycle summary.
// One sleep from the export; naps are flagged with isNap.
public struct WhoopSleepRow: Sendable, Equatable {
    public var cycleStart: Date?
    public var sleepOnset: Date?
    public var wakeOnset: Date?
    public var tzOffsetMin: Int
    public var isNap: Bool

    public var sleepPerformancePct: Double?
    public var respiratoryRate: Double?
    public var asleepDurationMin: Double?
    public var inBedDurationMin: Double?
    public var lightSleepDurationMin: Double?
    public var deepSleepDurationMin: Double?
    public var remDurationMin: Double?
    public var awakeDurationMin: Double?
    public var sleepEfficiencyPct: Double?
    public var sleepConsistencyPct: Double?
    public var sleepNeedMin: Double?
    public var sleepDebtMin: Double?

    public init() {
        self.cycleStart = nil
        self.sleepOnset = nil
        self.wakeOnset = nil
        self.tzOffsetMin = 0
        self.isNap = false
    }
}

// MARK: - Whoop workout (workouts.csv)

/// One row of `workouts.csv`. GPS / distance / altitude columns are optional.
// One workout from the export, including zone percentages.
public struct WhoopWorkoutRow: Sendable, Equatable {
    public var cycleStart: Date?
    public var workoutStart: Date?
    public var workoutEnd: Date?
    public var tzOffsetMin: Int

    public var activityName: String?
    public var activityStrain: Double?
    public var energyKcal: Double?
    public var avgHeartRate: Double?
    public var maxHeartRate: Double?

    public var hrZone1Pct: Double?
    public var hrZone2Pct: Double?
    public var hrZone3Pct: Double?
    public var hrZone4Pct: Double?
    public var hrZone5Pct: Double?

    // Optional GPS / distance / altitude columns (may be absent entirely).
    public var distanceMeters: Double?
    public var altitudeGainMeters: Double?
    public var altitudeChangeMeters: Double?

    public init() {
        self.cycleStart = nil
        self.workoutStart = nil
        self.workoutEnd = nil
        self.tzOffsetMin = 0
    }
}

// MARK: - Whoop journal (journal_entries.csv)

/// One row of `journal_entries.csv` — tall format: a question and its answer
/// (with optional notes) per cycle.
public struct WhoopJournalRow: Sendable, Equatable {
    public var cycleStart: Date?
    public var tzOffsetMin: Int
    public var question: String?
    public var answer: String?
    public var notes: String?

    public init() {
        self.cycleStart = nil
        self.tzOffsetMin = 0
    }
}

// MARK: - Import results & summary

/// Lightweight summary of an import: how many normalized rows were produced and
/// the overall date span they cover.
// Lightweight stats shown to the user after an import.
public struct ImportSummary: Sendable, Equatable {
    public var sourceKind: DataSourceKind
    public var recordCount: Int
    public var earliest: Date?
    public var latest: Date?
    /// Per-category counts (e.g. `["cycles": 30, "workouts": 12]`).
    public var countsByCategory: [String: Int]

    public init(
        sourceKind: DataSourceKind,
        recordCount: Int,
        earliest: Date?,
        latest: Date?,
        countsByCategory: [String: Int]
    ) {
        self.sourceKind = sourceKind
        self.recordCount = recordCount
        self.earliest = earliest
        self.latest = latest
        self.countsByCategory = countsByCategory
    }
}

/// Normalized output of parsing a Whoop CSV export bundle.
public struct WhoopImportResult: Sendable, Equatable {
    public var cycles: [WhoopCycleRow]
    public var sleeps: [WhoopSleepRow]
    public var workouts: [WhoopWorkoutRow]
    public var journal: [WhoopJournalRow]
    public var summary: ImportSummary

    public init(
        cycles: [WhoopCycleRow],
        sleeps: [WhoopSleepRow],
        workouts: [WhoopWorkoutRow],
        journal: [WhoopJournalRow],
        summary: ImportSummary
    ) {
        self.cycles = cycles
        self.sleeps = sleeps
        self.workouts = workouts
        self.journal = journal
        self.summary = summary
    }
}

// MARK: - Errors

public enum ImportError: Error, Equatable, Sendable, CustomStringConvertible {
    case fileNotFound(String)
    case notAZipOrFolder(String)
    case missingEntry(String)
    case emptyExport(String)

    public var description: String {
        switch self {
        case .fileNotFound(let p):    return "File not found: \(p)"
        case .notAZipOrFolder(let p): return "Expected a folder or .zip: \(p)"
        case .missingEntry(let e):    return "Required entry not found: \(e)"
        case .emptyExport(let m):     return "Export contained no usable data: \(m)"
        }
    }
}
