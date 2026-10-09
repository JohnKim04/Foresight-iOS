import Foundation
import Testing
@testable import Foresight

@MainActor
struct CheckInFlowTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func snapshot(_ checkIns: [OutcomeCheckIn]) -> JournalSnapshot {
        JournalSnapshot(entries: [], categories: [], checkIns: checkIns)
    }

    @Test("offers two hours, tonight and tomorrow morning in the afternoon")
    func afternoonOptions() {
        let options = CheckInLaterOption.options(now: date(9, 14), calendar: calendar)
        #expect(options.map(\.kind) == [.inTwoHours, .tonight, .morning])
        #expect(options.map(\.dueAt) == [date(9, 16), date(9, 20), date(10, 9)])
        #expect(options.last?.title == "Tomorrow morning")
    }

    @Test("drops tonight once it is less than three hours away")
    func eveningOptions() {
        let options = CheckInLaterOption.options(now: date(9, 18), calendar: calendar)
        #expect(options.map(\.kind) == [.inTwoHours, .morning])
        #expect(options.map(\.dueAt) == [date(9, 20), date(10, 9)])
    }

    @Test("after midnight the morning option is the same morning")
    func earlyMorningOptions() {
        let options = CheckInLaterOption.options(now: date(9, 1, 30), calendar: calendar)
        #expect(options.map(\.kind) == [.inTwoHours, .tonight, .morning])
        #expect(options.last?.dueAt == date(9, 9))
        #expect(options.last?.title == "This morning")
    }

    @Test("skips a morning that is too close and offers the next one")
    func lateMorningOptions() {
        let options = CheckInLaterOption.options(now: date(9, 7), calendar: calendar)
        #expect(options.last?.dueAt == date(10, 9))
        #expect(options.last?.title == "Tomorrow morning")
    }

    @Test("every option is in the future")
    func optionsAreFuture() {
        for hour in 0..<24 {
            let now = date(9, hour, 15)
            for option in CheckInLaterOption.options(now: now, calendar: calendar) {
                #expect(option.dueAt > now)
            }
        }
    }

    @Test("counts only pending later check-ins that are due")
    func dueCount() {
        let now = date(9, 12)
        let entry = JournalEntry(body: "Log", eventAt: now)
        let checkIns = [
            OutcomeCheckIn(entry: entry, phase: .delayed, dueAt: date(9, 11)),
            OutcomeCheckIn(entry: entry, phase: .delayed, dueAt: now),
            OutcomeCheckIn(entry: entry, phase: .delayed, dueAt: date(9, 13)),
            OutcomeCheckIn(entry: entry, phase: .delayed, status: .answered, dueAt: date(9, 10), overall: .same),
            OutcomeCheckIn(entry: entry, phase: .delayed, status: .skipped, dueAt: date(9, 10)),
            OutcomeCheckIn(entry: entry, phase: .immediate)
        ]
        #expect(dueCheckInCount(snapshot(checkIns), now: now) == 2)
        #expect(nextCheckInDueDate(snapshot(checkIns), after: now) == date(9, 13))
    }

    @Test("has no next due date when nothing is waiting")
    func noNextDue() {
        let now = date(9, 12)
        let entry = JournalEntry(body: "Log", eventAt: now)
        let checkIns = [OutcomeCheckIn(entry: entry, phase: .delayed, dueAt: date(9, 11))]
        #expect(nextCheckInDueDate(snapshot(checkIns), after: now) == nil)
        #expect(dueCheckInCount(snapshot([]), now: now) == 0)
    }
}
