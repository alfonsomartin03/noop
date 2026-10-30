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
    case sleep24h                 // minutes of sleep in the 24 h ending at the day's final awakening
    case lnRMSSDDeviation         // robust z of ln RMSSD vs a causal reference, unitless
    case restingHRDeviation       // robust z of sleeping resting HR, unitless
    case legacyRecoveryIndex      // RecoveryScorer logistic index, 0–100
    case vendorRecovery           // a vendor's proprietary composite, 0–100
    case cardioLoadZone           // fitted zone load integrated over supported seconds, AU
    case strainIndex              // versioned display mapping of cardio load, 0–21
}

public enum MetricSource: String, Codable, Sendable {
    case noopComputed = "noop"
    case whoopExport = "whoop-export"
    case appleHealth = "apple-health"
    case manual
}

public enum MeasurementContext: String, Codable, Sendable {
    case sleep, daytimeSpot, pacedBreathing, wholeDay, awakeTime, unknown
}

public enum MetricAggregation: String, Codable, Sendable {
    case medianOf5MinWindows      // SleepVitals HRV
    case lowQuartileOf5MinWindows // SleepVitals resting HR
    case meanOf5MinWindows
    case dailyMean
    case intervalUnion            // union of sleep intervals (SleepAccounting)
    case intervalSum              // sum over unique supported intervals (CardioLoad)
    case modelOutput              // output of a named model (see algorithmVersion)
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

// MARK: - Persisted provenance

extension MetricIdentity {
    /// The identity a stored provenance row describes; nil when a field holds a value this build does not know
    /// (e.g. written by a newer version) — such a value is never treated as compatible.
    public init?(record r: ProvenanceRecord) {
        guard let d = MetricDefinition(rawValue: r.definition), let s = MetricSource(rawValue: r.source),
              let c = MeasurementContext(rawValue: r.context), let a = MetricAggregation(rawValue: r.aggregation)
        else { return nil }
        self.init(definition: d, unit: r.unit, source: s, hardware: r.hardware, algorithmVersion: r.algorithmVersion,
                  context: c, aggregation: a)
    }

    public func record(day: String, key: String, coverage: Double? = nil, exclusionReasons: [String] = [],
                       scoringVersion: Int) -> ProvenanceRecord {
        ProvenanceRecord(day: day, key: key, definition: definition.rawValue, unit: unit, source: source.rawValue,
                         hardware: hardware, algorithmVersion: algorithmVersion, context: context.rawValue,
                         aggregation: aggregation.rawValue, coverage: coverage, exclusionReasons: exclusionReasons,
                         scoringVersion: scoringVersion)
    }
}

extension MetricObservation {
    /// Stored NOOP nightly rows as typed observations, each carrying the identity its PERSISTED provenance records.
    /// A row with no provenance (written before provenance existed) or with provenance this build can't read gets an
    /// explicitly unknown identity, so it can never join a current-version reference.
    public static func noopNightly(_ rows: [DailyMetric], provenance: [ProvenanceRecord])
        -> (rmssd: [MetricObservation], restingHR: [MetricObservation]) {
        var byKey: [String: ProvenanceRecord] = [:]
        for p in provenance { byKey[p.day + "|" + p.key] = p }
        func identity(_ day: String, _ key: String, _ def: MetricDefinition, _ unit: String) -> MetricIdentity {
            byKey[day + "|" + key].flatMap(MetricIdentity.init(record:))
                ?? MetricIdentity(definition: def, unit: unit, source: .noopComputed, context: .unknown,
                                  aggregation: .vendorUnspecified)
        }
        func reasons(_ day: String, _ key: String, _ present: Bool) -> [String] {
            (present ? [] : ["unavailable"]) + (byKey[day + "|" + key]?.exclusionReasons ?? [])
        }
        let h = rows.map { MetricObservation(identity: identity($0.day, ProvenanceKey.avgHrv, .rmssd, "ms"), day: $0.day,
                                             value: $0.avgHrv, coverage: byKey[$0.day + "|" + ProvenanceKey.avgHrv]?.coverage,
                                             exclusionReasons: reasons($0.day, ProvenanceKey.avgHrv, $0.avgHrv != nil)) }
        let r = rows.map { MetricObservation(identity: identity($0.day, ProvenanceKey.restingHr, .sleepRestingHR, "bpm"),
                                             day: $0.day, value: $0.restingHr.map(Double.init),
                                             exclusionReasons: reasons($0.day, ProvenanceKey.restingHr, $0.restingHr != nil)) }
        return (h, r)
    }

    /// Rows produced in this very run (identity known without a store round trip).
    public static func noopNightly(_ rows: [DailyMetric], hardware: String = MetricIdentity.unknownValue)
        -> (rmssd: [MetricObservation], restingHR: [MetricObservation]) {
        noopNightly(rows, provenance: rows.flatMap { ProvenanceKey.records(for: $0, assessment: nil, hardware: hardware,
                                                                            scoringVersion: 0) })
    }
}

/// Keys under which a day's derived values and their provenance are stored.
public enum ProvenanceKey {
    public static let avgHrv = "avgHrv"
    public static let restingHr = "restingHr"
    public static let respRateBpm = "respRateBpm"
    public static let totalSleepMin = "totalSleepMin"
    public static let recovery = "recovery"
    public static let sleep24h = "noop.sleep_24h_min"
    public static let lnRMSSDz = "noop.ln_rmssd_z"
    public static let restingHRz = "noop.resting_hr_z"
    public static let strain = "strain"
    public static let cardioLoad = "noop.cardio_load"

