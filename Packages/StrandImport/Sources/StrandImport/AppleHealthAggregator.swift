import Foundation

// MARK: - Daily aggregate model

/// One day's worth of Apple Health metrics, bucketed by the sample's own local
/// day (`start` shifted by `tzOffsetMin`). Mirrors the per-day shape the app
/// stores and charts alongside Whoop.
///
/// All `*Min` fields are minutes; energies are kcal; heart rates are count/min;
/// `spo2Pct` is a 0–100 percentage; `vo2max` is mL/kg/min.
// One row per local day, combining sample-based metrics with that night's sleep totals.
public struct AppleDailyAggregate: Equatable, Sendable {
    /// `yyyy-MM-dd` in the sample's own UTC offset (local civil day).
    public let day: String

    // Cardio / respiratory means
    public let restingHr: Double?
    public let hrvSDNN: Double?
    public let spo2Pct: Double?
    public let respRate: Double?

    // Heart-rate stream
    public let avgHr: Double?
    public let maxHr: Double?
    public let walkingHr: Double?

    // Activity / fitness
    public let steps: Double?
    public let activeKcal: Double?
    public let basalKcal: Double?
    public let vo2max: Double?

    // Body composition (daily latest)
    public let weightKg: Double?
    public let bodyFatPct: Double?
    public let leanMassKg: Double?
    public let bmi: Double?

    // Sleep (minutes per stage), keyed by the wake day
    public let asleepMin: Double?
    public let deepMin: Double?
    public let remMin: Double?
    public let coreMin: Double?
    public let awakeMin: Double?
    public let inBedMin: Double?

    public init(
        day: String,
        restingHr: Double? = nil,
        hrvSDNN: Double? = nil,
        spo2Pct: Double? = nil,
        respRate: Double? = nil,
        avgHr: Double? = nil,
        maxHr: Double? = nil,
        walkingHr: Double? = nil,
        steps: Double? = nil,
        activeKcal: Double? = nil,
        basalKcal: Double? = nil,
        vo2max: Double? = nil,
        weightKg: Double? = nil,
        bodyFatPct: Double? = nil,
        leanMassKg: Double? = nil,
        bmi: Double? = nil,
        asleepMin: Double? = nil,
        deepMin: Double? = nil,
        remMin: Double? = nil,
        coreMin: Double? = nil,
        awakeMin: Double? = nil,
        inBedMin: Double? = nil
    ) {
        self.day = day
        self.restingHr = restingHr
        self.hrvSDNN = hrvSDNN
        self.spo2Pct = spo2Pct
        self.respRate = respRate
        self.avgHr = avgHr
        self.maxHr = maxHr
        self.walkingHr = walkingHr
        self.steps = steps
        self.activeKcal = activeKcal
        self.basalKcal = basalKcal
        self.vo2max = vo2max
        self.weightKg = weightKg
        self.bodyFatPct = bodyFatPct
        self.leanMassKg = leanMassKg
        self.bmi = bmi
        self.asleepMin = asleepMin
        self.deepMin = deepMin
        self.remMin = remMin
        self.coreMin = coreMin
        self.awakeMin = awakeMin
        self.inBedMin = inBedMin
    }
}

// MARK: - Aggregator

/// Turns a parsed Apple Health export into per-day aggregates.
public enum AppleHealthAggregator {

    // MARK: Type identifiers
    //
    // `HealthSample.type` is stored with the `HKQuantityTypeIdentifier` /
    // `HKCategoryTypeIdentifier` prefix already stripped (see
    // `AppleHealthImporter.stripPrefix`). We still accept the full identifier
    // form so callers feeding raw HK strings get the same mapping.

    private static let restingHR = "RestingHeartRate"
    private static let hrvSDNN = "HeartRateVariabilitySDNN"
    private static let spo2 = "OxygenSaturation"
    private static let respRate = "RespiratoryRate"
    private static let walkingHR = "WalkingHeartRateAverage"
    private static let heartRate = "HeartRate"
    private static let stepCount = "StepCount"
    private static let activeEnergy = "ActiveEnergyBurned"
    private static let basalEnergy = "BasalEnergyBurned"
    private static let vo2max = "VO2Max"
    private static let bodyMass = "BodyMass"
    private static let bodyFat = "BodyFatPercentage"
    private static let leanMass = "LeanBodyMass"
    private static let bodyMassIndex = "BodyMassIndex"

