import Foundation
import SwiftData
import Testing
@testable import Foresight

@MainActor
struct SharedJournalStoreTests {
    private struct OpenFailed: Error { }

    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("SharedJournalTests-\(UUID().uuidString)", isDirectory: true)
    private var appDirectory: URL { root.appending(path: "app", directoryHint: .isDirectory) }
    private var groupDirectory: URL { root.appending(path: "group", directoryHint: .isDirectory) }
    private var appStore: URL { appDirectory.appending(path: "Foresight.store") }
    private var groupStore: URL { groupDirectory.appending(path: "Foresight.store") }
    private let defaults = UserDefaults(suiteName: "SharedJournalTests-\(UUID().uuidString)")!

    /// Opens a real journal, as the app does.
    private func openJournal(_ url: URL) throws -> (ModelContainer, JournalStore) {
        let container = try ForesightPersistence.makeContainer(storeURL: url)
        let store = JournalStore(modelContext: container.mainContext, modelContainer: container)
        if store.initializationError != nil { throw OpenFailed() }
        return (container, store)
    }

    private func writeJournal(at url: URL, body: String) throws {
        let (_, store) = try openJournal(url)
        let entry = try store.saveLog(body: body, eventAt: .now, categoryIDs: [])
        _ = try store.createCheckIn(for: entry, phase: .delayed, dueAt: .now.addingTimeInterval(3_600))
    }

    private func exists(_ url: URL, _ suffix: String = "") -> Bool { FileManager.default.fileExists(atPath: url.path + suffix) }

    @Test("without an App Group the journal stays in the app's own directory")
    func noGroup() throws {
        let (_, store) = try SharedJournal.open(groupDirectory: nil, appDirectory: appDirectory, defaults: defaults, using: openJournal)
        #expect(store.initializationError == nil)
        #expect(exists(appStore))
        #expect(!defaults.bool(forKey: SharedJournal.inGroupKey))
    }

    @Test("a fresh install opens its journal in the group container")
    func freshInstall() throws {
        let (_, store) = try SharedJournal.open(groupDirectory: groupDirectory, appDirectory: appDirectory, defaults: defaults, using: openJournal)
        #expect(store.initializationError == nil)
        #expect(exists(groupStore))
        #expect(!exists(appStore))
        #expect(defaults.bool(forKey: SharedJournal.inGroupKey))
    }

    @Test("a journal from an earlier build moves into the group container and still opens")
    func movesEarlierJournal() throws {
        try writeJournal(at: appStore, body: "Walked to work")
        let (_, store) = try SharedJournal.open(groupDirectory: groupDirectory, appDirectory: appDirectory, defaults: defaults, using: openJournal)
        #expect(store.entries.map(\.body) == ["Walked to work"])
        #expect(store.checkIns.count == 1)
        for suffix in SharedJournal.storeFileSuffixes + [".partial"] {
            #expect(!exists(appStore, suffix))
        }
        #expect(!exists(groupStore, ".partial"))
        #expect(defaults.bool(forKey: SharedJournal.inGroupKey))

        // The next launch opens the same journal from the group.
        let (_, reopened) = try SharedJournal.open(groupDirectory: groupDirectory, appDirectory: appDirectory, defaults: defaults, using: openJournal)
        #expect(reopened.entries.map(\.body) == ["Walked to work"])
    }

    @Test("if the group copy won't open, the old journal opens instead and is kept")
    func groupOpenFails() throws {
        try writeJournal(at: appStore, body: "Walked to work")
        var tried: [URL] = []
        let (_, store) = try SharedJournal.open(groupDirectory: groupDirectory, appDirectory: appDirectory, defaults: defaults) { url in
            tried.append(url)
            if url == groupStore { throw OpenFailed() }
            return try openJournal(url)
        }
        #expect(tried == [groupStore, appStore])
        #expect(store.entries.map(\.body) == ["Walked to work"])
        #expect(exists(appStore))
        #expect(!exists(groupStore))
        #expect(!defaults.bool(forKey: SharedJournal.inGroupKey))
    }

    @Test("a copy interrupted part way is replaced from the old journal on the next launch")
    func interruptedCopy() throws {
        try writeJournal(at: appStore, body: "Walked to work")
        // What a launch that died mid-copy could leave: a torn main file, a stray partial, no log.
        try FileManager.default.createDirectory(at: groupDirectory, withIntermediateDirectories: true)
        try Data("torn".utf8).write(to: groupStore)
        try Data("torn".utf8).write(to: URL(fileURLWithPath: groupStore.path + ".partial"))
        let (_, store) = try SharedJournal.open(groupDirectory: groupDirectory, appDirectory: appDirectory, defaults: defaults, using: openJournal)
        #expect(store.entries.map(\.body) == ["Walked to work"])
        #expect(!exists(appStore))
    }

    @Test("once the journal is in the group, an old app-directory copy never replaces it")
    func groupJournalWins() throws {
        try writeJournal(at: groupStore, body: "In the group")
        defaults.set(true, forKey: SharedJournal.inGroupKey)
        // Left by a launch that ended after the group opened but before cleaning up.
        try writeJournal(at: appStore, body: "Stale copy")
        let (_, store) = try SharedJournal.open(groupDirectory: groupDirectory, appDirectory: appDirectory, defaults: defaults, using: openJournal)
        #expect(store.entries.map(\.body) == ["In the group"])
        #expect(!exists(appStore))
    }

