import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import Foresight

actor FakeReminderCenter: ReminderNotificationCenter {
    private(set) var status: ReminderAuthorization
    private(set) var permissionRequests = 0
    private(set) var pending: [String: CheckInReminder] = [:]
    private(set) var delivered: [String] = []
    private(set) var addCount = 0
    private(set) var badgeCount = 0
    private var grantsPermission = true

    init(status: ReminderAuthorization = .allowed) { self.status = status }

    func setStatus(_ status: ReminderAuthorization) { self.status = status }
    func setGrantsPermission(_ grants: Bool) { grantsPermission = grants }
    func setDelivered(_ identifiers: [String]) { delivered = identifiers }
    func setPending(_ reminders: [CheckInReminder]) { reminders.forEach { pending[$0.identifier] = $0 } }

    func authorization() -> ReminderAuthorization { status }
    func requestAuthorization() -> Bool {
        permissionRequests += 1
        status = grantsPermission ? .allowed : .denied
        return grantsPermission
    }
    func scheduledReminders() -> [ScheduledReminder] {
        pending.values.map { ScheduledReminder(identifier: $0.identifier, fireAt: $0.fireAt, body: $0.body, badge: $0.badge) }
    }
    func deliveredIdentifiers() -> [String] { delivered }
    func add(_ reminder: CheckInReminder) {
        addCount += 1
        pending[reminder.identifier] = reminder
    }
    func removeScheduled(_ identifiers: [String]) { identifiers.forEach { pending[$0] = nil } }
    func removeDelivered(_ identifiers: [String]) { delivered.removeAll { identifiers.contains($0) } }
    func setBadgeCount(_ count: Int) { badgeCount = count }
}

