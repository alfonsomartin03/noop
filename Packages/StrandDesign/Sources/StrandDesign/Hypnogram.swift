import SwiftUI

// MARK: - Hypnogram (§9.4 Sleep)
//
// A sleep-stage horizontal banded timeline. Each interval is drawn as a band at
// the height of its stage (awake top → deep bottom), colored per §9.1 (awake
// rose, light periwinkle, deep indigo, REM glowing mint). Adjacent intervals are
// connected by vertical risers so the trace reads as one continuous "staircase".

/// A single stage interval. `start`/`end` are seconds from the start of the night.
public struct SleepInterval: Identifiable, Sendable {
    public let id = UUID()
    public var stage: SleepStage
    public var start: TimeInterval
    public var end: TimeInterval

    public init(stage: SleepStage, start: TimeInterval, end: TimeInterval) {
        self.stage = stage
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { max(0, end - start) }
}

public struct Hypnogram: View {

    public var intervals: [SleepInterval]
    /// Height of the plotting band.
    public var height: CGFloat
    /// Whether to draw the stage labels down the left edge.
    public var showsStageAxis: Bool
    /// Whether hovering a stage band highlights it and shows a tooltip
    /// (stage name, clock start–end, duration). Defaults on.
    public var showsHover: Bool
    /// Optional wall-clock time the night began. When set, the tooltip shows
    /// real clock times (e.g. "23:42–00:04"); otherwise it shows elapsed time
    /// from the start of the night (e.g. "0:06–0:28").
    public var nightStart: Date?
    /// When true, hovering scrubs minute by minute instead of snapping to whole stage bands: a crosshair follows the
    /// cursor and the tooltip gives the clock time and the stage you were in at exactly that minute.
    public var scrubsByMinute: Bool
    /// Draw hourly gridlines and a time-of-day axis under the plot (needs `nightStart`).
    public var showsTimeAxis: Bool
    /// Time zone the night was slept in; clock labels and hour gridlines use it, not the zone the Mac is in now.
    public var timeZone: TimeZone

    public init(
        intervals: [SleepInterval],
        height: CGFloat = 180,
        showsStageAxis: Bool = true,
        showsHover: Bool = true,
        nightStart: Date? = nil,
        scrubsByMinute: Bool = false,
        showsTimeAxis: Bool = false,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.timeZone = timeZone
        self.scrubsByMinute = scrubsByMinute
        self.showsTimeAxis = showsTimeAxis
        self.intervals = intervals.sorted { $0.start < $1.start }
        self.height = height
        self.showsStageAxis = showsStageAxis
        self.showsHover = showsHover
        self.nightStart = nightStart
    }

    /// Index of the hovered interval, or nil.
    @State private var hoverIndex: Int? = nil
    /// Local x of the cursor in scrub mode.
    @State private var hoverX: CGFloat? = nil

    private var clockFormatter: DateFormatter {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; f.timeZone = timeZone; return f
    }

    /// Format a seconds-from-origin offset either as wall-clock (if nightStart
    /// is set) or as elapsed H:MM from the start of the night.
    private func timeLabel(_ secondsFromOrigin: TimeInterval) -> String {
        if let nightStart {
            let d = nightStart.addingTimeInterval(secondsFromOrigin - origin)
            return clockFormatter.string(from: d)
        }
        let total = Int((secondsFromOrigin - origin).rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        return String(format: "%d:%02d", h, m)
    }

    private var span: TimeInterval {
        guard let first = intervals.first, let last = intervals.max(by: { $0.end < $1.end }) else { return 1 }
        return max(1, last.end - first.start)
    }
    private var origin: TimeInterval { intervals.first?.start ?? 0 }

    // 4 stage rows; awake = rank 0 (top), deep = rank 3 (bottom).
    private let rowCount = 4

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showsStageAxis { axis }
            VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack {
                    if showsTimeAxis { hourGrid(in: geo.size) }
                    // faint baselines per stage row
                    ForEach(0..<rowCount, id: \.self) { rank in
                        let y = rowY(rank, in: geo.size.height)
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: geo.size.width, y: y))
                        }
                        .stroke(StrandPalette.hairline.opacity(0.4), lineWidth: 1)
                    }

                    // connecting risers
                    risers(in: geo.size)

