import Foundation
import WhoopStore

// TrainingLog.swift — load dimensions that heart rate cannot supply, from what the user actually reports.
//
// Perceived effort and resistance-training work are separate measures, not inputs to a blended score. Nothing here is
// estimated: a missing response stays missing, and no HR-derived value may fill these fields. The workout sheet collects
// them and shows them beside strain; nothing below feeds the strain index or any other score.

/// Session RPE (Foster et al. 2001, https://pubmed.ncbi.nlm.nih.gov/11708692/): reported effort × session minutes, AU.
/// Those units are not TRIMP, calories or muscle damage.
public struct SessionRPE: Codable, Equatable, Sendable {
    /// The 0–10 category-ratio scale.
    public static let scale = "CR10"
    public let rpe: Double
    public let sessionMinutes: Double
    /// When the user answered (unix s), so a response collected much later can be told apart.
    public let collectedAt: Int

    /// Nil for a response off the scale or a non-positive duration.
    public init?(rpe: Double, sessionMinutes: Double, collectedAt: Int) {
        guard rpe.isFinite, (0...10).contains(rpe), sessionMinutes.isFinite, sessionMinutes > 0 else { return nil }
        self.rpe = rpe; self.sessionMinutes = sessionMinutes; self.collectedAt = collectedAt
    }

    public var load: Double { rpe * sessionMinutes }
}

extension SessionRPE {
    public func row(workoutStartTs: Int, workoutEndTs: Int) -> SessionEffortRow {
        SessionEffortRow(workoutStartTs: workoutStartTs, workoutEndTs: workoutEndTs, scale: Self.scale, rpe: rpe,
                         sessionMinutes: sessionMinutes, collectedAt: collectedAt)
    }

    /// Nil for a row on another scale: loads from different scales are not comparable.
    public init?(row: SessionEffortRow) {
        guard row.scale == Self.scale else { return nil }
        self.init(rpe: row.rpe, sessionMinutes: row.sessionMinutes, collectedAt: row.collectedAt)
    }
}

/// One logged set. `externalKg` is the load lifted as logged: nil for bodyweight work, since full body mass is not what
/// moves in every lift. Dumbbells and unilateral work count as the user logged them, so compare an exercise with itself.
public struct StrengthSet: Codable, Equatable, Sendable {
    public let exercise: String
    public let reps: Int
    public let externalKg: Double?
    /// Repetitions in reserve, if reported.
    public let rir: Int?
    public init(exercise: String, reps: Int, externalKg: Double?, rir: Int? = nil) {
        self.exercise = exercise; self.reps = reps; self.externalKg = externalKg; self.rir = rir
    }
}

extension StrengthSet {
    /// A set from what the user typed. Blank load means none was logged and blank RIR means not reported; anything else
    /// unreadable is nil, so a typo can't pass as bodyweight. Accepts a decimal comma.
    public init?(exercise: String, reps: String, kg: String, rir: String) {
        let name = exercise.trimmingCharacters(in: .whitespacesAndNewlines)
        func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }
        func int(_ s: String) -> Int? { Int(s.trimmingCharacters(in: .whitespaces)) }
        guard !name.isEmpty, let repCount = int(reps), repCount > 0 else { return nil }
        var load: Double?
        if !blank(kg) {
            guard let v = Double(kg.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
                  v.isFinite, v >= 0 else { return nil }
            load = v
        }
        var reserve: Int?
        if !blank(rir) {
            guard let v = int(rir), v >= 0 else { return nil }
            reserve = v
        }
        self.init(exercise: name, reps: repCount, externalKg: load, rir: reserve)
    }

    public init(row: StrengthSetRow) {
        self.init(exercise: row.exercise, reps: row.reps, externalKg: row.externalKg, rir: row.rir)
    }

    public func row(workoutStartTs: Int, workoutEndTs: Int, collectedAt: Int) -> StrengthSetRow {
        StrengthSetRow(workoutStartTs: workoutStartTs, workoutEndTs: workoutEndTs, exercise: exercise, reps: reps,
                       externalKg: externalKg, rir: rir, collectedAt: collectedAt)
    }
}

public enum StrengthVolume {
    /// sum(reps × kg) per exercise. Kept per exercise because equal tonnage across lifts is not equal stress
    /// (https://pmc.ncbi.nlm.nih.gov/articles/PMC7706636/). An exercise with no external load has no entry, not zero.
    public static func byExercise(_ sets: [StrengthSet]) -> [String: Double] {
        sets.reduce(into: [:]) { acc, s in
            guard let kg = s.externalKg, kg.isFinite, kg >= 0, s.reps > 0 else { return }
            acc[s.exercise, default: 0] += Double(s.reps) * kg
        }
    }

    /// One exercise as the workout sheet shows it. `volumeKg` is nil when no set carried an external load.
    public struct ExerciseSummary: Equatable, Sendable {
        public let exercise: String
        public let sets: Int
        public let reps: Int
        public let volumeKg: Double?
    }

    /// Per-exercise rows in first-logged order. Never totalled across exercises, for the reason above.
    public static func summaries(_ sets: [StrengthSet]) -> [ExerciseSummary] {
        let volume = byExercise(sets)
        var order: [String] = []
        for s in sets where !order.contains(s.exercise) { order.append(s.exercise) }
        return order.map { name in
            let own = sets.filter { $0.exercise == name }
            return ExerciseSummary(exercise: name, sets: own.count, reps: own.map(\.reps).reduce(0, +), volumeKg: volume[name])
        }
    }
}
