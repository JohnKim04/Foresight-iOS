import Foundation
import Testing
import UserNotifications
@testable import Foresight

actor FakeNudgeCenter: NudgeNotificationCenter {
    private(set) var status: ReminderAuthorization
    private(set) var pending: [String: (fireAt: Date, body: String, category: String?)] = [:]
    private(set) var delivered: [String] = []
    private(set) var addCount = 0

    init(status: ReminderAuthorization = .allowed) { self.status = status }

    func setStatus(_ status: ReminderAuthorization) { self.status = status }
    func setPending(identifier: String, fireAt: Date) { pending[identifier] = (fireAt, "", nil) }
    func identifiers() -> [String] { pending.keys.sorted() }
    func setDelivered(_ identifiers: [String]) { delivered = identifiers }

    func authorization() -> ReminderAuthorization { status }
    func scheduledReminders() -> [ScheduledReminder] {
        pending.map { ScheduledReminder(identifier: $0.key, fireAt: $0.value.fireAt, body: $0.value.body, categoryIdentifier: $0.value.category) }
    }
    func addNudge(_ nudge: SuggestionNudge) {
        addCount += 1
        pending[nudge.identifier] = (nudge.fireAt, nudge.body, SuggestionNudgePlan.categoryIdentifier)
    }
    func removeScheduled(_ identifiers: [String]) { identifiers.forEach { pending[$0] = nil } }
    func deliveredIdentifiers() -> [String] { delivered }
    func removeDelivered(_ identifiers: [String]) { delivered.removeAll { identifiers.contains($0) } }
}

final class MemoryNudgeLedger: NudgeLedger {
    var fires: [NudgeFire] = []
    var mutedUntil: [UUID: Date] = [:]
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
    private func candidate(_ name: String, hour: Int, strength: Double = 1, loggedToday: Bool = false, weekendsOnly: Bool = false, kind: NudgeKind = .better, id: UUID = UUID()) -> NudgeCandidate {
        NudgeCandidate(categoryID: id, categoryName: name, usualHour: hour, matchingCount: 4, numericCount: 5, strength: strength, loggedToday: loggedToday, weekendsOnly: weekendsOnly, kind: kind)
    }

