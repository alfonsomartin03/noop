import Foundation
import WhoopStore

// WorkoutLabels.swift — what kind of activity a workout was, and who says so.
//
// Classification is separate from detection and load. Nothing here feeds `WorkoutDetector` or `CardioLoad`, and no current
// load method depends on activity type, so changing a label changes no score and invalidates no calculation.
//
// A label wins in this order: what the user selected, what an import reported, an inference. NOOP has no validated
// classifier, and its motion channel can't support one (see WorkoutDetector.swift), so nothing is inferred today and a
// detected session reads Unknown until someone says otherwise.

/// The activity types offered for selection. `other` is a known activity not listed; `unknown` means no one has said.
public enum ActivityType: String, CaseIterable, Codable, Sendable {
    case running, walking, hiking, cycling, swimming, rowing, strength, hiit, yoga, boxing, elliptical, skiing
    case tennis, golf, teamSport, other, unknown

    public var displayName: String {
        switch self {
        case .running: return "Running"
        case .walking: return "Walking"
        case .hiking: return "Hiking"
        case .cycling: return "Cycling"
        case .swimming: return "Swimming"
        case .rowing: return "Rowing"
        case .strength: return "Strength"
        case .hiit: return "HIIT"
        case .yoga: return "Yoga"
        case .boxing: return "Boxing"
        case .elliptical: return "Elliptical"
        case .skiing: return "Skiing"
        case .tennis: return "Tennis"
        case .golf: return "Golf"
        case .teamSport: return "Team sport"
        case .other: return "Other"
        case .unknown: return "Unknown"
        }
    }

    /// The closest type for a free-text imported name, or nil. Imported names are shown verbatim; this only preselects
    /// the picker, so a miss loses nothing.
    public init?(matching name: String) {
        let s = name.lowercased()
        let rules: [(ActivityType, [String])] = [
            (.running, ["run"]), (.hiking, ["hik"]), (.walking, ["walk"]),
            (.cycling, ["cycl", "bike", "ride", "spin"]), (.swimming, ["swim"]), (.rowing, ["row"]),
            (.strength, ["strength", "weight", "lift", "functional", "powerlift"]), (.hiit, ["hiit", "interval", "crossfit"]),
            (.yoga, ["yoga"]), (.boxing, ["box"]), (.elliptical, ["elliptical"]), (.skiing, ["ski"]), (.tennis, ["tennis"]),
            (.golf, ["golf"]), (.teamSport, ["soccer", "football", "basketball", "hockey", "rugby", "volleyball"]),
        ]
        guard let hit = rules.first(where: { $0.1.contains { s.contains($0) } }) else { return nil }
        self = hit.0
    }
}

/// Who a label came from.
public enum LabelProvenance: String, Codable, Sendable {
    case userSelected = "user-selected"
    case imported
    case inferred
    /// No source: the label is Unknown.
    case none
}

public struct ActivityLabel: Equatable, Sendable {
    public let type: ActivityType
    /// What to show. An imported name stays as the source wrote it.
    public let name: String
    public let provenance: LabelProvenance
    /// The stored label behind this, when there is one. Later edits must keep using its span.
    public let stored: WorkoutLabelRow?

    public static let unknown = ActivityLabel(type: .unknown, name: ActivityType.unknown.displayName, provenance: .none, stored: nil)
}

public enum WorkoutLabels {
    /// The `source` of rows NOOP detected itself; anything else was imported.
    static let detectedSource = "noop"
    /// Share of a workout a stored label must cover to still apply after detection moved its edges.
    public static let minOverlap = 0.5

    /// The stored label covering most of this workout, else one set at its exact start. A re-score that moves, trims,
    /// splits or merges a session keeps the label on whatever still covers the same time.
    static func stored(for w: WorkoutRow, in labels: [WorkoutLabelRow]) -> WorkoutLabelRow? {
        func overlap(_ l: WorkoutLabelRow) -> Int { min(l.workoutEndTs, w.endTs) - max(l.workoutStartTs, w.startTs) }
        let span = max(1, w.endTs - w.startTs)
        return labels.filter { Double(overlap($0)) >= minOverlap * Double(span) }.max { overlap($0) < overlap($1) }
            ?? labels.first { $0.workoutStartTs == w.startTs }
    }

    public static func resolve(_ w: WorkoutRow, labels: [WorkoutLabelRow]) -> ActivityLabel {
        if let l = stored(for: w, in: labels) {
            let type = ActivityType(rawValue: l.activity) ?? .unknown
            return ActivityLabel(type: type, name: type.displayName,
                                 provenance: LabelProvenance(rawValue: l.provenance) ?? .none, stored: l)
        }
        guard w.source != detectedSource, !w.sport.isEmpty else { return .unknown }
        return ActivityLabel(type: ActivityType(matching: w.sport) ?? .other, name: w.sport, provenance: .imported, stored: nil)
    }

    /// Rows as screens show them: `sport` is the resolved name. The stored rows and their key are not changed.
    public static func applying(_ labels: [WorkoutLabelRow], to rows: [WorkoutRow]) -> [WorkoutRow] {
        rows.map { w in
            WorkoutRow(startTs: w.startTs, endTs: w.endTs, sport: resolve(w, labels: labels).name, source: w.source,
                       durationS: w.durationS, energyKcal: w.energyKcal, avgHr: w.avgHr, maxHr: w.maxHr, strain: w.strain,
                       distanceM: w.distanceM, zonesJSON: w.zonesJSON, notes: w.notes)
        }
    }
}
