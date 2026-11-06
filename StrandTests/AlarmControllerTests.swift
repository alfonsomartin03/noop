import XCTest
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import NOOP

// MARK: doubles

@MainActor
private final class FakeLink: AlarmStrapLink {
    var alarmLinkReady = true
    var alarmClock: ClockEstimate? = ClockEstimate(offset: 0, uncertainty: 0.5, measuredAt: 0)
    private(set) var sent: [(cmd: AlarmStrapCommand, seq: UInt8)] = []
    private(set) var owners = Set<String>()
    private var seq: UInt8 = 0
    func sendAlarmCommand(_ c: AlarmStrapCommand) -> UInt8? {
        guard alarmLinkReady else { return nil }
        seq &+= 1; sent.append((c, seq)); return seq
    }
    func acquireRealtime(owner: String) { owners.insert(owner) }
    func releaseRealtime(owner: String) { owners.remove(owner) }
    var runs: Int { sent.filter { $0.cmd == .run }.count }
    var last: (cmd: AlarmStrapCommand, seq: UInt8)? { sent.last }
}

@MainActor
private final class FakeNotifier: AlarmNotifying {
    var posts = 0
    func postWake(title: String, body: String) async -> AlarmNotificationOutcome { posts += 1; return .submitted(critical: false) }
}

private actor FakeSink: AlarmHistorySink {
    var rows: [AlarmEventRow] = []
    var fail = false
    func setFail(_ f: Bool) { fail = f }
    func appendAlarmEvents(_ r: [AlarmEventRow]) async throws -> Int {
        if fail { throw CocoaError(.fileWriteUnknown) }
        rows += r; return r.count
    }
    func alarmEvents(since: Double, limit: Int) async throws -> [AlarmEventRow] { rows }
    func setAlarmAnnotation(_ a: AlarmAnnotationRow) async throws {}
    func alarmAnnotations() async throws -> [AlarmAnnotationRow] { [] }
}

@MainActor
private final class Clock { var now: Date; init(_ d: Date) { now = d } }