                    // stage bands
                    ForEach(Array(intervals.enumerated()), id: \.element.id) { idx, interval in
                        let rect = bandRect(for: interval, in: geo.size)
                        let color = StrandPalette.sleepStageColor(interval.stage)
                        let dimmed = hoverIndex != nil && hoverIndex != idx
                        // glow under REM for the "REM glowing" requirement
                        if interval.stage == .rem {
                            RoundedRectangle(cornerRadius: rect.height / 2)
                                .fill(color)
                                .frame(width: rect.width, height: rect.height)
                                .blur(radius: 6)
                                .opacity(dimmed ? 0.35 : 0.7)
                                .blendMode(.plusLighter)
                                .position(x: rect.midX, y: rect.midY)
                        }
                        RoundedRectangle(cornerRadius: rect.height / 2)
                            .fill(color)
                            .frame(width: rect.width, height: rect.height)
                            .opacity(dimmed ? 0.45 : 1.0)
                            .position(x: rect.midX, y: rect.midY)
                    }

                    // Minute scrubber: crosshair + dot on the stage row + tooltip for the hovered minute.
                    if scrubsByMinute, let x = hoverX, geo.size.width > 0 {
                        let raw = origin + Double(x / geo.size.width) * span
                        let minute = (((raw - origin) / 60).rounded(.down)) * 60 + origin
                        let clamped = min(max(minute, origin), origin + span)
                        let cx = CGFloat((clamped + 30 - origin) / span) * geo.size.width
                        let iv = intervals.first { clamped + 30 >= $0.start && clamped + 30 < $0.end }
                        CrosshairRule(x: cx, height: geo.size.height)
                        if let iv {
                            let color = StrandPalette.sleepStageColor(iv.stage)
                            let y = rowY(iv.stage.bandRank, in: geo.size.height)
                            Circle().fill(color).frame(width: 14, height: 14)
                                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                .position(x: cx, y: y)
                            PositionedTooltip(
                                anchor: CGPoint(x: cx, y: y), container: geo.size,
                                tooltip: ChartTooltip(value: iv.stage.label, label: timeLabel(clamped), accent: color))
                        }
                    }

