import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import WhoopProtocol
import Foundation

// MARK: - Sleep stages for the Today card

/// Turns a night into hypnogram intervals. The on-device scorer stores a real per-epoch timeline (a JSON array of
/// {start,end,stage}). WHOOP imports only hold stage totals, so for those the same plausible stage order the Sleep tab
/// uses is drawn and flagged `estimated`.
enum SleepTimeline {
    private struct Segment: Decodable { let start: Int; let end: Int; let stage: String }

    /// The session that belongs to a day. Imports key a day by the cycle that started on it (the night often ends the
    /// next morning), the strap's own scoring keys it by the morning the night ended, so look in both places and take the
    /// candidate whose length best matches the day's recorded sleep.
    static func pick(_ sessions: [CachedSleepSession], range r: (from: Int, to: Int), day: DailyMetric?) -> CachedSleepSession? {
        let cands = sessions.filter { $0.endTs >= r.from && $0.endTs < r.to + 14 * 3600 && $0.startTs >= r.from - 14 * 3600 }
        guard !cands.isEmpty else { return nil }
        let target = day?.totalSleepMin
        return cands.min { a, b in
            func score(_ s: CachedSleepSession) -> Double {
                let mins = Double(s.endTs - s.startTs) / 60
                let endsOnDay = s.endTs >= r.from && s.endTs < r.to
                return abs(mins - (target ?? 480)) - (endsOnDay ? 30 : 0)
            }
            return score(a) < score(b)
        }
    }

    static func intervals(session: CachedSleepSession?, day: DailyMetric?) -> (intervals: [SleepInterval], estimated: Bool)? {
        if let session, let data = session.stagesJSON?.data(using: .utf8),
           let segs = try? JSONDecoder().decode([Segment].self, from: data), !segs.isEmpty {
            let origin = TimeInterval(session.startTs)
            let out: [SleepInterval] = segs.sorted { $0.start < $1.start }.compactMap { s in
                let stage: SleepStage
                switch s.stage {
                case "wake": stage = .awake
                case "light": stage = .light
                case "deep": stage = .deep
                case "rem": stage = .rem
                default: return nil
                }
                return SleepInterval(stage: stage, start: TimeInterval(s.start) - origin, end: TimeInterval(s.end) - origin)
            }
            if !out.isEmpty { return (out, false) }
        }
        // Stage totals in minutes: the session's JSON dict if present, else the day's columns.
        var light = day?.lightMin ?? 0, deep = day?.deepMin ?? 0, rem = day?.remMin ?? 0, awake = 0.0
        if let data = session?.stagesJSON?.data(using: .utf8),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            func v(_ k: String) -> Double { (dict[k] as? NSNumber)?.doubleValue ?? 0 }
            if v("light") + v("deep") + v("rem") > 0 { light = v("light"); deep = v("deep"); rem = v("rem"); awake = v("awake") }
        }
        guard light + deep + rem > 0 else { return nil }
        var t: TimeInterval = 0
        var out: [SleepInterval] = []
        func add(_ stage: SleepStage, _ minutes: Double) {
            guard minutes > 0 else { return }
            out.append(SleepInterval(stage: stage, start: t, end: t + minutes * 60)); t += minutes * 60
        }
        add(.light, light * 0.4); add(.deep, deep); add(.light, light * 0.3)
        add(.rem, rem); add(.light, light * 0.3); add(.awake, awake)
        return (out, true)
    }
}

// MARK: - Workout detail

/// A tapped workout opened as a sheet. WorkoutRow has no id, so the start time stands in for one.
struct WorkoutSelection: Identifiable {
    let row: WorkoutRow
    var id: Int { row.startTs }
}

/// One workout: elapsed time, summary numbers and the heart-rate curve across it. Hovering the curve reads out the
/// bpm and the elapsed time (plus wall-clock time) at that point. Below it, optional reported effort and logged sets,
/// shown as their own fields beside strain and never combined with it.
struct WorkoutDetailView: View {
    @EnvironmentObject var repo: Repository
    @Environment(\.dismiss) private var dismiss
    let workout: WorkoutRow

    @State private var samples: [HRSample] = []
    @State private var loaded = false
    @State private var sessionLoad: SessionLoadRecord?
    @State private var log: TrainingLogEntry?
    @State private var logFailed = false
    @State private var exerciseText = ""
    @State private var repsText = ""
    @State private var kgText = ""
    @State private var rirText = ""
    @FocusState private var editing: Bool
    @State private var label: ActivityLabel?

