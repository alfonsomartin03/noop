import XCTest
import WhoopStore
@testable import StrandAnalytics

final class AlarmHistoryTests: XCTestCase {
    func row(_ kind: String, _ t: Double, _ p: [String: Any] = [:], occ: String? = "a@100", prov: String = "host") -> AlarmEventRow {
        AlarmEventRow(occurrenceId: occ, kind: kind, recordedAt: t, provenance: prov, payload: AlarmHistory.payload(p))
    }

    func testStatusesFromHistory() {
        let base = [row(AlarmHistoryKind.scheduled, 1, ["alarmId": "a", "deadline": 100.0, "windowStart": 40.0, "policyVersion": "v2"]),
                    row(AlarmHistoryKind.decision, 50, ["trigger": "hrRun", "reason": "r"])]
        func status(_ extra: [AlarmEventRow]) -> AlarmOccurrenceSummary.Status? { AlarmHistory.summarize(base + extra).first?.status }
        XCTAssertEqual(status([row(AlarmHistoryKind.commandRequested, 51, ["command": "run"])]), .buzzRequested)
        XCTAssertEqual(status([row(AlarmHistoryKind.commandRequested, 51, ["command": "run"]),
                               row(AlarmHistoryKind.deliveryOutcome, 82, ["outcome": "unconfirmed"])]), .deliveryUnconfirmed)
        XCTAssertEqual(status([row(AlarmHistoryKind.strapEvent, 52, ["event": "HAPTICS_FIRED"], prov: "live")]), .strapReportedVibration)
        XCTAssertEqual(status([row(AlarmHistoryKind.strapEvent, 52, ["event": "HAPTICS_FIRED"]),
                               row(AlarmHistoryKind.dismissal, 60, ["source": "strap"])]), .dismissedOnStrap)
        XCTAssertEqual(status([row(AlarmHistoryKind.deliveryOutcome, 50, ["outcome": "macOnly"])]), .ringingOnMac)
        let s = AlarmHistory.summarize(base).first!
        XCTAssertEqual(s.deadline, Date(timeIntervalSince1970: 100)); XCTAssertEqual(s.policyVersion, "v2")
    }

    func testSkippedAsAwakeIsItsOwnStatus() {
        let rows = [row(AlarmHistoryKind.scheduled, 1, ["alarmId": "a", "deadline": 100.0]),
                    row(AlarmHistoryKind.skipped, 20, ["reason": "alreadyAwake", "phase": "beforeWindow"])]
        let s = AlarmHistory.summarize(rows).first!
        XCTAssertEqual(s.status, .skippedAwake)
        XCTAssertEqual(s.skipReason, "alreadyAwake")
        XCTAssertEqual(s.anchor, Date(timeIntervalSince1970: 20))
        // A stored strap alarm that still rang (strap offline at skip time) doesn't hide the skip.
        let rang = rows + [row(AlarmHistoryKind.strapEvent, 100, ["event": "STRAP_DRIVEN_ALARM_EXECUTED"], prov: "live")]
        XCTAssertEqual(AlarmHistory.summarize(rang).first?.status, .skippedAwake)
    }

    func testUnattributedEventsAreNotGuessedIntoAnOccurrence() {
        let rows = [row(AlarmHistoryKind.scheduled, 1, ["deadline": 100.0]),
                    row(AlarmHistoryKind.strapEvent, 52, ["event": "HAPTICS_FIRED"], occ: nil, prov: "history")]
        XCTAssertEqual(AlarmHistory.summarize(rows).first?.status, .scheduled)
    }

    // MARK: stage lookup

    func episode(_ start: Int, _ end: Int, _ json: String?) -> CachedSleepSession {
        CachedSleepSession(startTs: start, endTs: end, efficiency: 0.9, restingHr: nil, avgHrv: nil, stagesJSON: json, kind: "primary", sessionId: "s")
    }

    func testGenuineSegmentsGiveAnEstimate() {
        let e = episode(0, 600, #"[{"end":300,"stage":"deep","start":0},{"end":600,"stage":"light","start":300}]"#)
        XCTAssertEqual(AlarmStageLookup.stage(at: 450, episodes: [e], source: "NOOP v5"), .estimated(stage: "light", source: "NOOP v5"))
    }

    func testTotalsSyntheticGapsAndUnknownAreUnavailable() {
        // Imported totals: never a timeline.
        let totals = episode(0, 600, #"{"awake":10,"deep":60,"light":200,"rem":90}"#)
        XCTAssertEqual(AlarmStageLookup.stage(at: 100, episodes: [totals], source: "x"), .unavailable("Stage unavailable (stage totals only)"))
        // Two episodes with a gap: the gap is not "wake" just because a recombined row labels it so.
        let a = episode(0, 300, #"[{"end":300,"stage":"light","start":0}]"#)
        let b = episode(900, 1200, #"[{"end":1200,"stage":"rem","start":900}]"#)
        XCTAssertEqual(AlarmStageLookup.stage(at: 600, episodes: [a, b], source: "x"), .unavailable("Stage unavailable (no estimate at this time)"))
        // A recombined row whose inserted "wake" gap segment lies outside... is still a row whose segments are its own:
        // callers pass RAW episodes; a segment outside its episode's bounds is dropped.
        let bogus = episode(0, 300, #"[{"end":900,"stage":"wake","start":300}]"#)
        XCTAssertEqual(AlarmStageLookup.stage(at: 600, episodes: [bogus], source: "x"), .unavailable("Stage unavailable"))
        let unk = episode(0, 300, #"[{"end":300,"stage":"unknown","start":0}]"#)
        XCTAssertEqual(AlarmStageLookup.stage(at: 100, episodes: [unk], source: "x"), .unavailable("Stage unavailable (unknown)"))
        XCTAssertEqual(AlarmStageLookup.stage(at: 100, episodes: [], source: "x"), .unavailable("Stage unavailable"))
    }

    func testTimelineClips() {
        let e = episode(0, 600, #"[{"end":300,"stage":"deep","start":0},{"end":600,"stage":"light","start":300}]"#)
        XCTAssertEqual(AlarmStageLookup.timeline(from: 200, to: 400, episodes: [e]).map { [$0.start, $0.end] }, [[200, 300], [300, 400]])
    }
}