                    // Hover affordance: crosshair, band highlight ring, tooltip.
                    if showsHover, !scrubsByMinute, let idx = hoverIndex, idx < intervals.count {
                        let interval = intervals[idx]
                        let rect = bandRect(for: interval, in: geo.size)
                        let color = StrandPalette.sleepStageColor(interval.stage)
                        // vertical crosshair across the full height at band centre
                        CrosshairRule(x: rect.midX, height: geo.size.height)
                        // ring around the hovered band
                        RoundedRectangle(cornerRadius: (rect.height + 6) / 2)
                            .stroke(StrandPalette.hairlineStrong, lineWidth: 1.5)
                            .frame(width: rect.width + 6, height: rect.height + 6)
                            .position(x: rect.midX, y: rect.midY)
                        PositionedTooltip(
                            anchor: CGPoint(x: rect.midX, y: rect.midY),
                            container: geo.size,
                            tooltip: ChartTooltip(
                                value: interval.stage.label,
                                label: "\(timeLabel(interval.start))–\(timeLabel(interval.end)) · \(Int((interval.duration / 60).rounded()))m",
                                accent: color
                            )
                        )
                    }
                }
                .clipped()
                .animation(StrandMotion.fade, value: hoverIndex)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    guard showsHover else { return }
                    switch phase {
                    case .active(let location):
                        if scrubsByMinute { hoverX = location.x }
                        else { hoverIndex = intervalIndex(atX: location.x, in: geo.size) }
                    case .ended:
                        hoverIndex = nil; hoverX = nil
                    }
                }
            }
            .frame(height: height)
            if showsTimeAxis { timeAxis.frame(height: 14) }
            }
        }
    }

    // MARK: Time-of-day axis

    /// Whole-hour tick positions as (offset in seconds from `origin`, label); empty without a wall-clock start.
    private var hourTicks: [(t: TimeInterval, label: String)] {
        guard let nightStart else { return [] }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let end = nightStart.addingTimeInterval(span)
        guard var tick = cal.nextDate(after: nightStart, matching: DateComponents(minute: 0, second: 0), matchingPolicy: .nextTime) else { return [] }
        let stepH = span > 10 * 3600 ? 2 : 1
        var out: [(TimeInterval, String)] = []
        let f = DateFormatter(); f.dateFormat = "h a"; f.timeZone = timeZone
        while tick < end {
            out.append((origin + tick.timeIntervalSince(nightStart), f.string(from: tick)))
            guard let next = cal.date(byAdding: .hour, value: stepH, to: tick) else { break }
            tick = next
        }
        return out
    }

    private func hourGrid(in size: CGSize) -> some View {
        Path { p in
            for tk in hourTicks {
                let x = CGFloat((tk.t - origin) / span) * size.width
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
            }
        }
        .stroke(StrandPalette.hairline.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
    }

    private var timeAxis: some View {
        GeometryReader { geo in
            ForEach(Array(hourTicks.enumerated()), id: \.offset) { _, tk in
                Text(tk.label).font(.system(size: 10, weight: .medium)).foregroundStyle(StrandPalette.textTertiary)
                    .position(x: CGFloat((tk.t - origin) / span) * geo.size.width, y: 7)
            }
        }
    }

    /// The interval whose horizontal span contains a local x, or the nearest.
    private func intervalIndex(atX x: CGFloat, in size: CGSize) -> Int? {
        guard !intervals.isEmpty, size.width > 0 else { return nil }
        let t = origin + Double(x / size.width) * span
        // First try an exact containment hit.
        for (i, iv) in intervals.enumerated() where t >= iv.start && t <= iv.end {
            return i
        }
        // Otherwise snap to the nearest interval by centre time.
        return intervals.enumerated().min(by: { a, b in
            abs(midTime(a.element) - t) < abs(midTime(b.element) - t)
        })?.offset
    }

    private func midTime(_ iv: SleepInterval) -> TimeInterval { (iv.start + iv.end) / 2 }

    // MARK: Axis

    private var axis: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(stagesTopToBottom, id: \.self) { stage in
                Text(stage.label)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(width: 44, height: height)
    }

    private var stagesTopToBottom: [SleepStage] {
        [.awake, .rem, .light, .deep]
    }

    // MARK: Geometry

    // Stage -> vertical row: awake at the top, deep at the bottom.
    private func rowY(_ rank: Int, in totalHeight: CGFloat) -> CGFloat {
        let usable = totalHeight
        let step = usable / CGFloat(rowCount)
        return step * (CGFloat(rank) + 0.5)
    }

    // Each interval becomes a horizontal band positioned by time (x) and stage (y).
    private func bandRect(for interval: SleepInterval, in size: CGSize) -> CGRect {
        let x0 = min(size.width, max(0, CGFloat((interval.start - origin) / span) * size.width))
        let x1 = min(size.width, max(0, CGFloat((interval.end - origin) / span) * size.width))
        let thickness: CGFloat = max(10, size.height / CGFloat(rowCount) * 0.42)
        let y = rowY(interval.stage.bandRank, in: size.height)
        return CGRect(x: x0, y: y - thickness / 2, width: max(2, x1 - x0), height: thickness)
    }

    // Soft gradient connectors from one stage's colour to the next, so the night reads as one flowing ribbon.
    private func risers(in size: CGSize) -> some View {
        ZStack {
            ForEach(0..<max(0, intervals.count - 1), id: \.self) { i in
                let a = intervals[i], b = intervals[i + 1]
                let x = CGFloat((b.start - origin) / span) * size.width
                let ya = rowY(a.stage.bandRank, in: size.height)
                let yb = rowY(b.stage.bandRank, in: size.height)
                if abs(ya - yb) > 1 {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(LinearGradient(colors: [StrandPalette.sleepStageColor(a.stage).opacity(0.75),
                                                      StrandPalette.sleepStageColor(b.stage).opacity(0.75)],
                                             startPoint: ya < yb ? .top : .bottom, endPoint: ya < yb ? .bottom : .top))
                        .frame(width: 3, height: abs(yb - ya))
                        .position(x: x, y: (ya + yb) / 2)
                }
            }
        }
    }
}

#if DEBUG
private func sampleNight() -> [SleepInterval] {
    // ~7.5h night, seconds.
    var t: TimeInterval = 0
    func add(_ stage: SleepStage, _ minutes: Double) -> SleepInterval {
        let s = SleepInterval(stage: stage, start: t, end: t + minutes * 60)
        t += minutes * 60
        return s
    }
    return [
        add(.awake, 6),
        add(.light, 22),
        add(.deep, 38),
        add(.light, 18),
        add(.rem, 24),
        add(.light, 14),
        add(.deep, 30),
        add(.rem, 28),
        add(.light, 20),
        add(.awake, 4),
        add(.rem, 32),
        add(.light, 26),
        add(.awake, 8),
    ]
}

#Preview("Hypnogram") {
    let start = Calendar.current.date(bySettingHour: 23, minute: 18, second: 0, of: Date())
    return VStack(alignment: .leading, spacing: 12) {
        Text("Last night").strandOverline()
        Text("Hover a band: stage name, clock start–end and duration.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        Hypnogram(intervals: sampleNight(), height: 200, nightStart: start)
    }
    .padding(28)
    .frame(width: 720, height: 340)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
