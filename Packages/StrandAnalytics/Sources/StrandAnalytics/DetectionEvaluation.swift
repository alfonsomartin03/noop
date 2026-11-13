import Foundation

// DetectionEvaluation.swift — a reproducible scoring harness for workout detection against independently annotated
// sessions, in the spirit of StagingEvaluation.
//
// It computes metrics; it contains no reference data. Nothing NOOP ships has been scored with it, so no accuracy claim
// follows from its existence. Rules it enforces:
//   • matching is one-to-one under a criterion fixed before scoring: highest overlap first, IoU ≥ `minIoU`;
//   • ordinary negative days count: `observedDays` is the denominator of false positives per day, so a recording with no
//     workouts in it still costs the detector for anything it finds;
//   • fragmentation and merging are reported apart from errors, since both can hide inside a good F1;
//   • company exports are not references: compare with one only as a separate compatibility check;
//   • split by participant and recording BEFORE any windowing (`StagingEvaluation.participantFolds`).

public enum DetectionEvaluation {

    /// One annotated session; `label` (activity) is optional and only feeds per-label recall.
    public struct Annotated: Sendable {
        public let span: TimeSpan
        public let label: String?
        public init(span: TimeSpan, label: String? = nil) { self.span = span; self.label = label }
    }

    public struct Recording: Sendable {
        public let participant: String
        public let recordingId: String
        /// Days of supported signal in this recording, including days with no workout.
        public let observedDays: Double
        public let reference: [Annotated]
        public let predicted: [TimeSpan]
        public init(participant: String, recordingId: String, observedDays: Double,
                    reference: [Annotated], predicted: [TimeSpan]) {
            self.participant = participant; self.recordingId = recordingId; self.observedDays = observedDays
            self.reference = reference; self.predicted = predicted
        }
    }

    public struct Report: Equatable, Sendable {
        public let truePositives: Int
        public let falsePositives: Int
        public let falseNegatives: Int
        public let precision: Double?
        public let recall: Double?
        public let f1: Double?
        public let falsePositivesPerObservedDay: Double?
        /// Mean absolute edge error of matched events, seconds. These are MEANS; the nap targets are medians (below).
        public let onsetErrorS: Double?
        public let offsetErrorS: Double?
        /// Median absolute edge error of matched events, seconds (issue #19's frozen targets are medians).
        public let medianOnsetErrorS: Double?
        public let medianOffsetErrorS: Double?
        /// Per matched event, in recording order then REFERENCE order within each recording (not match order): |onset error|,
        /// |offset error| and the signed event-span duration error (predicted − reference), seconds. Positions follow
        /// matched references only (missed references have no entry), so join context by `matches`, not by index.
        public let onsetErrorsS: [Double]
        public let offsetErrorsS: [Double]
        public let durationErrorsS: [Double]
        /// Median |predicted − reference| event-span duration, seconds.
        public let medianAbsDurationErrorS: Double?
        /// 95 % Wilson score intervals; they assume independent events, so with correlated recordings (one person,
        /// many days) they are too narrow — resample by participant/day blocks for the real uncertainty.
        public let precisionInterval: ClosedRange<Double>?
        public let recallInterval: ClosedRange<Double>?
        /// Recall per reference-duration stratum (all reference lengths are matched first, then split).
        public let recallByDuration: [String: Fraction]
        /// Identity of each entry in the per-event arrays (same order): recording, reference index, prediction index.
        public let matches: [Match]
        /// References overlapped by two or more predictions.
        public let fragmented: Int
        /// Predictions overlapping two or more references.
        public let merged: Int
        /// Matched share of each reference label.
        public let recallByLabel: [String: Double]
        public let recordings: Int
        public let participants: Int
    }

    public struct Match: Equatable, Sendable {
        public let recordingId: String
        public let referenceIndex: Int
        public let predictionIndex: Int
    }

    /// hits / total with its 95 % Wilson interval; `value`/`interval` nil when total is 0 ("not estimable").
    public struct Fraction: Equatable, Sendable {
        public let hits: Int
        public let total: Int
        public var value: Double? { total > 0 ? Double(hits) / Double(total) : nil }
        public var interval: ClosedRange<Double>? { DetectionEvaluation.wilson(hits, total) }
    }

    /// Wilson score interval for a binomial proportion (NIST/SEMATECH e-Handbook 7.2.4.1); nil when n = 0.
    public static func wilson(_ successes: Int, _ n: Int, z: Double = 1.959964) -> ClosedRange<Double>? {
        guard n > 0 else { return nil }
        let p = Double(successes) / Double(n), nn = Double(n), z2 = z * z
        let centre = (p + z2 / (2 * nn)) / (1 + z2 / nn)
        let half = z * ((p * (1 - p) / nn + z2 / (4 * nn * nn)).squareRoot()) / (1 + z2 / nn)
        return max(0, centre - half)...min(1, centre + half)
    }

    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted(), m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    static func iou(_ a: TimeSpan, _ b: TimeSpan) -> Double {
        let inter = max(0, min(a.end, b.end) - max(a.start, b.start))
        let union = a.duration + b.duration - inter
        return union > 0 ? Double(inter) / Double(union) : 0
    }