struct CheckInReminderPlanTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func source(_ id: UUID = UUID(), in seconds: TimeInterval, body: String = "Went for a run") -> ReminderSource {
        ReminderSource(checkInID: id, dueAt: now.addingTimeInterval(seconds), entryBody: body)
    }

    @Test("schedules only future check-ins, soonest first")
    func futureOnlySorted() {
        let late = source(in: 7_200)
        let soon = source(in: 600)
        let past = source(in: -60)
        let reminders = CheckInReminderPlan.reminders(for: [late, past, soon], now: now)
        #expect(reminders.map(\.checkInID) == [soon.checkInID, late.checkInID])
    }

    @Test("caps scheduled reminders at the system limit, keeping the soonest")
    func respectsLimit() {
        let sources = (1...80).map { source(in: TimeInterval($0) * 60) }
        let reminders = CheckInReminderPlan.reminders(for: sources.shuffled(), now: now)
        #expect(reminders.count == CheckInReminderPlan.pendingLimit)
        #expect(reminders.map(\.checkInID) == sources.prefix(CheckInReminderPlan.pendingLimit).map(\.checkInID))
    }

    @Test("trigger components name one instant, even in the repeated daylight-saving hour")
    func triggerComponentsAcrossDST() throws {
        // New York repeats 01:00-02:00 on Nov 3 2024: 01:30 EDT is 05:30 UTC, 01:30 EST is 06:30 UTC.
        let first = Date(timeIntervalSince1970: 1_730_611_800)
        let second = first.addingTimeInterval(3_600)
        for instant in [first, second, now] {
            let components = CheckInReminderPlan.triggerComponents(for: instant)
            let calendar = try #require(components.calendar)
            #expect(calendar.date(from: components) == instant)
        }
        #expect(CheckInReminderPlan.triggerComponents(for: first) != CheckInReminderPlan.triggerComponents(for: second))
    }

    @Test("a real trigger fires at the planned instant, including both passes of a repeated hour")
    func realTriggerMatchesFireAt() throws {
        // The next daylight-saving change in New York; around a fall-back it repeats an hour.
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let transition = try #require(newYork.nextDaylightSavingTimeTransition(after: .now))
        let base = Date(timeIntervalSinceReferenceDate: Date.now.timeIntervalSinceReferenceDate.rounded(.up))
        for instant in [base.addingTimeInterval(3_600), transition.addingTimeInterval(-1_800), transition.addingTimeInterval(1_800)] {
            let trigger = UNCalendarNotificationTrigger(dateMatching: CheckInReminderPlan.triggerComponents(for: instant), repeats: false)
            #expect(trigger.nextTriggerDate() == instant)
        }
    }

    @Test("rounds the fire date up to a whole second")
    func roundsUp() {
        let reminder = CheckInReminderPlan.reminders(for: [source(in: 90.25)], now: now)[0]
        #expect(reminder.fireAt == now.addingTimeInterval(91))
    }

    @Test("identifiers round-trip and ignore other notifications")
    func identifiers() {
        let id = UUID()
        #expect(CheckInReminderPlan.checkInID(fromIdentifier: CheckInReminderPlan.identifier(for: id)) == id)
        #expect(CheckInReminderPlan.checkInID(fromIdentifier: "daily-reflection") == nil)
        #expect(CheckInReminderPlan.checkInID(fromIdentifier: "check-in.not-a-uuid") == nil)
    }

    @Test("uses the first line of the log, truncated")
    func body() {
        #expect(CheckInReminderPlan.body(for: "  Drinks with Sam  \nStayed late") == "Drinks with Sam")
        let long = CheckInReminderPlan.body(for: String(repeating: "a", count: 120))
        #expect(long.count == 80)
        #expect(long.hasSuffix("…"))
    }

    @Test("uses generic text when log text is switched off")
    func genericBody() {
        #expect(CheckInReminderPlan.body(for: "Drinks with Sam", showsLogText: false) == CheckInReminderPlan.genericBody)
    }

    @Test("diff keeps unchanged reminders and replaces moved or edited ones")
    func diff() {
        let unchanged = CheckInReminderPlan.reminders(for: [source(in: 600)], now: now)[0]
        let moved = CheckInReminderPlan.reminders(for: [source(in: 1_200)], now: now)[0]
        let edited = CheckInReminderPlan.reminders(for: [source(in: 1_800, body: "New text")], now: now)[0]
        let obsolete = CheckInReminderPlan.identifier(for: UUID())
        let scheduled = [
            ScheduledReminder(identifier: unchanged.identifier, fireAt: unchanged.fireAt, body: unchanged.body),
            ScheduledReminder(identifier: moved.identifier, fireAt: moved.fireAt.addingTimeInterval(-3_600), body: moved.body),
            ScheduledReminder(identifier: edited.identifier, fireAt: edited.fireAt, body: "Old text"),
            ScheduledReminder(identifier: obsolete, fireAt: now.addingTimeInterval(60), body: ""),
            ScheduledReminder(identifier: "daily-reflection", fireAt: now.addingTimeInterval(60), body: "")
        ]
        let changes = CheckInReminderPlan.changes(desired: [unchanged, moved, edited], scheduled: scheduled)
        #expect(changes.toAdd.map(\.identifier) == [moved.identifier, edited.identifier])
        #expect(changes.toRemove == [obsolete])
    }

    @Test("clears delivered reminders only for check-ins that are no longer due")
    func staleDelivered() {
        let stillDue = UUID()
        let answered = UUID()
        let delivered = [CheckInReminderPlan.identifier(for: stillDue), CheckInReminderPlan.identifier(for: answered), "daily-reflection"]
        #expect(CheckInReminderPlan.staleDelivered(delivered, dueCheckInIDs: [stillDue]) == [CheckInReminderPlan.identifier(for: answered)])
    }

    @Test("each reminder carries the icon count for when it fires, overdue check-ins included")
    func badges() {
        let overdue = source(in: -600)
        let soon = source(in: 600)
        let late = source(in: 7_200)
        let reminders = CheckInReminderPlan.reminders(for: [late, overdue, soon], now: now)
        #expect(reminders.map(\.checkInID) == [soon.checkInID, late.checkInID])
        #expect(reminders.map(\.badge) == [2, 3])
        #expect(CheckInReminderPlan.dueCount([late, overdue, soon], at: now) == 1)
    }

    @Test("diff replaces a reminder whose icon count changed")
    func diffBadge() {
        let reminder = CheckInReminderPlan.reminders(for: [source(in: 600)], now: now)[0]
        let scheduled = ScheduledReminder(identifier: reminder.identifier, fireAt: reminder.fireAt, body: reminder.body, badge: 2)
        #expect(CheckInReminderPlan.changes(desired: [reminder], scheduled: [scheduled]).toAdd == [reminder])
        let current = ScheduledReminder(identifier: reminder.identifier, fireAt: reminder.fireAt, body: reminder.body, badge: reminder.badge)
        #expect(CheckInReminderPlan.changes(desired: [reminder], scheduled: [current]).toAdd.isEmpty)
    }

    @Test("parses taps and snoozes, ignoring other actions")
    func responses() {
        let id = UUID()
        let identifier = CheckInReminderPlan.identifier(for: id)
        #expect(ReminderResponse(requestIdentifier: identifier, actionIdentifier: UNNotificationDefaultActionIdentifier)?.action == .open)
        #expect(ReminderResponse(requestIdentifier: identifier, actionIdentifier: CheckInReminderPlan.snoozeActionIdentifier)?.action == .snooze)
        #expect(ReminderResponse(requestIdentifier: identifier, actionIdentifier: UNNotificationDismissActionIdentifier) == nil)
        #expect(ReminderResponse(requestIdentifier: "daily-reflection", actionIdentifier: UNNotificationDefaultActionIdentifier) == nil)
    }
}

