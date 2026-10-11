import Foundation
import SwiftData
import Testing
@testable import Foresight

@MainActor
struct SharedJournalStoreTests {
    private func temporaryDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SharedJournalTests-\(UUID().uuidString)/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("without an App Group the journal stays in the app's own directory")
    func noGroup() throws {
        let appDirectory = try temporaryDirectory("app")
        #expect(SharedJournal.resolveStoreURL(groupDirectory: nil, appDirectory: appDirectory) == appDirectory.appending(path: "Foresight.store"))
    }

    @Test("a fresh install opens its journal in the group container")
    func freshInstall() throws {
        let appDirectory = try temporaryDirectory("app")
        let groupDirectory = try temporaryDirectory("group")
        let url = SharedJournal.resolveStoreURL(groupDirectory: groupDirectory, appDirectory: appDirectory)
        #expect(url == groupDirectory.appending(path: "Foresight.store"))
        let container = try ForesightPersistence.makeContainer(storeURL: url)
        let store = JournalStore(modelContext: container.mainContext, modelContainer: container)
        #expect(store.initializationError == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a journal from an earlier build moves into the group container and still opens")
    func movesEarlierJournal() throws {
        let appDirectory = try temporaryDirectory("app")
        let groupDirectory = try temporaryDirectory("group")
        let oldURL = appDirectory.appending(path: "Foresight.store")
        do {
            let container = try ForesightPersistence.makeContainer(storeURL: oldURL)
            let store = JournalStore(modelContext: container.mainContext, modelContainer: container)
            let entry = try store.saveLog(body: "Walked to work", eventAt: .now, categoryIDs: [])
            _ = try store.createCheckIn(for: entry, phase: .delayed, dueAt: .now.addingTimeInterval(3_600))
        }

        let url = SharedJournal.resolveStoreURL(groupDirectory: groupDirectory, appDirectory: appDirectory)

        #expect(url == groupDirectory.appending(path: "Foresight.store"))
        for suffix in SharedJournal.storeFileSuffixes {
            #expect(!FileManager.default.fileExists(atPath: oldURL.path + suffix))
        }
        let container = try ForesightPersistence.makeContainer(storeURL: url)
        let store = JournalStore(modelContext: container.mainContext, modelContainer: container)
        #expect(store.initializationError == nil)
        #expect(store.entries.map(\.body) == ["Walked to work"])
        #expect(store.checkIns.count == 1)

        // Run again on the next launch: nothing more to move, same store.
        #expect(SharedJournal.resolveStoreURL(groupDirectory: groupDirectory, appDirectory: appDirectory) == url)
    }

    @Test("a journal already in the group is never replaced by an older one")
    func keepsGroupJournal() throws {
        let appDirectory = try temporaryDirectory("app")
        let groupDirectory = try temporaryDirectory("group")
        let groupURL = groupDirectory.appending(path: "Foresight.store")
        let oldURL = appDirectory.appending(path: "Foresight.store")
        try Data("group".utf8).write(to: groupURL)
        try Data("old".utf8).write(to: oldURL)
        #expect(SharedJournal.resolveStoreURL(groupDirectory: groupDirectory, appDirectory: appDirectory) == groupURL)
        #expect(try Data(contentsOf: groupURL) == Data("group".utf8))
        #expect(FileManager.default.fileExists(atPath: oldURL.path))
    }

    @Test("if the move fails part way, the app keeps the old journal where it was")
    func failedMoveKeepsOldJournal() throws {
        let appDirectory = try temporaryDirectory("app")
        let oldURL = appDirectory.appending(path: "Foresight.store")
        try Data("old".utf8).write(to: oldURL)
        // A file where the group directory should be makes creating it fail.
        let blocked = try temporaryDirectory("blocked").appending(path: "file")
        try Data().write(to: blocked)
        let url = SharedJournal.resolveStoreURL(groupDirectory: blocked.appending(path: "Application Support"), appDirectory: appDirectory)
        #expect(url == oldURL)
        #expect(try Data(contentsOf: oldURL) == Data("old".utf8))
    }

    @Test("the widget opens the journal read-only")
    func readOnlyContainer() throws {
        let url = try temporaryDirectory("group").appending(path: "Foresight.store")
        do {
            let container = try ForesightPersistence.makeContainer(storeURL: url)
            let store = JournalStore(modelContext: container.mainContext, modelContainer: container)
            let entry = try store.saveLog(body: "Late coffee\nThen couldn't sleep", eventAt: .now, categoryIDs: [])
            _ = try store.createCheckIn(for: entry, phase: .delayed, dueAt: .now.addingTimeInterval(60))
        }
        let container = try ForesightPersistence.makeContainer(storeURL: url, allowsSave: false)
        let items = CheckInWidgetPlan.items(from: try ModelContext(container).fetch(FetchDescriptor<OutcomeCheckIn>()))
        #expect(items.map(\.text) == ["Late coffee"])
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
