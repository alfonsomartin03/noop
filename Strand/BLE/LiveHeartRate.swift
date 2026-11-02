import Foundation
import Combine
import StrandAnalytics

/// The one live heart-rate number every screen shows: the median of the last ~10 s of plausible readings
/// (strap-reported HR, else 60000 / latest R-R), so single beats don't make it jump.
///
/// Its own observable, separate from `AppModel` and `LiveState`, and it publishes only when the displayed value
/// changes: a view that shows the number redraws on a new value, and nothing else redraws per beat.
@MainActor
final class LiveHeartRate: ObservableObject {
    @Published private(set) var bpm: Int?

    /// Readings outside this range are treated as garbage (0, dropouts, spikes).
    static let plausible = 30.0...220.0
    private static let windowS: TimeInterval = 10
    private static let maxSamples = 40

    private var window: [(t: Date, v: Double)] = []
    private var cancellables = Set<AnyCancellable>()

    init() {}

    /// Follow `live`: both the reported HR and R-R feed the same smoother.
    convenience init(following live: LiveState) {
        self.init()
        live.$heartRate.combineLatest(live.$rr)
            .sink { [weak self] hr, rr in self?.ingest(heartRate: hr, rr: rr) }
            .store(in: &cancellables)
    }

    /// Fold one notification in. No usable reading (stream stopped) clears the value so a stale bpm isn't shown.
    func ingest(heartRate: Int?, rr: [Int], at now: Date = Date()) {
        var inst: Double?
        if let hr = heartRate, Self.plausible.contains(Double(hr)) {
            inst = Double(hr)
        } else if let last = rr.last, last > 0, Self.plausible.contains(60_000.0 / Double(last)) {
            inst = 60_000.0 / Double(last)
        }
        guard let inst else {
            window.removeAll()
            publish(nil)
            return
        }
        window.append((now, inst))
        window.removeAll { now.timeIntervalSince($0.t) > Self.windowS }
        if window.count > Self.maxSamples { window.removeFirst(window.count - Self.maxSamples) }
        let vals = window.map(\.v).sorted()
        publish(Int(vals[vals.count / 2].rounded()))
    }

    private func publish(_ v: Int?) { if bpm != v { bpm = v } }

    /// Live zone on the same %HRmax bands scoring uses (`HRZones`): 1…5, or 0 below Zone 1.
    static func zone(bpm: Int, maxHR: Int) -> Int {
        HRZones.zones(maxHR: Double(max(maxHR, 1))).zoneNumber(forBPM: Double(bpm))
    }

    /// "Zone 3", or "Below Zone 1".
    static func zoneLabel(_ zone: Int) -> String { zone >= 1 ? "Zone \(zone)" : "Below Zone 1" }
}