@MainActor
struct CheckInReminderSchedulerTests {
    private let fixedNow = Date(timeIntervalSince1970: 1_725_000_000)

    private func makeStore() throws -> JournalStore {
        let container = try ForesightPersistence.makeContainer(storeURL: nil)
        return JournalStore(modelContext: container.mainContext, modelContainer: container, now: { fixedNow })
    }

    private func makeSubject(status: ReminderAuthorization = .allowed) throws -> (JournalStore, CheckInReminderScheduler, FakeReminderCenter) {
        let store = try makeStore()
        let center = FakeReminderCenter(status: status)
        let scheduler = CheckInReminderScheduler(center: center, now: { fixedNow })
        scheduler.attach(to: store)
        return (store, scheduler, center)
    }

    private func scheduledCheckIn(_ store: JournalStore, in seconds: TimeInterval = 7_200) throws -> OutcomeCheckIn {
        let entry = try store.saveLog(body: "Stayed up late", eventAt: fixedNow, categoryIDs: [])
        return try store.createCheckIn(for: entry, phase: .delayed, dueAt: fixedNow.addingTimeInterval(seconds))
    }

    @Test("schedules a reminder when a delayed check-in is created")
    func schedulesOnCreate() async throws {
        let (store, scheduler, center) = try makeSubject()
        let checkIn = try scheduledCheckIn(store)
        await scheduler.waitForPendingWork()
        let reminder = try #require(await center.pending[CheckInReminderPlan.identifier(for: checkIn.id)])
        #expect(reminder.fireAt == fixedNow.addingTimeInterval(7_200))
        #expect(reminder.body == "Stayed up late")
    }

    @Test("does not schedule immediate check-ins")
    func ignoresImmediate() async throws {
        let (store, scheduler, center) = try makeSubject()
        let entry = try store.saveLog(body: "Walked home", eventAt: fixedNow, categoryIDs: [])
        _ = try store.createCheckIn(for: entry, phase: .immediate)
        await scheduler.waitForPendingWork()
        #expect(await center.pending.isEmpty)
    }

    @Test("cancels the reminder when the check-in is answered early")
    func cancelsOnAnswer() async throws {
        let (store, scheduler, center) = try makeSubject()
        let checkIn = try scheduledCheckIn(store)
        try store.answer(checkIn, response: .same, notSure: false, note: "", excludedFromAnalysis: false)
        await scheduler.waitForPendingWork()
        #expect(await center.pending.isEmpty)
    }

    @Test("cancels the reminder when the check-in is skipped or removed")
    func cancelsOnSkipAndRemove() async throws {
        let (store, scheduler, center) = try makeSubject()
        let skipped = try scheduledCheckIn(store)
        let removed = try scheduledCheckIn(store, in: 9_000)
        try store.skip(skipped)
        try store.removeCheckIn(removed)
        await scheduler.waitForPendingWork()
        #expect(await center.pending.isEmpty)
    }

