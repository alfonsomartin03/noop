import Foundation
import WhoopProtocol

// HRQuality.swift — conservative validation of raw heart-rate samples before any score uses them.
//
// Only removes what cannot be physiology: duplicate timestamps, out-of-range values and short isolated
// spikes that sit far from BOTH neighbours while the neighbours agree with each other (optical/motion
// artifacts). A sustained jump (a sprint, an interval) has no agreeing "before and after" anchors, so it is kept.
public enum HRQuality {
    public static let minValidBPM = 30
    public static let maxValidBPM = 230
    /// A spike must deviate from both anchors by more than this (bpm)…
    static let spikeDeviationBPM = 30
    /// …while the anchors agree within this (bpm), and last at most this many samples.
    static let anchorAgreementBPM = 15
    static let maxSpikeRun = 3
    /// Anchors must be this close in time (s) for the spike test to apply (otherwise it is a data gap, not a spike).
    static let maxAnchorGapS = 10

    public struct Report: Equatable, Sendable {
        public var duplicates = 0, outOfRange = 0, spikes = 0
    }

    /// Time-sorted, de-duplicated, artifact-filtered samples.
    public static func clean(_ hr: [HRSample]) -> [HRSample] { cleanWithReport(hr).samples }

    public static func cleanWithReport(_ hr: [HRSample]) -> (samples: [HRSample], report: Report) {
        var rep = Report()
        let sorted = hr.sorted { $0.ts < $1.ts }
        var s: [HRSample] = []
        s.reserveCapacity(sorted.count)
        for x in sorted {
            if let l = s.last, l.ts == x.ts { rep.duplicates += 1; continue }
            if x.bpm < minValidBPM || x.bpm > maxValidBPM { rep.outOfRange += 1; continue }
            s.append(x)
        }
        guard s.count >= 5 else { return (s, rep) }
        var drop = [Bool](repeating: false, count: s.count)
        var i = 1
        while i < s.count - 1 {
            var matched = false
            for run in 1...maxSpikeRun where i + run < s.count {
                let a = s[i - 1], b = s[i + run]
                guard b.ts - a.ts <= maxAnchorGapS + run, abs(a.bpm - b.bpm) <= anchorAgreementBPM else { continue }
                let lo = min(a.bpm, b.bpm), hi = max(a.bpm, b.bpm)
                let allOff = (i..<(i + run)).allSatisfy { s[$0].bpm > hi + spikeDeviationBPM || s[$0].bpm < lo - spikeDeviationBPM }
                if allOff {
                    for k in i..<(i + run) { drop[k] = true }
                    rep.spikes += run
                    i += run
                    matched = true
                    break
                }
            }
            if !matched { i += 1 }
        }
        return (zip(s, drop).filter { !$0.1 }.map { $0.0 }, rep)
    }
}