    @Test("a build that loses the group shows an error instead of an empty journal")
    func groupUnreachable() throws {
        defaults.set(true, forKey: SharedJournal.inGroupKey)
        #expect(throws: SharedJournalError.groupUnreachable) {
            try SharedJournal.open(groupDirectory: nil, appDirectory: appDirectory, defaults: defaults, using: openJournal)
        }
        #expect(!exists(appStore))
    }

    @Test("the widget opens the journal read-only")
    func readOnlyContainer() throws {
        try writeJournal(at: groupStore, body: "Late coffee\nThen couldn't sleep")
        let container = try ForesightPersistence.makeContainer(storeURL: groupStore, allowsSave: false)
        let context = ModelContext(container)
        let items = CheckInWidgetPlan.items(from: try context.fetch(FetchDescriptor<OutcomeCheckIn>()))
        #expect(items.map(\.text) == ["Late coffee"])
        context.insert(JournalCategory(name: "Widget"))
        #expect(throws: (any Error).self) { try context.save() }
    }
}

struct ForesightLinkTests {
    @Test("links round-trip through their URLs")
    func roundTrip() {
        let id = UUID()
        for link in [ForesightLink.newLog, .checkIns, .checkIn(id)] {
            #expect(ForesightLink(url: link.url) == link)
        }
        #expect(ForesightLink.checkIn(id).url.absoluteString == "foresight://check-in/\(id.uuidString)")
    }

    @Test("other URLs are ignored")
    func rejects() throws {
        for string in ["https://check-in", "foresight://patterns", "foresight://check-in/not-an-id", "foresight://log/extra", "foresight://"] {
            #expect(ForesightLink(url: try #require(URL(string: string))) == nil)
        }
    }
}

struct CheckInWidgetPlanTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func item(in seconds: TimeInterval, _ text: String = "Went for a run") -> CheckInWidgetItem {
        CheckInWidgetItem(checkInID: UUID(), dueAt: now.addingTimeInterval(seconds), text: text)
    }

    @Test("counts what's due, oldest first, and when the next one falls due")
    func state() {
        let recent = item(in: -60, "Recent")
        let old = item(in: -7_200, "Old")
        let soon = item(in: 600)
        let later = item(in: 7_200)
        let state = CheckInWidgetPlan.state(for: [later, recent, soon, old], at: now)
        #expect(state.due.map(\.text) == ["Old", "Recent"])
        #expect(state.nextDueAt == soon.dueAt)
        #expect(CheckInWidgetPlan.state(for: [], at: now) == .empty)
    }

    @Test("a timeline entry for now and for each moment a check-in falls due")
    func entryDates() {
        let items = [item(in: 600), item(in: -60), item(in: 600), item(in: 7_200)]
        #expect(CheckInWidgetPlan.entryDates(for: items, now: now) == [now, now.addingTimeInterval(600), now.addingTimeInterval(7_200)])
        let many = (1...40).map { item(in: TimeInterval($0) * 60) }
        #expect(CheckInWidgetPlan.entryDates(for: many, now: now).count == CheckInWidgetPlan.entryLimit)
    }

    @Test("the widget counts the same check-ins as the Check In badge")
    @MainActor
    func matchesBadge() throws {
        let container = try ForesightPersistence.makeContainer(storeURL: nil)
        let store = JournalStore(modelContext: container.mainContext, modelContainer: container, now: { now })
        let first = try store.saveLog(body: "Stayed up late", eventAt: now, categoryIDs: [])
        let due = try store.createCheckIn(for: first, phase: .delayed, dueAt: now.addingTimeInterval(60))
        _ = try store.createCheckIn(for: first, phase: .immediate)
        let second = try store.saveLog(body: "Skipped lunch", eventAt: now, categoryIDs: [])
        let answered = try store.createCheckIn(for: second, phase: .delayed, dueAt: now.addingTimeInterval(120))
        try store.answer(answered, response: .same, notSure: false, note: "", excludedFromAnalysis: false)
        let third = try store.saveLog(body: "Long walk", eventAt: now, categoryIDs: [])
        _ = try store.createCheckIn(for: third, phase: .delayed, dueAt: now.addingTimeInterval(3_600))

        let later = now.addingTimeInterval(600)
        let state = CheckInWidgetPlan.state(for: CheckInWidgetPlan.items(from: store.checkIns), at: later)
        #expect(state.due.map(\.checkInID) == [due.id])
        #expect(state.due.count == dueCheckInCount(store.snapshot, now: later))
        #expect(state.nextDueAt == nextCheckInDueDate(store.snapshot, after: later))
    }
}

@MainActor
struct WidgetLinkRoutingTests {
    @Test("widget links open a new log, the Check In tab, or a pending check-in's answer sheet")
    func routes() throws {
        let fixedNow = Date(timeIntervalSince1970: 1_725_000_000)
        let container = try ForesightPersistence.makeContainer(storeURL: nil)
        let store = JournalStore(modelContext: container.mainContext, modelContainer: container, now: { fixedNow })
        let router = CheckInReminderRouter(reminders: CheckInReminderScheduler(center: InertReminderNotificationCenter()), now: { fixedNow })
        router.store = store
        let entry = try store.saveLog(body: "Stayed up late", eventAt: fixedNow, categoryIDs: [])
        let checkIn = try store.createCheckIn(for: entry, phase: .delayed, dueAt: fixedNow.addingTimeInterval(60))

        router.open(.newLog)
        #expect(router.destination == .newLog)
        router.open(.checkIns)
        #expect(router.destination == .checkIns)
        router.open(.checkIn(checkIn.id))
        #expect(router.destination == .answer(CheckInTarget(entryID: entry.id, checkInID: checkIn.id)))

        try store.skip(checkIn)
        router.open(.checkIn(checkIn.id))
        #expect(router.destination == .checkIns)
        router.open(.checkIn(UUID()))
        #expect(router.destination == .checkIns)
    }
}