    @Test("cancels the reminder when its log is deleted")
    func cancelsOnDelete() async throws {
        let (store, scheduler, center) = try makeSubject()
        let checkIn = try scheduledCheckIn(store)
        try store.deleteEntry(try #require(checkIn.entry))
        await scheduler.waitForPendingWork()
        #expect(await center.pending.isEmpty)
    }

    @Test("moves the reminder when the check-in is rescheduled")
    func movesOnReschedule() async throws {
        let (store, scheduler, center) = try makeSubject()
        let checkIn = try scheduledCheckIn(store)
        try store.reschedule(checkIn, to: fixedNow.addingTimeInterval(86_400))
        await scheduler.waitForPendingWork()
        #expect(await center.pending.values.map(\.fireAt) == [fixedNow.addingTimeInterval(86_400)])
    }

    @Test("does not re-add reminders that are already scheduled correctly")
    func idempotent() async throws {
        let (store, scheduler, center) = try makeSubject()
        _ = try scheduledCheckIn(store)
        await scheduler.waitForPendingWork()
        scheduler.resync()
        scheduler.resync()
        await scheduler.waitForPendingWork()
        #expect(await center.addCount == 1)
    }

    @Test("schedules nothing and clears old reminders while notifications are denied")
    func deniedSchedulesNothing() async throws {
        let (store, scheduler, center) = try makeSubject()
        _ = try scheduledCheckIn(store)
        await scheduler.waitForPendingWork()
        await center.setStatus(.denied)
        scheduler.resync()
        await scheduler.waitForPendingWork()
        #expect(await center.pending.isEmpty)
        #expect(scheduler.authorization == .denied)
    }

    @Test("asks for permission only when undecided, then schedules")
    func asksOnce() async throws {
        let (store, scheduler, center) = try makeSubject(status: .notDetermined)
        _ = try scheduledCheckIn(store)
        await scheduler.waitForPendingWork()
        #expect(await center.pending.isEmpty)
        await scheduler.requestAuthorizationIfNeeded()
        await scheduler.requestAuthorizationIfNeeded()
        #expect(await center.permissionRequests == 1)
        #expect(await center.pending.count == 1)
        #expect(scheduler.authorization == .allowed)
    }

    @Test("does not ask again after the user declined")
    func respectsDecline() async throws {
        let (_, scheduler, center) = try makeSubject(status: .notDetermined)
        await center.setGrantsPermission(false)
        await scheduler.requestAuthorizationIfNeeded()
        await scheduler.requestAuthorizationIfNeeded()
        #expect(await center.permissionRequests == 1)
        #expect(scheduler.authorization == .denied)
    }

    /// The scheduler's clock and switch, which a test moves while the store stays at `fixedNow`,
    /// so check-ins can be created ahead and then fall due.
    private final class Clock {
        var now: Date
        var remindersOn = true
        init(now: Date) { self.now = now }
    }

    private func makeSubject(clock: Clock) throws -> (JournalStore, CheckInReminderScheduler, FakeReminderCenter) {
        let store = try makeStore()
        let center = FakeReminderCenter()
        let scheduler = CheckInReminderScheduler(center: center, now: { clock.now }, isEnabled: { clock.remindersOn })
        scheduler.attach(to: store)
        return (store, scheduler, center)
    }

    @Test("removes a delivered reminder once its check-in is answered")
    func clearsDelivered() async throws {
        let clock = Clock(now: fixedNow)
        let (store, scheduler, center) = try makeSubject(clock: clock)
        let checkIn = try scheduledCheckIn(store)
        let other = try scheduledCheckIn(store, in: 9_000)
        clock.now = fixedNow.addingTimeInterval(10_000)
        await center.setDelivered([CheckInReminderPlan.identifier(for: checkIn.id), CheckInReminderPlan.identifier(for: other.id)])
        try store.answer(checkIn, response: .aLittleBetter, notSure: false, note: "", excludedFromAnalysis: false)
        await scheduler.waitForPendingWork()
        #expect(await center.delivered == [CheckInReminderPlan.identifier(for: other.id)])
    }

    @Test("removes a delivered reminder once its check-in is moved to later")
    func clearsDeliveredOnReschedule() async throws {
        let clock = Clock(now: fixedNow)
        let (store, scheduler, center) = try makeSubject(clock: clock)
        let checkIn = try scheduledCheckIn(store, in: 60)
        let identifier = CheckInReminderPlan.identifier(for: checkIn.id)
        clock.now = fixedNow.addingTimeInterval(120)
        await center.setDelivered([identifier])
        scheduler.resync()
        await scheduler.waitForPendingWork()
        #expect(await center.delivered == [identifier])

        // The store's own clock is still at fixedNow, so any later time counts as the future.
        try store.reschedule(checkIn, to: fixedNow.addingTimeInterval(3_600))
        await scheduler.waitForPendingWork()
        #expect(await center.delivered.isEmpty)
        #expect(await center.pending[identifier]?.fireAt == fixedNow.addingTimeInterval(3_600))
    }

    @Test("the app icon counts due check-ins, and clears when reminders can't be shown")
    func iconBadge() async throws {
        let clock = Clock(now: fixedNow)
        let (store, scheduler, center) = try makeSubject(clock: clock)
        let first = try scheduledCheckIn(store, in: 60)
        _ = try scheduledCheckIn(store, in: 600)
        _ = try scheduledCheckIn(store, in: 7_200)
        await scheduler.waitForPendingWork()
        #expect(await center.badgeCount == 0)
        #expect(await center.pending.values.map(\.badge).compactMap { $0 }.sorted() == [1, 2, 3])

        clock.now = fixedNow.addingTimeInterval(700)
        scheduler.resync()
        await scheduler.waitForPendingWork()
        #expect(await center.badgeCount == 2)

        try store.answer(first, response: .same, notSure: false, note: "", excludedFromAnalysis: false)
        await scheduler.waitForPendingWork()
        #expect(await center.badgeCount == 1)
        #expect(await center.pending.values.compactMap(\.badge) == [2])

        clock.remindersOn = false
        scheduler.resync()
        await scheduler.waitForPendingWork()
        #expect(await center.badgeCount == 0)

        clock.remindersOn = true
        await center.setStatus(.denied)
        scheduler.resync()
        await scheduler.waitForPendingWork()
        #expect(await center.badgeCount == 0)
    }

    @Test("tapping a reminder opens that check-in")
    func tapOpensCheckIn() async throws {
        let (store, scheduler, _) = try makeSubject()
        let router = CheckInReminderRouter(reminders: scheduler, now: { fixedNow })
        router.store = store
        let checkIn = try scheduledCheckIn(store)
        await router.handle(try #require(ReminderResponse(requestIdentifier: CheckInReminderPlan.identifier(for: checkIn.id), actionIdentifier: UNNotificationDefaultActionIdentifier)))
        let entryID = try #require(checkIn.entry?.id)
        #expect(router.destination == .answer(CheckInTarget(entryID: entryID, checkInID: checkIn.id)))
    }

    @Test("tapping a reminder for an already answered check-in falls back to the Check In tab")
    func tapAnsweredCheckIn() async throws {
        let (store, scheduler, _) = try makeSubject()
        let router = CheckInReminderRouter(reminders: scheduler, now: { fixedNow })
        router.store = store
        let checkIn = try scheduledCheckIn(store)
        try store.answer(checkIn, response: .same, notSure: false, note: "", excludedFromAnalysis: false)
        await router.handle(try #require(ReminderResponse(requestIdentifier: CheckInReminderPlan.identifier(for: checkIn.id), actionIdentifier: UNNotificationDefaultActionIdentifier)))
        #expect(router.destination == .checkIns)
    }

    @Test("tapping a reminder for a deleted check-in falls back to the Check In tab")
    func tapMissingCheckIn() async throws {
        let (store, scheduler, _) = try makeSubject()
        let router = CheckInReminderRouter(reminders: scheduler, now: { fixedNow })
        router.store = store
        await router.handle(try #require(ReminderResponse(requestIdentifier: CheckInReminderPlan.identifier(for: UUID()), actionIdentifier: UNNotificationDefaultActionIdentifier)))
        #expect(router.destination == .checkIns)
    }

    @Test("snoozing moves the check-in and its reminder an hour out")
    func snooze() async throws {
        let (store, scheduler, center) = try makeSubject()
        let router = CheckInReminderRouter(reminders: scheduler, now: { fixedNow })
        router.store = store
        let checkIn = try scheduledCheckIn(store, in: 60)
        await router.handle(try #require(ReminderResponse(requestIdentifier: CheckInReminderPlan.identifier(for: checkIn.id), actionIdentifier: CheckInReminderPlan.snoozeActionIdentifier)))
        #expect(checkIn.dueAt == fixedNow.addingTimeInterval(3_600))
        #expect(await center.pending[CheckInReminderPlan.identifier(for: checkIn.id)]?.fireAt == fixedNow.addingTimeInterval(3_600))
        #expect(router.destination == nil)
    }

    @Test("snoozing an already answered check-in changes nothing")
    func snoozeAnswered() async throws {
        let (store, scheduler, _) = try makeSubject()
        let router = CheckInReminderRouter(reminders: scheduler, now: { fixedNow })
        router.store = store
        let checkIn = try scheduledCheckIn(store, in: 60)
        try store.answer(checkIn, response: .same, notSure: false, note: "", excludedFromAnalysis: false)
        await router.handle(try #require(ReminderResponse(requestIdentifier: CheckInReminderPlan.identifier(for: checkIn.id), actionIdentifier: CheckInReminderPlan.snoozeActionIdentifier)))
        #expect(checkIn.status == .answered)
        #expect(checkIn.dueAt == fixedNow.addingTimeInterval(60))
    }

    @Test("schedules check-ins that already exist when the app launches")
    func launchResync() async throws {
        let store = try makeStore()
        let checkIn = try scheduledCheckIn(store)
        let center = FakeReminderCenter()
        let scheduler = CheckInReminderScheduler(center: center, now: { fixedNow })
        scheduler.attach(to: store)
        await scheduler.waitForPendingWork()
        #expect(await center.pending.keys.sorted() == [CheckInReminderPlan.identifier(for: checkIn.id)])
    }

    @Test("a foreground resync restores reminders the system dropped")
    func foregroundResync() async throws {
        let (store, scheduler, center) = try makeSubject()
        let checkIn = try scheduledCheckIn(store)
        await scheduler.waitForPendingWork()
        await center.removeScheduled([CheckInReminderPlan.identifier(for: checkIn.id)])
        scheduler.resync()
        await scheduler.waitForPendingWork()
        #expect(await center.pending.count == 1)
    }

    @Test("sample history never schedules a real reminder")
    func ignoresFixtures() async throws {
        let (store, scheduler, center) = try makeSubject()
        try store.addDemoHistory()
        #expect(store.checkIns.contains { $0.isFixture && $0.status == .pending && ($0.dueAt ?? .distantPast) > fixedNow })
        await scheduler.waitForPendingWork()
        #expect(await center.pending.isEmpty)
    }

    @Test("the notification delegate routes taps and snoozes, and ignores other notifications")
    func delegateDispatch() async throws {
        let (store, scheduler, center) = try makeSubject()
        let router = CheckInReminderRouter(reminders: scheduler, now: { fixedNow })
        router.store = store
        let delegate = CheckInReminderNotificationDelegate { router }
        let checkIn = try scheduledCheckIn(store, in: 60)
        let identifier = CheckInReminderPlan.identifier(for: checkIn.id)

        await delegate.handle(requestIdentifier: "daily-reflection", actionIdentifier: UNNotificationDefaultActionIdentifier, body: "")
        #expect(router.destination == nil)

        await delegate.handle(requestIdentifier: identifier, actionIdentifier: UNNotificationDefaultActionIdentifier, body: "Stayed up late")
        let entryID = try #require(checkIn.entry?.id)
        #expect(router.destination == .answer(CheckInTarget(entryID: entryID, checkInID: checkIn.id)))

        router.destination = nil
        await delegate.handle(requestIdentifier: identifier, actionIdentifier: CheckInReminderPlan.snoozeActionIdentifier, body: "Stayed up late")
        #expect(checkIn.dueAt == fixedNow.addingTimeInterval(3_600))
        #expect(await center.pending[identifier]?.fireAt == fixedNow.addingTimeInterval(3_600))
        #expect(router.destination == nil)
    }

    @Test("a reminder offers every answer, best first, then the snooze")
    func answerActions() throws {
        let actions = SystemReminderNotificationCenter.checkInActions
        #expect(actions.map(\.title) == ["Much better", "A little better", "About the same", "A little worse", "Much worse", "Remind me in an hour"])
        // Answering runs in the background; none of the buttons opens the app or needs an unlock.
        #expect(actions.allSatisfy { $0.options.isEmpty })
        for value in OutcomeValue.allCases {
            let response = try #require(ReminderResponse(requestIdentifier: CheckInReminderPlan.identifier(for: UUID()), actionIdentifier: CheckInReminderPlan.answerActionIdentifier(for: value)))
            #expect(response.action == .answer(value))
        }
        #expect(ReminderResponse(requestIdentifier: CheckInReminderPlan.identifier(for: UUID()), actionIdentifier: "CHECK_IN_ANSWER_7") == nil)
        #expect(ReminderResponse(requestIdentifier: CheckInReminderPlan.identifier(for: UUID()), actionIdentifier: "CHECK_IN_ANSWER_") == nil)
    }

    @Test("answering from the notification records the check-in and clears its reminder")
    func answerFromNotification() async throws {
        let (store, scheduler, center) = try makeSubject()
        let router = CheckInReminderRouter(reminders: scheduler, now: { fixedNow })
        router.store = store
        let delegate = CheckInReminderNotificationDelegate { router }
        let checkIn = try scheduledCheckIn(store, in: 60)
        let other = try scheduledCheckIn(store, in: 600)
        let identifier = CheckInReminderPlan.identifier(for: checkIn.id)
        await scheduler.waitForPendingWork()
        await center.setDelivered([identifier])
        #expect(dueCheckInCount(store.snapshot, now: fixedNow.addingTimeInterval(700)) == 2)

        await delegate.handle(requestIdentifier: identifier, actionIdentifier: CheckInReminderPlan.answerActionIdentifier(for: .aLittleWorse), body: "Stayed up late")

        #expect(checkIn.status == .answered)
        #expect(checkIn.overall == .aLittleWorse)
        #expect(checkIn.answeredAt == fixedNow)
        #expect(checkIn.note.isEmpty)
        #expect(!checkIn.excludedFromAnalysis)
        #expect(other.status == .pending)
        #expect(router.destination == nil)
        #expect(await center.pending.keys.sorted() == [CheckInReminderPlan.identifier(for: other.id)])
        #expect(await center.delivered.isEmpty)
        // The Check In tab's badge counts from the store, so it drops with the answer.
        #expect(dueCheckInCount(store.snapshot, now: fixedNow.addingTimeInterval(700)) == 1)
    }

    @Test("answering from a notification doesn't overwrite an answer given first in the app")
    func answerAfterAnswered() async throws {
        let (store, scheduler, _) = try makeSubject()
        let router = CheckInReminderRouter(reminders: scheduler, now: { fixedNow })
        router.store = store
        let checkIn = try scheduledCheckIn(store, in: 60)
        try store.answer(checkIn, response: .muchBetter, notSure: false, note: "Slept well", excludedFromAnalysis: false)
        let skipped = try scheduledCheckIn(store, in: 120)
        try store.skip(skipped)
        for target in [checkIn, skipped] {
            await router.handle(try #require(ReminderResponse(requestIdentifier: CheckInReminderPlan.identifier(for: target.id), actionIdentifier: CheckInReminderPlan.answerActionIdentifier(for: .muchWorse))))
        }
        #expect(checkIn.overall == .muchBetter)
        #expect(checkIn.note == "Slept well")
        #expect(skipped.status == .skipped)
        #expect(skipped.overall == nil)
    }

    @Test("an answer that can't be saved asks again in an hour")
    func answerWithoutStore() async throws {
        let center = FakeReminderCenter()
        let scheduler = CheckInReminderScheduler(center: center, now: { fixedNow })
        let router = CheckInReminderRouter(reminders: scheduler, now: { fixedNow })
        let id = UUID()
        await router.handle(try #require(ReminderResponse(requestIdentifier: CheckInReminderPlan.identifier(for: id), actionIdentifier: CheckInReminderPlan.answerActionIdentifier(for: .same), body: "Stayed up late")))
        let reminder = try #require(await center.pending[CheckInReminderPlan.identifier(for: id)])
        #expect(reminder.fireAt == fixedNow.addingTimeInterval(3_600))
        #expect(reminder.body == "Stayed up late")
    }

    @Test("snoozing while the journal can't be read re-posts the reminder from its own text")
    func snoozeWithoutStore() async throws {
        let center = FakeReminderCenter()
        let scheduler = CheckInReminderScheduler(center: center, now: { fixedNow })
        let router = CheckInReminderRouter(reminders: scheduler, now: { fixedNow })
        let id = UUID()
        await router.handle(try #require(ReminderResponse(requestIdentifier: CheckInReminderPlan.identifier(for: id), actionIdentifier: CheckInReminderPlan.snoozeActionIdentifier, body: "Stayed up late")))
        let reminder = try #require(await center.pending[CheckInReminderPlan.identifier(for: id)])
        #expect(reminder.fireAt == fixedNow.addingTimeInterval(3_600))
        #expect(reminder.body == "Stayed up late")
    }
}
