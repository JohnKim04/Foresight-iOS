import Foundation
import Testing
@testable import Foresight

@MainActor
struct JournalDiscoveryTests {
    private let now = Date(timeIntervalSince1970: 1_725_000_000)

    private func category(_ name: String = "Workout") -> JournalCategory { JournalCategory(name: name) }
    private func entry(_ body: String, date: Date, categories: [JournalCategory] = []) -> JournalEntry { JournalEntry(body: body, eventAt: date, createdAt: date, updatedAt: date, categories: categories) }
    private func checkIn(_ entry: JournalEntry, phase: OutcomePhase = .delayed, status: OutcomeStatus = .pending, due: Date? = nil, overall: OutcomeValue? = nil, updated: Date? = nil) -> OutcomeCheckIn { OutcomeCheckIn(entry: entry, phase: phase, status: status, dueAt: due, answeredAt: status == .answered ? updated ?? now : nil, overall: overall, createdAt: now, updatedAt: updated ?? now) }

    @Test("matches text and category names with all search tokens")
    func filtersTextAndCategories() {
        let workout = category()
        let social = category("Social")
        let first = entry("Went on a long walk", date: now, categories: [workout])
        let second = entry("Called a friend", date: now, categories: [social])
        let results = filterJournalEntries([first, second], categories: [workout, social], checkIns: [], filters: JournalFilters(query: "long workout"))
        #expect(results.map(\.id) == [first.id])
    }

    @Test("filters entries by an explicit category")
    func filtersCategory() {
        let workout = category()
        let social = category("Social")
        let first = entry("Run", date: now, categories: [workout])
        let second = entry("Dinner", date: now, categories: [social])
        let results = filterJournalEntries([first, second], categories: [workout, social], checkIns: [], filters: JournalFilters(categoryID: social.id))
        #expect(results.map(\.id) == [second.id])
    }

    @Test("finds logs with no check-ins")
    func filtersNoCheckIns() {
        let first = entry("No check-in", date: now)
        let second = entry("Has check-in", date: now)
        let item = checkIn(second)
        let results = filterJournalEntries([first, second], categories: [], checkIns: [item], filters: JournalFilters(checkIn: .none))
        #expect(results.map(\.id) == [first.id])
    }

    @Test("finds logs with scheduled check-ins")
    func filtersScheduledCheckIns() {
        let first = entry("Scheduled", date: now)
        let second = entry("Answered", date: now)
        let scheduled = checkIn(first, due: now.addingTimeInterval(3_600))
        let answered = checkIn(second, status: .answered, due: now, overall: .same)
        let results = filterJournalEntries([first, second], categories: [], checkIns: [scheduled, answered], filters: JournalFilters(checkIn: .scheduled))
        #expect(results.map(\.id) == [first.id])
    }

    @Test("finds answered and not-sure logs")
    func filtersAnsweredCheckIns() {
        let first = entry("Answered", date: now)
        let second = entry("Unsure", date: now)
        let third = entry("Pending", date: now)
        let results = filterJournalEntries([first, second, third], categories: [], checkIns: [checkIn(first, status: .answered, overall: .same), checkIn(second, status: .notSure), checkIn(third)], filters: JournalFilters(checkIn: .answered))
        #expect(Set(results.map(\.id)) == Set([first.id, second.id]))
    }

