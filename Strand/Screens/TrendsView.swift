import SwiftUI
import StrandDesign
import WhoopStore
import Foundation

// MARK: - Trends
//
// The longitudinal view: one range control, the four numbers to read first, a hero recovery chart, a uniform grid of
// HRV / Resting HR / Day Strain charts (all NoopMetrics.chartHeight tall), and the whole history as a recovery
// YearHeatStrip. Shared pieces and window logic live in TrendSections.swift.

// Trends: recovery hero chart, HRV/RHR/strain small multiples and a year heat strip.
struct TrendsView: View {
    @EnvironmentObject var repo: Repository
    // NOTE: deliberately does NOT observe LiveState — Trends shows historical data only, and
    // observing it forced a full re-render of this subtree on every ~1 Hz live-HR tick.

    typealias Range = TrendRange

    @State private var range: Range = .quarter

    /// Windows are relative to the LATEST day with data and auto-expand when the chosen range is empty.
    private var latestDay: Date? { repo.days.last.flatMap { TrendWindow.date($0.day) } }

    // Each metric is resolved once per render and reused by the charts, so a single body evaluation filters each
    // metric's window once instead of dozens of times.
    private func resolve(_ value: (DailyMetric) -> Double?) -> TrendSeries {
        TrendWindow.series(repo.days, value, range: range, anchor: latestDay)
    }

    var body: some View {
        ScreenScaffold(title: "Trends", subtitle: "The thread of you over time.") {
            if repo.days.isEmpty {
                ComingSoon(what: repo.loaded
                    ? "Trends need history to draw. Import your WHOOP export in Settings → Data to see weeks, months and years instantly."
                    : "Loading your history…")
            } else {
                // Resolve each metric's window ONCE per body and pass the results
                // down — rangeBar/heroRecovery/smallMultiples all reuse these
                // instead of re-filtering repo.days through caption/widened/
                // windowPoints on every render (hover, animation, 1 Hz HR tick).
                let recovery = resolve { $0.recovery }
                let hrv = resolve { $0.avgHrv }
                let rhr = resolve { $0.restingHr.map(Double.init) }
                let strain = resolve { $0.strain }
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                        TrendRangeBar(range: $range, sparseNote: recovery.widened ? recovery.caption : nil)
                        summary(recovery: recovery, hrv: hrv, rhr: rhr, strain: strain)
                    }
                    heroRecovery(recovery: recovery)
                    smallMultiples(hrv: hrv, rhr: rhr, strain: strain)
                    yearStrip
                    RecentCyclesCard()
                }
            }
        }
    }

    // MARK: Summary

    /// The four numbers to read first. Each shares its window with the chart below it.
    private func summary(recovery: TrendSeries, hrv: TrendSeries, rhr: TrendSeries, strain: TrendSeries) -> some View {
        let whole: (Double) -> String = { "\(Int($0.rounded()))" }
        let recoveryColor = recovery.mean.map(StrandPalette.recoveryColor)
        let strainColor = strain.mean.map(StrandPalette.strainColor)
        let one: (Double) -> String = { String(format: "%.1f", $0) }
        func change(_ v: @escaping (DailyMetric) -> Double?, _ s: TrendSeries, _ unit: String, _ tol: Double, _ f: @escaping (Double) -> String) -> TrendChange? {
            TrendWindow.change(repo.days, v, series: s, anchor: latestDay, unit: unit, tolerance: tol, format: f)
        }
        return TrendSummaryRow {
            TrendStat(label: "Recovery", value: recovery.mean.map(whole), unit: "%", caption: recovery.effective.subtitle,
                      tint: recoveryColor.map(StrandPalette.scoreInk) ?? StrandPalette.textPrimary,
                      symbol: "bolt.heart.fill", accent: recoveryColor ?? StrandPalette.statusPositive,
                      change: change({ $0.recovery }, recovery, "%", 2, whole))
            TrendStat(label: "HRV", value: hrv.mean.map(whole), unit: "ms", caption: hrv.effective.subtitle,
                      symbol: "waveform.path.ecg", accent: StrandPalette.metricPurple,
                      change: change({ $0.avgHrv }, hrv, "ms", 2, whole))
            TrendStat(label: "Resting HR", value: rhr.mean.map(whole), unit: "bpm", caption: rhr.effective.subtitle,
                      symbol: "heart.fill", accent: StrandPalette.metricRose,
                      change: change({ $0.restingHr.map(Double.init) }, rhr, "bpm", 1, whole))
            TrendStat(label: "Day strain", value: strain.mean.map { String(format: "%.1f", $0) }, unit: "/ 21", caption: strain.effective.subtitle,
                      tint: strainColor.map(StrandPalette.scoreInk) ?? StrandPalette.textPrimary,
                      symbol: "flame.fill", accent: strainColor ?? StrandPalette.zone4,
                      change: change({ $0.strain }, strain, "", 0.5, one))
        }
    }

    // MARK: Hero — recovery over time

    private func heroRecovery(recovery: TrendSeries) -> some View {
        let whole: (Double) -> String = { "\(Int($0.rounded()))" }
        let accent = recovery.mean.map(StrandPalette.recoveryColor)
        return TrendCard(title: "Recovery", caption: recovery.caption, value: recovery.mean.map(whole), accent: accent) {
            if recovery.canDraw {
                TrendChart(points: recovery.points,
                           gradient: StrandPalette.recoveryGradient,
                           valueRange: 0...100,
                           showsArea: true,
                           height: NoopMetrics.chartHeight,
                           style: .soft)
            } else {
                TrendEmptyChart(count: recovery.points.count)
            }
        } footer: {
            TrendFooter([
                ("Average", recovery.mean.map(whole) ?? "—"),
                ("Peak", recovery.high.map(whole) ?? "—"),
                ("Low", recovery.low.map(whole) ?? "—"),
                ("Days", "\(recovery.points.count)"),
            ], accent: accent ?? StrandPalette.statusPositive)
        }
    }

    // MARK: Small multiples — HRV / Resting HR / Day Strain

    private func smallMultiples(hrv: TrendSeries, rhr: TrendSeries, strain: TrendSeries) -> some View {
        let cols = [GridItem(.adaptive(minimum: 320), spacing: NoopMetrics.gap, alignment: .top)]
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Daily signals", overline: "Trends", trailing: range.subtitle)
            LazyVGrid(columns: cols, alignment: .leading, spacing: NoopMetrics.gap) {
                TrendLineCard(title: "Heart rate variability", unit: "ms", series: hrv,
                              gradient: TrendWindow.gradient(StrandPalette.metricPurple),
                              valueRange: TrendWindow.valueRange(hrv.points, fallback: 20...120))
                TrendLineCard(title: "Resting heart rate", unit: "bpm", series: rhr,
                              gradient: TrendWindow.gradient(StrandPalette.metricRose),
                              valueRange: TrendWindow.valueRange(rhr.points, fallback: 40...80))
                TrendLineCard(title: "Day strain", unit: "/ 21", series: strain, gradient: StrandPalette.strainGradient,
                              valueRange: TrendWindow.valueRange(strain.points, fallback: 0...21),
                              format: { String(format: "%.1f", $0) })
            }
        }
    }

    // MARK: Year heat-strip

    private var yearStrip: some View {
        // Always show at least a full year for context; expand to all history on ALL.
        let stripDays = max(range.days ?? repo.days.count, 365)
        let recent = repo.days.suffix(stripDays)
        let recoveryDays: [RecoveryDay] = recent.compactMap { d in
            guard let dt = TrendWindow.date(d.day) else { return nil }
            return RecoveryDay(date: dt, score: d.recovery)
        }
        let title = (range == .all && repo.days.count > 365) ? "Recovery — all history" : "Recovery — past year"
        return NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title, overline: "Calendar", trailing: "\(recoveryDays.filter { $0.score != nil }.count) days")
                if recoveryDays.isEmpty {
                    TrendEmptyChart(count: 0).frame(height: 120)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        YearHeatStrip(days: recoveryDays).padding(.vertical, 2)
                    }
                    Divider().overlay(StrandPalette.hairline)
                    legend
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 8) {
            Text("Depleted").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            LinearGradient(gradient: StrandPalette.recoveryGradient, startPoint: .leading, endPoint: .trailing)
                .frame(width: 120, height: 8)
                .clipShape(Capsule())
            Text("Peaked").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Spacer()
        }
    }
}

