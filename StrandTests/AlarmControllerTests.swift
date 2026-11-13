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
    /// Identifiers currently pending or shown (submitted and not withdrawn).
    private(set) var shown: [String] = []
    private(set) var withdrawn: [String] = []
    /// When true, submissions suspend (like the system's authorization lookup) until `resume()`.
    var suspend = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var suspended: Int { waiters.count }
    func resume() { let w = waiters; waiters = []; w.forEach { $0.resume() } }
    func postWake(id: String, title: String, body: String, stillWanted: @MainActor () -> Bool) async -> AlarmNotificationOutcome {
        if suspend { await withCheckedContinuation { waiters.append($0) } }
        guard stillWanted() else { return .withdrawn }
        posts += 1; shown.append(id)
        return .submitted(critical: false)
    }
    func withdraw(ids: [String]) { withdrawn += ids; shown.removeAll { ids.contains($0) } }
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

    // MARK: deadline follow-up, backup buzz, missed

    /// An exact alarm 5 min ahead, the deadline stored on the strap and read back.
    private func exactSetup(linkReady: Bool = true) -> (AlarmController, FakeLink, Clock, AlarmOccurrence) {
        verifiedCapabilities()
        let start = Calendar.current.date(bySetting: .second, value: 0, of: Date())!
        let clock = Clock(start)
        let link = FakeLink()
        link.alarmLinkReady = linkReady
        let a = AlarmController(defaults: defaults, now: { clock.now }, notifier: FakeNotifier())
        a.attach(link: link)
        a.save(alarm(weekdays: Set(1...7), from: start, minutesAhead: 5))
        let o = a.next!
        if linkReady, case .set(let target)? = link.last?.cmd {
            respond(a, 66, seq: link.last!.seq)
            respond(a, 67, seq: link.last!.seq, body: readBack(target))
            XCTAssertEqual(a.states[o.alarmId], .confirmedOnDevice)
        }
        return (a, link, clock, o)
    }
    /// Ring-now SETs sent for the occurrence with this deadline (not the next day's deadline arm).
    private func ringNowSets(_ link: FakeLink, after deadline: Date) -> Int {
        link.sent.filter {
            if case .set(let t) = $0.cmd { let d = Double(t) - deadline.timeIntervalSince1970; return d > 30 && d < 2 * 3600 }
            return false
        }.count
    }
    private func at(_ a: AlarmController, _ clock: Clock, _ d: Date) { clock.now = d; a.tick(now: d) }

    func testStoredAlarmThatDoesNotReportRingingGetsABackupBuzz() {
        let (a, link, clock, o) = exactSetup()
        at(a, clock, o.deadline.addingTimeInterval(1))
        XCTAssertEqual(link.runs, 0, "the strap's own alarm is expected to ring first")
        XCTAssertTrue(a.followUpPending)
        at(a, clock, o.deadline.addingTimeInterval(60))
        XCTAssertEqual(ringNowSets(link, after: o.deadline), 0, "no buzz on top of a possibly ringing strap")
        at(a, clock, o.deadline.addingTimeInterval(AlarmController.storedAlarmGrace + 2))
        XCTAssertEqual(ringNowSets(link, after: o.deadline), 1, "nothing reported: backup buzz")
        XCTAssertTrue(a.history.contains { $0.kind == AlarmHistoryKind.followUp })
    }

    func testStrapDismissalOfTheStoredAlarmEndsTheFollowUp() {
        let (a, link, clock, o) = exactSetup()
        at(a, clock, o.deadline.addingTimeInterval(1))
        a.handle(event: event(57, at: o.deadline), live: true)                                  // STRAP_DRIVEN_ALARM_EXECUTED
        a.handle(event: event(100, at: o.deadline.addingTimeInterval(20), body: [0, 2]), live: true)   // dismissed
        XCTAssertFalse(a.followUpPending)
        for k in 1...10 { at(a, clock, o.deadline.addingTimeInterval(Double(k) * 120)) }
        XCTAssertEqual(ringNowSets(link, after: o.deadline), 0)
        XCTAssertEqual(AlarmHistory.summarize(a.history).first { $0.id == AlarmController.key(o) }?.status, .dismissedOnStrap)
    }

    func testUndismissedDeadlineBuzzesAgainThenStops() {
        let (a, link, clock, o) = exactSetup()
        at(a, clock, o.deadline.addingTimeInterval(1))
        a.handle(event: event(57, at: o.deadline), live: true)                                  // it rang…
        a.handle(event: event(100, at: o.deadline.addingTimeInterval(30), body: [0, 0]), live: true)   // …and expired
        for k in 1...40 {
            at(a, clock, o.deadline.addingTimeInterval(Double(k) * 30))
            // Answer each ring-now SET/RUN so the delivery can settle and the next follow-up can go out.
            if case .set? = link.last?.cmd, ringNowSets(link, after: o.deadline) > 0 { respond(a, 66, seq: link.last!.seq) }
            if link.last?.cmd == .run { respond(a, 68, seq: link.last!.seq) }
        }
        XCTAssertEqual(ringNowSets(link, after: o.deadline), AlarmController.maxFollowUps)
        XCTAssertFalse(a.followUpPending, "stops after its limit")
        XCTAssertEqual(AlarmHistory.summarize(a.history).first { $0.id == AlarmController.key(o) }?.followUpBuzzes, AlarmController.maxFollowUps)
    }

    func testHistoryReplayDismissalDoesNotEndTheFollowUp() {
        let (a, _, clock, o) = exactSetup()
        at(a, clock, o.deadline.addingTimeInterval(1))
        a.handle(event: event(57, at: o.deadline), live: false)
        a.handle(event: event(100, at: o.deadline.addingTimeInterval(20), body: [0, 2]), live: false)
        XCTAssertTrue(a.followUpPending)
    }

    func testInAppDismissalEndsTheFollowUp() {
        let (a, link, clock, o) = exactSetup()
        at(a, clock, o.deadline.addingTimeInterval(1))
        a.dismissPendingFallback()
        XCTAssertFalse(a.followUpPending)
        for k in 1...10 { at(a, clock, o.deadline.addingTimeInterval(Double(k) * 120)) }
        XCTAssertEqual(ringNowSets(link, after: o.deadline), 0)
        XCTAssertEqual(AlarmHistory.summarize(a.history).first { $0.id == AlarmController.key(o) }?.status, .dismissedInApp)
    }

    func testUnreachableStrapRecordsFollowUpsWithoutClaimingDelivery() {
        let (a, link, clock, o) = exactSetup(linkReady: false)
        for k in 0...12 { at(a, clock, o.deadline.addingTimeInterval(1 + Double(k) * 120)) }
        XCTAssertEqual(link.runs, 0)
        let s = AlarmHistory.summarize(a.history).first { $0.id == AlarmController.key(o) }
        XCTAssertEqual(s?.status, .ringingOnMac)
        XCTAssertNil(s?.vibrationReportedAt)
        XCTAssertFalse(a.followUpPending)
    }

    func testDeadlineSeenLongAfterIsMissedNotRung() {
        let (a, link, clock, o) = exactSetup()
        at(a, clock, o.deadline.addingTimeInterval(-60))
        a.hostPowerChanged(asleep: true)
        clock.now = o.deadline.addingTimeInterval(AlarmController.maxLateRing + 600)        // the Mac slept through it
        a.hostPowerChanged(asleep: false)                                                   // waking ticks at once
        XCTAssertEqual(link.runs, 0)
        XCTAssertEqual(ringNowSets(link, after: o.deadline), 0)
        XCTAssertNotEqual(a.next, o)
        let s = AlarmHistory.summarize(a.history).first { $0.id == AlarmController.key(o) }
        XCTAssertEqual(s?.status, .missed)
        XCTAssertEqual(s?.hostNotes, ["macSleep", "macWake"])
    }

    func testRelaunchAfterAPassedFallbackRecordsItMissed() {
        let (a, _, clock, o) = smartSetup()
        feedHighHR(a, clock, from: o.windowStart.addingTimeInterval(60))
        XCTAssertTrue(a.fallbackPending)
        clock.now = o.deadline.addingTimeInterval(3600)
        let b = AlarmController(defaults: defaults, now: { clock.now }, notifier: FakeNotifier())
        XCTAssertFalse(b.fallbackPending)
        XCTAssertEqual(AlarmHistory.summarize(b.history).first { $0.id == AlarmController.key(o) }?.status, .missed)
    }

    func testWindowRecordsLiveEvidenceSummaries() {
        let (a, _, clock, o) = smartSetup()
        at(a, clock, o.windowStart.addingTimeInterval(-300))
        XCTAssertEqual(a.history.filter { $0.kind == AlarmHistoryKind.evidence }.count, 1)
        let f = AlarmHistory.fields(a.history.first { $0.kind == AlarmHistoryKind.evidence }!.payload)
        XCTAssertEqual((f["liveSamples"] as? NSNumber)?.intValue, 0, "no live HR yet is recorded as zero, not assumed")
    }

    // MARK: already awake (issue #15)

    private func setTargets(_ link: FakeLink) -> [UInt32] {
        link.sent.compactMap { if case .set(let t) = $0.cmd { return t }; return nil }
    }

    func testSkipBeforeWindowMovesTheStrapDeadlineAndKeepsTheSchedule() {
        let (a, link, clock, o) = smartSetup()
        clock.now = o.windowStart.addingTimeInterval(-15 * 60)
        XCTAssertTrue(a.canSkipNext(at: clock.now))
        a.skipNextAsAwake()
        let n = try! XCTUnwrap(a.next)
        XCTAssertGreaterThan(n.deadline, o.deadline.addingTimeInterval(23 * 3600), "the following occurrence stays scheduled")
        XCTAssertEqual(a.alarms.first?.enabled, true)
        XCTAssertEqual(setTargets(link).last.map(Int.init), Int(n.deadline.timeIntervalSince1970), "strap slot moved to the next occurrence")
        let s = AlarmHistory.summarize(a.history).first { $0.id == AlarmController.key(o) }
        XCTAssertEqual(s?.status, .skippedAwake)
        XCTAssertEqual(s?.skipReason, "alreadyAwake")
        // Through the window and past the deadline: no ring, no buzz, no follow-up.
        let runs = link.runs, sets = setTargets(link).count
        feedHighHR(a, clock, from: o.windowStart.addingTimeInterval(60))
        for k in 0...10 { at(a, clock, o.deadline.addingTimeInterval(Double(k) * 60)) }
        XCTAssertEqual(link.runs, runs)
        XCTAssertEqual(setTargets(link).count, sets)
        XCTAssertFalse(a.followUpPending)
        XCTAssertFalse(a.history.contains { $0.occurrenceId == AlarmController.key(o) && $0.kind == AlarmHistoryKind.decision })
    }

    func testSkipInsideTheWindowReleasesTheStream() {
        let (a, link, clock, o) = smartSetup()
        at(a, clock, o.windowStart.addingTimeInterval(30))
        XCTAssertTrue(link.owners.contains(AlarmController.realtimeOwner))
        a.skipNextAsAwake()
        XCTAssertFalse(link.owners.contains(AlarmController.realtimeOwner))
        XCTAssertNotEqual(a.next, o)
        XCTAssertEqual(AlarmHistory.fields(a.history.first { $0.kind == AlarmHistoryKind.skipped }?.payload)["phase"] as? String, "inWindow")
    }

    func testSkipSurvivesRestart() {
        let (a, _, clock, o) = smartSetup()
        a.skipNextAsAwake()
        let b = AlarmController(defaults: defaults, now: { clock.now }, notifier: FakeNotifier())
        b.attach(link: FakeLink())
        XCTAssertNotEqual(b.next, o)
        XCTAssertEqual(b.next?.alarmId, o.alarmId)
        at(b, clock, o.deadline.addingTimeInterval(1))
        XCTAssertFalse(b.followUpPending)
    }

    func testSkipWithPendingEarlyWakeFallbackDismissesIt() {
        let (a, _, clock, o) = smartSetup()
        feedHighHR(a, clock, from: o.windowStart.addingTimeInterval(60))
        XCTAssertTrue(a.fallbackPending)
        XCTAssertFalse(a.canSkipNext(), "an occurrence that already rang is dismissed, not skipped")
        a.skipNextAsAwake()
        XCTAssertFalse(a.fallbackPending)
        XCTAssertNotEqual(a.next, o)
        XCTAssertEqual(AlarmHistory.summarize(a.history).first { $0.id == AlarmController.key(o) }?.status, .dismissedInApp)
    }

    func testSkipDuringFollowUpEndsIt() {
        let (a, link, clock, o) = exactSetup()
        at(a, clock, o.deadline.addingTimeInterval(1))
        XCTAssertTrue(a.followUpPending)
        a.skipNextAsAwake()
        XCTAssertFalse(a.followUpPending)
        for k in 1...10 { at(a, clock, o.deadline.addingTimeInterval(Double(k) * 120)) }
        XCTAssertEqual(ringNowSets(link, after: o.deadline), 0)
    }

    // MARK: dismissal racing the Mac notification (issue #15 review)

    /// Let queued main-actor tasks (notification submissions) run.
    private func drain() async { for _ in 0..<20 { await Task.yield() } }
    private func notificationOutcomes(_ a: AlarmController, _ key: String) -> [String] {
        a.history.filter { $0.occurrenceId == key && $0.kind == AlarmHistoryKind.notification }
            .compactMap { AlarmHistory.fields($0.payload)["outcome"] as? String }
    }
    private func exactSetup(notifier: FakeNotifier) -> (AlarmController, FakeLink, Clock, AlarmOccurrence) {
        verifiedCapabilities()
        let start = Calendar.current.date(bySetting: .second, value: 0, of: Date())!
        let clock = Clock(start)
        let link = FakeLink()
        let a = AlarmController(defaults: defaults, now: { clock.now }, notifier: notifier)
        a.attach(link: link)
        a.save(alarm(weekdays: Set(1...7), from: start, minutesAhead: 30))
        return (a, link, clock, a.next!)
    }

    func testDismissalWhileTheDeadlineNotificationIsSuspendedShowsNothing() async {
        let n = FakeNotifier(); n.suspend = true
        let (a, link, clock, o) = exactSetup(notifier: n)
        let key = AlarmController.key(o)
        at(a, clock, o.deadline.addingTimeInterval(1))
        await drain()
        XCTAssertEqual(n.suspended, 1, "the submission is waiting on the system")
        a.dismissPendingFallback()                                   // "I'm awake" while it waits
        n.resume()
        await drain()
        XCTAssertEqual(n.posts, 0, "no notification after the dismissal")
        XCTAssertTrue(n.shown.isEmpty)
        XCTAssertEqual(notificationOutcomes(a, key), ["withdrawn"])
        // And nothing follows for this occurrence: no follow-up buzz, no later notification.
        n.suspend = false
        let buzzes = ringNowSets(link, after: o.deadline)
        for k in 1...10 { at(a, clock, o.deadline.addingTimeInterval(Double(k) * 120)) }
        await drain()
        XCTAssertEqual(n.posts, 0)
        XCTAssertEqual(ringNowSets(link, after: o.deadline), buzzes, "no further buzz once dismissed")
        XCTAssertFalse(a.followUpPending)
        // The schedule is untouched, and a fresh launch still has the following occurrence.
        XCTAssertGreaterThan(try! XCTUnwrap(a.next).deadline, o.deadline.addingTimeInterval(23 * 3600))
        let b = AlarmController(defaults: defaults, now: { clock.now }, notifier: FakeNotifier())
        b.attach(link: FakeLink())
        XCTAssertEqual(b.next?.alarmId, o.alarmId)
        XCTAssertNotEqual(b.next, o)
        XCTAssertFalse(b.followUpPending)
    }

    func testDismissalWhileAFollowUpNotificationIsSuspendedShowsNothing() async {
        let n = FakeNotifier()
        let (a, _, clock, o) = exactSetup(notifier: n)
        let key = AlarmController.key(o)
        at(a, clock, o.deadline.addingTimeInterval(1))
        await drain()
        XCTAssertEqual(n.shown, [AlarmController.notificationId(key, .deadline)])
        n.suspend = true
        var t = o.deadline.addingTimeInterval(1)
        while n.suspended == 0, t < o.deadline.addingTimeInterval(15 * 60) {   // run on to the first follow-up buzz
            t = t.addingTimeInterval(30); at(a, clock, t); await drain()
        }
        XCTAssertEqual(n.suspended, 1)
        a.skipNextAsAwake()                                          // routes to the follow-up dismissal
        n.resume()
        await drain()
        XCTAssertEqual(n.posts, 1, "only the first ring was ever shown")
        XCTAssertTrue(n.shown.isEmpty, "the delivered ring is taken down with the dismissal")
        XCTAssertTrue(n.withdrawn.contains(AlarmController.notificationId(key, .followUp(1))))
        XCTAssertEqual(notificationOutcomes(a, key).sorted(), ["submitted", "withdrawn"])
    }

    func testDismissedEarlyWakeWithdrawsItsNotificationAndKeepsTheNextOccurrence() async {
        let n = FakeNotifier(); n.suspend = true
        verifiedCapabilities()
        let start = Calendar.current.date(bySetting: .second, value: 0, of: Date())!
        let clock = Clock(start)
        let a = AlarmController(defaults: defaults, now: { clock.now }, notifier: n)
        a.baseline = { WakeBaseline(bpm: 55, source: "test", asOf: clock.now.addingTimeInterval(-86_400)) }
        a.attach(link: FakeLink())
        a.save(alarm(weekdays: Set(1...7), mode: .smart(windowMin: 30), from: start, minutesAhead: 40))
        let o = a.next!
        feedHighHR(a, clock, from: o.windowStart.addingTimeInterval(60))
        XCTAssertTrue(a.fallbackPending)
        await drain()
        XCTAssertEqual(n.suspended, 1)
        a.dismissPendingFallback()
        n.resume()
        await drain()
        XCTAssertEqual(n.posts, 0)
        XCTAssertEqual(notificationOutcomes(a, AlarmController.key(o)), ["withdrawn"])
        at(a, clock, o.deadline.addingTimeInterval(1))               // the old deadline passes silently
        await drain()
        XCTAssertEqual(n.posts, 0)
        XCTAssertFalse(a.followUpPending)
        XCTAssertEqual(a.next?.alarmId, o.alarmId)
        XCTAssertNotEqual(a.next, o)
    }

    func testNotificationIdentifiersAreScopedToTheOccurrence() async {
        let n = FakeNotifier()
        let (a, _, clock, o) = exactSetup(notifier: n)
        at(a, clock, o.deadline.addingTimeInterval(1))
        await drain()
        let key = AlarmController.key(o)
        XCTAssertEqual(n.shown, ["noop.alarm.\(key).deadline"])
        XCTAssertEqual(Set(AlarmController.notificationIds(for: key)).count, 2 + AlarmController.maxFollowUps)
        XCTAssertTrue(AlarmController.notificationIds(for: key).allSatisfy { $0.contains(key) })
    }

    func testSkipIsOnlyOfferedWithinTheHorizonAndBeforeTheDeadline() {
        let (a, _, clock, o) = exactSetup()
        XCTAssertFalse(a.canSkipNext(at: o.deadline.addingTimeInterval(-AlarmController.skipHorizon - 60)))
        XCTAssertTrue(a.canSkipNext(at: o.deadline.addingTimeInterval(-60)))
        XCTAssertFalse(a.canSkipNext(at: o.deadline.addingTimeInterval(1)))
        _ = clock
    }

    func testSkipWhileStrapUnreachableSaysTheStrapMayStillBuzzThenReArmsOnReconnect() {
        let (a, link, clock, o) = exactSetup()
        link.alarmLinkReady = false
        a.skipNextAsAwake()
        XCTAssertTrue(a.status?.contains("may buzz") == true)
        let skipped = AlarmHistory.fields(a.history.first { $0.kind == AlarmHistoryKind.skipped }?.payload)
        XCTAssertEqual(skipped["strapAlarmStored"] as? Bool, true)
        XCTAssertEqual(skipped["strapReachable"] as? Bool, false)
        link.alarmLinkReady = true
        a.syncDeviceAlarm()                                                                    // what AppModel does on reconnect
        let n = try! XCTUnwrap(a.next)
        XCTAssertEqual(setTargets(link).last.map(Int.init), Int(n.deadline.timeIntervalSince1970))
        // If the old stored alarm still rang, it is recorded, never followed up.
        a.handle(event: event(57, at: o.deadline), live: true)
        at(a, clock, o.deadline.addingTimeInterval(AlarmController.storedAlarmGrace + 5))
        XCTAssertFalse(a.followUpPending)
        XCTAssertEqual(AlarmHistory.summarize(a.history).first { $0.id == AlarmController.key(o) }?.status, .skippedAwake)
    }
}

