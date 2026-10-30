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
        /// Mean absolute edge error of matched events, seconds.
        public let onsetErrorS: Double?
        public let offsetErrorS: Double?
        /// References overlapped by two or more predictions.
        public let fragmented: Int
        /// Predictions overlapping two or more references.
        public let merged: Int
        /// Matched share of each reference label.
        public let recallByLabel: [String: Double]
        public let recordings: Int
        public let participants: Int
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

    public static func evaluate(_ recordings: [Recording], minIoU: Double = 0.5) -> Report {
        var tp = 0, fp = 0, fn = 0, fragmented = 0, merged = 0, days = 0.0
        var onset: [Double] = [], offset: [Double] = []
        var labelTotal: [String: Int] = [:], labelHit: [String: Int] = [:]
        func overlaps(_ a: TimeSpan, _ b: TimeSpan) -> Bool { a.start < b.end && b.start < a.end }

        for rec in recordings {
            let ref = rec.reference.map(\.span)
            let pairs = match(ref, rec.predicted, minIoU: minIoU)
            tp += pairs.count
            fp += rec.predicted.count - pairs.count
            fn += ref.count - pairs.count
            days += rec.observedDays
            for (r, p) in pairs {
                onset.append(Double(abs(ref[r].start - rec.predicted[p].start)))
                offset.append(Double(abs(ref[r].end - rec.predicted[p].end)))
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
                      onsetErrorS: mean(onset), offsetErrorS: mean(offset), fragmented: fragmented, merged: merged,
                      recallByLabel: labelTotal.reduce(into: [:]) { $0[$1.key] = Double(labelHit[$1.key] ?? 0) / Double($1.value) },
                      recordings: recordings.count, participants: Set(recordings.map(\.participant)).count)
    }
}
