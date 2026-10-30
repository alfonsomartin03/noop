import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

// perf_probe — times the real read and processing steps behind NOOP's screens and scoring. Build with -c release.
//
// Opening a store runs migrations, so ALWAYS point this at a COPY of the database:
//   sqlite3 "file:<app db>?mode=ro" ".backup /path/to/copy.sqlite"
//   swift run -c release perf_probe /path/to/copy.sqlite <device-id> <age> [hrMaxOverride]
//
// Figures are medians of repeated runs on one machine and one person's history: representative, not a benchmark.

let args = CommandLine.arguments
guard args.count >= 4, let age = Double(args[3]) else {
    print("usage: perf_probe <copy.sqlite> <device-id> <age> [hrMaxOverride]"); exit(2)
}
let rawId = args[2], computedId = rawId + "-noop"
let maxHR = args.count > 4 ? Double(args[4]) : nil
let profile = UserProfile(weightKg: 68, heightCm: 165, age: age)

extension String {
    var hashStable: String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

func ms(_ start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}
func timed<T>(_ label: String, runs: Int = 5, _ body: () async throws -> T) async rethrows -> T {
    var times: [Double] = [], out: T? = nil
    for _ in 0..<runs { let t = ContinuousClock.now; out = try await body(); times.append(ms(t)) }
    let m = times.sorted()[times.count / 2]
    print(String(format: "%9.2f ms  %@", m, label))
    return out!
}

let store = try await WhoopStore(path: args[1])
ZoneTimeline.shared.refreshFromSystem()

// --score: one incremental scoring pass, reporting what it recomputed. --hash: a digest of every derived result.
if let mode = args.dropFirst(5).first {
    let computed = rawId + "-noop"
    if mode == "--score" {
        let t = ContinuousClock.now
        let out = try await IncrementalScorer.run(store: store, request: ScoringRequest(
            rawId: rawId, profile: profile, maxHROverride: maxHR, scoringVersion: 5, now: Int(Date().timeIntervalSince1970), maxDays: 21))
        print(String(format: "%8.0f ms  recomputed %d: %@", ms(t), out.recomputed.count, out.recomputed.joined(separator: " ")))
        print("          reasons:", Dictionary(grouping: out.reasons.values, by: \.rawValue).mapValues(\.count))
    } else {
        let d = try await store.dailyMetrics(deviceId: computed, from: "0", to: "9")
        let w = try await store.workouts(deviceId: computed, from: 0, to: Int.max, limit: 5000)
        let l = try await store.loadRecords(deviceId: computed, from: "0", to: "9")
        let p = try await store.provenance(deviceId: computed, from: "0", to: "9")
        let s = try await store.sleepSessions(deviceId: computed, from: 0, to: Int.max, limit: 5000)
        print("days", d.count, "workouts", w.count, "records", l.count)
        print("\(d)".hashStable, "\(w)".hashStable, "\(l)".hashStable, "\(p)".hashStable, "\(s)".hashStable)
    }
    exit(0)
}
let stored = try await store.dailyMetrics(deviceId: computedId, from: "0000-00-00", to: "9999-99-99")
let day = stored.filter { ($0.strain ?? 0) > 10 }.map(\.day).sorted().last ?? stored.last!.day
let range = ZoneTimeline.shared.dayRange(day)!
let from = range.from - 16 * 3600, to = range.to, tail = to + AnalyticsEngine.followingWindowS
print("day:", day, " history days:", stored.count)

print("\n-- reads, one day's scoring window (-16 h to midnight) --")
let hr = try await timed("hrSamples") { try await store.hrSamples(deviceId: rawId, from: from, to: to, limit: 200_000) }
let rr = try await timed("rrIntervals") { try await store.rrIntervals(deviceId: rawId, from: from, to: to, limit: 200_000) }
let resp = try await timed("respSamples") { try await store.respSamples(deviceId: rawId, from: from, to: to, limit: 200_000) }
let grav = try await timed("gravitySamples") { try await store.gravitySamples(deviceId: rawId, from: from, to: to, limit: 200_000) }
print("rows: hr \(hr.count) rr \(rr.count) resp \(resp.count) gravity \(grav.count)")

print("\n-- reads behind screens --")
_ = try await timed("dailyMetrics, all (x2 in refresh)") { try await store.dailyMetrics(deviceId: computedId, from: "0000-00-00", to: "9999-99-99") }
_ = try await timed("dailyMetrics imported, all") { try await store.dailyMetrics(deviceId: rawId, from: "0000-00-00", to: "9999-99-99") }
_ = try await timed("sleepSessions imported") { try await store.sleepSessions(deviceId: rawId, from: 0, to: Int.max, limit: 4000) }
_ = try await timed("sleepSessions computed") { try await store.sleepSessions(deviceId: computedId, from: 0, to: Int.max, limit: 4000) }
let imports = try await timed("workouts imported") { try await store.workouts(deviceId: rawId, from: 0, to: Int.max, limit: 5000) }
let detected = try await timed("workouts computed") { try await store.workouts(deviceId: computedId, from: 0, to: Int.max, limit: 5000) }
_ = try await timed("provenance, all") { try await store.provenance(deviceId: computedId, from: "0000-00-00", to: "9999-99-99") }
_ = try await timed("loadRecords, one day") { try await store.loadRecords(deviceId: computedId, from: day, to: day) }

print("\n-- on the main actor when a Today or Strain screen opens --")
let dayHR = try await store.hrSamples(deviceId: rawId, from: range.from, to: range.to, limit: 200_000)
_ = await timed("hr.sorted (already sorted)") { dayHR.sorted { $0.ts < $1.ts } }
let zones = HRZones.zones(maxHR: maxHR ?? 190)
_ = await timed("HRZones.timeInZone") { HRZones.timeInZone(dayHR, zoneSet: zones) }
_ = await timed("SupportedHR(raw:)") { SupportedHR(raw: dayHR) }
_ = await timed("LoadSummary") { LoadSummary(SupportedHR(raw: dayHR), requestedS: 0, hrMax: maxHR ?? 190) }
_ = await timed("estimateDayCalories") { Calories.estimateDayCalories(dayHR, profile: profile, hrmax: maxHR, restingHR: 55) }
_ = await timed("workoutRows overlap filter + reconcile") {
    WorkoutReconciliation.reconcile(detected.filter { w in !imports.contains { w.startTs < $0.endTs && $0.startTs < w.endTs } })
}

print("\n-- scoring one day --")
let cleaned = HRQuality.clean(hr)
_ = await timed("HRQuality.clean") { HRQuality.clean(hr) }
_ = await timed("SleepStager.detectSleep", runs: 3) { SleepStager.detectSleep(hr: cleaned, rr: rr, resp: resp, gravity: grav) }
let support = SupportedHR(cleaned: cleaned).clipped(to: TimeSpan(range.from, range.to))
let cal = HRCalibration.resolve(day: day, declaredMax: maxHR, age: age)
_ = await timed("WorkoutDetector.detect") {
    WorkoutDetector.detect(cleaned: cleaned.filter { $0.ts >= range.from && $0.ts < range.to }, support: support,
                           gravity: grav.filter { $0.ts >= range.from && $0.ts < range.to }, calibration: cal, profile: profile)
}
let tailHR = try await store.hrSamples(deviceId: rawId, from: to, to: tail, limit: 200_000)
let tailGrav = try await store.gravitySamples(deviceId: rawId, from: to, to: tail, limit: 200_000)
_ = await timed("analyzeDay (no following)", runs: 3) {
    AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: rr, resp: resp, gravity: grav, profile: profile, maxHROverride: maxHR, dayRange: range)
}
_ = await timed("analyzeDay (following, hr+gravity)", runs: 3) {
    AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: rr, resp: resp, gravity: grav, profile: profile, maxHROverride: maxHR,
                               dayRange: range, following: .init(hr: tailHR, gravity: tailGrav))
}