#if DEBUG
@MainActor
private func previewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    let cal = Calendar(identifier: .gregorian)
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "UTC")
    fmt.dateFormat = "yyyy-MM-dd"
    let today = Date()
    var seeded: [DailyMetric] = []
    let span = 365 * 3
    for i in stride(from: span - 1, through: 0, by: -1) {
        guard let d = cal.date(byAdding: .day, value: -i, to: today) else { continue }
        let phase = Double(span - 1 - i)
        let rec = 55 + 28 * sin(phase / 11.0) + Double((Int(phase) * 31) % 17) - 8
        let hrv = 58 + 16 * sin(phase / 9.0) + Double((Int(phase) * 13) % 11) - 5
        let rhr = 52 + 4 * sin(phase / 7.0) + Double((Int(phase) * 7) % 5) - 2
        let strain = 9 + 6 * sin(phase / 5.0 + 1.2) + Double((Int(phase) * 5) % 4) - 2
        let gap = Int(phase) % 23 == 0
        seeded.append(DailyMetric(
            day: fmt.string(from: d),
            totalSleepMin: 420, efficiency: 0.9, deepMin: 90, remMin: 110, lightMin: 200,
            disturbances: 6, restingHr: gap ? nil : Int(rhr.rounded()),
            avgHrv: gap ? nil : max(15, hrv), recovery: gap ? nil : max(2, min(99, rec)),
            strain: gap ? nil : max(0, min(21, strain)), exerciseCount: 1
        ))
    }
    repo.days = seeded
    repo.loaded = true
    return repo
}

#Preview("Trends") {
    TrendsView()
        .environmentObject(previewRepo())
        .environmentObject(LiveState())
        .frame(width: 960, height: 960)
        .preferredColorScheme(.dark)
}
#endif