    @Test("uses inclusive local calendar dates")
    func filtersDateRangeInclusive() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: start)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: start)!
        let results = filterEntriesByDateRange([entry("Yesterday", date: yesterday), entry("Today", date: now), entry("Tomorrow", date: tomorrow)], range: JournalDateRange(start: yesterday, end: start))
        #expect(results.map(\.body) == ["Yesterday", "Today"])
    }

    @Test("accepts a reversed custom date range")
    func reversedDateRange() {
        let start = Calendar.current.startOfDay(for: now)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: start)!
        let results = filterEntriesByDateRange([entry("Yesterday", date: yesterday), entry("Today", date: now)], range: JournalDateRange(start: start, end: yesterday))
        #expect(results.count == 2)
    }

    @Test("groups timeline entries by local day in descending order")
    func groupsTimeline() {
        let earlier = entry("Earlier", date: now.addingTimeInterval(-86_400))
        let late = entry("Late", date: now.addingTimeInterval(-200))
        let recent = entry("Recent", date: now)
        let groups = groupEntriesByDay([earlier, late, recent])
        #expect(groups.count == 2)
        #expect(groups.first?.entries.map(\.body) == ["Recent", "Late"])
    }

    @Test("builds a six-week calendar grid")
    func buildsCalendarGrid() {
        let days = calendarDays(month: now, entries: [])
        #expect(days.count == 42)
        #expect(days.contains { $0.inMonth })
    }

    @Test("counts logs on calendar days")
    func countsCalendarDays() {
        let logs = [entry("One", date: now), entry("Two", date: now.addingTimeInterval(100))]
        let day = calendarDays(month: now, entries: logs).first { localDayKey($0.date) == localDayKey(now) }
        #expect(day?.count == 2)
    }

    @Test("shows due status before other statuses")
    func dueLabel() {
        let log = entry("Log", date: now)
        let overdue = checkIn(log, due: now.addingTimeInterval(-1))
        let reflected = checkIn(log, phase: .immediate, status: .answered, overall: .same)
        #expect(entryCheckInLabel(entry: log, checkIns: [reflected, overdue], now: now) == "Check-in due")
    }

    @Test("shows scheduled and reflected statuses")
    func scheduledAndReflectedLabels() {
        let scheduledLog = entry("Scheduled", date: now)
        let reflectedLog = entry("Reflected", date: now)
        #expect(entryCheckInLabel(entry: scheduledLog, checkIns: [checkIn(scheduledLog, due: now.addingTimeInterval(60))], now: now) == "Check-in scheduled")
        #expect(entryCheckInLabel(entry: reflectedLog, checkIns: [checkIn(reflectedLog, phase: .immediate, status: .answered, overall: .same)], now: now) == "Reflected")
    }

    @Test("orders due check-ins before upcoming check-ins")
    func queuesCheckIns() {
        let first = entry("Due", date: now)
        let second = entry("Upcoming", date: now)
        let due = checkIn(first, due: now.addingTimeInterval(-60))
        let upcoming = checkIn(second, due: now.addingTimeInterval(60))
        let queue = delayedCheckInQueue(JournalSnapshot(entries: [first, second], categories: [], checkIns: [upcoming, due]), now: now)
        #expect(queue.map(\.entry.body) == ["Due", "Upcoming"])
        #expect(queue.first?.overdue == true)
    }

    @Test("returns only recent completed delayed check-ins")
    func recentQueue() {
        let first = entry("First", date: now)
        let second = entry("Second", date: now)
        let answered = checkIn(first, status: .answered, due: now, overall: .same, updated: now)
        let skipped = checkIn(second, status: .skipped, due: now, updated: now.addingTimeInterval(-1))
        let pending = checkIn(second, due: now.addingTimeInterval(300))
        let recent = recentCompletedCheckIns(JournalSnapshot(entries: [first, second], categories: [], checkIns: [pending, skipped, answered]))
        #expect(recent.map(\.checkIn.id) == [answered.id, skipped.id])
    }

    @Test("formats list dates without seconds")
    func formatsListDate() {
        #expect(!ForesightFormat.listDate(now).contains(":" ) || ForesightFormat.listDate(now).split(separator: ":").count == 2)
    }

    @Test("formats outcome labels faithfully")
    func formatsOutcomes() {
        #expect(OutcomeValue.muchWorse.title == "Much worse")
        #expect(OutcomeCheckIn(entry: entry("x", date: now), phase: .immediate, status: .notSure).responseSummary == "Not sure yet")
    }
}
