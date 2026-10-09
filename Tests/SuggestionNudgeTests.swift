import Foundation
import Testing
import UserNotifications
@testable import Foresight

actor FakeNudgeCenter: NudgeNotificationCenter {
    private(set) var status: ReminderAuthorization
    private(set) var pending: [String: (fireAt: Date, body: String)] = [:]
    private(set) var delivered: [String] = []
    private(set) var addCount = 0

    init(status: ReminderAuthorization = .allowed) { self.status = status }

    func setStatus(_ status: ReminderAuthorization) { self.status = status }
    func setPending(identifier: String, fireAt: Date) { pending[identifier] = (fireAt, "") }
    func identifiers() -> [String] { pending.keys.sorted() }
    func setDelivered(_ identifiers: [String]) { delivered = identifiers }

    func authorization() -> ReminderAuthorization { status }
    func scheduledReminders() -> [ScheduledReminder] {
        pending.map { ScheduledReminder(identifier: $0.key, fireAt: $0.value.fireAt, body: $0.value.body) }
    }
    func addNudge(_ nudge: SuggestionNudge) {
        addCount += 1
        pending[nudge.identifier] = (nudge.fireAt, nudge.body)
    }
    func removeScheduled(_ identifiers: [String]) { identifiers.forEach { pending[$0] = nil } }
    func deliveredIdentifiers() -> [String] { delivered }
    func removeDelivered(_ identifiers: [String]) { delivered.removeAll { identifiers.contains($0) } }
}

final class MemoryNudgeLedger: NudgeLedger {
    var fireDates: [Date] = []
}