print("\n-- one full analyzeRecent pass over stored days, as the 15-minute loop runs it --")
let days = stored.map(\.day).sorted()
var readMs = 0.0, computeMs = 0.0
let t0 = ContinuousClock.now
for d in days {
    guard let r = ZoneTimeline.shared.dayRange(d) else { continue }
    let t1 = ContinuousClock.now
    let f = r.from - 16 * 3600, e = r.to, x = e + AnalyticsEngine.followingWindowS
    let h = try await store.hrSamples(deviceId: rawId, from: f, to: e, limit: 200_000)
    guard h.count >= 200 else { continue }
    let a = try await store.rrIntervals(deviceId: rawId, from: f, to: e, limit: 200_000)
    let b = try await store.respSamples(deviceId: rawId, from: f, to: e, limit: 200_000)
    let c = try await store.gravitySamples(deviceId: rawId, from: f, to: e, limit: 200_000)
    let fo = AnalyticsEngine.FollowingData(
        hr: try await store.hrSamples(deviceId: rawId, from: e, to: x, limit: 200_000),
        rr: try await store.rrIntervals(deviceId: rawId, from: e, to: x, limit: 200_000),
        resp: try await store.respSamples(deviceId: rawId, from: e, to: x, limit: 200_000),
        gravity: try await store.gravitySamples(deviceId: rawId, from: e, to: x, limit: 200_000))
    readMs += ms(t1)
    let t2 = ContinuousClock.now
    _ = AnalyticsEngine.analyzeDay(day: d, hr: h, rr: a, resp: b, gravity: c, profile: profile, maxHROverride: maxHR,
                                   dayRange: r, following: fo)
    computeMs += ms(t2)
}
print(String(format: "%9.0f ms  total for %d days (reads %.0f, compute %.0f)", ms(t0), days.count, readMs, computeMs))
