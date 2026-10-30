import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

// strain_replay — compares current scoring with the rows already stored, day by day. Nothing is written back.
//
// Opening a store runs migrations, so ALWAYS point this at a COPY of the database, never at the app's own file:
//   sqlite3 "file:<app db>?mode=ro" ".backup /path/to/copy.sqlite"
//   swift run strain_replay /path/to/copy.sqlite <device-id> <age> [hrMaxOverride]
//
// The agreement it prints is a compatibility check with the previous NOOP version, not evidence of accuracy.

let args = CommandLine.arguments
guard args.count >= 4, let age = Double(args[3]) else {
    print("usage: strain_replay <copy.sqlite> <device-id> <age> [hrMaxOverride]")
    exit(2)
}
let rawId = args[2]
let computedId = rawId + "-noop"
let maxHR = args.count > 4 ? Double(args[4]) : nil
let profile = UserProfile(age: age)

func fmt(_ v: Double?, _ d: Int = 2) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "—" }

let store = try await WhoopStore(path: args[1])
ZoneTimeline.shared.refreshFromSystem()

let stored = try await store.dailyMetrics(deviceId: computedId, from: "0000-00-00", to: "9999-99-99")
let storedWorkouts = try await store.workouts(deviceId: computedId, from: 0, to: Int.max, limit: 5000)
let days = stored.map(\.day).sorted()
let old = Dictionary(uniqueKeysWithValues: stored.map { ($0.day, $0) })

struct Scored { let res: AnalyticsEngine.DayResult }

let output = try await CausalReplay.run(
    days: days, seed: [], seedProvenance: [], scoringVersion: 0,
    analyze: { (day: String, baselines: AnalyticsEngine.ProfileBaselines) -> Scored? in
        guard let range = ZoneTimeline.shared.dayRange(day) else { return nil }
        let from = range.from - 16 * 3_600, to = range.to
        let hr = try await store.hrSamples(deviceId: rawId, from: from, to: to, limit: 200_000)
        guard hr.count >= 200 else { return nil }
        let rr = try await store.rrIntervals(deviceId: rawId, from: from, to: to, limit: 200_000)
        let resp = try await store.respSamples(deviceId: rawId, from: from, to: to, limit: 200_000)
        let grav = try await store.gravitySamples(deviceId: rawId, from: from, to: to, limit: 200_000)
        let tail = to + AnalyticsEngine.followingWindowS
        let following = AnalyticsEngine.FollowingData(
            hr: try await store.hrSamples(deviceId: rawId, from: to, to: tail, limit: 200_000),
            rr: try await store.rrIntervals(deviceId: rawId, from: to, to: tail, limit: 200_000),
            resp: try await store.respSamples(deviceId: rawId, from: to, to: tail, limit: 200_000),
            gravity: try await store.gravitySamples(deviceId: rawId, from: to, to: tail, limit: 200_000))
        return Scored(res: AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: rr, resp: resp, gravity: grav, profile: profile,
                                                      baselines: baselines, maxHROverride: maxHR, dayRange: range,
                                                      following: following))
    },
    daily: { $0.res.daily }, assessment: { $0.res.assessment }, load: { $0.res.load })

print("day         old    new    Δ      status    cover  obs_h  load    exerc   incid   edw   wOld wNew sleep_h slpLoad unsureH reasons")
var vitalsDiffs = 0
for (day, s) in output.results {
    let l = s.res.load, o = old[day]
    let delta = (o?.strain).flatMap { a in s.res.strain.map { $0 - a } }
    let line = [day, fmt(o?.strain).padding(toLength: 6, withPad: " ", startingAt: 0),
                fmt(s.res.strain).padding(toLength: 6, withPad: " ", startingAt: 0),
                fmt(delta).padding(toLength: 6, withPad: " ", startingAt: 0),
                (l?.status.rawValue ?? "—").padding(toLength: 9, withPad: " ", startingAt: 0),
                fmt(l?.summary?.coverage).padding(toLength: 6, withPad: " ", startingAt: 0),
                fmt(l?.summary.map { Double($0.observedS) / 3600 }, 1).padding(toLength: 6, withPad: " ", startingAt: 0),
                fmt(l?.summary?.zoneLoad, 1).padding(toLength: 7, withPad: " ", startingAt: 0),
                fmt(l?.exerciseLoad, 1).padding(toLength: 7, withPad: " ", startingAt: 0),
                fmt(l?.incidentalLoad, 1).padding(toLength: 7, withPad: " ", startingAt: 0),
                fmt(l?.summary?.edwardsLoad, 0).padding(toLength: 5, withPad: " ", startingAt: 0),
                "\(o?.exerciseCount ?? 0)".padding(toLength: 4, withPad: " ", startingAt: 0),
                "\(s.res.workouts.count)".padding(toLength: 4, withPad: " ", startingAt: 0),
                fmt(l.map { Double($0.sleepExcludedS) / 3600 }, 1).padding(toLength: 7, withPad: " ", startingAt: 0),
                fmt(l?.sleepExcludedLoad, 2).padding(toLength: 7, withPad: " ", startingAt: 0),
                fmt(l.map { Double($0.uncertainStateS) / 3600 }, 1).padding(toLength: 7, withPad: " ", startingAt: 0),
                (l?.reasons ?? []).joined(separator: ",")]
    print(line.joined(separator: " "))
    if let o {
        let d = s.res.daily
        if o.restingHr != d.restingHr || o.avgHrv != d.avgHrv || o.recovery != d.recovery || o.totalSleepMin != d.totalSleepMin {
            vitalsDiffs += 1
            print("   sleep/recovery differ: rhr \(String(describing: o.restingHr))→\(String(describing: d.restingHr)) hrv \(fmt(o.avgHrv))→\(fmt(d.avgHrv)) rec \(fmt(o.recovery))→\(fmt(d.recovery)) sleep \(fmt(o.totalSleepMin))→\(fmt(d.totalSleepMin))")
        }
    }
}
print("days with changed sleep/recovery fields: \(vitalsDiffs) of \(output.results.count)")

print("\nsessions (new)  start       elapsed active paused unknown cover  avg peak index  load    moving evidence")
for (_, s) in output.results {
    for w in s.res.workouts {
        let r = w.load
        print(String(format: "%@ %7.1f %6.1f %6.1f %7.1f %.2f %5.0f %4d %5.2f %6.1f  %@ %@",
                     "\(w.start)", w.durationS / 60, Double(r.activeS) / 60, Double(r.pausedS) / 60, Double(r.unknownS) / 60,
                     r.summary.coverage, w.avgHR, w.peakHR, w.strain ?? -1, r.summary.zoneLoad,
                     fmt(r.movingFraction), r.evidence.rawValue))
    }
}
print("\nsessions (stored)")
for w in storedWorkouts.sorted(by: { $0.startTs < $1.startTs }) {
    print(String(format: "%d %7.1f strain %5.2f avg %d", w.startTs, (w.durationS ?? 0) / 60, w.strain ?? -1, w.avgHr ?? 0))
}