    /// Normalize a sample's `type` to the stripped HK identifier so matching
    /// works whether the caller passed `HeartRate` or
    /// `HKQuantityTypeIdentifierHeartRate`.
    private static func normalizedType(_ raw: String) -> String {
        let prefixes = [
            "HKQuantityTypeIdentifier",
            "HKCategoryTypeIdentifier",
            "HKDataTypeIdentifier",
        ]
        for p in prefixes where raw.hasPrefix(p) {
            return String(raw.dropFirst(p.count))
        }
        return raw
    }

    /// Whether a HealthKit mass unit string denotes pounds (`lb`, `lbs`).
    /// HealthKit normally exports BodyMass/LeanBodyMass in kg, but guard against
    /// pound-denominated exports.
    private static func unitLooksLikePounds(_ unit: String?) -> Bool {
        guard let u = unit?.lowercased() else { return false }
        return u == "lb" || u == "lbs" || u.contains("pound")
    }

    // MARK: Day bucketing

    /// `yyyy-MM-dd` for a UTC `Date` shifted into its own local offset.
    /// We add the offset to the UTC instant and read the calendar fields in
    /// UTC, which yields the civil (wall-clock) date the sample was recorded on.
    static func localDay(_ utc: Date, tzOffsetMin: Int) -> String {
        let shifted = utc.addingTimeInterval(TimeInterval(tzOffsetMin * 60))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Sample daily aggregation

    /// Group `HealthSamples` by local day and apply the per-type reduction rules.
    // Reduction rules differ by metric: resting HR/HRV/SpO2 are averaged, steps and energy summed, VO2max and body metrics keep the latest.
    public static func daily(samples: [HealthSample]) -> [AppleDailyAggregate] {
        // Per-day accumulators.
        struct Acc {
            var resting: [Double] = []
            var hrv: [Double] = []
            var spo2: [Double] = []
            var resp: [Double] = []
            var walking: [Double] = []
            var hr: [Double] = []
            var steps = 0.0
            var hasSteps = false
            var active = 0.0
            var hasActive = false
            var basal = 0.0
            var hasBasal = false
            // VO2Max: keep the latest by sample end time.
            var vo2: Double?
            var vo2At: Date?
            // Body composition: keep the latest by sample end time.
            var weight: Double?
            var weightAt: Date?
            var bodyFat: Double?
            var bodyFatAt: Date?
            var lean: Double?
            var leanAt: Date?
            var bmi: Double?
            var bmiAt: Date?
        }

        var byDay: [String: Acc] = [:]
        // Preserve first-seen day order for deterministic output before sort.
        var order: [String] = []

        for s in samples {
            let type = normalizedType(s.type)
            let day = localDay(s.start, tzOffsetMin: s.tzOffsetMin)
            if byDay[day] == nil {
                byDay[day] = Acc()
                order.append(day)
            }

            switch type {
            case restingHR:
                if let v = s.value { byDay[day]!.resting.append(v) }
            case hrvSDNN:
                if let v = s.value { byDay[day]!.hrv.append(v) }
            case spo2:
                if let v = s.value {
                    // Detect fraction (0..1) → percent. The importer already
                    // scales OxygenSaturation by 100, but defend against raw
                    // fractional values here too.
                    let pct = (v > 0 && v <= 1.0) ? v * 100.0 : v
                    byDay[day]!.spo2.append(pct)
                }
            case respRate:
                if let v = s.value { byDay[day]!.resp.append(v) }
            case walkingHR:
                if let v = s.value { byDay[day]!.walking.append(v) }
            case heartRate:
                if let v = s.value { byDay[day]!.hr.append(v) }
            case stepCount:
                if let v = s.value { byDay[day]!.steps += v; byDay[day]!.hasSteps = true }
            case activeEnergy:
                if let v = s.value { byDay[day]!.active += v; byDay[day]!.hasActive = true }
            case basalEnergy:
                if let v = s.value { byDay[day]!.basal += v; byDay[day]!.hasBasal = true }
            case vo2max:
                if let v = s.value {
                    let acc = byDay[day]!
                    if acc.vo2 == nil || (acc.vo2At ?? .distantPast) <= s.end {
                        byDay[day]!.vo2 = v
                        byDay[day]!.vo2At = s.end
                    }
                }
            case bodyMass:
                if let v = s.value {
                    // HealthKit stores BodyMass in kg by default. If the unit
                    // looks like pounds, convert to kg; otherwise assume kg.
                    let kg = Self.unitLooksLikePounds(s.unit) ? v * 0.453592 : v
                    let acc = byDay[day]!
                    if acc.weight == nil || (acc.weightAt ?? .distantPast) <= s.end {
                        byDay[day]!.weight = kg
                        byDay[day]!.weightAt = s.end
                    }
                }
            case bodyFat:
                if let v = s.value {
                    // HealthKit stores a 0..1 fraction → percent. Defend against
                    // already-percent values the same way SpO2 does.
                    let pct = (v > 0 && v <= 1.0) ? v * 100.0 : v
                    let acc = byDay[day]!
                    if acc.bodyFat == nil || (acc.bodyFatAt ?? .distantPast) <= s.end {
                        byDay[day]!.bodyFat = pct
                        byDay[day]!.bodyFatAt = s.end
                    }
                }
            case leanMass:
                if let v = s.value {
                    let kg = Self.unitLooksLikePounds(s.unit) ? v * 0.453592 : v
                    let acc = byDay[day]!
                    if acc.lean == nil || (acc.leanAt ?? .distantPast) <= s.end {
                        byDay[day]!.lean = kg
                        byDay[day]!.leanAt = s.end
                    }
                }
            case bodyMassIndex:
                if let v = s.value {
                    let acc = byDay[day]!
                    if acc.bmi == nil || (acc.bmiAt ?? .distantPast) <= s.end {
                        byDay[day]!.bmi = v
                        byDay[day]!.bmiAt = s.end
                    }
                }
            default:
                break
            }
        }

        func mean(_ xs: [Double]) -> Double? {
            xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
        }
        func mx(_ xs: [Double]) -> Double? { xs.max() }

        let result: [AppleDailyAggregate] = order.map { day in
            let a = byDay[day]!
            return AppleDailyAggregate(
                day: day,
                restingHr: mean(a.resting),
                hrvSDNN: mean(a.hrv),
                spo2Pct: mean(a.spo2),
                respRate: mean(a.resp),
                avgHr: mean(a.hr),
                maxHr: mx(a.hr),
                walkingHr: mean(a.walking),
                steps: a.hasSteps ? a.steps : nil,
                activeKcal: a.hasActive ? a.active : nil,
                basalKcal: a.hasBasal ? a.basal : nil,
                vo2max: a.vo2,
                weightKg: a.weight,
                bodyFatPct: a.bodyFat,
                leanMassKg: a.lean,
                bmi: a.bmi
            )
        }
        return result.sorted { $0.day < $1.day }
    }

    // MARK: - Sleep daily aggregation

    /// Collapse sleep-stage intervals into per-night totals keyed by the **wake
    /// day** — the local civil day of each interval's `end`. Minutes are summed
    /// per stage; `asleep = core + deep + rem` (+ any legacy "asleep
    /// unspecified" intervals, which Apple emitted before staged sleep).
    // Sleep is assigned to the day you WAKE UP, so a night from 11pm to 7am counts toward the morning's day.
    public static func sleepDaily(
        _ intervals: [SleepStageInterval]
    ) -> [String: (asleep: Double, deep: Double, rem: Double, core: Double, awake: Double, inBed: Double)] {
        struct Night {
            var deep = 0.0, rem = 0.0, core = 0.0, unspecified = 0.0, awake = 0.0, inBed = 0.0
        }
        var byDay: [String: Night] = [:]

        for iv in intervals {
            let minutes = max(0, iv.end.timeIntervalSince(iv.start)) / 60.0
            // Wake day = local day of the interval end.
            let day = localDay(iv.end, tzOffsetMin: iv.tzOffsetMin)
            var n = byDay[day] ?? Night()
            switch iv.stage {
            case .asleepDeep:        n.deep += minutes
            case .asleepREM:         n.rem += minutes
            case .asleepCore:        n.core += minutes
            case .asleepUnspecified: n.unspecified += minutes
            case .awake:             n.awake += minutes
            case .inBed:             n.inBed += minutes
            case .unknown:           break
            }
            byDay[day] = n
        }

        var out: [String: (asleep: Double, deep: Double, rem: Double, core: Double, awake: Double, inBed: Double)] = [:]
        for (day, n) in byDay {
            let asleep = n.core + n.deep + n.rem + n.unspecified
            out[day] = (asleep: asleep, deep: n.deep, rem: n.rem, core: n.core, awake: n.awake, inBed: n.inBed)
        }
        return out
    }

    // MARK: - Full merge

    /// Full merge of sample-daily + sleep-daily into `[AppleDailyAggregate]`,
    /// one row per day present in either source, sorted ascending by day.
    // Union of days from both sources, so a day with sleep but no samples (or vice versa) still appears.
    public static func aggregate(_ result: AppleHealthImportResult) -> [AppleDailyAggregate] {
        let sampleDaily = daily(samples: result.samples)
        let sleep = sleepDaily(result.sleepIntervals)

        var byDay: [String: AppleDailyAggregate] = [:]
        for d in sampleDaily { byDay[d.day] = d }

        // Union of days from both sources.
        var days = Set(byDay.keys)
        days.formUnion(sleep.keys)

        let merged: [AppleDailyAggregate] = days.map { day in
            let base = byDay[day]
            let s = sleep[day]
            return AppleDailyAggregate(
                day: day,
                restingHr: base?.restingHr,
                hrvSDNN: base?.hrvSDNN,
                spo2Pct: base?.spo2Pct,
                respRate: base?.respRate,
                avgHr: base?.avgHr,
                maxHr: base?.maxHr,
                walkingHr: base?.walkingHr,
                steps: base?.steps,
                activeKcal: base?.activeKcal,
                basalKcal: base?.basalKcal,
                vo2max: base?.vo2max,
                weightKg: base?.weightKg,
                bodyFatPct: base?.bodyFatPct,
                leanMassKg: base?.leanMassKg,
                bmi: base?.bmi,
                asleepMin: s?.asleep,
                deepMin: s?.deep,
                remMin: s?.rem,
                coreMin: s?.core,
                awakeMin: s?.awake,
                inBedMin: s?.inBed
            )
        }
        return merged.sorted { $0.day < $1.day }
    }

    // MARK: - Metric point flattening

    /// Flatten daily aggregates into generic `(day, key, value)` metric points
    /// for the metricSeries store. Only present (non-nil) values are emitted.
    /// Keys are stable, snake_case identifiers.
    // Flattens to (day, key, value) rows for the generic metric store.
    public static func metricPoints(_ daily: [AppleDailyAggregate]) -> [(day: String, key: String, value: Double)] {
        var out: [(day: String, key: String, value: Double)] = []
        for d in daily {
            func add(_ key: String, _ value: Double?) {
                if let v = value { out.append((day: d.day, key: key, value: v)) }
            }
            add("resting_hr", d.restingHr)
            add("hrv", d.hrvSDNN)
            add("spo2", d.spo2Pct)
            add("resp_rate", d.respRate)
            add("avg_hr", d.avgHr)
            add("max_hr", d.maxHr)
            add("walking_hr", d.walkingHr)
            add("steps", d.steps)
            add("active_kcal", d.activeKcal)
            add("basal_kcal", d.basalKcal)
            add("vo2max", d.vo2max)
            add("weight", d.weightKg)
            add("body_fat", d.bodyFatPct)
            add("lean_mass", d.leanMassKg)
            add("bmi", d.bmi)
            add("asleep_min", d.asleepMin)
            add("deep_min", d.deepMin)
            add("rem_min", d.remMin)
            add("core_min", d.coreMin)
            add("awake_min", d.awakeMin)
            add("in_bed_min", d.inBedMin)
        }
        return out
    }
}
