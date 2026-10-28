import Foundation
import WhoopStore

// MetricProvenance.swift — what a number IS, so incompatible numbers never share a baseline.
//
// "HRV 52 ms" is not one quantity. RMSSD and SDNN are different statistics; a nightly median of 5-min windows is not
// a whole-night summary or a morning spot check; a WHOOP-exported value and a NOOP-computed value come from different
// processing even on the same strap. A `MetricIdentity` carries every field that changes the meaning of the value,
// and two observations may share a personal reference ONLY when their identities are equal. Unknown metadata is kept
// as the explicit value "unknown" (it is not a wildcard: unknown hardware matches only unknown hardware).
//
// A change of source, hardware, algorithm version, context or aggregation therefore starts a new calibration period.
// Bridging two identities would need an overlap-based migration validated on paired data; none exists yet.

public enum MetricDefinition: String, Codable, Sendable {
    case rmssd                    // Task Force RMSSD, ms
    case sdnn                     // Task Force SDNN, ms
    case sleepRestingHR           // low-quantile sleeping HR, bpm (see SleepVitals.restingQuantile)
    case sleepMeanHR              // mean HR over valid sleep windows, bpm
    case respiratoryRateInferred  // respiratory-sinus-arrhythmia frequency from R-R, breaths/min (experimental)
    case respiratoryRateDirect    // a device-reported respiration channel, breaths/min
    case totalSleepTime           // minutes
    case vendorRecovery           // a vendor's proprietary composite, 0–100
}

public enum MetricSource: String, Codable, Sendable {
    case noopComputed = "noop"
    case whoopExport = "whoop-export"
    case appleHealth = "apple-health"
    case manual
}

public enum MeasurementContext: String, Codable, Sendable {
    case sleep, daytimeSpot, pacedBreathing, wholeDay, unknown
}

public enum MetricAggregation: String, Codable, Sendable {
    case medianOf5MinWindows      // SleepVitals HRV
    case lowQuartileOf5MinWindows // SleepVitals resting HR
    case meanOf5MinWindows
    case dailyMean
    case vendorUnspecified        // the exporter does not say
}

public struct MetricIdentity: Hashable, Codable, Sendable {
    public let definition: MetricDefinition
    public let unit: String
    public let source: MetricSource
    public let hardware: String
    public let algorithmVersion: String
    public let context: MeasurementContext
    public let aggregation: MetricAggregation

    public static let unknownValue = "unknown"

    public init(definition: MetricDefinition, unit: String, source: MetricSource,
                hardware: String = MetricIdentity.unknownValue, algorithmVersion: String = MetricIdentity.unknownValue,
                context: MeasurementContext, aggregation: MetricAggregation) {
        self.definition = definition; self.unit = unit; self.source = source; self.hardware = hardware
        self.algorithmVersion = algorithmVersion; self.context = context; self.aggregation = aggregation
    }

    /// Two observations may share one personal reference only when every identity field matches.
    public func isBaselineCompatible(with other: MetricIdentity) -> Bool { self == other }

    // MARK: Identities of the values NOOP handles today

    /// Version of NOOP's nightly vitals pipeline (SleepVitals gates + HRVAnalyzer cleaning). Bump with any change that
    /// alters these values; a bump starts a new baseline partition.
    public static let noopVitalsVersion = "vitals-2026.10"

    public static func noopNightlyRMSSD(hardware: String = unknownValue) -> MetricIdentity {
        MetricIdentity(definition: .rmssd, unit: "ms", source: .noopComputed, hardware: hardware,
                       algorithmVersion: noopVitalsVersion, context: .sleep, aggregation: .medianOf5MinWindows)
    }
    public static func noopSleepRestingHR(hardware: String = unknownValue) -> MetricIdentity {
        MetricIdentity(definition: .sleepRestingHR, unit: "bpm", source: .noopComputed, hardware: hardware,
                       algorithmVersion: noopVitalsVersion, context: .sleep, aggregation: .lowQuartileOf5MinWindows)
    }
    public static func noopInferredRespiration(hardware: String = unknownValue) -> MetricIdentity {
        MetricIdentity(definition: .respiratoryRateInferred, unit: "breaths/min", source: .noopComputed,
                       hardware: hardware, algorithmVersion: noopVitalsVersion, context: .sleep,
                       aggregation: .medianOf5MinWindows)
    }
    /// WHOOP's exported nightly HRV: RMSSD by WHOOP's description, aggregation/window not disclosed.
    public static let whoopExportRMSSD = MetricIdentity(definition: .rmssd, unit: "ms", source: .whoopExport,
                                                        context: .sleep, aggregation: .vendorUnspecified)
    public static let whoopExportRestingHR = MetricIdentity(definition: .sleepRestingHR, unit: "bpm",
                                                            source: .whoopExport, context: .sleep,
                                                            aggregation: .vendorUnspecified)
    /// Apple Health "HeartRateVariabilitySDNN" daily mean of mostly daytime spot readings.
    public static let appleHealthSDNN = MetricIdentity(definition: .sdnn, unit: "ms", source: .appleHealth,
                                                       context: .unknown, aggregation: .dailyMean)
}

/// One value with its identity, time and quality. `value == nil` means unavailable, with `exclusionReasons`.
public struct MetricObservation: Equatable, Sendable {
    public let identity: MetricIdentity
    /// Wake day the value belongs to ("YYYY-MM-DD", the wearer's local calendar).
    public let day: String
    /// End of the measured period (unix s), if known; orders same-day observations.
    public let endTs: Int?
    public let value: Double?
    /// Measurement coverage in [0, 1] (e.g. valid-window temporal coverage), if known.
    public let coverage: Double?
    /// Why the value is unavailable or must not update a reference. Empty = eligible.
    public let exclusionReasons: [String]

    public init(identity: MetricIdentity, day: String, endTs: Int? = nil, value: Double?,
                coverage: Double? = nil, exclusionReasons: [String] = []) {
        self.identity = identity; self.day = day; self.endTs = endTs; self.value = value
        self.coverage = coverage; self.exclusionReasons = exclusionReasons
    }

    public var isEligible: Bool {
        exclusionReasons.isEmpty && value.map { $0.isFinite } == true
    }
}

extension MetricObservation {
    /// NOOP-computed nightly rows (the "-noop" device) as typed observations. Only call this with rows NOOP computed
    /// itself under the CURRENT algorithm version; merged dashboard rows mix sources field by field.
    public static func noopNightly(_ rows: [DailyMetric], hardware: String = MetricIdentity.unknownValue)
        -> (rmssd: [MetricObservation], restingHR: [MetricObservation]) {
        let h = rows.map { MetricObservation(identity: .noopNightlyRMSSD(hardware: hardware), day: $0.day, value: $0.avgHrv,
                                             exclusionReasons: $0.avgHrv == nil ? ["unavailable"] : []) }
        let r = rows.map { MetricObservation(identity: .noopSleepRestingHR(hardware: hardware), day: $0.day,
                                             value: $0.restingHr.map(Double.init),
                                             exclusionReasons: $0.restingHr == nil ? ["unavailable"] : []) }
        return (h, r)
    }
}
