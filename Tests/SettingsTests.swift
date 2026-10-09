import Foundation
import SwiftData
import Testing
@testable import Foresight

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

/// 2024-08-30 at the given UTC time.
private func utcDate(hour: Int, minute: Int = 0, dayOffset: Int = 0) -> Date {
    let calendar = utcCalendar()
    let day = calendar.date(from: DateComponents(year: 2024, month: 8, day: 30 + dayOffset))!
    return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
}

struct QuietHoursTests {
    private let calendar = utcCalendar()

    @Test("defers a time inside overnight quiet hours to when they end")
    func defersOvernight() {
        #expect(QuietHours.standard.deferring(utcDate(hour: 23, minute: 30), calendar: calendar) == utcDate(hour: 8, dayOffset: 1))
        #expect(QuietHours.standard.deferring(utcDate(hour: 6, minute: 15), calendar: calendar) == utcDate(hour: 8))
    }

    @Test("leaves a time outside quiet hours alone")
    func keepsDaytime() {
        #expect(QuietHours.standard.deferring(utcDate(hour: 8), calendar: calendar) == utcDate(hour: 8))
        #expect(QuietHours.standard.deferring(utcDate(hour: 21, minute: 59), calendar: calendar) == utcDate(hour: 21, minute: 59))
    }

    @Test("handles a window that doesn't cross midnight, and the off setting")
    func daytimeWindowAndOff() {
        let afternoon = QuietHours(start: 13, end: 15)
        #expect(afternoon.deferring(utcDate(hour: 14), calendar: calendar) == utcDate(hour: 15))
        #expect(afternoon.deferring(utcDate(hour: 16), calendar: calendar) == utcDate(hour: 16))
        #expect((0..<24).allSatisfy { !QuietHours.off.contains(hour: $0) })
        #expect(QuietHours.off.deferring(utcDate(hour: 3), calendar: calendar) == utcDate(hour: 3))
    }
}

struct QuietHoursReminderPlanTests {
    private let calendar = utcCalendar()

    @Test("a check-in due in quiet hours is reminded about when they end")
    func defersReminders() {
        let evening = ReminderSource(checkInID: UUID(), dueAt: utcDate(hour: 21), entryBody: "Dinner out")
        let late = ReminderSource(checkInID: UUID(), dueAt: utcDate(hour: 23), entryBody: "Late show")
        let reminders = CheckInReminderPlan.reminders(for: [late, evening], now: utcDate(hour: 12), quietHours: .standard, calendar: calendar)
        #expect(reminders.map(\.checkInID) == [evening.checkInID, late.checkInID])
        #expect(reminders.map(\.fireAt) == [utcDate(hour: 21), utcDate(hour: 8, dayOffset: 1)])
    }

    @Test("a check-in that fell due overnight is still reminded about in the morning")
    func pastDueInQuietHours() {
        let source = ReminderSource(checkInID: UUID(), dueAt: utcDate(hour: 23), entryBody: "Late show")
        let reminders = CheckInReminderPlan.reminders(for: [source], now: utcDate(hour: 2, dayOffset: 1), quietHours: .standard, calendar: calendar)
        #expect(reminders.map(\.fireAt) == [utcDate(hour: 8, dayOffset: 1)])
    }
}

@MainActor
struct ReminderPreferenceTests {
    private final class Settings {
        var enabled = true
        var quietHours = QuietHours.off
    }

    /// 2024-08-30 12:00 UTC.
    private let noon = utcDate(hour: 12)

    private func makeSubject(status: ReminderAuthorization = .allowed, settings: Settings) throws -> (JournalStore, CheckInReminderScheduler, FakeReminderCenter) {
        let container = try ForesightPersistence.makeContainer(storeURL: nil)
        let now = noon
        let store = JournalStore(modelContext: container.mainContext, modelContainer: container, now: { now })
        let center = FakeReminderCenter(status: status)
        let scheduler = CheckInReminderScheduler(center: center, now: { now }, calendar: { utcCalendar() }, isEnabled: { settings.enabled }, quietHours: { settings.quietHours })
        scheduler.attach(to: store)
        return (store, scheduler, center)
    }

