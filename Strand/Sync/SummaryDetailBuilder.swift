import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics

/// Builds the per-day detail the phone's Recovery / Sleep / Strain pages show (#79/#80): the same inputs as the Mac's
/// own detail pages, reduced to static numbers (sleep need and times, energy, average and peak heart rate, minutes in
/// each zone) plus a short workout list. No samples or curves leave the Mac (owner display rule, 2026-11-27).
@MainActor
enum SummaryDetailBuilder {
    static func build(day key: String, repo: Repository, profile: ProfileStore) async -> SummaryDetail? {
        guard let r = DayMath.range(key) else { return nil }
        let metric = repo.days.first { $0.day == key }
        var v: [String: Double] = [:]

        // Strain: heart-rate zones and energy over the recorded time of the day.
        let hr = await repo.hrSamples(from: r.from, to: r.to, limit: 200_000)
        if !hr.isEmpty {
            let stats = await DayHRStats.build(hr: hr, profile: profile, restingHR: metric?.restingHr)
            if let k = stats.kcal { v["kcal"] = k.rounded() }
            if let a = stats.average { v["avgHr"] = Double(a) }
            if let p = stats.peak { v["maxHr"] = Double(p.bpm) }
            v["activeMin"] = stats.activeMin.rounded()
            for z in 1...5 { v["zone\(z)Min"] = (stats.inZone.seconds(inZone: z) / 60).rounded() }
        }

        // Sleep: the main night ending on this day; bed/wake times, time in bed, awake time, need and performance.
        let nights = repo.sleeps.filter { $0.isMainSleep && Repository.dayString(Date(timeIntervalSince1970: TimeInterval($0.endTs))) == key }
        if let night = nights.max(by: { ($0.endTs - $0.startTs) < ($1.endTs - $1.startTs) }) {
            let inBed = Double(night.endTs - night.startTs) / 60
            v["sleepStartTs"] = Double(night.startTs)
            v["sleepEndTs"] = Double(night.endTs)
            v["timeInBedMin"] = inBed.rounded()
            if let asleep = metric?.totalSleepMin { v["awakeMin"] = max(0, inBed - asleep).rounded() }
        }
        let needMin = await repo.series(key: "sleep_need_min", source: repo.deviceId, days: 30).first { $0.day == key }?.value
        let debt = await repo.series(key: "sleep_debt_min", source: repo.deviceId, days: 30).first { $0.day == key }?.value
        let recent = repo.days.filter { $0.day < key }.suffix(14).compactMap(\.totalSleepMin)
        if let need = SleepNeed.summarize(officialNeed: needMin, officialDebt: debt, asleep: metric?.totalSleepMin,
                                          recentAsleep: recent) {
            v["sleepNeedMin"] = need.needMin.rounded()
            v["sleepPerformance"] = min(100, (need.asleepMin / max(need.needMin, 1) * 100)).rounded()
        }

        // Workouts that started on this day.
        let workouts = await repo.workoutRows(days: 60)
            .filter { Repository.dayString(Date(timeIntervalSince1970: TimeInterval($0.startTs))) == key }
            .sorted { $0.startTs < $1.startTs }
            .map { w in
                WorkoutSummary(sport: w.sport, startTs: w.startTs,
                               durationMin: ((w.durationS ?? Double(w.endTs - w.startTs)) / 60).rounded(),
                               strain: w.strain, avgHr: w.avgHr, maxHr: w.maxHr, kcal: w.energyKcal?.rounded())
            }
        guard !v.isEmpty || !workouts.isEmpty else { return nil }
        return SummaryDetail(values: v, workouts: workouts)
    }
}