    private func plan(_ candidates: [NudgeCandidate], now: Date = morning, calendar: Calendar = utc, quietHours: QuietHours = .standard, usedToday: Bool = false, lastNudged: [UUID: Date] = [:], muted: Set<UUID> = [], cooldownDays: Int = SuggestionNudgePlan.cooldownDays) -> [SuggestionNudge] {
        SuggestionNudgePlan.nudges(for: candidates, now: now, calendar: calendar, quietHours: quietHours, usedToday: usedToday, lastNudged: lastNudged, muted: muted, cooldownDays: cooldownDays)
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

    @Test("schedules a nudge at the hour the pattern holds, then rests that category for three days")
    func oneAtUsualHour() {
        let walk = candidate("Walk", hour: 18)
        let nudges = plan([walk])
        #expect(nudges.map(\.fireAt) == [at(hour: 18)])
        #expect(nudges.allSatisfy { $0.categoryID == walk.categoryID })
        // Without the rest, the same category would come every day.
        let daily = plan([walk], cooldownDays: 1)
        #expect(daily.map(\.fireAt) == [at(hour: 18), at(hour: 18, dayOffset: 1), at(hour: 18, dayOffset: 2)])
        #expect(Set(daily.map(\.identifier)).count == 3)
    }

    @Test("a category nudged on an earlier day waits until its third day")
    func cooldownFromHistory() {
        let walk = candidate("Walk", hour: 18)
        #expect(plan([walk], lastNudged: [walk.categoryID: at(hour: 18, dayOffset: -1)]).map(\.fireAt) == [at(hour: 18, dayOffset: 2)])
        #expect(plan([walk], lastNudged: [walk.categoryID: at(hour: 8, dayOffset: -2)]).map(\.fireAt) == [at(hour: 18, dayOffset: 1)])
        #expect(plan([walk], lastNudged: [walk.categoryID: at(hour: 23, dayOffset: -3)]).map(\.fireAt) == [at(hour: 18)])
        // Another category isn't held back by it.
        let read = candidate("Read", hour: 20, strength: 0.5)
        #expect(plan([walk, read], lastNudged: [walk.categoryID: at(hour: 8, dayOffset: -2)]).map(\.categoryID) == [read.categoryID, walk.categoryID])
    }

    @Test("a category turned down with Less often gets nothing while muted")
    func mutedCategory() {
        let walk = candidate("Walk", hour: 18, strength: 2)
        let read = candidate("Read", hour: 20)
        #expect(plan([walk, read], muted: [walk.categoryID]).map(\.categoryID) == [read.categoryID])
        #expect(plan([walk], muted: [walk.categoryID]).isEmpty)
    }

    @Test("skips today when its hour has passed or a nudge already went out")
    func skipsToday() {
        let walk = candidate("Walk", hour: 8)
        #expect(plan([walk]).map(\.fireAt) == [at(hour: 8, dayOffset: 1)])
        let evening = candidate("Read", hour: 20)
        #expect(plan([evening], usedToday: true).map(\.fireAt) == [at(hour: 20, dayOffset: 1)])
    }

    @Test("skips today for a category already logged today")
    func skipsLoggedToday() {
        let walk = candidate("Walk", hour: 18, strength: 2, loggedToday: true)
        let read = candidate("Read", hour: 20)
        let nudges = plan([walk, read])
        #expect(nudges.map(\.categoryID) == [read.categoryID, walk.categoryID])
    }

    @Test("a pattern that held mostly on weekends is only nudged on weekends")
    func weekendsOnly() {
        // `morning` is a Friday, so the three days ahead are Friday, Saturday and Sunday.
        let hike = candidate("Hike", hour: 10, strength: 2, weekendsOnly: true)
        let walk = candidate("Walk", hour: 18)
        let nudges = plan([hike, walk])
        #expect(nudges.map(\.categoryID) == [walk.categoryID, hike.categoryID])
        #expect(nudges.map(\.fireAt) == [at(hour: 18), at(hour: 10, dayOffset: 1)])
        #expect(plan([hike], cooldownDays: 1).map(\.fireAt) == [at(hour: 10, dayOffset: 1), at(hour: 10, dayOffset: 2)])
    }

    @Test("never nudges during quiet hours")
    func quietHours() {
        let late = candidate("Late show", hour: 22)
        let early = candidate("Early run", hour: 6)
        #expect(plan([late, early]).isEmpty)
        #expect(QuietHours.standard.contains(hour: 23))
        #expect(QuietHours.standard.contains(hour: 7))
        #expect(!QuietHours.standard.contains(hour: 8))
        #expect(!QuietHours.standard.contains(hour: 21))
        #expect(QuietHours(start: 1, end: 5).contains(hour: 3))
    }

    @Test("respects an edited quiet-hours window that doesn't cross midnight")
    func daytimeQuietHours() {
        let walk = candidate("Walk", hour: 18)
        let read = candidate("Read", hour: 20)
        let afternoon = QuietHours(start: 17, end: 19)
        let nudges = SuggestionNudgePlan.nudges(for: [walk, read], now: morning, calendar: utc, quietHours: afternoon, usedToday: false)
        #expect(nudges.map(\.categoryID) == [read.categoryID])
        #expect(SuggestionNudgePlan.nudges(for: [walk, read], now: morning, calendar: utc, quietHours: .off, usedToday: false).contains { $0.categoryID == walk.categoryID })
    }

    @Test("a heads-up comes an hour before the usual time, in its own words")
    func headsUp() throws {
        let coffee = candidate("Coffee", hour: 15, kind: .worse)
        let nudges = plan([coffee])
        #expect(nudges.map(\.fireAt) == [at(hour: 14)])
        let first = try #require(nudges.first)
        #expect(first.kind == .worse)
        #expect(first.identifier == SuggestionNudgePlan.identifier(day: "2024-08-30", categoryID: coffee.categoryID, kind: .worse))
        #expect(first.identifier.hasPrefix("heads-up."))
        #expect(first.title == "Often followed by feeling worse")
        #expect(first.body == "Coffee has often been followed by feeling worse later: worse or much worse in 4 of 5 later check-ins. Something to weigh if it’s coming up.")
        // Quiet hours apply to when it arrives: 08:00 is after quiet hours, but its heads-up at 07:00 isn't.
        #expect(plan([candidate("Coffee", hour: 8, kind: .worse)]).isEmpty)
        #expect(plan([candidate("Coffee", hour: 9, kind: .worse)]).map(\.fireAt) == [at(hour: 8, dayOffset: 1)])
        // Heads-ups group apart from feel-better nudges.
        #expect(SuggestionNudgePlan.threadIdentifier(for: .worse) != SuggestionNudgePlan.threadIdentifier(for: .better))
    }

    @Test("a heads-up for a midnight pattern is skipped rather than sent at the usual time")
    func midnightHeadsUp() {
        let late = candidate("Late snack", hour: 0, kind: .worse)
        #expect(plan([late], quietHours: .off).isEmpty)
        // A feel-better nudge at midnight is still planned when quiet hours allow it.
        #expect(plan([candidate("Late walk", hour: 0)], quietHours: .off).map(\.fireAt) == [at(hour: 0, dayOffset: 1)])
    }

    @Test("a heads-up for a weekend pattern only comes on weekends")
    func weekendHeadsUp() {
        // `morning` is a Friday, so the three days ahead are Friday, Saturday and Sunday.
        let brunch = candidate("Brunch", hour: 11, weekendsOnly: true, kind: .worse)
        #expect(plan([brunch]).map(\.fireAt) == [at(hour: 10, dayOffset: 1)])
    }

    @Test("prefers the strongest pattern, then the next while the first rests")
    func alternates() {
        let walk = candidate("Walk", hour: 18, strength: 3)
        let read = candidate("Read", hour: 20, strength: 1)
        let fold = candidate("Fold", hour: 19, strength: 0.5)
        #expect(plan([read, walk]).map(\.categoryID) == [walk.categoryID, read.categoryID])
        #expect(plan([read, walk, fold]).map(\.categoryID) == [walk.categoryID, read.categoryID, fold.categoryID])
    }

    @Test("identifiers carry the category and leave check-in reminders alone")
    func identifiersAndDiff() {
        let id = UUID()
        let identifier = SuggestionNudgePlan.identifier(day: "2024-08-30", categoryID: id)
        #expect(SuggestionNudgePlan.categoryID(fromIdentifier: identifier) == id)
        #expect(SuggestionNudgePlan.categoryID(fromIdentifier: CheckInReminderPlan.identifier(for: id)) == nil)

        let nudges = plan([candidate("Walk", hour: 18)], cooldownDays: 1)
        let checkIn = ScheduledReminder(identifier: CheckInReminderPlan.identifier(for: UUID()), fireAt: morning, body: "Run")
        let kept = ScheduledReminder(identifier: nudges[0].identifier, fireAt: nudges[0].fireAt, body: nudges[0].body, categoryIdentifier: SuggestionNudgePlan.categoryIdentifier)
        let edited = ScheduledReminder(identifier: nudges[1].identifier, fireAt: nudges[1].fireAt, body: "old", categoryIdentifier: SuggestionNudgePlan.categoryIdentifier)
        let stale = ScheduledReminder(identifier: SuggestionNudgePlan.identifier(day: "2024-08-29", categoryID: id), fireAt: morning, body: "")
        let changes = SuggestionNudgePlan.changes(desired: nudges, scheduled: [checkIn, kept, edited, stale])
        #expect(changes.toAdd.map(\.identifier) == [nudges[1].identifier, nudges[2].identifier])
        #expect(changes.toRemove == [stale.identifier])
        // One scheduled before nudges had buttons is replaced so it gets them.
        let withoutButtons = ScheduledReminder(identifier: nudges[0].identifier, fireAt: nudges[0].fireAt, body: nudges[0].body)
        #expect(SuggestionNudgePlan.changes(desired: [nudges[0]], scheduled: [withoutButtons]).toAdd.map(\.identifier) == [nudges[0].identifier])
    }

    @Test("a real trigger built from a nudge's wall-clock time fires at its planned instant")
    func realTriggerMatchesFireAt() throws {
        // Floating triggers use the device's zone, so plan with the device's calendar.
        let nudges = plan([candidate("Walk", hour: 18)], now: .now, calendar: .autoupdatingCurrent)
        let nudge = try #require(nudges.first)
        let trigger = UNCalendarNotificationTrigger(dateMatching: nudge.wallClock, repeats: false)
        #expect(trigger.nextTriggerDate() == nudge.fireAt)
    }

    @Test("parses a tapped nudge and ignores dismissals and reminders")
    func responses() {
        let id = UUID()
        let headsUp = SuggestionNudgePlan.identifier(day: "2024-08-30", categoryID: id, kind: .worse)
        #expect(NudgeResponse(requestIdentifier: headsUp, actionIdentifier: UNNotificationDefaultActionIdentifier)?.categoryID == id)
        #expect(NudgeResponse(requestIdentifier: headsUp, actionIdentifier: SuggestionNudgePlan.lessOftenActionIdentifier)?.kind == .worse)
        let identifier = SuggestionNudgePlan.identifier(day: "2024-08-30", categoryID: id)
        #expect(NudgeResponse(requestIdentifier: identifier, actionIdentifier: UNNotificationDefaultActionIdentifier)?.categoryID == id)
        #expect(NudgeResponse(requestIdentifier: identifier, actionIdentifier: UNNotificationDefaultActionIdentifier)?.action == .open)
        #expect(NudgeResponse(requestIdentifier: identifier, actionIdentifier: SuggestionNudgePlan.logActionIdentifier)?.action == .logIt)
        #expect(NudgeResponse(requestIdentifier: identifier, actionIdentifier: SuggestionNudgePlan.lessOftenActionIdentifier)?.action == .lessOften)
        #expect(NudgeResponse(requestIdentifier: identifier, actionIdentifier: SuggestionNudgePlan.lessOftenActionIdentifier)?.kind == .better)
        // A check-in reminder's answer button means nothing on a nudge.
        #expect(NudgeResponse(requestIdentifier: identifier, actionIdentifier: CheckInReminderPlan.snoozeActionIdentifier) == nil)
        #expect(NudgeResponse(requestIdentifier: identifier, actionIdentifier: UNNotificationDismissActionIdentifier) == nil)
        #expect(NudgeResponse(requestIdentifier: CheckInReminderPlan.identifier(for: id), actionIdentifier: UNNotificationDefaultActionIdentifier) == nil)
    }

    @Test("reminders and nudges together stay within the system's 64 pending requests")
    func sharesPendingLimit() {
        let sources = (1...80).map { ReminderSource(checkInID: UUID(), dueAt: morning.addingTimeInterval(TimeInterval($0) * 60), entryBody: "Run") }
        let reminders = CheckInReminderPlan.reminders(for: sources, now: morning)
        // The most either kind can plan: one every day.
        let nudges = plan([candidate("Walk", hour: 18), candidate("Read", hour: 20), candidate("Fold", hour: 19)])
        let headsUps = plan([candidate("Coffee", hour: 15, kind: .worse)], cooldownDays: 1)
        #expect(nudges.count == SuggestionNudgePlan.daysAhead)
        #expect(headsUps.count == SuggestionNudgePlan.daysAhead)
        #expect(reminders.count + nudges.count + headsUps.count == 64)
    }

    @Test("clears delivered nudges from earlier days, and all of them once nudges are off")
    func staleDelivered() {
        let id = UUID()
        let yesterday = SuggestionNudgePlan.identifier(day: "2024-08-29", categoryID: id)
        let today = SuggestionNudgePlan.identifier(day: "2024-08-30", categoryID: id)
        let reminder = CheckInReminderPlan.identifier(for: id)
        #expect(SuggestionNudgePlan.staleDelivered([yesterday, today, reminder], today: "2024-08-30", enabled: true) == [yesterday])
        #expect(SuggestionNudgePlan.staleDelivered([yesterday, today, reminder], today: "2024-08-30", enabled: false) == [yesterday, today])
        // Each kind clears only its own.
        let headsUp = SuggestionNudgePlan.identifier(day: "2024-08-30", categoryID: id, kind: .worse)
        #expect(SuggestionNudgePlan.staleDelivered([today, headsUp], today: "2024-08-30", enabled: false, kind: .worse) == [headsUp])
        #expect(SuggestionNudgePlan.staleDelivered([today, headsUp], today: "2024-08-30", enabled: false) == [today])
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
        var headsUpsEnabled = true
    }

    private struct Subject {
        let store: JournalStore
        let scheduler: SuggestionNudgeScheduler
        let center: FakeNudgeCenter
        let ledger: MemoryNudgeLedger
        let clock: Clock
        let walk: JournalCategory
    }

    /// Five walks at 18:00 on the previous days, each followed later by feeling better, over ten
    /// untagged logs that felt the same later, so patterns have a usual rate to beat.
    /// With `alsoRead`, a weaker pattern: reading at 21:00, better in 4 of 5 later check-ins.
    private func makeSubject(status: ReminderAuthorization = .allowed, enabled: Bool = true, alsoRead: Bool = false, headsUpLedger: MemoryNudgeLedger = MemoryNudgeLedger(), setUp: (JournalStore, Clock) throws -> Void = { _, _ in }) throws -> Subject {
        let clock = Clock()
        clock.enabled = enabled
        let container = try ForesightPersistence.makeContainer(storeURL: nil)
        let store = JournalStore(modelContext: container.mainContext, modelContainer: container, now: { clock.now })
        let walk = try addPattern("Walk", hour: 18, responses: [.aLittleBetter], store: store, clock: clock)
        try addSteadyLogs(store: store, clock: clock)
        if alsoRead { _ = try addPattern("Read", hour: 21, responses: [.aLittleBetter, .aLittleBetter, .aLittleBetter, .aLittleBetter, .same], store: store, clock: clock) }
        try setUp(store, clock)
        let center = FakeNudgeCenter(status: status)
        let ledger = MemoryNudgeLedger()
        let scheduler = SuggestionNudgeScheduler(center: center, ledger: ledger, headsUpLedger: headsUpLedger, now: { clock.now }, calendar: { clock.calendar }, isEnabled: { clock.enabled }, headsUpsEnabled: { clock.headsUpsEnabled })
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

    /// Untagged logs at noon on each of the ten previous days, each answered "Same" later.
    private func addSteadyLogs(store: JournalStore, clock: Clock) throws {
        let current = clock.now
        defer { clock.now = current }
        for day in 1...10 {
            let loggedAt = at(hour: 12, dayOffset: -day)
            clock.now = loggedAt
            let entry = try store.saveLog(body: "Ordinary day \(day)", eventAt: loggedAt, categoryIDs: [])
            let checkIn = try store.createCheckIn(for: entry, phase: .delayed, dueAt: loggedAt.addingTimeInterval(7_200))
            try store.answer(checkIn, response: .same, notSure: false, note: "", excludedFromAnalysis: false)
        }
    }

    private func fireDates(_ center: FakeNudgeCenter) async -> [Date] {
        await center.scheduledReminders().compactMap(\.fireAt).sorted()
    }

    @Test("schedules a nudge at the usual hour for a qualifying suggestion")
    func schedules() async throws {
        let subject = try makeSubject()
        await subject.scheduler.waitForPendingWork()
        #expect(await fireDates(subject.center) == [at(hour: 18)])
        let body = try #require(await subject.center.scheduledReminders().first?.body)
        #expect(body == SuggestionNudgeCopy.body(categoryName: "Walk", betterCount: 5, numericCount: 5))
    }

    @Test("drops today's nudge once the category is logged today")
    func dropsAfterLogging() async throws {
        let subject = try makeSubject()
        _ = try subject.store.saveLog(body: "Morning walk", eventAt: morning, categoryIDs: [subject.walk.id])
        await subject.scheduler.waitForPendingWork()
        #expect(await fireDates(subject.center) == [at(hour: 18, dayOffset: 1)])
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
        // Reading moves to tomorrow, and walking rests until its third day.
        #expect(await fireDates(subject.center) == [at(hour: 21, dayOffset: 1)])
    }

    @Test("the next day, a category nudged yesterday waits while another takes the day")
    func cooldownAcrossDays() async throws {
        let subject = try makeSubject(alsoRead: true)
        await subject.scheduler.waitForPendingWork()
        // Walk went out at 18:00 today; tomorrow morning the app opens again.
        subject.clock.now = at(hour: 9, dayOffset: 1)
        await subject.center.removeScheduled([SuggestionNudgePlan.identifier(day: "2024-08-30", categoryID: subject.walk.id)])
        subject.scheduler.resync()
        await subject.scheduler.waitForPendingWork()
        #expect(await fireDates(subject.center) == [at(hour: 21, dayOffset: 1), at(hour: 18, dayOffset: 3)])
        #expect(subject.ledger.fires.contains { $0.categoryID == subject.walk.id && $0.wallClock.day == 30 })
    }

    @Test("schedules a heads-up for a pattern often followed by feeling worse, on its own daily budget")
    func schedulesHeadsUp() async throws {
        let headsUpLedger = MemoryNudgeLedger()
        var coffee: JournalCategory?
        let subject = try makeSubject(headsUpLedger: headsUpLedger, setUp: { store, clock in
            coffee = try addPattern("Coffee", hour: 15, responses: [.aLittleWorse], store: store, clock: clock)
        })
        await subject.scheduler.waitForPendingWork()
        let coffeeID = try #require(coffee?.id)
        let pending = await subject.center.scheduledReminders()
        let headsUps = pending.filter { $0.identifier.hasPrefix("heads-up.") }
        // Walk's feel-better nudge still goes out every day alongside the heads-up.
        #expect(pending.filter { $0.identifier.hasPrefix("nudge.") }.compactMap(\.fireAt).sorted() == [at(hour: 18)])
        #expect(headsUps.compactMap(\.fireAt).sorted() == [at(hour: 14)])
        #expect(headsUps.allSatisfy { SuggestionNudgePlan.categoryID(fromIdentifier: $0.identifier) == coffeeID })
        #expect(headsUps.first?.body == SuggestionNudgeCopy.headsUpBody(categoryName: "Coffee", worseCount: 5, numericCount: 5))
        #expect(headsUpLedger.fires.map(\.categoryID) == [coffeeID])
        #expect(subject.ledger.fires.map(\.categoryID) == [subject.walk.id])

        // Turning heads-ups off leaves the feel-better nudges alone.
        subject.clock.headsUpsEnabled = false
        subject.scheduler.resync()
        await subject.scheduler.waitForPendingWork()
        #expect(await subject.center.identifiers().allSatisfy { $0.hasPrefix("nudge.") })
        #expect(await subject.center.identifiers().count == 1)
    }

    @Test("schedules nothing and clears nudges when notifications are off")
    func respectsPermission() async throws {
        let subject = try makeSubject()
        await subject.scheduler.waitForPendingWork()
        await subject.center.setStatus(.denied)
        subject.scheduler.resync()
        await subject.scheduler.waitForPendingWork()
        #expect(await subject.center.identifiers().isEmpty)
        #expect(subject.ledger.fires.isEmpty)
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
        #expect(await subject.center.identifiers().count == 1)
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

    @Test("a nudge that fired early after travelling east still counts toward the one a day")
    func firedAfterTravellingEastCounts() async throws {
        // Walks at 18:00 UTC are 14:00 in New York, so today's nudge is planned for 14:00 there.
        // Folding at 16:00 UTC is a weaker pattern: 12:00 in New York, 17:00 in London.
        let subject = try makeSubject(setUp: { store, clock in
            _ = try addPattern("Fold", hour: 16, responses: [.aLittleBetter, .aLittleBetter, .aLittleBetter, .aLittleBetter, .same], store: store, clock: clock)
            clock.calendar = calendar("America/New_York")
        })
        await subject.scheduler.waitForPendingWork()
        let today = SuggestionNudgePlan.identifier(day: "2024-08-30", categoryID: subject.walk.id)
        #expect(await subject.center.scheduledReminders().first { $0.identifier == today }?.fireAt == at(hour: 18))

        // In London the floating trigger fires at 14:00 local (13:00 UTC), before the instant
        // that was planned. It was swiped away, so nothing is pending or delivered for today.
        subject.clock.calendar = calendar("Europe/London")
        subject.clock.now = at(hour: 14)
        await subject.center.removeScheduled([today])
        subject.scheduler.resync()
        await subject.scheduler.waitForPendingWork()
        // Folding at 17:00 London is still ahead today, but waits for tomorrow.
        #expect(await fireDates(subject.center) == [at(hour: 16, dayOffset: 1)])
    }

    @Test("the stored ledger keeps wall-clock times with their categories, and upgrades the old formats")
    func ledgerRoundTrip() throws {
        let suite = "SuggestionNudgeTests.ledger"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let instant = Date(timeIntervalSinceReferenceDate: 800_000_000)
        defaults.set([instant.timeIntervalSinceReferenceDate], forKey: "suggestionNudgeFireDates")
        let ledger = UserDefaultsNudgeLedger(defaults: defaults)
        let upgraded = try #require(ledger.fires.first)
        #expect(Calendar.autoupdatingCurrent.date(from: upgraded.wallClock) == instant)
        #expect(upgraded.categoryID == nil)

        // Wall-clock times from before categories were kept still count toward the one a day.
        let time = DateComponents(year: 2024, month: 8, day: 30, hour: 18, minute: 0, second: 0)
        defaults.set([[2024, 8, 30, 18, 0, 0]], forKey: "suggestionNudgeWallClockTimes")
        #expect(ledger.fires == [NudgeFire(wallClock: time)])
        let headsUps = UserDefaultsNudgeLedger.headsUps(defaults: defaults)
        defaults.set([[2024, 8, 30, 14, 0, 0]], forKey: "headsUpWallClockTimes")
        #expect(headsUps.fires.map(\.wallClock.hour) == [14])

        let id = UUID()
        ledger.fires = [NudgeFire(wallClock: time, categoryID: id), NudgeFire(wallClock: time)]
        #expect(UserDefaultsNudgeLedger(defaults: defaults).fires == [NudgeFire(wallClock: time, categoryID: id), NudgeFire(wallClock: time)])
        #expect(defaults.object(forKey: "suggestionNudgeFireDates") == nil)
        #expect(defaults.object(forKey: "suggestionNudgeWallClockTimes") == nil)

        let until = Date(timeIntervalSinceReferenceDate: 800_000_000)
        headsUps.mutedUntil = [id: until]
        #expect(UserDefaultsNudgeLedger.headsUps(defaults: defaults).mutedUntil == [id: until])
        #expect(UserDefaultsNudgeLedger(defaults: defaults).mutedUntil.isEmpty)
    }

    @Test("erasing the journal clears scheduled and delivered nudges and the ledger")
    func eraseClearsNudges() async throws {
        let subject = try makeSubject()
        await subject.scheduler.waitForPendingWork()
        #expect(await subject.center.identifiers().count == 1)
        #expect(!subject.ledger.fires.isEmpty)
        subject.ledger.mutedUntil = [UUID(): at(hour: 9, dayOffset: 7)]
        let reminder = CheckInReminderPlan.identifier(for: UUID())
        await subject.center.setDelivered([SuggestionNudgePlan.identifier(day: "2024-08-30", categoryID: subject.walk.id), reminder])
        // A nudge that already went out at 08:00 today, which an ordinary resync would keep.
        subject.ledger.fires.append(NudgeFire(wallClock: DateComponents(year: 2024, month: 8, day: 30, hour: 8, minute: 0, second: 0), categoryID: subject.walk.id))
        subject.store.resetStore()
        await subject.scheduler.waitForPendingWork()
        #expect(await subject.center.identifiers().isEmpty)
        #expect(await subject.center.delivered == [reminder])
        #expect(subject.ledger.fires.isEmpty)
        #expect(subject.ledger.mutedUntil.isEmpty)
    }

    @Test("a nudge already delivered today counts toward the one a day, even without a ledger entry")
    func deliveredTodayCounts() async throws {
        let subject = try makeSubject(alsoRead: true)
        await subject.scheduler.waitForPendingWork()
        let today = SuggestionNudgePlan.identifier(day: "2024-08-30", categoryID: subject.walk.id)
        await subject.center.removeScheduled(await subject.center.identifiers())
        await subject.center.setDelivered([today])
        subject.ledger.fires = []
        subject.scheduler.resync()
        await subject.scheduler.waitForPendingWork()
        // Reading at 21:00 would otherwise go out today; walking rests after today's delivery.
        let dates = await fireDates(subject.center)
        #expect(dates == [at(hour: 21, dayOffset: 1)])
        #expect(await subject.center.delivered == [today])
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
        await delegate.handle(requestIdentifier: SuggestionNudgePlan.identifier(day: "2024-08-30", categoryID: id, kind: .worse), actionIdentifier: SuggestionNudgePlan.logActionIdentifier, body: "")
        #expect(router.destination == .newLogInCategory(id))
    }

    @Test("Less often mutes that category's nudges for two weeks, and only that kind")
    func lessOften() async throws {
        var coffee: JournalCategory?
        let subject = try makeSubject(alsoRead: true, setUp: { store, clock in
            coffee = try addPattern("Coffee", hour: 15, responses: [.aLittleWorse], store: store, clock: clock)
        })
        let coffeeID = try #require(coffee?.id)
        let router = CheckInReminderRouter(reminders: CheckInReminderScheduler(center: InertReminderNotificationCenter()))
        router.nudges = subject.scheduler
        let delegate = CheckInReminderNotificationDelegate { router }
        await subject.scheduler.waitForPendingWork()
        let walkToday = SuggestionNudgePlan.identifier(day: "2024-08-30", categoryID: subject.walk.id)
        #expect(await subject.center.identifiers().contains(walkToday))

        await delegate.handle(requestIdentifier: walkToday, actionIdentifier: SuggestionNudgePlan.lessOftenActionIdentifier, body: "")
        let walkID = subject.walk.id
        let pending = await subject.center.identifiers()
        #expect(!pending.contains { SuggestionNudgePlan.categoryID(fromIdentifier: $0) == walkID })
        // Reading takes today, and Coffee's heads-up is untouched.
        let read = try #require(subject.store.categories.first { $0.name == "Read" })
        #expect(pending.contains(SuggestionNudgePlan.identifier(day: "2024-08-30", categoryID: read.id)))
        #expect(pending.contains(SuggestionNudgePlan.identifier(day: "2024-08-30", categoryID: coffeeID, kind: .worse)))
        #expect(router.destination == nil)

        // Two weeks on, the mute has lapsed and is forgotten.
        subject.clock.now = at(hour: 9, dayOffset: 15)
        subject.scheduler.resync()
        await subject.scheduler.waitForPendingWork()
        #expect(await subject.center.identifiers().contains { SuggestionNudgePlan.categoryID(fromIdentifier: $0) == walkID })
        #expect(subject.ledger.mutedUntil.isEmpty)
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

    @Test("tapping a nudge opens that category's evidence on Patterns, and Log it opens a new log in it")
    func tapOpensEvidence() async {
        let reminders = CheckInReminderScheduler(center: InertReminderNotificationCenter())
        let router = CheckInReminderRouter(reminders: reminders)
        let id = UUID()
        await router.handle(NudgeResponse(requestIdentifier: SuggestionNudgePlan.identifier(day: "2024-08-30", categoryID: id), actionIdentifier: UNNotificationDefaultActionIdentifier)!)
        #expect(router.destination == .evidence(id))
        await router.handle(NudgeResponse(requestIdentifier: SuggestionNudgePlan.identifier(day: "2024-08-30", categoryID: id), actionIdentifier: SuggestionNudgePlan.logActionIdentifier)!)
        #expect(router.destination == .newLogInCategory(id))
    }

    @Test("nudges carry the Log it and Less often actions")
    func nudgeActions() {
        let category = SystemReminderNotificationCenter.nudgeCategory
        #expect(category.identifier == SuggestionNudgePlan.categoryIdentifier)
        #expect(category.actions.map(\.title) == ["Log it", "Less often"])
        #expect(category.actions.first?.options.contains(.foreground) == true)
        #expect(category.actions.last?.options.contains(.foreground) == false)
    }
}
