import Foundation
import WhoopProtocol

// SkinTemperature.swift — nightly wrist skin temperature and its change from a personal, strictly causal reference.
//
// Input: WHOOP 5.0 skin-temperature samples in 1/100 °C (`SkinTempSample.unit == "centi_celsius"`, type-47 v0x12
// payload 65; layout SUPPORTED by two external sources and consistent with local frames, not calibrated against a
// reference thermometer). 4.0 ADC counts have no verified conversion and are never used.
//
// Night value  = median of the samples inside the asleep stages of the night's primary sleep (wake, unknown and gap
//                time excluded), only with enough sleep covered (`minSamples`, `minCoverage`); otherwise unavailable.
// Change       = night value − median of earlier nights (CausalReference, identity transform, °C), only while that
//                reference is provisional or established. Missing is never 0.
//
// Every threshold here is a provisional NOOP engineering choice (issue #25), not a validated physiological rule.
// Skin temperature at the wrist is not core body temperature, and a change is not a fever or illness reading.

public enum SkinTemperature {
    /// Bump with any change to the night value or reference; it is part of the scoring `algorithmKey` and identity.
    public static let version = "skin-temp-night-v1"

    /// Identity of the nightly absolute value (the reference only mixes nights of exactly this identity).
    public static func nightIdentity(hardware: String = MetricIdentity.unknownValue) -> MetricIdentity {
        MetricIdentity(definition: .skinTemperature, unit: "°C", source: .noopComputed, hardware: hardware,
                       algorithmVersion: version, context: .sleep, aggregation: .medianOverAsleep)
    }

    /// Identity of the stored change from the reference.
    public static func changeIdentity(hardware: String = MetricIdentity.unknownValue) -> MetricIdentity {
        MetricIdentity(definition: .skinTemperatureDeviation, unit: "°C", source: .noopComputed, hardware: hardware,
                       algorithmVersion: version, context: .sleep, aggregation: .modelOutput)
    }

    /// At least 30 min of 1-Hz samples inside asleep time.
    public static let minSamples = 1800
    /// And samples for at least half of the asleep seconds.
    public static let minCoverage = 0.5
    /// 30-day lookback like the Health Monitor; 5 earlier nights to start (provisional), 14 to be established;
    /// stale after 21 days without a night; scale floor 0.1 °C; nights outside 25–40 °C are excluded as implausible
    /// for a worn wrist during sleep.
    public static let reference = ReferenceConfig(transform: .identity, windowDays: 30, minPrior: 5, establishedAfter: 14,
                                                  staleAfterDays: 21, noiseFloor: 0.1, plausibleRange: 25...40)

    public struct Night: Equatable, Sendable {
        /// Median skin temperature over asleep time, °C; nil when unavailable (see `exclusionReasons`).
        public let valueC: Double?
        public let samples: Int
        public let asleepS: Int
        /// Share of asleep seconds with a sample, 0…1.
        public let coverage: Double
        public let exclusionReasons: [String]
    }

    /// The night value from skin samples and the asleep stage segments of the primary sleep.
    public static func night(samples: [SkinTempSample], stages: [StageSegment]) -> Night {
        let asleep = stages.filter { $0.state.isSleep && $0.end > $0.start }.sorted { $0.start < $1.start }
        let asleepS = asleep.reduce(0) { $0 + ($1.end - $1.start) }
        guard asleepS > 0 else {
            return Night(valueC: nil, samples: 0, asleepS: 0, coverage: 0, exclusionReasons: ["no asleep time"])
        }
        // One value per second (duplicates dropped), walked against the sorted segments.
        let usable = samples.filter { $0.unit == Whoop5HistoricalRecord.skinTempUnit && $0.celsius != nil }
            .sorted { $0.ts < $1.ts }
        var values: [Double] = []
        var i = 0
        var lastTs: Int?
        for s in usable {
            if s.ts == lastTs { continue }
            lastTs = s.ts
            while i < asleep.count && asleep[i].end <= s.ts { i += 1 }
            guard i < asleep.count else { break }
            if s.ts >= asleep[i].start, let c = s.celsius { values.append(c) }
        }
        let coverage = min(1, Double(values.count) / Double(asleepS))
        var reasons: [String] = []
        if values.isEmpty { reasons.append("no skin-temperature samples") }
        else if values.count < minSamples { reasons.append("too few samples") }
        if !values.isEmpty, coverage < minCoverage { reasons.append("low coverage") }
        let value = reasons.isEmpty ? HRVAnalyzer.median(values) : nil
        return Night(valueC: value, samples: values.count, asleepS: asleepS, coverage: coverage, exclusionReasons: reasons)
    }

    /// Change from the reference, °C, or nil while the reference is missing, calibrating or stale, or the night is
    /// unavailable or outside the plausible range.
    public static func change(night: Double?, reference ref: ReferenceSnapshot?) -> Double? {
        guard let v = night, reference.plausibleRange.contains(v), let r = ref,
              r.state == .provisional || r.state == .established, r.center.isFinite else { return nil }
        return v - r.center
    }
}
