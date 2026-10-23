import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore
import WhoopProtocol

/// Developer panel (Settings → Advanced): for one stored night, exactly which samples, windows and baselines fed
/// resting HR, HRV and recovery, and what was rejected. Everything shown is recomputed from raw samples with the
/// same functions the scoring uses, so it cannot drift from the real calculation.
struct RecoveryDiagnosticsView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore

    private struct Report {
        let session: CachedSleepSession
        let stages: [StageSegment]
        let vitals: SleepVitals
        let hrReport: HRQuality.Report
        let breakdown: RecoveryScorer.Breakdown?
        let storedHRV: Double?, storedRHR: Int?, storedRecovery: Double?
        let hrvBase: BaselineState, rhrBase: BaselineState
        let importedNights: Int, ownNights: Int
    }

    @State private var choice: Int?          // startTs of the selected session
    @State private var report: Report?
    @State private var loading = false
    @State private var message: String?

    private var nights: [CachedSleepSession] { Array(repo.sleeps.suffix(14).reversed()) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                Picker("Night", selection: Binding(get: { choice ?? nights.first?.startTs ?? 0 },
                                                   set: { choice = $0 })) {
                    ForEach(nights, id: \.startTs) { Text(Self.label($0)).tag($0.startTs) }
                }
                .pickerStyle(.menu).fixedSize()
                if loading { ProgressView().controlSize(.small) }
                if let m = message { Text(m).font(.system(size: 13)).foregroundStyle(StrandPalette.textSecondary) }
                if let r = report { content(r) }
            }
            .padding(.horizontal, NoopMetrics.screenPadding).padding(.top, 6).padding(.bottom, 44)
            .frame(maxWidth: NoopMetrics.contentMaxWidth, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(StrandPalette.surfaceBase)
        .task(id: "\(choice ?? nights.first?.startTs ?? 0)-\(repo.dataVersion)") { await load() }
    }

    private static func label(_ s: CachedSleepSession) -> String {
        let z = ZoneTimeline.shared.zone(forSpan: s.startTs, s.endTs)
        return "\(ZoneTimeline.shared.dayString(s.endTs))  \(ZoneTimeline.shared.clock(s.startTs, in: z)) → \(ZoneTimeline.shared.clock(s.endTs, in: z))"
    }

    // MARK: - Content

    @ViewBuilder private func content(_ r: Report) -> some View {
        let v = r.vitals
        let z = ZoneTimeline.shared.zone(forSpan: r.session.startTs, r.session.endTs)
        let clock = { (t: Int) in ZoneTimeline.shared.clock(t, in: z) }

        card("Sleep window") {
            row("Detected onset → final wake", "\(clock(r.session.startTs)) → \(clock(r.session.endTs))")
            row("HR near onset / near final wake", "\(fmt(v.onsetHR)) / \(fmt(v.wakeHR)) bpm")
        }
        card("Resting HR (sleep-derived)") {
            row("Used for recovery", v.restingHR.map { "\($0) bpm" } ?? "unavailable", strong: true)
            row("Stored value", r.storedRHR.map { "\($0) bpm" } ?? "—")
            row("Average sleeping HR", "\(fmt(v.avgSleepHR)) bpm")
            row("Lowest 5-min mean (old definition)", "\(fmt(v.minWindowHR)) bpm")
            row("Lowest single sample", v.minSampleHR.map { "\($0) bpm" } ?? "—")
            row("Method", "mean of the lowest quartile of \(v.hrWindowCount) valid 5-min windows")
        }
        card("HRV (RMSSD)") {
            row("Used for recovery", v.hrv.map { String(format: "%.1f ms", $0) } ?? "unavailable", strong: true)
            row("Stored value", r.storedHRV.map { String(format: "%.1f ms", $0) } ?? "—")
            row("Valid windows", "\(v.hrvWindowCount) of \(v.windows.count) (median of these)")
            row("RR intervals / kept after cleaning", "\(v.rrBeats) / \(v.rrClean)")
            row("HR samples", "\(v.hrSamples)  ·  removed: \(r.hrReport.duplicates) duplicate, \(r.hrReport.outOfRange) out of range, \(r.hrReport.spikes) spike")
        }
        card("Rejected windows") {
            if v.rejectionCounts.isEmpty { Text("None").font(.system(size: 13)).foregroundStyle(StrandPalette.textTertiary) }
            ForEach(v.rejectionCounts.sorted { $0.key < $1.key }, id: \.key) { row($0.key, "\($0.value) windows") }
        }
        card("Baselines") {
            row("HRV baseline", String(format: "%.1f ms ± %.1f  (%d nights)", r.hrvBase.baseline, r.hrvBase.spread, r.hrvBase.nValid))
            row("Resting HR baseline", String(format: "%.1f bpm ± %.1f  (%d nights)", r.rhrBase.baseline, r.rhrBase.spread, r.rhrBase.nValid))
            row("Source mix", "\(r.importedNights) imported WHOOP nights, \(r.ownNights) NOOP-measured")
            Text("Imported and NOOP nights come from different methods; a persistent offset between them shifts every z-score.")
                .font(.system(size: 11)).foregroundStyle(StrandPalette.textTertiary)
        }
        card("Recovery") {
            if let b = r.breakdown {
                row("Score", String(format: "%.1f  (stored %@)", b.score, r.storedRecovery.map { String(format: "%.1f", $0) } ?? "—"), strong: true)
                ForEach(b.terms, id: \.name) { t in
                    row(t.name, String(format: "value %.2f · z %+.2f · weight %.0f%% · contributes %+.2f z",
                                       t.value, t.z, t.normalizedWeight * 100, t.contributionZ))
                }
                row("Composite z", String(format: "%+.2f", b.compositeZ))
            } else {
                Text("Not scored: HRV or baseline unavailable.").font(.system(size: 13)).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        card("Timeline") { timeline(r) }
    }

    private func timeline(_ r: Report) -> some View {
        let w = r.vitals.windows
        let date = { (t: Int) in Date(timeIntervalSince1970: TimeInterval(t)) }
        return VStack(alignment: .leading, spacing: 14) {
            Text("Heart rate by 5-min window").font(.system(size: 12)).foregroundStyle(StrandPalette.textSecondary)
            Chart {
                ForEach(r.stages.filter { $0.stage == "wake" }, id: \.start) {
                    BarMark(xStart: .value("s", date($0.start)), xEnd: .value("e", date($0.end)))
                        .foregroundStyle(StrandPalette.statusWarning.opacity(0.12))
                }
                ForEach(w, id: \.start) { win in
                    if let hr = win.meanHR {
                        PointMark(x: .value("t", date(win.start + 150)), y: .value("HR", hr))
                            .symbolSize(18).foregroundStyle(win.usedForHR ? StrandPalette.metricRose : StrandPalette.textTertiary)
                    }
                }
                if let rhr = r.vitals.restingHR { RuleMark(y: .value("RHR", Double(rhr))).foregroundStyle(StrandPalette.accent).lineStyle(StrokeStyle(dash: [4, 3])) }
                RuleMark(x: .value("onset", date(r.session.startTs))).foregroundStyle(StrandPalette.sleepLight)
                RuleMark(x: .value("wake", date(r.session.endTs))).foregroundStyle(StrandPalette.accent)
            }
            .chartYScale(domain: .automatic(includesZero: false)).frame(height: 170)
            Text("RMSSD by window (grey = rejected, dashed = selected median; shaded = detected awake)").font(.system(size: 12)).foregroundStyle(StrandPalette.textSecondary)
            Chart {
                ForEach(w, id: \.start) { win in
                    if let v = win.rmssd {
                        PointMark(x: .value("t", date(win.start + 150)), y: .value("RMSSD", v))
                            .symbolSize(18).foregroundStyle(StrandPalette.metricCyan)
                    }
                }
                if let hrv = r.vitals.hrv { RuleMark(y: .value("HRV", hrv)).foregroundStyle(StrandPalette.accent).lineStyle(StrokeStyle(dash: [4, 3])) }
                ForEach(r.stages.filter { $0.stage == "wake" }, id: \.start) {
                    BarMark(xStart: .value("s", date($0.start)), xEnd: .value("e", date($0.end)))
                        .foregroundStyle(StrandPalette.statusWarning.opacity(0.12))
                }
            }
            .frame(height: 150)
        }
    }

    // MARK: - Small pieces

    private func card<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
            body()
        }
        .padding(NoopMetrics.cardPadding).frame(maxWidth: .infinity, alignment: .leading).strandSurface()
    }

    private func row(_ k: String, _ v: String, strong: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.system(size: 13)).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 12)
            Text(v).font(.system(size: 13, weight: strong ? .bold : .regular).monospacedDigit())
                .foregroundStyle(StrandPalette.textPrimary).multilineTextAlignment(.trailing)
        }
    }

    private func fmt(_ x: Double?) -> String { x.map { String(format: "%.1f", $0) } ?? "—" }

    // MARK: - Load

    private func load() async {
        guard let s = nights.first(where: { $0.startTs == (choice ?? nights.first?.startTs) }) else {
            message = "No sleep sessions yet."; report = nil; return
        }
        loading = true; message = nil
        defer { loading = false }
        guard let store = await repo.storeHandle() else { return }
        let id = repo.deviceId
        let hr = (try? await store.hrSamples(deviceId: id, from: s.startTs, to: s.endTs, limit: 200_000)) ?? []
        let rr = (try? await store.rrIntervals(deviceId: id, from: s.startTs, to: s.endTs, limit: 200_000)) ?? []
        guard hr.count > 100 else {
            message = "This night has no raw heart-rate data on this Mac (it came from an import), so nothing can be recomputed."
            report = nil; return
        }
        let stages = (s.stagesJSON?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([StageSegment].self, from: $0) } ?? []
        let cleaned = HRQuality.cleanWithReport(hr)
        let vitals = SleepVitalsCalculator.compute(start: s.startTs, end: s.endTs, stages: stages, hr: cleaned.samples, rr: rr)
        let base = IntelligenceEngine.baselines(from: repo.days)
        let day = ZoneTimeline.shared.dayString(s.endTs)
        let stored = repo.days.first { $0.day == day }
        var breakdown: RecoveryScorer.Breakdown? = nil
        if let b = base, let hrv = vitals.hrv, let rhr = vitals.restingHR, let hb = b.hrv {
            breakdown = RecoveryScorer.breakdown(hrv: hrv, rhr: Double(rhr), resp: nil,
                hrvBaseline: .init(hb), rhrBaseline: b.restingHR.map(RecoveryScorer.DriverBaseline.init), respBaseline: nil,
                sleepPerf: s.efficiency.map { $0 <= 1 ? $0 : $0 / 100 }, hrvBaselineUsable: hb.usable)
        }
        guard let b = base, let hb = b.hrv, let rb = b.restingHR else { return }
        report = Report(session: s, stages: stages, vitals: vitals, hrReport: cleaned.report, breakdown: breakdown,
                        storedHRV: stored?.avgHrv, storedRHR: stored?.restingHr, storedRecovery: stored?.recovery,
                        hrvBase: hb, rhrBase: rb,
                        importedNights: repo.officialDays.count, ownNights: repo.estimates.count)
    }
}
