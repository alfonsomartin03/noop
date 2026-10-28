import Foundation

// StagingEvaluation.swift — a reproducible scoring harness for sleep/wake and stage estimates against a reference
// (PSG hypnogram), following the structure of Menghini et al. 2021 (Sleep 44:zsaa170): epoch-by-epoch agreement,
// per-stage metrics, and night-level discrepancy (bias, limits of agreement).
//
// It computes metrics; it contains no reference data. Nothing NOOP ships has been scored with it yet, so no accuracy
// claim follows from its existence. Rules it enforces:
//   • abstention is visible: predicted `asleep` (unstaged) or `unknown` never counts as a correct OR wrong stage, it is
//     reported as lost coverage; reference epochs that are themselves unscored are excluded;
//   • uncertainty is clustered by PARTICIPANT (epochs of one person are not independent): the bootstrap resamples
//     participants, never epochs;
//   • splits are by participant (`participantFolds`), so no person appears in both training and test. Any
//     normalisation/thresholds must be fitted on the training participants only — the harness can't enforce that.

public enum StagingEvaluation {

    public struct Night: Sendable {
        public let participant: String
        public let reference: [SleepState]
        public let predicted: [SleepState]
        public let epochS: Int
        public init(participant: String, reference: [SleepState], predicted: [SleepState], epochS: Int = 30) {
            self.participant = participant; self.reference = reference; self.predicted = predicted; self.epochS = epochS
        }
    }

    public static let stageClasses: [SleepState] = [.wake, .light, .deep, .rem]

    public struct ClassMetrics: Equatable, Sendable {
        public let state: SleepState
        public let support: Int
        public let precision: Double?
        public let recall: Double?
        public let f1: Double?
    }

    public struct Agreement: Equatable, Sendable {
        public let bias: Double              // mean(pred − ref)
        public let lowerLoA: Double          // bias − 1.96·SD (night-level; not participant-clustered)
        public let upperLoA: Double
        public let mae: Double
        public let n: Int
    }

    public struct Report: Equatable, Sendable {
        /// counts[r][p] over `stageClasses`, epochs where both reference and prediction carry a 4-class label.
        public let confusion: [[Int]]
        public let perClass: [ClassMetrics]
        public let macroF1: Double?
        public let kappa: Double?
        /// 95 % percentile interval of kappa from a participant-level bootstrap (nil with < 2 participants).
        public let kappaCI: ClosedRange<Double>?
        public let sleepSensitivity: Double?
        public let wakeSpecificity: Double?
        public let binaryKappa: Double?
        /// Share of reference-scored epochs that got a known sleep/wake prediction.
        public let sleepWakeCoverage: Double
        /// Share of reference SLEEP epochs (predicted asleep) that got a stage rather than `asleep`.
        public let stageCoverage: Double
        /// Nights where the prediction has no known epoch at all.
        public let failureRate: Double
        public let tstMinutes: Agreement?
        public let onsetMinutes: Agreement?
        public let finalWakeMinutes: Agreement?
        public let nights: Int
        public let participants: Int
    }