@MainActor
final class AlarmControllerTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "AlarmControllerTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    /// An alarm `minutesAhead` minutes after `from` (whole minute), on `weekdays`.
    private func alarm(weekdays: Set<Int>, mode: AlarmSpec.Mode = .exact, from: Date = Date(), minutesAhead: Double = 5) -> AlarmSpec {
        let c = Calendar.current.dateComponents([.hour, .minute], from: from.addingTimeInterval(minutesAhead * 60))
        return AlarmSpec(hour: c.hour!, minute: c.minute!, weekdays: weekdays, mode: mode)
    }

    private func verifiedCapabilities() {
        defaults.set(try! JSONEncoder().encode(AlarmController.verified(firmware: "50.43.1.0")), forKey: "alarm.capabilities")
    }

    private func respond(_ a: AlarmController, _ cmd: UInt8, seq: UInt8, ok: Bool = true, body: [UInt8] = [4, 1]) {
        a.handle(response: Whoop5CommandResponse(command: cmd, appSeq: seq, strapSeq: 0, result: ok ? .success : .failure, body: body))
    }
    private func readBack(_ t: UInt32) -> [UInt8] { [4, 1, UInt8(t & 0xFF), UInt8(t >> 8 & 0xFF), UInt8(t >> 16 & 0xFF), UInt8(t >> 24 & 0xFF)] }
    private func event(_ n: Int, at: Date, body: [UInt8] = []) -> Whoop5Event {
        Whoop5Event(number: n, kind: Whoop5EventKind(n), unix: Int(at.timeIntervalSince1970), subseconds: 0, body: body)
    }

    /// Controller with fakes, a smart alarm 40 min ahead (window opens at +10 min), the deadline armed and read back.
    private func smartSetup(sink: FakeSink? = nil) -> (AlarmController, FakeLink, Clock, AlarmOccurrence) {
        verifiedCapabilities()
        let start = Calendar.current.date(bySetting: .second, value: 0, of: Date())!
        let clock = Clock(start)
        let link = FakeLink()
        let a = AlarmController(defaults: defaults, now: { clock.now }, notifier: FakeNotifier(), history: { sink })
        a.baseline = { WakeBaseline(bpm: 55, source: "test", asOf: clock.now.addingTimeInterval(-86_400)) }
        a.attach(link: link)
        a.save(alarm(weekdays: Set(1...7), mode: .smart(windowMin: 30), from: start, minutesAhead: 40))
        let o = a.next!
        // Deadline arm: SET, answered, then GET read-back.
        guard case .set(let target)? = link.last?.cmd else { XCTFail("deadline not armed"); return (a, link, clock, o) }
        respond(a, 66, seq: link.last!.seq)
        XCTAssertEqual(link.last?.cmd, .get)
        respond(a, 67, seq: link.last!.seq, body: readBack(target))
        XCTAssertEqual(a.states[o.alarmId], .confirmedOnDevice)
        return (a, link, clock, o)
    }

    /// Up to 3 min of HR well above the baseline inside the window, ticking every 5 s, stopping at the first tick that
    /// decides (the history gains a decision row).
    private func feedHighHR(_ a: AlarmController, _ clock: Clock, from: Date) {
        clock.now = from
        a.tick(now: clock.now)
        let decisions = { a.history.filter { $0.kind == AlarmHistoryKind.decision }.count }
        let before = decisions()
        for s in 0..<180 {
            clock.now = from.addingTimeInterval(Double(s))
            a.ingest(HRObservation(at: clock.now, bpm: 68, receivedAt: clock.now))
            if s % 5 == 0 { a.tick(now: clock.now); if decisions() > before { return } }
        }
    }

    // MARK: existing behaviour

    func testOneOffAlarmSwitchesOffAfterRinging() throws {
        let alarms = AlarmController(defaults: defaults, notifier: FakeNotifier())
        alarms.save(alarm(weekdays: []))
        let first = try XCTUnwrap(alarms.next)
        alarms.tick(now: first.deadline.addingTimeInterval(1))
        XCTAssertEqual(alarms.alarms.first?.enabled, false)
        XCTAssertEqual(alarms.states[first.alarmId], .canceled)
        XCTAssertNil(alarms.next)
    }

    func testRungOccurrenceIsNotScheduledAgain() throws {
        let alarms = AlarmController(defaults: defaults, notifier: FakeNotifier())
        alarms.save(alarm(weekdays: Set(1...7)))
        let first = try XCTUnwrap(alarms.next)
        alarms.tick(now: first.deadline.addingTimeInterval(1))
        let second = try XCTUnwrap(alarms.next)
        XCTAssertGreaterThan(second.deadline, first.deadline.addingTimeInterval(23 * 3600))
        XCTAssertEqual(alarms.states[first.alarmId], .active)
        XCTAssertEqual(alarms.alarms.first?.enabled, true)
    }

    // MARK: delivery lifecycle

    /// SET → (answer) → RUN, never RUN first; repeated ticks never buzz twice; an unconfirmed buzz keeps the deadline
    /// fallback (re-armed on the strap) and the occurrence stays scheduled.
    func testEarlyDeliveryIsSerializedAndUnconfirmedKeepsFallback() throws {
        let (a, link, clock, o) = smartSetup()
        XCTAssertTrue(link.owners.contains(AlarmController.realtimeOwner) == false)   // not before the window
        feedHighHR(a, clock, from: o.windowStart.addingTimeInterval(60))
        guard case .set? = link.last?.cmd else { return XCTFail("early wake should SET the ring-now alarm first") }
        XCTAssertEqual(link.runs, 0)
        XCTAssertFalse(link.owners.contains(AlarmController.realtimeOwner))         // stream released on decision
        XCTAssertTrue(a.fallbackPending)
        let setSeq = link.last!.seq
        for i in 1...6 { clock.now = clock.now.addingTimeInterval(1); a.tick(now: clock.now); _ = i }
        XCTAssertEqual(link.sent.filter { if case .set = $0.cmd { return true }; return false }.count, 2)   // deadline + ring-now only
        // A stale or mismatched answer changes nothing.
        respond(a, 66, seq: setSeq &+ 9)
        XCTAssertEqual(link.runs, 0)
        respond(a, 66, seq: setSeq)
        XCTAssertEqual(link.last?.cmd, .run)
        respond(a, 68, seq: link.last!.seq)
        XCTAssertEqual(link.runs, 1)
        // No HAPTICS_FIRED within 30 s → unconfirmed → the deadline goes back on the strap.
        clock.now = clock.now.addingTimeInterval(31); a.tick(now: clock.now)
        guard case .set(let t)? = link.last?.cmd else { return XCTFail("deadline not re-armed after unconfirmed delivery") }
        XCTAssertEqual(Int(t), Int(o.deadline.timeIntervalSince1970))
        XCTAssertEqual(a.next, o)
        XCTAssertEqual(link.runs, 1)
        XCTAssertEqual(AlarmHistory.summarize(a.history).first?.status, .deliveryUnconfirmed)
        // The deadline still rings (by the re-armed strap alarm) and only then is the occurrence finished.
        respond(a, 66, seq: link.last!.seq); respond(a, 67, seq: link.last!.seq, body: readBack(t))
        clock.now = o.deadline.addingTimeInterval(1); a.tick(now: clock.now)
        XCTAssertEqual(link.runs, 1)                                                  // strap rings itself: no extra buzz
        XCTAssertNotEqual(a.next, o)
    }

    func testRejectedSetFailsAndRestoresDeadline() {
        let (a, link, clock, o) = smartSetup()
        feedHighHR(a, clock, from: o.windowStart.addingTimeInterval(60))
        respond(a, 66, seq: link.last!.seq, ok: false, body: [4, 10])
        XCTAssertEqual(link.runs, 0)
        guard case .set(let t)? = link.last?.cmd else { return XCTFail("deadline not restored") }
        XCTAssertEqual(Int(t), Int(o.deadline.timeIntervalSince1970))
        XCTAssertEqual(AlarmHistory.summarize(a.history).first?.status, .failed)
    }

    /// Live strap events complete the occurrence; a history replay of a dismissal never does.
    func testLiveDismissalCompletesButHistoryReplayDoesNot() {
        let (a, link, clock, o) = smartSetup()
        feedHighHR(a, clock, from: o.windowStart.addingTimeInterval(60))
        respond(a, 66, seq: link.last!.seq); respond(a, 68, seq: link.last!.seq)
        clock.now = clock.now.addingTimeInterval(1)
        a.handle(event: event(60, at: clock.now), live: true)                        // HAPTICS_FIRED
        XCTAssertEqual(AlarmHistory.summarize(a.history).first?.status, .strapReportedVibration)
        a.handle(event: event(100, at: clock.now.addingTimeInterval(5), body: [0, 2]), live: false)   // replayed
        XCTAssertTrue(a.fallbackPending)
        XCTAssertEqual(a.next, o)
        a.handle(event: event(100, at: clock.now.addingTimeInterval(6), body: [0, 2]), live: true)
        XCTAssertFalse(a.fallbackPending)
        XCTAssertNotEqual(a.next, o)
        XCTAssertEqual(AlarmHistory.summarize(a.history).first { $0.id == AlarmController.key(o) }?.status, .dismissedOnStrap)
        // The replayed copy was kept as unmatched history, the live copy deduplicated by key.
        let dupKeys = a.history.compactMap(\.dedupeKey).filter { $0.hasPrefix("strap:100") }
        XCTAssertEqual(Set(dupKeys).count, dupKeys.count)
    }

    func testDisconnectDuringDeliveryFailsAndKeepsFallback() {
        let (a, link, clock, o) = smartSetup()
        feedHighHR(a, clock, from: o.windowStart.addingTimeInterval(60))
        link.alarmLinkReady = false
        a.linkDropped()
        XCTAssertEqual(AlarmHistory.summarize(a.history).first?.status, .failed)
        XCTAssertTrue(a.fallbackPending)
        XCTAssertEqual(a.next, o)
    }

    // MARK: stream ownership, restart, persistence

    func testStreamOwnershipReleasedOnDeletion() {
        let (a, link, clock, o) = smartSetup()
        clock.now = o.windowStart.addingTimeInterval(30); a.tick(now: clock.now)
        XCTAssertTrue(link.owners.contains(AlarmController.realtimeOwner))
        a.delete(o.alarmId)
        XCTAssertFalse(link.owners.contains(AlarmController.realtimeOwner))
    }

    func testRestartAfterEarlyWakeDoesNotBuzzEarlyAgain() {
        let (a, link, clock, o) = smartSetup()
        feedHighHR(a, clock, from: o.windowStart.addingTimeInterval(60))
        XCTAssertTrue(a.fallbackPending)
        // Relaunch: same defaults, new controller and link.
        let link2 = FakeLink()
        let b = AlarmController(defaults: defaults, now: { clock.now }, notifier: FakeNotifier())
        b.baseline = { WakeBaseline(bpm: 55, source: "test", asOf: clock.now.addingTimeInterval(-86_400)) }
        b.attach(link: link2)
        XCTAssertEqual(b.next, o)
        XCTAssertTrue(b.fallbackPending)
        let before = link2.sent.count
        feedHighHR(b, clock, from: clock.now.addingTimeInterval(120))
        XCTAssertEqual(link2.sent.count, before)                                      // no second early buzz
        _ = link
    }

    func testHistoryFailureIsSurfacedAndNeverBlocksDelivery() async {
        let sink = FakeSink()
        await sink.setFail(true)
        let (a, link, clock, o) = smartSetup(sink: sink)
        feedHighHR(a, clock, from: o.windowStart.addingTimeInterval(60))
        guard case .set? = link.last?.cmd else { return XCTFail("delivery must not wait for history") }
        for _ in 0..<20 where a.historyWarning == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(a.historyWarning)
        await sink.setFail(false)
        a.tick(now: clock.now.addingTimeInterval(1))                                  // the next tick retries the queue
        for _ in 0..<20 where a.historyWarning != nil { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(a.historyWarning)
        let saved = await sink.rows
        XCTAssertTrue(saved.contains { $0.kind == AlarmHistoryKind.decision })
    }
}