private func calendar(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

private let utc = calendar("UTC")

/// 2024-08-30 09:00 UTC.
private let morning = Date(timeIntervalSince1970: 1_725_008_400)

private func at(hour: Int, dayOffset: Int = 0) -> Date {
    utc.date(byAdding: .day, value: dayOffset, to: utc.date(bySettingHour: hour, minute: 0, second: 0, of: morning)!)!
}

struct SuggestionNudgePlanTests {
    private func candidate(_ name: String, hour: Int, strength: Double = 1, loggedToday: Bool = false, id: UUID = UUID()) -> NudgeCandidate {
        NudgeCandidate(categoryID: id, categoryName: name, usualHour: hour, betterCount: 4, numericCount: 5, strength: strength, loggedToday: loggedToday)
    }

    private func plan(_ candidates: [NudgeCandidate], now: Date = morning, calendar: Calendar = utc, usedToday: Bool = false) -> [SuggestionNudge] {
        SuggestionNudgePlan.nudges(for: candidates, now: now, calendar: calendar, usedToday: usedToday)
    }

    @Test("plans the usual hour in the local time zone")
    func localZone() {
        let newYork = calendar("America/New_York")
        let nudges = plan([candidate("Walk", hour: 18)], calendar: newYork)
        // 18:00 in New York on Aug 30 2024 is 22:00 UTC.
        #expect(nudges.first?.fireAt == at(hour: 22))
        #expect(nudges.first?.identifier.contains(".2024-08-30.") == true)
        #expect(nudges.allSatisfy { newYork.component(.hour, from: $0.fireAt) == 18 })
        // The trigger gets New York wall-clock time with no zone attached.
        #expect(nudges.first?.wallClock.hour == 18)
        #expect(nudges.first?.wallClock.day == 30)
        #expect(nudges.first?.wallClock.timeZone == nil)
    }

    @Test("schedules one nudge a day at the hour the pattern holds")
    func oneADayAtUsualHour() {
        let walk = candidate("Walk", hour: 18)
        let nudges = plan([walk])
        #expect(nudges.map(\.fireAt) == [at(hour: 18), at(hour: 18, dayOffset: 1), at(hour: 18, dayOffset: 2)])
        #expect(Set(nudges.map(\.identifier)).count == 3)
        #expect(nudges.allSatisfy { $0.categoryID == walk.categoryID })
    }

    @Test("skips today when its hour has passed or a nudge already went out")
    func skipsToday() {
        let walk = candidate("Walk", hour: 8)
        #expect(plan([walk]).map(\.fireAt) == [at(hour: 8, dayOffset: 1), at(hour: 8, dayOffset: 2)])
        let evening = candidate("Read", hour: 20)
        #expect(plan([evening], usedToday: true).map(\.fireAt) == [at(hour: 20, dayOffset: 1), at(hour: 20, dayOffset: 2)])
    }

    @Test("skips today for a category already logged today")
    func skipsLoggedToday() {
        let walk = candidate("Walk", hour: 18, strength: 2, loggedToday: true)
        let read = candidate("Read", hour: 20)
        let nudges = plan([walk, read])
        #expect(nudges.map(\.categoryID) == [read.categoryID, walk.categoryID, read.categoryID])
    }

    @Test("never nudges during quiet hours")
    func quietHours() {
        let late = candidate("Late show", hour: 22)
        let early = candidate("Early run", hour: 6)
        #expect(plan([late, early]).isEmpty)
        #expect(NudgeQuietHours.standard.contains(hour: 23))
        #expect(NudgeQuietHours.standard.contains(hour: 7))
        #expect(!NudgeQuietHours.standard.contains(hour: 8))
        #expect(!NudgeQuietHours.standard.contains(hour: 21))
        #expect(NudgeQuietHours(start: 1, end: 5).contains(hour: 3))
    }

    @Test("prefers the strongest pattern but alternates days when there is another")
    func alternates() {
        let walk = candidate("Walk", hour: 18, strength: 3)
        let read = candidate("Read", hour: 20, strength: 1)
        #expect(plan([read, walk]).map(\.categoryID) == [walk.categoryID, read.categoryID, walk.categoryID])
    }

    @Test("identifiers carry the category and leave check-in reminders alone")
    func identifiersAndDiff() {
        let id = UUID()
        let identifier = SuggestionNudgePlan.identifier(day: "2024-08-30", categoryID: id)
        #expect(SuggestionNudgePlan.categoryID(fromIdentifier: identifier) == id)
        #expect(SuggestionNudgePlan.categoryID(fromIdentifier: CheckInReminderPlan.identifier(for: id)) == nil)

        let nudges = plan([candidate("Walk", hour: 18)])
        let checkIn = ScheduledReminder(identifier: CheckInReminderPlan.identifier(for: UUID()), fireAt: morning, body: "Run")
        let kept = ScheduledReminder(identifier: nudges[0].identifier, fireAt: nudges[0].fireAt, body: nudges[0].body)
        let edited = ScheduledReminder(identifier: nudges[1].identifier, fireAt: nudges[1].fireAt, body: "old")
        let stale = ScheduledReminder(identifier: SuggestionNudgePlan.identifier(day: "2024-08-29", categoryID: id), fireAt: morning, body: "")
        let changes = SuggestionNudgePlan.changes(desired: nudges, scheduled: [checkIn, kept, edited, stale])
        #expect(changes.toAdd.map(\.identifier) == [nudges[1].identifier, nudges[2].identifier])
        #expect(changes.toRemove == [stale.identifier])
    }

    @Test("parses a tapped nudge and ignores dismissals and reminders")
    func responses() {
        let id = UUID()
        let identifier = SuggestionNudgePlan.identifier(day: "2024-08-30", categoryID: id)
        #expect(NudgeResponse(requestIdentifier: identifier, actionIdentifier: UNNotificationDefaultActionIdentifier)?.categoryID == id)
        #expect(NudgeResponse(requestIdentifier: identifier, actionIdentifier: UNNotificationDismissActionIdentifier) == nil)
        #expect(NudgeResponse(requestIdentifier: CheckInReminderPlan.identifier(for: id), actionIdentifier: UNNotificationDefaultActionIdentifier) == nil)
    }

    @Test("reminders and nudges together stay within the system's 64 pending requests")
    func sharesPendingLimit() {
        let sources = (1...80).map { ReminderSource(checkInID: UUID(), dueAt: morning.addingTimeInterval(TimeInterval($0) * 60), entryBody: "Run") }
        let reminders = CheckInReminderPlan.reminders(for: sources, now: morning)
        let nudges = plan([candidate("Walk", hour: 18), candidate("Read", hour: 20)])
        #expect(nudges.count == SuggestionNudgePlan.daysAhead)
        #expect(reminders.count + nudges.count == 64)
    }

    @Test("clears delivered nudges from earlier days, and all of them once nudges are off")
    func staleDelivered() {
        let id = UUID()
        let yesterday = SuggestionNudgePlan.identifier(day: "2024-08-29", categoryID: id)
        let today = SuggestionNudgePlan.identifier(day: "2024-08-30", categoryID: id)
        let reminder = CheckInReminderPlan.identifier(for: id)
        #expect(SuggestionNudgePlan.staleDelivered([yesterday, today, reminder], today: "2024-08-30", enabled: true) == [yesterday])
        #expect(SuggestionNudgePlan.staleDelivered([yesterday, today, reminder], today: "2024-08-30", enabled: false) == [yesterday, today])
    }

    @Test("can switch the lock-screen text to a generic line")
    func genericCopy() {
        let generic = SuggestionNudgeCopy.body(categoryName: "Walk", betterCount: 4, numericCount: 5, style: .generic)
        #expect(!generic.contains("Walk"))
        #expect(!generic.contains("4 of 5"))
        #expect(SuggestionNudgeCopy.body(categoryName: "Walk", betterCount: 4, numericCount: 5, style: .specific).contains("Walk"))
    }
}

@MainActor
struct SuggestionNudgeSchedulerTests {
    private final class Clock: @unchecked Sendable {
        var now = morning
        var calendar = utc
        var enabled = true
    }

    private struct Subject {
        let store: JournalStore
        let scheduler: SuggestionNudgeScheduler
        let center: FakeNudgeCenter
        let ledger: MemoryNudgeLedger
        let clock: Clock
        let walk: JournalCategory
    }

    /// Five walks at 18:00 on the previous days, each followed later by feeling better.
    /// With `alsoRead`, a weaker pattern: reading at 21:00, better in 3 of 5 later check-ins.
    private func makeSubject(status: ReminderAuthorization = .allowed, enabled: Bool = true, alsoRead: Bool = false, setUp: (JournalStore, Clock) throws -> Void = { _, _ in }) throws -> Subject {
        let clock = Clock()
        clock.enabled = enabled
        let container = try ForesightPersistence.makeContainer(storeURL: nil)
        let store = JournalStore(modelContext: container.mainContext, modelContainer: container, now: { clock.now })
        let walk = try addPattern("Walk", hour: 18, responses: [.aLittleBetter], store: store, clock: clock)
        if alsoRead { _ = try addPattern("Read", hour: 21, responses: [.aLittleBetter, .same], store: store, clock: clock) }
        try setUp(store, clock)
        let center = FakeNudgeCenter(status: status)
        let ledger = MemoryNudgeLedger()
        let scheduler = SuggestionNudgeScheduler(center: center, ledger: ledger, now: { clock.now }, calendar: { clock.calendar }, isEnabled: { clock.enabled })
        scheduler.attach(to: store)
        return Subject(store: store, scheduler: scheduler, center: center, ledger: ledger, clock: clock, walk: walk)
    }

    /// Logs the category at `hour` on each of the five previous days and answers each later check-in.
    private func addPattern(_ name: String, hour: Int, responses: [OutcomeValue], store: JournalStore, clock: Clock) throws -> JournalCategory {
        let current = clock.now
        defer { clock.now = current }
        let category = try store.addCategory(named: name)
        for day in 1...5 {
            let loggedAt = at(hour: hour, dayOffset: -day)
            clock.now = loggedAt
            let entry = try store.saveLog(body: "\(name) \(day)", eventAt: loggedAt, categoryIDs: [category.id])
            let checkIn = try store.createCheckIn(for: entry, phase: .delayed, dueAt: loggedAt.addingTimeInterval(7_200))
            try store.answer(checkIn, response: responses[(day - 1) % responses.count], notSure: false, note: "", excludedFromAnalysis: false)
        }
        return category
    }

    private func fireDates(_ center: FakeNudgeCenter) async -> [Date] {
        await center.scheduledReminders().compactMap(\.fireAt).sorted()
    }

    @Test("schedules a nudge at the usual hour for a qualifying suggestion")
    func schedules() async throws {
        let subject = try makeSubject()
        await subject.scheduler.waitForPendingWork()
        #expect(await fireDates(subject.center) == [at(hour: 18), at(hour: 18, dayOffset: 1), at(hour: 18, dayOffset: 2)])
        let body = try #require(await subject.center.scheduledReminders().first?.body)
        #expect(body == SuggestionNudgeCopy.body(categoryName: "Walk", betterCount: 5, numericCount: 5))
    }

    @Test("drops today's nudge once the category is logged today")
    func dropsAfterLogging() async throws {
        let subject = try makeSubject()
        _ = try subject.store.saveLog(body: "Morning walk", eventAt: morning, categoryIDs: [subject.walk.id])
        await subject.scheduler.waitForPendingWork()
        #expect(await fireDates(subject.center) == [at(hour: 18, dayOffset: 1), at(hour: 18, dayOffset: 2)])
    }

    @Test("sends no second nudge on a day one already went out")
    func oneADay() async throws {
        let subject = try makeSubject(alsoRead: true)
        await subject.scheduler.waitForPendingWork()
        #expect(await fireDates(subject.center).first == at(hour: 18))
        // Walk's 18:00 nudge fires and leaves the pending list. Reading at 21:00 is still ahead today.
        subject.clock.now = at(hour: 19)
        await subject.center.removeScheduled([SuggestionNudgePlan.identifier(day: "2024-08-30", categoryID: subject.walk.id)])
        subject.scheduler.resync()
        await subject.scheduler.waitForPendingWork()
        let dates = await fireDates(subject.center)
        #expect(dates.count == 2)
        #expect(dates.allSatisfy { !utc.isDate($0, inSameDayAs: morning) })
    }

    @Test("schedules nothing and clears nudges when notifications are off")
    func respectsPermission() async throws {
        let subject = try makeSubject()
        await subject.scheduler.waitForPendingWork()
        await subject.center.setStatus(.denied)
        subject.scheduler.resync()
        await subject.scheduler.waitForPendingWork()
        #expect(await subject.center.identifiers().isEmpty)
        #expect(subject.ledger.fireDates.isEmpty)
    }

    @Test("a preference can turn nudges off without touching check-in reminders")
    func disabled() async throws {
        let subject = try makeSubject(enabled: false)
        let reminder = CheckInReminderPlan.identifier(for: UUID())
        await subject.center.setPending(identifier: reminder, fireAt: at(hour: 12))
        subject.scheduler.resync()
        await subject.scheduler.waitForPendingWork()
        #expect(await subject.center.identifiers() == [reminder])
    }

    @Test("turning nudges off removes ones already scheduled and delivered")
    func turningOffClears() async throws {
        let subject = try makeSubject()
        await subject.scheduler.waitForPendingWork()
        #expect(await subject.center.identifiers().count == 3)
        await subject.center.setDelivered([SuggestionNudgePlan.identifier(day: "2024-08-30", categoryID: subject.walk.id)])
        subject.clock.enabled = false
        subject.scheduler.resync()
        await subject.scheduler.waitForPendingWork()
        #expect(await subject.center.identifiers().isEmpty)
        #expect(await subject.center.delivered.isEmpty)
    }

    @Test("re-plans in the new time zone after a zone change")
    func followsZoneChange() async throws {
        // Logged at 00:00 UTC: 20:00 in New York, but 01:00 in London, inside quiet hours.
        let subject = try makeSubject(setUp: { store, clock in
            _ = try addPattern("Late walk", hour: 0, responses: [.aLittleBetter], store: store, clock: clock)
            clock.calendar = calendar("America/New_York")
        })
        await subject.scheduler.waitForPendingWork()
        let newYork = calendar("America/New_York")
        let walkID = subject.walk.id
        let lateWalk = await subject.center.scheduledReminders().filter { SuggestionNudgePlan.categoryID(fromIdentifier: $0.identifier) != walkID }.compactMap(\.fireAt)
        #expect(!lateWalk.isEmpty)
        #expect(lateWalk.allSatisfy { newYork.component(.hour, from: $0) == 20 })

        subject.clock.calendar = calendar("Europe/London")
        subject.scheduler.resync()
        await subject.scheduler.waitForPendingWork()
        #expect(await subject.center.scheduledReminders().allSatisfy { SuggestionNudgePlan.categoryID(fromIdentifier: $0.identifier) == walkID })
    }

    @Test("sample history never schedules a nudge")
    func ignoresFixtures() async throws {
        let subject = try makeSubject(setUp: { store, _ in
            for entry in store.entries { entry.isFixture = true }
            for checkIn in store.checkIns { checkIn.isFixture = true }
        })
        await subject.scheduler.waitForPendingWork()
        #expect(await subject.center.identifiers().isEmpty)
    }

    @Test("a tapped nudge reaches the router through the notification delegate")
    func delegateRoutesNudge() async {
        let router = CheckInReminderRouter(reminders: CheckInReminderScheduler(center: InertReminderNotificationCenter()))
        let delegate = CheckInReminderNotificationDelegate { router }
        let id = UUID()
        await delegate.handle(requestIdentifier: SuggestionNudgePlan.identifier(day: "2024-08-30", categoryID: id), actionIdentifier: UNNotificationDefaultActionIdentifier, body: "")
        #expect(router.destination == .evidence(id))
    }

    @Test("does not re-add nudges that are already scheduled correctly")
    func idempotent() async throws {
        let subject = try makeSubject()
        await subject.scheduler.waitForPendingWork()
        let added = await subject.center.addCount
        subject.scheduler.resync()
        await subject.scheduler.waitForPendingWork()
        #expect(await subject.center.addCount == added)
    }

    @Test("tapping a nudge opens that category's evidence on Patterns")
    func tapOpensEvidence() {
        let reminders = CheckInReminderScheduler(center: InertReminderNotificationCenter())
        let router = CheckInReminderRouter(reminders: reminders)
        let id = UUID()
        router.handle(NudgeResponse(requestIdentifier: SuggestionNudgePlan.identifier(day: "2024-08-30", categoryID: id), actionIdentifier: UNNotificationDefaultActionIdentifier)!)
        #expect(router.destination == .evidence(id))
    }
}