    /// Pairs (reference index, predicted index), highest overlap first, each event used once.
    static func match(_ reference: [TimeSpan], _ predicted: [TimeSpan], minIoU: Double) -> [(Int, Int)] {
        var candidates: [(r: Int, p: Int, iou: Double)] = []
        for (r, a) in reference.enumerated() {
            for (p, b) in predicted.enumerated() {
                let v = iou(a, b)
                if v >= minIoU, v > 0 { candidates.append((r, p, v)) }
            }
        }
        candidates.sort { ($1.iou, $0.r, $0.p) < ($0.iou, $1.r, $1.p) }
        var usedR = Set<Int>(), usedP = Set<Int>(), out: [(Int, Int)] = []
        for c in candidates where !usedR.contains(c.r) && !usedP.contains(c.p) {
            usedR.insert(c.r); usedP.insert(c.p); out.append((c.r, c.p))
        }
        return out
    }

    /// `durationEdgesS` splits references by length for `recallByDuration` (e.g. naps: `[1800, 5400]` → "<1800 s",
    /// "1800–5400 s", "≥5400 s"); matching always uses every reference first.
    public static func evaluate(_ recordings: [Recording], minIoU: Double = 0.5, durationEdgesS: [Int] = []) -> Report {
        var tp = 0, fp = 0, fn = 0, fragmented = 0, merged = 0, days = 0.0
        var onset: [Double] = [], offset: [Double] = [], durationErr: [Double] = [], matches: [Match] = []
        var strata: [String: (hits: Int, total: Int)] = [:]
        let edges = durationEdgesS.sorted()
        func stratum(_ d: Int) -> String? {
            guard !edges.isEmpty else { return nil }
            if d < edges[0] { return "<\(edges[0]) s" }
            for (lo, hi) in zip(edges, edges.dropFirst()) where d >= lo && d < hi { return "\(lo)–\(hi) s" }
            return "≥\(edges.last!) s"
        }
        var labelTotal: [String: Int] = [:], labelHit: [String: Int] = [:]
        func overlaps(_ a: TimeSpan, _ b: TimeSpan) -> Bool { a.start < b.end && b.start < a.end }

        for rec in recordings {
            let ref = rec.reference.map(\.span)
            let pairs = match(ref, rec.predicted, minIoU: minIoU)
            tp += pairs.count
            fp += rec.predicted.count - pairs.count
            fn += ref.count - pairs.count
            days += rec.observedDays
            // Emitted in REFERENCE order (the documented contract), not the matcher's highest-IoU order.
            for (r, p) in pairs.sorted(by: { $0.0 < $1.0 }) {
                onset.append(Double(abs(ref[r].start - rec.predicted[p].start)))
                offset.append(Double(abs(ref[r].end - rec.predicted[p].end)))
                durationErr.append(Double(rec.predicted[p].duration - ref[r].duration))
                matches.append(Match(recordingId: rec.recordingId, referenceIndex: r, predictionIndex: p))
            }
            let matchedRefs = Set(pairs.map(\.0))
            for (r, a) in ref.enumerated() {
                guard let k = stratum(a.duration) else { continue }
                strata[k, default: (0, 0)].total += 1
                if matchedRefs.contains(r) { strata[k, default: (0, 0)].hits += 1 }
            }
            fragmented += ref.filter { a in rec.predicted.filter { overlaps(a, $0) }.count >= 2 }.count
            merged += rec.predicted.filter { a in ref.filter { overlaps(a, $0) }.count >= 2 }.count
            let hit = Set(pairs.map(\.0))
            for (r, a) in rec.reference.enumerated() {
                guard let l = a.label else { continue }
                labelTotal[l, default: 0] += 1
                if hit.contains(r) { labelHit[l, default: 0] += 1 }
            }
        }
        let precision = tp + fp > 0 ? Double(tp) / Double(tp + fp) : nil
        let recall = tp + fn > 0 ? Double(tp) / Double(tp + fn) : nil
        var f1: Double?
        if let p = precision, let r = recall, p + r > 0 { f1 = 2 * p * r / (p + r) }
        func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
        return Report(truePositives: tp, falsePositives: fp, falseNegatives: fn, precision: precision, recall: recall, f1: f1,
                      falsePositivesPerObservedDay: days > 0 ? Double(fp) / days : nil,
                      onsetErrorS: mean(onset), offsetErrorS: mean(offset),
                      medianOnsetErrorS: median(onset), medianOffsetErrorS: median(offset),
                      onsetErrorsS: onset, offsetErrorsS: offset, durationErrorsS: durationErr,
                      medianAbsDurationErrorS: median(durationErr.map(abs)),
                      precisionInterval: wilson(tp, tp + fp), recallInterval: wilson(tp, tp + fn),
                      recallByDuration: strata.mapValues { Fraction(hits: $0.hits, total: $0.total) }, matches: matches,
                      fragmented: fragmented, merged: merged,
                      recallByLabel: labelTotal.reduce(into: [:]) { $0[$1.key] = Double(labelHit[$1.key] ?? 0) / Double($1.value) },
                      recordings: recordings.count, participants: Set(recordings.map(\.participant)).count)
    }
}
