import XCTest
@testable import StrandAnalytics

final class CheckInInsightsTests: XCTestCase {
    private func obs(_ date: String, _ answer: CheckInAnswer, prompt: String = "alcohol_before_bed",
                     session: CheckInSession = .morning) -> CheckInObservation {
        CheckInObservation(localDate: date, session: session, promptId: prompt, promptVersion: 1, answer: answer)
    }
    private func day(_ i: Int) -> String { HighlightCalendar.addDays("2026-10-01", i)! }
    private func outcomes(_ values: [Int: Double], _ m: CheckInMeasure = .recovery) -> [String: CheckInOutcomeDay] {
        Dictionary(uniqueKeysWithValues: values.map { (day($0.key), CheckInOutcomeDay(day: day($0.key), values: [m: $0.value])) })
    }

    func testLibraryIdsAreUniqueAndSessionsSplit() {
        let ids = CheckInLibrary.prompts.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(CheckInLibrary.prompts(for: .morning).count, 8)
        XCTAssertEqual(CheckInLibrary.prompts(for: .evening).count, 9)
        for id in CheckInLibrary.defaultMorning + CheckInLibrary.defaultEvening { XCTAssertNotNil(CheckInLibrary.prompt(id)) }
    }

    func testOutcomeWindows() {
        XCTAssertEqual(CheckInInsights.outcomeDay(for: obs("2026-10-05", .yes), measure: .recovery), "2026-10-05")
        let evening = obs("2026-10-05", .yes, prompt: "hard_workout", session: .evening)
        XCTAssertEqual(CheckInInsights.outcomeDay(for: evening, measure: .recovery), "2026-10-06")
        XCTAssertEqual(CheckInInsights.outcomeDay(for: evening, measure: .dayStrain), "2026-10-05")
        // Month boundary.
        XCTAssertEqual(CheckInInsights.outcomeDay(for: obs("2026-10-31", .no, session: .evening), measure: .hrv), "2026-11-01")
    }

    func testNotSureSkippedUnansweredAreNeverNo() {
        var o: [CheckInObservation] = []
        var v: [Int: Double] = [:]
        for i in 0..<5 { o.append(obs(day(i), .yes)); v[i] = 40 }
        for i in 5..<20 { o.append(obs(day(i), [.notSure, .skipped, .unanswered][i % 3])); v[i] = 90 }
        let c = CheckInInsights.compare(promptId: "alcohol_before_bed", measure: .recovery, observations: o, outcomes: outcomes(v))
        XCTAssertEqual(c.yesCount, 5)
        XCTAssertEqual(c.noCount, 0)
        XCTAssertEqual(c.verdict, .notEnoughData)
        XCTAssertNil(c.difference)
    }

    func testMissingOutcomeIsNotPaired() {
        var o: [CheckInObservation] = []
        var v: [Int: Double] = [:]
        for i in 0..<10 { o.append(obs(day(i), i < 5 ? .yes : .no)); if i != 2 && i != 7 { v[i] = i < 5 ? 50 : 70 } }
        let c = CheckInInsights.compare(promptId: "alcohol_before_bed", measure: .recovery, observations: o, outcomes: outcomes(v))
        XCTAssertEqual(c.yesCount, 4)
        XCTAssertEqual(c.noCount, 4)
        XCTAssertEqual(c.verdict, .notEnoughData)
    }

    func testClearDifferenceUsesAssociationLanguage() {
        var o: [CheckInObservation] = []
        var v: [Int: Double] = [:]
        for i in 0..<12 {
            let yes = i % 2 == 0
            o.append(obs(day(i), yes ? .yes : .no))
            v[i] = (yes ? 50 : 70) + Double(i % 3)
        }
        let c = CheckInInsights.compare(promptId: "alcohol_before_bed", measure: .recovery, observations: o, outcomes: outcomes(v))
        XCTAssertEqual(c.verdict, .lowerOnYes)
        XCTAssertEqual(c.yesCount, 6); XCTAssertEqual(c.noCount, 6)
        XCTAssertEqual(c.firstDay, day(0)); XCTAssertEqual(c.lastDay, day(11))
        XCTAssertLessThan(c.difference!, -15)
        let s = c.sentence(topic: "Alcohol")
        XCTAssertTrue(s.contains("lower"))
        XCTAssertTrue(s.contains("not proof of cause"))
    }

    func testOverlappingGroupsAreNoClearDifference() {
        var o: [CheckInObservation] = []
        var v: [Int: Double] = [:]
        let vals: [Double] = [40, 80, 60, 50, 70, 41, 79, 61, 51, 69]
        for i in 0..<10 { o.append(obs(day(i), i < 5 ? .yes : .no)); v[i] = vals[i] }
        let c = CheckInInsights.compare(promptId: "alcohol_before_bed", measure: .recovery, observations: o, outcomes: outcomes(v))
        XCTAssertEqual(c.verdict, .noClearDifference)
    }

    func testEveningAnswerPairsWithNextDay() {
        var o: [CheckInObservation] = []
        var v: [Int: Double] = [:]
        for i in 0..<10 {
            o.append(obs(day(i), i % 2 == 0 ? .yes : .no, prompt: "hard_workout", session: .evening))
            v[i + 1] = i % 2 == 0 ? 40 : 80      // next morning's recovery
            v[i] = v[i] ?? 0
        }
        let c = CheckInInsights.compare(promptId: "hard_workout", measure: .recovery, observations: o, outcomes: outcomes(v))
        XCTAssertEqual(c.verdict, .lowerOnYes)
    }
}
