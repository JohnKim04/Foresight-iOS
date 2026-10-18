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
        defaults.set(true, forKey: SharedJournal.copyingKey)
        let (_, store) = try SharedJournal.open(groupDirectory: groupDirectory, appDirectory: appDirectory, defaults: defaults, using: openJournal)
        #expect(store.entries.map(\.body) == ["Walked to work"])
        #expect(!exists(appStore))
        #expect(backups().isEmpty)
        #expect(!defaults.bool(forKey: SharedJournal.copyingKey))
    }

    private func backups() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: groupDirectory.path)) ?? []
        return names.filter { $0.hasPrefix(SharedJournal.backupPrefix) && $0.hasSuffix(".store") }.sorted().map { groupDirectory.appending(path: $0) }
    }

    @Test("a group journal left behind by a reset is backed up, not overwritten, when the group comes back")
    func resetJournalIsBackedUp() throws {
        // The journal moved into the group, then a build without App Groups was reset and started
        // a new journal in the app's directory. Now the group is reachable again.
        try writeJournal(at: groupStore, body: "Months of logs")
        try writeJournal(at: appStore, body: "After the reset")
        let (_, store) = try SharedJournal.open(groupDirectory: groupDirectory, appDirectory: appDirectory, defaults: defaults, using: openJournal)
        #expect(store.entries.map(\.body) == ["After the reset"])
        #expect(!exists(appStore))
        #expect(defaults.bool(forKey: SharedJournal.inGroupKey))

        let backup = try #require(backups().first)
        #expect(backups().count == 1)
        let (_, saved) = try openJournal(backup)
        #expect(saved.entries.map(\.body) == ["Months of logs"])
    }

    @Test("backups taken in the same second get their own names")
    func backupNames() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.createDirectory(at: groupDirectory, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: groupStore)
        let first = try SharedJournal.backUpStore(at: groupStore, date: date)
        try Data("two".utf8).write(to: groupStore)
        try Data("log".utf8).write(to: URL(fileURLWithPath: groupStore.path + "-wal"))
        let second = try SharedJournal.backUpStore(at: groupStore, date: date)
        #expect(first != second)
        #expect(try String(contentsOf: first, encoding: .utf8) == "one")
        #expect(try String(contentsOf: second, encoding: .utf8) == "two")
        #expect(exists(second, "-wal"))
        #expect(!exists(groupStore))
        #expect(!exists(groupStore, "-wal"))
    }

    @Test("only the newest backups are kept")
    func prunesOldBackups() throws {
        try FileManager.default.createDirectory(at: groupDirectory, withIntermediateDirectories: true)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var made: [URL] = []
        // Two in the same second, so the numbered name has to count as the newer one.
        for (index, offset) in [0, 3_600, 7_200, 7_200, 10_800].enumerated() {
            try Data("journal \(index)".utf8).write(to: groupStore)
            try Data("log".utf8).write(to: URL(fileURLWithPath: groupStore.path + "-wal"))
            made.append(try SharedJournal.backUpStore(at: groupStore, date: start.addingTimeInterval(TimeInterval(offset))))
        }
        #expect(Set(backups()) == Set(made.suffix(SharedJournal.backupLimit)))
        #expect(!exists(made[0], "-wal"))
        #expect(!exists(made[1]))
        #expect(exists(made[2], "-wal"))
        #expect(try String(contentsOf: made[4], encoding: .utf8) == "journal 4")
    }

    @Test("a new backup is kept even when a clock that moved backward gives it the oldest name")
    func keepsNewBackupAfterClockChange() throws {
        try FileManager.default.createDirectory(at: groupDirectory, withIntermediateDirectories: true)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var made: [URL] = []
        for offset in [3_600, 7_200, 10_800, -86_400] {
            try Data("journal".utf8).write(to: groupStore)
            made.append(try SharedJournal.backUpStore(at: groupStore, date: start.addingTimeInterval(TimeInterval(offset))))
        }
        #expect(backups().count == SharedJournal.backupLimit)
        #expect(exists(made[3]))
        #expect(!exists(made[0]))
    }

    /// Fails to move a store's main file, after its log has moved.
    private final class MainFileWontMove: FileManager {
        struct Refused: Error { }
        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            if srcURL.pathExtension == "store" { throw Refused() }
            try super.moveItem(at: srcURL, to: dstURL)
        }
    }

    @Test("a backup that can't finish leaves the store whole where it was")
    func backupRollsBack() throws {
        try FileManager.default.createDirectory(at: groupDirectory, withIntermediateDirectories: true)
        try Data("main".utf8).write(to: groupStore)
        try Data("log".utf8).write(to: URL(fileURLWithPath: groupStore.path + "-wal"))
        #expect(throws: MainFileWontMove.Refused.self) {
            try SharedJournal.backUpStore(at: groupStore, fileManager: MainFileWontMove())
        }
        #expect(exists(groupStore))
        #expect(exists(groupStore, "-wal"))
        #expect(backups().isEmpty)
        let leftovers = (try FileManager.default.contentsOfDirectory(atPath: groupDirectory.path)).filter { $0.hasPrefix(SharedJournal.backupPrefix) }
        #expect(leftovers.isEmpty)
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

    @Test("the widget asks for the app to be opened until there's a journal in the group")
    func widgetWithoutJournal() throws {
        #expect(CheckInWidgetPlan.loadItems(storeURL: nil) == nil)
        #expect(CheckInWidgetPlan.loadItems(storeURL: groupStore) == nil)
        #expect(!exists(groupStore))
        try writeJournal(at: groupStore, body: "Late coffee")
        #expect(CheckInWidgetPlan.loadItems(storeURL: groupStore)?.map(\.text) == ["Late coffee"])
    }
}