    private func schedule(_ store: JournalStore, at dueAt: Date) throws -> OutcomeCheckIn {
        let entry = try store.saveLog(body: "Stayed up late", eventAt: noon, categoryIDs: [])
        return try store.createCheckIn(for: entry, phase: .delayed, dueAt: dueAt)
    }

    @Test("turning reminders off removes scheduled ones, and turning them on restores them")
    func toggles() async throws {
        let settings = Settings()
        let (store, scheduler, center) = try makeSubject(settings: settings)
        let checkIn = try schedule(store, at: utcDate(hour: 15))
        await scheduler.waitForPendingWork()
        #expect(await center.pending.count == 1)

        settings.enabled = false
        scheduler.resync()
        await scheduler.waitForPendingWork()
        #expect(await center.pending.isEmpty)

        settings.enabled = true
        scheduler.resync()
        await scheduler.waitForPendingWork()
        #expect(await center.pending[CheckInReminderPlan.identifier(for: checkIn.id)]?.fireAt == utcDate(hour: 15))
    }

    @Test("changing quiet hours moves a scheduled reminder")
    func followsQuietHours() async throws {
        let settings = Settings()
        let (store, scheduler, center) = try makeSubject(settings: settings)
        let checkIn = try schedule(store, at: utcDate(hour: 23))
        await scheduler.waitForPendingWork()
        let identifier = CheckInReminderPlan.identifier(for: checkIn.id)
        #expect(await center.pending[identifier]?.fireAt == utcDate(hour: 23))

        settings.quietHours = .standard
        scheduler.resync()
        await scheduler.waitForPendingWork()
        #expect(await center.pending[identifier]?.fireAt == utcDate(hour: 8, dayOffset: 1))
    }

    @Test("with reminders off, scheduling a check-in doesn't ask for permission, but Settings can")
    func permissionWhenOff() async throws {
        let settings = Settings()
        settings.enabled = false
        let (_, scheduler, center) = try makeSubject(status: .notDetermined, settings: settings)
        await scheduler.requestAuthorizationIfNeeded()
        #expect(await center.permissionRequests == 0)
        await scheduler.requestAuthorizationIfNeeded(evenWhenRemindersAreOff: true)
        #expect(await center.permissionRequests == 1)
    }

    @Test("a snooze without the journal respects quiet hours")
    func snoozeRespectsQuietHours() async throws {
        let settings = Settings()
        settings.quietHours = QuietHours(start: 12, end: 14)
        let (_, scheduler, center) = try makeSubject(settings: settings)
        let id = UUID()
        await scheduler.snoozeWithoutStore(checkInID: id, body: "Stayed up late")
        #expect(await center.pending[CheckInReminderPlan.identifier(for: id)]?.fireAt == utcDate(hour: 14))
    }
}

struct NotificationPreferencesTests {
    private func makePreferences() throws -> (NotificationPreferences, UserDefaults) {
        let suite = "NotificationPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (NotificationPreferences(defaults: defaults), defaults)
    }

    @Test("everything is on by default, with quiet hours from 10pm to 8am")
    func defaults() throws {
        let (preferences, _) = try makePreferences()
        #expect(preferences.remindersEnabled)
        #expect(preferences.nudgesEnabled)
        #expect(preferences.quietHours == .standard)
    }

    @Test("stores each choice, and quiet hours turned off never hold anything back")
    func roundTrip() throws {
        let (preferences, defaults) = try makePreferences()
        preferences.remindersEnabled = false
        preferences.nudgesEnabled = false
        preferences.quietHoursStart = 23
        preferences.quietHoursEnd = 7
        let reread = NotificationPreferences(defaults: defaults)
        #expect(!reread.remindersEnabled)
        #expect(!reread.nudgesEnabled)
        #expect(reread.quietHours == QuietHours(start: 23, end: 7))
        reread.quietHoursEnabled = false
        #expect(preferences.quietHours == .off)
    }