    private static let gradient = Gradient(colors: [StrandPalette.metricCyan, StrandPalette.metricRose, StrandPalette.statusCritical])

    private var durationS: Double { workout.durationS ?? Double(max(workout.endTs - workout.startTs, 0)) }
    private var avg: Int? { workout.avgHr ?? (samples.isEmpty ? nil : samples.map(\.bpm).reduce(0, +) / samples.count) }
    private var peak: Int? { samples.map(\.bpm).max() ?? workout.maxHr }

    /// At most ~600 points so a multi-hour session stays smooth; each point is the mean of its slice.
    private var points: [(ts: Int, bpm: Double)] {
        let n = 600
        guard samples.count > n else { return samples.map { ($0.ts, Double($0.bpm)) } }
        let step = Double(samples.count) / Double(n)
        return (0..<n).map { i in
            let lo = Int(Double(i) * step), hi = max(lo + 1, min(samples.count, Int(Double(i + 1) * step)))
            let slice = samples[lo..<hi]
            return (slice[slice.startIndex + slice.count / 2].ts, Double(slice.map(\.bpm).reduce(0, +)) / Double(slice.count))
        }
    }

    /// Reported effort as a load, or nil when the user gave no response.
    private var sessionRPE: SessionRPE? { log?.effort.flatMap { SessionRPE(row: $0) } }
    /// An existing entry keeps the span it was logged under, even if a re-score has since moved this workout.
    private var logStart: Int { log?.workoutStartTs ?? workout.startTs }
    private var logEnd: Int { log?.workoutEndTs ?? workout.endTs }
    /// The set the form would add; nil until what's typed can be read.
    private var draftSet: StrengthSet? { StrengthSet(exercise: exerciseText, reps: repsText, kg: kgText, rir: rirText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    activityMenu
                    Text("\(Self.dateText(workout.startTs)) · \(DayMath.clock(workout.startTs)) – \(DayMath.clock(workout.endTs))")
                        .font(.system(size: 13)).foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer()
                // Return in a set field adds the set rather than closing the sheet.
                Button("Done") { dismiss() }.buttonStyle(.strandPrimary).keyboardShortcut(editing ? nil : .defaultAction)
            }
            .padding(24)

            ScrollView {
                details
                    .padding([.horizontal, .bottom], 24)
            }
        }
        .frame(minWidth: 620, minHeight: 460, idealHeight: 760)
        .background(StrandPalette.surfaceBase)
        .task { await load() }
    }

    /// The activity type, editable. Changing it changes no score.
    private var activityMenu: some View {
        Menu {
            ForEach(ActivityType.allCases, id: \.self) { type in
                Button(type.displayName) { pick(type) }
            }
            if label?.stored != nil {
                Divider()
                Button("Remove my label") { pick(nil) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(label?.name ?? workout.sport).font(.system(size: 22, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                if let source = labelSource {
                    Text(source).font(.system(size: 11)).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Activity type")
    }

    private var labelSource: String? {
        switch label?.provenance {
        case .userSelected: return "Set by you"
        case .imported: return "From import"
        case .inferred: return "Estimated"
        default: return label == nil ? nil : "Tap to set"
        }
    }

    private func pick(_ type: ActivityType?) {
        guard let current = label else { return }
        Task {
            await repo.setActivity(type, for: workout, current: current)
            label = await repo.activityLabel(workout)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack(spacing: NoopMetrics.gap) {
                stat("Elapsed", Self.elapsed(durationS), StrandPalette.accent)
                stat("Avg HR", avg.map { "\($0) bpm" }, StrandPalette.metricRose)
                stat("Peak HR", peak.map { "\($0) bpm" }, StrandPalette.statusCritical)
                if let kcal = workout.energyKcal { stat("Energy", "\(Int(kcal.rounded())) kcal", StrandPalette.metricAmber) }
            }

            loadFields

            if let note = sessionNote {
                Text(note).font(.system(size: 12)).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Heart rate").font(.system(size: 17, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                chart
            }
            .padding(NoopMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .strandSurface()

            logCard
        }
    }

    /// Cardio, perceived effort and each exercise's volume side by side, each in its own units. No total across them.
    private var loadFields: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: NoopMetrics.gap)], alignment: .leading, spacing: NoopMetrics.gap) {
            if let s = workout.strain {
                stat("Cardio strain", String(format: "%.1f", s), StrandPalette.scoreInk(StrandPalette.strainColor(s)), caption: "From heart rate")
            }
            stat("Session RPE load", sessionRPE.map { "\(Int($0.load.rounded())) AU" }, StrandPalette.lavenderInk,
                 caption: sessionRPE.map { "RPE \(Self.number($0.rpe)) × \(Int($0.sessionMinutes.rounded())) min" } ?? "Not reported")
            ForEach(StrengthVolume.summaries((log?.sets ?? []).map(StrengthSet.init(row:))), id: \.exercise) { e in
                stat(e.exercise, e.volumeKg.map { "\(Self.number($0)) kg" }, StrandPalette.accentInk,
                     caption: "\(e.sets) \(e.sets == 1 ? "set" : "sets") · \(e.reps) reps" + (e.volumeKg == nil ? " · no load" : ""))
            }
        }
    }

    // MARK: Session log

    private var logCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Session log").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text("Optional, and separate from strain. Blank stays blank.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Perceived effort").font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    if log?.effort != nil {
                        Button("Clear") { Task { await clearEffort() } }.buttonStyle(.strandSecondary)
                    }
                }
                HStack(spacing: 4) {
                    ForEach(0...10, id: \.self) { n in rpeChoice(n) }
                }
                .disabled(!loaded || durationS <= 0)
                Text("How hard was the whole session? CR10 scale: 0 rest · 3 moderate · 5 hard · 7 very hard · 10 maximal.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let e = log?.effort {
                    Text(Self.collectionNote(e)).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Rectangle().fill(StrandPalette.hairline).frame(height: 0.5)

            VStack(alignment: .leading, spacing: 8) {
                Text("Exercises").font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
                ForEach(log?.sets ?? [], id: \.setIndex) { setRow($0) }
                HStack(spacing: 8) {
                    logField("Exercise", $exerciseText)
                    logField("Reps", $repsText).frame(width: 64)
                    logField("kg", $kgText).frame(width: 72)
                    logField("RIR", $rirText).frame(width: 64)
                    Button("Add set") { Task { await addSet() } }
                        .buttonStyle(.strandSecondary)
                        .disabled(!loaded || draftSet == nil)
                }
                Text("Leave kg blank for bodyweight: body mass is never added. Load counts as you enter it, so compare an exercise with itself.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let log, log.workoutStartTs != workout.startTs {
                Text("Logged against this session as it was detected then, \(DayMath.clock(log.workoutStartTs)) – \(DayMath.clock(log.workoutEndTs)).")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            if logFailed {
                Text("That change couldn't be saved.").font(StrandFont.caption).foregroundStyle(StrandPalette.statusCriticalInk)
            }
        }
        .padding(NoopMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .strandSurface()
    }

    private func rpeChoice(_ n: Int) -> some View {
        let selected = log?.effort?.rpe == Double(n)
        return Button { Task { await setEffort(n) } } label: {
            Text("\(n)")
                .font(StrandFont.captionNumber)
                .foregroundStyle(selected ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(selected ? StrandPalette.accentMuted : StrandPalette.surfaceInset,
                            in: RoundedRectangle(cornerRadius: NoopMetrics.controlRadius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Effort \(n) of 10")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func setRow(_ s: StrengthSetRow) -> some View {
        HStack(spacing: 8) {
            Text(s.exercise).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary).lineLimit(1)
            Spacer()
            Text(Self.setText(s)).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textSecondary)
            Button { Task { await deleteSet(s) } } label: {
                Image(systemName: "xmark").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove set")
        }
    }

    private func logField(_ prompt: String, _ text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(StrandFont.body)
            .foregroundStyle(StrandPalette.textPrimary)
            .focused($editing)
            .onSubmit { Task { await addSet() } }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: NoopMetrics.controlRadius, style: .continuous))
    }

    private func setEffort(_ n: Int) async {
        // Tapping the current answer isn't a new response, so it keeps its collection time.
        guard log?.effort?.rpe != Double(n),
              let rpe = SessionRPE(rpe: Double(n), sessionMinutes: durationS / 60, collectedAt: Int(Date().timeIntervalSince1970)) else { return }
        await applyLog(await repo.saveEffort(rpe, workoutStartTs: logStart, workoutEndTs: logEnd))
    }

    private func clearEffort() async {
        await applyLog(await repo.clearEffort(workoutStartTs: logStart))
    }

    private func addSet() async {
        guard loaded, let set = draftSet else { return }
        await applyLog(await repo.addSet(set, workoutStartTs: logStart, workoutEndTs: logEnd,
                                         collectedAt: Int(Date().timeIntervalSince1970)))
        // The fields stay filled: the next set is usually the same lift.
    }

    private func deleteSet(_ s: StrengthSetRow) async {
        await applyLog(await repo.deleteSet(workoutStartTs: s.workoutStartTs, setIndex: s.setIndex))
    }

    private func applyLog(_ saved: Bool) async {
        logFailed = !saved
        log = await repo.trainingLog(workout)
    }

    @ViewBuilder private var chart: some View {
        let pts = points
        if pts.count > 1 {
            let start = workout.startTs
            Sparkline(values: pts.map(\.bpm), gradient: Self.gradient, lineWidth: 2.5, showsArea: true,
                      showsHead: false, showsHover: true,
                      valueFormat: { "\(Int($0.rounded())) bpm" },
                      indexLabel: { i in
                          guard pts.indices.contains(i) else { return "" }
                          return "\(Self.elapsed(Double(pts[i].ts - start))) elapsed · \(DayMath.clock(pts[i].ts))"
                      })
                .frame(height: 220)
            HStack {
                Text("0:00"); Spacer()
                Text(Self.elapsed(Double(pts[pts.count / 2].ts - start))); Spacer()
                Text(Self.elapsed(Double(pts[pts.count - 1].ts - start)))
            }
            .font(.system(size: 10)).foregroundStyle(StrandPalette.textTertiary)
            Text("Move over the chart to read the heart rate at any moment of the session.")
                .font(.system(size: 11)).foregroundStyle(StrandPalette.textTertiary)
        } else {
            Text(loaded ? "No heart-rate samples stored for this session." : "Loading…")
                .font(.system(size: 13)).foregroundStyle(StrandPalette.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 160)
        }
    }

    /// What the detection rests on and how much of the session was seen. Nil for imported workouts.
    private var sessionNote: String? {
        guard let l = sessionLoad else { return nil }
        var parts = [l.evidence.note + ". Cardiovascular load only; muscular work isn't measured."]
        if l.pausedS > 0 { parts.append("\(Self.elapsed(Double(l.pausedS))) paused.") }
        if l.unknownS > 0 { parts.append("\(Self.elapsed(Double(l.unknownS))) not recorded.") }
        return parts.joined(separator: " ")
    }

    private func stat(_ label: String, _ value: String?, _ tint: Color, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
            Text(value ?? "—").font(.system(size: 22, weight: .bold).monospacedDigit()).foregroundStyle(tint)
            if let caption {
                Text(caption).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .strandSurface(cornerRadius: 16)
    }

    private func load() async {
        samples = (await repo.hrSamples(from: workout.startTs, to: workout.endTs, limit: 50_000)).sorted { $0.ts < $1.ts }
        sessionLoad = await repo.sessionLoad(workout)
        label = await repo.activityLabel(workout)
        log = await repo.trainingLog(workout)
        loaded = true
    }

    /// Whole numbers without a decimal, half kilos with one, thousands grouped.
    private static func number(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...1)))
    }

    private static func setText(_ s: StrengthSetRow) -> String {
        var t = s.externalKg.map { "\(s.reps) × \(number($0)) kg" } ?? "\(s.reps) reps, no external load"
        if let rir = s.rir { t += " · RIR \(rir)" }
        return t
    }

    /// When the answer was given relative to the session, so a late response can be told apart.
    private static func collectionNote(_ e: SessionEffortRow) -> String {
        let lag = e.collectedAt - e.workoutEndTs
        let timing = lag > 0 ? ", \(elapsed(Double(lag))) after the session" : " during the session"
        return "Reported by you \(dateText(e.collectedAt)) at \(DayMath.clock(e.collectedAt))\(timing) (\(e.scale))."
    }

    /// h:mm:ss, or m:ss under an hour.
    static func elapsed(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded()))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static func dateText(_ ts: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .abbreviated, time: .omitted)
    }
}