@MainActor
struct JournalBackupTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("JournalBackupTests-\(UUID().uuidString)", isDirectory: true)
    private var storeURL: URL { root.appending(path: SharedJournal.storeFileName) }
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func openJournal(at url: URL? = nil, now date: Date? = nil) throws -> JournalStore {
        let container = try ForesightPersistence.makeContainer(storeURL: url ?? storeURL)
        let fixed = date ?? now
        return JournalStore(modelContext: container.mainContext, modelContainer: container, now: { fixed })
    }

    /// A separate journal saved as a backup made at `date`.
    private func writeBackup(at date: Date, bodies: [String]) throws -> URL {
        let url = SharedJournal.newBackupURL(beside: storeURL, date: date)
        let journal = try openJournal(at: url, now: date)
        for body in bodies { _ = try journal.saveLog(body: body, eventAt: date, categoryIDs: []) }
        return url
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test("restoring a backup replaces the journal, and the copy it saves first undoes it")
    func restoresAndUndoes() throws {
        let store = try openJournal()
        let workout = try #require(store.categories.first { $0.name == "Workout" })
        let run = try store.saveLog(body: "Morning run", eventAt: now.addingTimeInterval(-3_600), categoryIDs: [workout.id])
        let runID = run.id
        let answered = try store.createCheckIn(for: run, phase: .immediate)
        try store.answer(answered, response: .muchBetter, notSure: false, note: "Lighter all day", excludedFromAnalysis: false)
        let scroll = try store.saveLog(body: "Late scroll", eventAt: now.addingTimeInterval(-600), categoryIDs: [])
        _ = try store.createCheckIn(for: scroll, phase: .delayed, dueAt: now.addingTimeInterval(3_600))
        try store.archiveCategory(try #require(store.categories.first { $0.name == "Sleep" }))

        let other = try writeBackup(at: now.addingTimeInterval(-60), bodies: ["From another phone"])
        let listed = try #require(store.backups().first)
        #expect(store.backups().count == 1)
        #expect(listed.url.lastPathComponent == other.lastPathComponent)
        #expect(listed.date == now.addingTimeInterval(-60))
        #expect(listed.logCount == 1)
        #expect(listed.checkInCount == 0)

        let safetyCopy = try store.restoreBackup(at: other)
        #expect(store.entries.map(\.body) == ["From another phone"])
        #expect(store.checkIns.isEmpty)
        #expect(!store.categories.contains { $0.isArchived })
        // The backup restored stays, beside the journal it replaced.
        #expect(store.backups().map(\.url.lastPathComponent) == [safetyCopy, other].map(\.lastPathComponent))
        #expect(store.backups().first?.logCount == 2)
        #expect(store.backups().first?.checkInCount == 2)
        #expect(store.backups().first?.date == now)

        try store.restoreBackup(at: safetyCopy)
        #expect(store.entries.map(\.body) == ["Late scroll", "Morning run"])
        let restoredRun = try #require(store.entries.first { $0.body == "Morning run" })
        #expect(restoredRun.categories.map(\.name) == ["Workout"])
        let restoredAnswer = try #require(store.checkIns.first { $0.phase == .immediate })
        #expect(restoredAnswer.entry?.id == runID)
        #expect(restoredAnswer.overall == .muchBetter)
        #expect(restoredAnswer.note == "Lighter all day")
        let pending = try #require(store.checkIns.first { $0.phase == .delayed })
        #expect(pending.status == .pending)
        #expect(pending.dueAt == now.addingTimeInterval(3_600))
        #expect(store.categories.first { $0.name == "Sleep" }?.isArchived == true)

        // Restoring over the same journal after edits updates the records it shares.
        _ = try store.saveLog(id: restoredRun.id, body: "Edited", eventAt: restoredRun.eventAt, categoryIDs: [])
        try store.deleteEntry(try #require(store.entries.first { $0.body == "Late scroll" }))
        _ = try store.saveLog(body: "Written after the backup", eventAt: now, categoryIDs: [])
        try store.restoreBackup(at: safetyCopy)
        #expect(store.entries.map(\.body) == ["Late scroll", "Morning run"])
        #expect(store.entries.first { $0.body == "Morning run" }?.categories.map(\.name) == ["Workout"])
        #expect(store.checkIns.count == 2)
        #expect(exists(safetyCopy))
        #expect(SharedJournal.backups(in: root).count == SharedJournal.backupLimit)
    }

    @Test("pruning after a restore keeps the copy it saved and the backup restored")
    func pruningSparesRestore() throws {
        let store = try openJournal()
        _ = try store.saveLog(body: "Today", eventAt: now, categoryIDs: [])
        // Made by a clock running ahead, so the copy the restore saves gets the oldest name.
        let oldest = try writeBackup(at: now.addingTimeInterval(3_600), bodies: ["One"])
        let middle = try writeBackup(at: now.addingTimeInterval(7_200), bodies: ["Two"])
        let newest = try writeBackup(at: now.addingTimeInterval(10_800), bodies: ["Three"])

        let listed = store.backups()
        let restoring = try #require(listed.first { $0.url.lastPathComponent == oldest.lastPathComponent })
        #expect(JournalStore.backupsRemovedByRestoring(restoring, from: listed).map(\.url.lastPathComponent) == [middle.lastPathComponent])

        let safetyCopy = try store.restoreBackup(at: oldest)
        #expect(store.entries.map(\.body) == ["One"])
        #expect(Set(SharedJournal.backups(in: root).map(\.url.lastPathComponent)) == Set([newest, oldest, safetyCopy].map(\.lastPathComponent)))
        #expect(!exists(middle))
        let saved = try JournalArchive.read(from: safetyCopy)
        #expect(saved.entries.map(\.body) == ["Today"])
    }

    @Test("a backup that can't be read is listed as such, and restoring it changes nothing")
    func unreadableBackup() throws {
        let store = try openJournal()
        _ = try store.saveLog(body: "Keep me", eventAt: now, categoryIDs: [])
        let broken = SharedJournal.newBackupURL(beside: storeURL, date: now.addingTimeInterval(-60))
        try Data("not a journal".utf8).write(to: broken)

        #expect(store.backups().map(\.isReadable) == [false])
        #expect(throws: (any Error).self) { try store.restoreBackup(at: broken) }
        #expect(store.entries.map(\.body) == ["Keep me"])
        #expect(SharedJournal.backups(in: root).map(\.url.lastPathComponent) == [broken.lastPathComponent])
    }

    @Test("a journal kept in memory has no backups to restore")
    func inMemoryJournal() throws {
        let container = try ForesightPersistence.makeContainer(storeURL: nil)
        let store = JournalStore(modelContext: container.mainContext, modelContainer: container)
        #expect(store.storeURL == nil)
        #expect(store.backups().isEmpty)
        #expect(throws: JournalBackupError.noBackups) { try store.restoreBackup(at: storeURL) }
    }

    @Test("backups list newest first, with the time in their names")
    func backupListing() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = SharedJournal.newBackupURL(beside: storeURL, date: now)
        try Data("one".utf8).write(to: first)
        let sameSecond = SharedJournal.newBackupURL(beside: storeURL, date: now)
        try Data("two".utf8).write(to: sameSecond)
        let later = SharedJournal.newBackupURL(beside: storeURL, date: now.addingTimeInterval(86_400))
        try Data("three".utf8).write(to: later)
        let listed = SharedJournal.backups(in: root)
        #expect(listed.map(\.url.lastPathComponent) == [later, sameSecond, first].map(\.lastPathComponent))
        #expect(listed.map(\.date) == [now.addingTimeInterval(86_400), now, now])
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
