import SwiftUI
import WhoopStore
import StrandSync
import StrandDesign

/// Recovery / Sleep / Strain detail pages (like the WHOOP app's), built only from static daily summaries the Mac sent:
/// numbers per day, the day's workouts, and averages of earlier days computed on the phone. No samples or curves
/// (owner display rule, 2026-11-27). Missing values show "—", never 0.
enum PhoneDetailKind: String, Identifiable { case recovery, sleep, strain; var id: String { rawValue } }

struct PhoneDetailView: View {
    let kind: PhoneDetailKind
    let summary: DailySummary
    let history: [DailySummary]
    @Environment(\.dismiss) private var dismiss

    private var v: [String: Double] { summary.values }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch kind {
                    case .recovery: recovery
                    case .sleep: sleep
                    case .strain: strain
                    }
                    Text("Scored on your Mac \(Date(timeIntervalSince1970: TimeInterval(summary.changedAt)).formatted(date: .abbreviated, time: .shortened)).")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity)
                }
                .padding(16)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var title: String {
        let d = ScoreHistory.noon(summary.day).map { $0.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)) } ?? summary.day
        switch kind {
        case .recovery: return "Recovery · \(d)"
        case .sleep: return "Sleep · \(d)"
        case .strain: return "Strain · \(d)"
        }
    }

    /// Average of `key` over the 30 days before this one (days without a value left out).
    private func baseline(_ key: String) -> Double? {
        guard let start = ScoreHistory.shift(summary.day, by: -30), let end = ScoreHistory.shift(summary.day, by: -1) else { return nil }
        let days = ScoreHistory.lastDays(30, through: end)
        guard days.first.map({ $0 >= start }) ?? false else { return nil }
        return ScoreHistory.average(ScoreHistory.series(key, days: days, in: history))?.value
    }

    // MARK: Recovery

    private var recovery: some View {
        let score = v["recovery"]
        let tint = score.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.scoreMissing
        return VStack(alignment: .leading, spacing: 14) {
            StrandWidget("Recovery", symbol: "circle.dotted.circle", tint: tint) {
                VStack(spacing: 10) {
                    ProgressRing(fraction: (score ?? 0) / 100, tint: tint, lineWidth: 14) {
                        Text(score.map { "\(Int($0.rounded()))%" } ?? "—")
                            .font(.system(size: 40, weight: .bold).monospacedDigit())
                            .foregroundStyle(score == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    }
                    .frame(width: 150, height: 150)
                    Text(score.map { StrandPalette.recoveryState($0).capitalized } ?? "No data")
                        .font(.system(size: 22, weight: .bold)).foregroundStyle(StrandPalette.scoreInk(tint))
                    Text("How ready your body is today, from last night's heart-rate variability, resting heart rate and sleep.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
            card("Vitals", note: "Compared with your average over the previous 30 days.") {
                compareRow("Heart-rate variability", "avgHrv", unit: "ms", digits: 0, higherIsBetter: true)
                compareRow("Resting heart rate", "restingHr", unit: "bpm", digits: 0, higherIsBetter: false)
                compareRow("Respiratory rate", "respRateBpm", unit: "rpm", digits: 1, higherIsBetter: nil)
                compareRow("Blood oxygen", "spo2Pct", unit: "%", digits: 1, higherIsBetter: nil)
                row("Skin temperature", v["skinTempDevC"].map { String(format: "%+.1f °C vs your baseline", $0) })
            }
        }
    }

    // MARK: Sleep

    private var sleep: some View {
        let asleep = v["totalSleepMin"], need = v["sleepNeedMin"], perf = v["sleepPerformance"]
        let tint = StrandPalette.sleepLight
        let stageTotal = [v["lightMin"], v["deepMin"], v["remMin"], v["awakeMin"]].compactMap { $0 }.reduce(0, +)
        return VStack(alignment: .leading, spacing: 14) {
            StrandWidget("Sleep performance", symbol: "bed.double.fill", tint: tint) {
                VStack(spacing: 10) {
                    ProgressRing(fraction: (perf ?? 0) / 100, tint: tint, lineWidth: 14) {
                        Text(perf.map { "\(Int($0.rounded()))%" } ?? "—")
                            .font(.system(size: 40, weight: .bold).monospacedDigit())
                            .foregroundStyle(perf == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    }
                    .frame(width: 150, height: 150)
                    Text(asleep.map { a in need.map { "\(hm(a)) of \(hm($0)) needed" } ?? "\(hm(a)) asleep" } ?? "No sleep recorded")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                }
                .frame(maxWidth: .infinity)
            }
            card("Night") {
                row("Fell asleep around", v["sleepStartTs"].map(time))
                row("Woke up", v["sleepEndTs"].map(time))
                row("Time in bed", v["timeInBedMin"].map(hm))
                row("Hours of sleep", asleep.map(hm))
                row("Awake", v["awakeMin"].map(hm))
            }
            card("Stages") {
                if v["deepMin"] != nil || v["remMin"] != nil || v["lightMin"] != nil {
                    SleepStageBar(deep: v["deepMin"], rem: v["remMin"], light: v["lightMin"], awake: v["awakeMin"])
                        .padding(.vertical, 8)
                }
                stageRow("Light", v["lightMin"], stageTotal, StrandPalette.sleepLight)
                stageRow("Deep (SWS)", v["deepMin"], stageTotal, StrandPalette.sleepDeep)
                stageRow("REM", v["remMin"], stageTotal, StrandPalette.sleepREM)
                stageRow("Awake", v["awakeMin"], stageTotal, StrandPalette.sleepAwake)
            }
            card("Quality") {
                row("Efficiency", v["efficiency"].map { String(format: "%.0f%%", $0) })
                row("Disturbances", v["disturbances"].map { "\(Int($0))" })
                row("Respiratory rate", v["respRateBpm"].map { String(format: "%.1f rpm", $0) })
            }
        }
    }

    // MARK: Strain

    private var strain: some View {
        let s = v["strain"]
        let tint = s.map { StrandPalette.strainColor($0) } ?? StrandPalette.scoreMissing
        let zones = (1...5).map { v["zone\($0)Min"] }
        let zoneMax = max(1, zones.compactMap { $0 }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 14) {
            StrandWidget("Day strain", symbol: "flame.fill", tint: tint) {
                VStack(spacing: 10) {
                    ProgressRing(fraction: (s ?? 0) / 21, tint: tint, lineWidth: 14) {
                        VStack(spacing: 0) {
                            Text(s.map { String(format: "%.1f", $0) } ?? "—")
                                .font(.system(size: 40, weight: .bold).monospacedDigit())
                                .foregroundStyle(s == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                            Text("of 21").font(.system(size: 11, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    .frame(width: 150, height: 150)
                    Text(s.map(PhoneHomeView.strainWord) ?? "No data")
                        .font(.system(size: 22, weight: .bold)).foregroundStyle(StrandPalette.scoreInk(tint))
                }
                .frame(maxWidth: .infinity)
            }
            card("Day") {
                row("Calories", v["kcal"].map { "\(Int($0).formatted()) kcal" })
                row("Average heart rate", v["avgHr"].map { "\(Int($0)) bpm" })
                row("Max heart rate", v["maxHr"].map { "\(Int($0)) bpm" })
                row("Active time (zone 2+)", v["activeMin"].map(hm))
            }
            card("Heart-rate zones") {
                ForEach(1...5, id: \.self) { z in
                    let m = zones[z - 1]
                    HStack(spacing: 10) {
                        Text("Zone \(z)").font(.system(size: 13, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary)
                            .frame(width: 56, alignment: .leading)
                        GeometryReader { g in
                            Capsule().fill(zoneColor(z))
                                .frame(width: max(4, g.size.width * CGFloat((m ?? 0) / zoneMax)), height: 8)
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 16)
                        Text(m.map(hm) ?? "—").font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(StrandPalette.textPrimary).frame(width: 64, alignment: .trailing)
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }
            }
            card("Activities") {
                if let ws = summary.workouts, !ws.isEmpty {
                    ForEach(Array(ws.enumerated()), id: \.offset) { _, w in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(w.sport.capitalized).font(.system(size: 15, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                                Spacer()
                                Text(w.strain.map { String(format: "%.1f", $0) } ?? "—")
                                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                                    .foregroundStyle(w.strain.map { StrandPalette.scoreInk(StrandPalette.strainColor($0)) } ?? StrandPalette.textTertiary)
                            }
                            Text([time(Double(w.startTs)), hm(w.durationMin),
                                  w.avgHr.map { "avg \($0) bpm" }, w.maxHr.map { "max \($0) bpm" },
                                  w.kcal.map { "\(Int($0)) kcal" }].compactMap { $0 }.joined(separator: " · "))
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                        .padding(.vertical, 8)
                    }
                } else {
                    Text(summary.workouts == nil ? "Activity details appear after your Mac sends them." : "No activities this day.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary).padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: pieces

    private func card<C: View>(_ title: String, note: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textTertiary).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 14).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .strandSurface()
            if let note { Text(note).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary).padding(.leading, 4) }
        }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label).font(.system(size: 14)).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(value ?? "—").font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    /// Today's value, the 30-day average, and the direction (green when better, when there is a "better").
    private func compareRow(_ label: String, _ key: String, unit: String, digits: Int, higherIsBetter: Bool?) -> some View {
        let today = v[key], base = baseline(key)
        let fmt = "%.\(digits)f"
        let arrow: (String, Color)? = {
            guard let t = today, let b = base, abs(t - b) >= (digits == 0 ? 1 : 0.1) else { return nil }
            let up = t > b
            let good = higherIsBetter.map { $0 == up }
            return (up ? "arrow.up" : "arrow.down",
                    good.map { $0 ? StrandPalette.statusPositive : StrandPalette.statusWarningInk } ?? StrandPalette.textTertiary)
        }()
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 14)).foregroundStyle(StrandPalette.textSecondary)
                Text(base.map { "30-day average \(String(format: fmt, $0)) \(unit)" } ?? "No 30-day average yet")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
            if let arrow { Image(systemName: arrow.0).font(.system(size: 11, weight: .bold)).foregroundStyle(arrow.1) }
            Text(today.map { "\(String(format: fmt, $0)) \(unit)" } ?? "—")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(today == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private func stageRow(_ label: String, _ minutes: Double?, _ total: Double, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.system(size: 14)).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(minutes.map { m in total > 0 ? "\(hm(m)) · \(Int((m / total * 100).rounded()))%" : hm(m) } ?? "—")
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(minutes == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private func zoneColor(_ z: Int) -> Color {
        [StrandPalette.zone1, StrandPalette.zone2, StrandPalette.zone3, StrandPalette.zone4, StrandPalette.zone5][z - 1]
    }

    private func hm(_ minutes: Double) -> String { PhoneHomeView.hm(minutes) }
    private func time(_ ts: Double) -> String { Date(timeIntervalSince1970: ts).formatted(date: .omitted, time: .shortened) }
}