    /// Provenance for a day's load and index. Coverage travels with the value; a withheld value records why.
    public static func records(forLoad l: DayLoadRecord, hardware: String = MetricIdentity.unknownValue,
                               scoringVersion: Int) -> [ProvenanceRecord] {
        let load = MetricIdentity(definition: .cardioLoadZone, unit: "AU", source: .noopComputed, hardware: hardware,
                                  algorithmVersion: l.loadVersion, context: .awakeTime, aggregation: .intervalSum)
        let index = MetricIdentity(definition: .strainIndex, unit: "index", source: .noopComputed, hardware: hardware,
                                   algorithmVersion: l.indexVersion, context: .awakeTime, aggregation: .modelOutput)
        let coverage = l.summary?.coverage
        func reasons(_ present: Bool) -> [String] { (present ? [] : ["unavailable"]) + l.reasons }
        return [load.record(day: l.day, key: cardioLoad, coverage: coverage, exclusionReasons: reasons(l.summary != nil),
                            scoringVersion: scoringVersion),
                index.record(day: l.day, key: strain, coverage: coverage, exclusionReasons: reasons(l.strainIndex != nil),
                             scoringVersion: scoringVersion)]
    }

    /// Provenance for every derived value of one NOOP day. Unavailable values still get a record with the reason,
    /// so "not computed" and "computed by an older version" stay distinguishable.
    public static func records(for d: DailyMetric, assessment a: RecoveryAssessment?,
                               hardware: String = MetricIdentity.unknownValue, scoringVersion: Int) -> [ProvenanceRecord] {
        let q = a?.autonomic.quality
        func why(_ present: Bool, _ extra: [String] = []) -> [String] { present ? [] : (["unavailable"] + extra) }
        var out: [ProvenanceRecord] = [
            MetricIdentity.noopNightlyRMSSD(hardware: hardware).record(
                day: d.day, key: avgHrv, coverage: q?.hrvTemporalCoverage, exclusionReasons: why(d.avgHrv != nil),
                scoringVersion: scoringVersion),
            MetricIdentity.noopSleepRestingHR(hardware: hardware).record(
                day: d.day, key: restingHr, exclusionReasons: why(d.restingHr != nil), scoringVersion: scoringVersion),
            MetricIdentity.noopInferredRespiration(hardware: hardware).record(
                day: d.day, key: respRateBpm, exclusionReasons: why(d.respRateBpm != nil, ["experimental"]),
                scoringVersion: scoringVersion),
            MetricIdentity(definition: .totalSleepTime, unit: "min", source: .noopComputed, hardware: hardware,
                           algorithmVersion: SleepStager.stagingMethod, context: .sleep, aggregation: .intervalUnion)
                .record(day: d.day, key: totalSleepMin, exclusionReasons: why(d.totalSleepMin != nil),
                        scoringVersion: scoringVersion),
        ]
        guard let a else { return out }
        out.append(MetricIdentity(definition: .legacyRecoveryIndex, unit: "index", source: .noopComputed, hardware: hardware,
                                  algorithmVersion: a.legacy.modelVersion, context: .sleep, aggregation: .modelOutput)
            .record(day: d.day, key: recovery,
                    exclusionReasons: d.recovery != nil ? [] : ["unavailable"] + (a.legacy.withheldReason.map { [$0] } ?? []),
                    scoringVersion: scoringVersion))
        out.append(MetricIdentity(definition: .sleep24h, unit: "min", source: .noopComputed, hardware: hardware,
                                  algorithmVersion: SleepStager.stagingMethod, context: .wholeDay, aggregation: .intervalUnion)
            .record(day: d.day, key: sleep24h, exclusionReasons: why(a.sleep.shortfall.sleepMin != nil),
                    scoringVersion: scoringVersion))
        out.append(MetricIdentity(definition: .lnRMSSDDeviation, unit: "z", source: .noopComputed, hardware: hardware,
                                  algorithmVersion: MetricIdentity.noopVitalsVersion, context: .sleep, aggregation: .modelOutput)
            .record(day: d.day, key: lnRMSSDz, coverage: q?.hrvTemporalCoverage,
                    exclusionReasons: a.autonomic.lnRMSSDz != nil ? [] : ["unavailable"] + a.autonomic.notes,
                    scoringVersion: scoringVersion))
        out.append(MetricIdentity(definition: .restingHRDeviation, unit: "z", source: .noopComputed, hardware: hardware,
                                  algorithmVersion: MetricIdentity.noopVitalsVersion, context: .sleep, aggregation: .modelOutput)
            .record(day: d.day, key: restingHRz,
                    exclusionReasons: a.autonomic.restingHRz != nil ? [] : ["unavailable"] + a.autonomic.notes,
                    scoringVersion: scoringVersion))
        return out
    }
}