    @Test("keeps the key nudges already used, and ignores an hour out of range")
    func compatibility() throws {
        let (preferences, defaults) = try makePreferences()
        defaults.set(false, forKey: "suggestionNudgesEnabled")
        defaults.set(31, forKey: NotificationPreferences.quietHoursStartKey)
        #expect(!preferences.nudgesEnabled)
        #expect(preferences.quietHoursStart == QuietHours.standard.start)
    }
}

@MainActor
struct JournalExportTests {
    private let fixedNow = Date(timeIntervalSince1970: 1_725_000_000)

    private func makeStore() throws -> JournalStore {
        let container = try ForesightPersistence.makeContainer(storeURL: nil)
        let now = fixedNow
        return JournalStore(modelContext: container.mainContext, modelContainer: container, now: { now })
    }

    @Test("exports logs with their categories and check-ins, and leaves out sample history")
    func exportsJournal() throws {
        let store = try makeStore()
        let workout = try #require(store.categories.first { $0.name == "Workout" })
        let entry = try store.saveLog(body: "Evening run", eventAt: fixedNow.addingTimeInterval(-3_600), categoryIDs: [workout.id])
        let immediate = try store.createCheckIn(for: entry, phase: .immediate)
        try store.answer(immediate, response: .aLittleBetter, notSure: false, note: "Lighter", excludedFromAnalysis: false)
        _ = try store.createCheckIn(for: entry, phase: .delayed, dueAt: fixedNow.addingTimeInterval(7_200))
        let sample = try store.saveLog(body: "Sample", eventAt: fixedNow, categoryIDs: [])
        sample.isFixture = true

        let export = JournalExport(snapshot: store.snapshot, exportedAt: fixedNow)
        #expect(export.format == JournalExport.format)
        #expect(export.entries.map(\.body) == ["Evening run"])
        #expect(export.entries[0].categories == ["Workout"])
        #expect(export.checkInCount == 2)
        let answered = try #require(export.entries[0].checkIns.first { $0.phase == "immediate" })
        #expect(answered.response == 1)
        #expect(answered.responseLabel == "A little better")
        #expect(answered.note == "Lighter")
        #expect(export.entries[0].checkIns.contains { $0.phase == "delayed" && $0.status == "pending" && $0.dueAt == fixedNow.addingTimeInterval(7_200) })
        #expect(Set(export.categories.map(\.name)) == Set(DefaultCategories.names))
    }

    @Test("the JSON file reads back as the same export")
    func jsonRoundTrip() throws {
        let store = try makeStore()
        _ = try store.saveLog(body: "Line one\nLine \"two\"", eventAt: fixedNow, categoryIDs: [])
        let export = JournalExport(snapshot: store.snapshot, exportedAt: fixedNow)
        let data = try export.jsonData()
        #expect(try JournalExport.decode(data) == export)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"exportedAt\" : \"2024-08-30T06:40:00Z\""))
    }

    @Test("erasing the journal leaves only the default categories")
    func eraseLeavesDefaults() throws {
        let store = try makeStore()
        let entry = try store.saveLog(body: "Evening run", eventAt: fixedNow, categoryIDs: [])
        _ = try store.createCheckIn(for: entry, phase: .delayed, dueAt: fixedNow.addingTimeInterval(7_200))
        _ = try store.addCategory(named: "Reading")
        store.resetStore()
        #expect(store.entries.isEmpty)
        #expect(store.checkIns.isEmpty)
        #expect(Set(store.categories.map(\.name)) == Set(DefaultCategories.names))
        #expect(JournalExport(snapshot: store.snapshot, exportedAt: fixedNow).entries.isEmpty)
    }
}