    public static func evaluate(_ nights: [Night], bootstrapReplicates: Int = 1000, seed: UInt64 = 1) -> Report {
        let k = stageClasses.count
        func idx(_ s: SleepState) -> Int? { stageClasses.firstIndex(of: s) }

        struct Tally { var cm = [[Int]](repeating: [Int](repeating: 0, count: 4), count: 4)
            var bin = [[Int]](repeating: [0, 0], count: 2)       // [refSleep][predSleep]
            var refScored = 0, predKnown = 0, predSleepOnRefSleep = 0, predStagedOnRefSleep = 0 }
        func tally(_ ns: [Night]) -> Tally {
            var t = Tally()
            for n in ns {
                for (r, p) in zip(n.reference, n.predicted) where r.isKnown && r != .asleep {
                    t.refScored += 1
                    guard p.isKnown else { continue }
                    t.predKnown += 1
                    t.bin[r.isSleep ? 1 : 0][p.isSleep ? 1 : 0] += 1
                    if r.isSleep && p.isSleep { t.predSleepOnRefSleep += 1; if p.isStaged { t.predStagedOnRefSleep += 1 } }
                    if let ri = idx(r), let pi = idx(p) { t.cm[ri][pi] += 1 }
                }
            }
            return t
        }
        func kappa(_ m: [[Int]]) -> Double? {
            let n = Double(m.joined().reduce(0, +))
            guard n > 0 else { return nil }
            let po = Double(m.indices.reduce(0) { $0 + m[$1][$1] }) / n
            let pe = m.indices.reduce(0.0) { acc, i in
                acc + Double(m[i].reduce(0, +)) * Double(m.reduce(0) { $0 + $1[i] }) / (n * n)
            }
            return pe < 1 ? (po - pe) / (1 - pe) : nil
        }

        let t = tally(nights)
        var perClass: [ClassMetrics] = []
        for i in 0..<k {
            let tp = Double(t.cm[i][i])
            let predN = Double(t.cm.reduce(0) { $0 + $1[i] }), refN = t.cm[i].reduce(0, +)
            let p = predN > 0 ? tp / predN : nil
            let r = refN > 0 ? tp / Double(refN) : nil
            let f1: Double? = { guard let p, let r else { return nil }; return p + r > 0 ? 2 * p * r / (p + r) : 0 }()
            perClass.append(ClassMetrics(state: stageClasses[i], support: refN, precision: p, recall: r, f1: f1))
        }
        let f1s = perClass.compactMap(\.f1)
        let macro = f1s.count == k ? f1s.reduce(0, +) / Double(k) : nil

        // Participant-clustered bootstrap for kappa.
        let groups = Dictionary(grouping: nights, by: \.participant)
        let ids = groups.keys.sorted()
        var kappaCI: ClosedRange<Double>? = nil
        if ids.count >= 2, bootstrapReplicates > 0 {
            var rng = SplitMix64(seed: seed)
            var ks: [Double] = []
            for _ in 0..<bootstrapReplicates {
                let sample = (0..<ids.count).flatMap { _ in groups[ids[Int(rng.next() % UInt64(ids.count))]]! }
                if let kv = kappa(tally(sample).cm) { ks.append(kv) }
            }
            ks.sort()
            if ks.count >= 20 {
                kappaCI = ks[Int(0.025 * Double(ks.count - 1))]...ks[Int(0.975 * Double(ks.count - 1))]
            }
        }

        // Night-level durations and boundaries.
        var tst: [Double] = [], onset: [Double] = [], final: [Double] = []
        var failures = 0
        for n in nights {
            let m = Double(n.epochS) / 60.0
            if !n.predicted.contains(where: \.isKnown) { failures += 1; continue }
            tst.append(Double(n.predicted.filter(\.isSleep).count - n.reference.filter(\.isSleep).count) * m)
            if let ro = n.reference.firstIndex(where: \.isSleep), let po = n.predicted.firstIndex(where: \.isSleep) {
                onset.append(Double(po - ro) * m)
            }
            if let rf = n.reference.lastIndex(where: \.isSleep), let pf = n.predicted.lastIndex(where: \.isSleep) {
                final.append(Double(pf - rf) * m)
            }
        }
        let b = t.bin
        let sens = b[1][0] + b[1][1] > 0 ? Double(b[1][1]) / Double(b[1][0] + b[1][1]) : nil
        let spec = b[0][0] + b[0][1] > 0 ? Double(b[0][0]) / Double(b[0][0] + b[0][1]) : nil

        return Report(
            confusion: t.cm, perClass: perClass, macroF1: macro, kappa: kappa(t.cm), kappaCI: kappaCI,
            sleepSensitivity: sens, wakeSpecificity: spec, binaryKappa: kappa(t.bin),
            sleepWakeCoverage: t.refScored > 0 ? Double(t.predKnown) / Double(t.refScored) : 0,
            stageCoverage: t.predSleepOnRefSleep > 0 ? Double(t.predStagedOnRefSleep) / Double(t.predSleepOnRefSleep) : 0,
            failureRate: nights.isEmpty ? 0 : Double(failures) / Double(nights.count),
            tstMinutes: agreement(tst), onsetMinutes: agreement(onset), finalWakeMinutes: agreement(final),
            nights: nights.count, participants: ids.count)
    }

    static func agreement(_ diffs: [Double]) -> Agreement? {
        guard !diffs.isEmpty else { return nil }
        let n = Double(diffs.count)
        let bias = diffs.reduce(0, +) / n
        let sd = diffs.count > 1 ? (diffs.reduce(0) { $0 + ($1 - bias) * ($1 - bias) } / (n - 1)).squareRoot() : 0
        return Agreement(bias: bias, lowerLoA: bias - 1.96 * sd, upperLoA: bias + 1.96 * sd,
                         mae: diffs.reduce(0) { $0 + abs($1) } / n, n: diffs.count)
    }

    /// Deterministic participant-level k-fold split: each participant lands in exactly one fold.
    public static func participantFolds(_ participants: [String], k: Int, seed: UInt64 = 1) -> [[String]] {
        guard k > 0 else { return [] }
        var ids = Array(Set(participants)).sorted()
        var rng = SplitMix64(seed: seed)
        for i in stride(from: ids.count - 1, to: 0, by: -1) { ids.swapAt(i, Int(rng.next() % UInt64(i + 1))) }
        var folds = [[String]](repeating: [], count: k)
        for (i, id) in ids.enumerated() { folds[i % k].append(id) }
        return folds.map { $0.sorted() }
    }
}

/// Small deterministic PRNG (SplitMix64) so evaluation runs are reproducible.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
