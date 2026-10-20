import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class JournalStore {
    private let modelContext: ModelContext
    // The context does not keep its owning container alive. Retaining it here
    // makes injected in-memory stores safe for tests and previews.
    private let modelContainer: ModelContainer?
    private let now: () -> Date
    private let makeID: () -> UUID

    private(set) var entries: [JournalEntry] = []
    private(set) var categories: [JournalCategory] = []
    private(set) var checkIns: [OutcomeCheckIn] = []
    private(set) var initializationError: String?
    private(set) var ignoredRecords = 0
    /// Called after every successful load, so reminders follow every check-in change.
    @ObservationIgnored var onCheckInsChanged: (@MainActor ([OutcomeCheckIn]) -> Void)?
    /// Called after every successful load, so suggestion nudges follow every journal change.
    @ObservationIgnored var onJournalChanged: (@MainActor (JournalStore) -> Void)?
    /// Called after every successful load, so the widget follows every journal change.
    @ObservationIgnored var onLoaded: (@MainActor () -> Void)?
    /// Called after the journal is erased, so notification history about it goes too.
    @ObservationIgnored var onReset: (@MainActor () -> Void)?
    /// Set while an automatic backup is being written, so two activations don't both take one.
    @ObservationIgnored private var isTakingAutomaticBackup = false

    init(modelContext: ModelContext, modelContainer: ModelContainer? = nil, now: @escaping () -> Date = { .now }, makeID: @escaping () -> UUID = UUID.init) {
        self.modelContext = modelContext
        self.modelContainer = modelContainer
        self.now = now
        self.makeID = makeID
        reload()
    }

    var snapshot: JournalSnapshot { JournalSnapshot(entries: entries, categories: categories, checkIns: checkIns) }
    var activeCategories: [JournalCategory] { categories.filter { !$0.isArchived } }

    func reload() {
        do {
            categories = try modelContext.fetch(FetchDescriptor<JournalCategory>(sortBy: [SortDescriptor(\.name)]))
            entries = try modelContext.fetch(FetchDescriptor<JournalEntry>(sortBy: [SortDescriptor(\.eventAt, order: .reverse)]))
            checkIns = try modelContext.fetch(FetchDescriptor<OutcomeCheckIn>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
            if categories.isEmpty {
                DefaultCategories.names.forEach { modelContext.insert(JournalCategory(name: $0)) }
                try modelContext.save()
                categories = try modelContext.fetch(FetchDescriptor<JournalCategory>(sortBy: [SortDescriptor(\.name)]))
            }
            initializationError = nil
            onCheckInsChanged?(checkIns)
            onJournalChanged?(self)
            onLoaded?()
        } catch {
            initializationError = "Your journal could not be opened. \(error.localizedDescription)"
        }
    }

    /// Erases the journal, after saving it as a backup when it holds a log of your own, so an
    /// erase can be undone from Settings. That copy also tells the daily backup the smaller
    /// journal is on purpose (see `SharedJournal.hasShrunk`). Returns the copy's URL, if one was made.
    @discardableResult
    func resetStore() -> URL? {
        let safetyCopy: URL?
        do {
            safetyCopy = try saveSafetyCopy(of: JournalArchive(context: modelContext))
        } catch {
            initializationError = "Your journal wasn't erased, because a copy of it couldn't be saved first. \(error.localizedDescription)"
            return nil
        }
        do {
            try modelContext.fetch(FetchDescriptor<OutcomeCheckIn>()).forEach(modelContext.delete)
            try modelContext.fetch(FetchDescriptor<JournalEntry>()).forEach(modelContext.delete)
            try modelContext.fetch(FetchDescriptor<JournalCategory>()).forEach(modelContext.delete)
            try modelContext.save()
            reload()
            onReset?()
        } catch {
            modelContext.rollback()
            if let safetyCopy { SharedJournal.removeStore(at: safetyCopy) }
            initializationError = "The journal could not be reset. \(error.localizedDescription)"
            return nil
        }
        if let safetyCopy, let storeURL { SharedJournal.pruneBackups(in: storeURL.deletingLastPathComponent(), sparing: [safetyCopy]) }
        return safetyCopy
    }

    func saveLog(id: UUID? = nil, body: String, eventAt: Date, categoryIDs: Set<UUID>) throws -> JournalEntry {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ForesightError.emptyEntry }
        guard text.count <= 5_000 else { throw ForesightError.entryTooLong }
        let selectedActive = categories.filter { categoryIDs.contains($0.id) && !$0.isArchived }
        let timestamp = now()
        if let id, let entry = entries.first(where: { $0.id == id }) {
            let archivedHistory = entry.categories.filter(\.isArchived)
            entry.body = text
            entry.eventAt = eventAt
            entry.updatedAt = timestamp
            entry.categories = uniqueCategories(selectedActive + archivedHistory)
            try persist()
            return entry
        }
        if id != nil { throw ForesightError.missingEntry }
        let entry = JournalEntry(id: makeID(), body: text, eventAt: eventAt, createdAt: timestamp, updatedAt: timestamp, categories: selectedActive)
        modelContext.insert(entry)
        try persist()
        return entry
    }

    func addCategory(named name: String) throws -> JournalCategory {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ForesightError.emptyCategory }
        guard !categories.contains(where: { $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else { throw ForesightError.duplicateCategory }
        let category = JournalCategory(id: makeID(), name: trimmed)
        modelContext.insert(category)
        try persist()
        return category
    }

    func archiveCategory(_ category: JournalCategory) throws {
        guard categories.contains(where: { $0.id == category.id }) else { throw ForesightError.missingCategory }
        category.archivedAt = now()
        try persist()
    }

    func restoreCategory(_ category: JournalCategory) throws {
        guard categories.contains(where: { $0.id == category.id }) else { throw ForesightError.missingCategory }
        category.archivedAt = nil
        try persist()
    }

    func deleteEntry(_ entry: JournalEntry) throws {
        guard entries.contains(where: { $0.id == entry.id }) else { throw ForesightError.missingEntry }
        entry.checkIns.forEach(modelContext.delete)
        modelContext.delete(entry)
        try persist()
    }

    func createCheckIn(for entry: JournalEntry, phase: OutcomePhase, dueAt: Date? = nil) throws -> OutcomeCheckIn {
        guard entries.contains(where: { $0.id == entry.id }) else { throw ForesightError.missingEntry }
        if phase == .immediate, checkIns.contains(where: { $0.entry?.id == entry.id && $0.phase == .immediate }) { throw ForesightError.duplicateImmediate }
        if phase == .delayed, checkIns.contains(where: { $0.entry?.id == entry.id && $0.phase == .delayed && $0.status == .pending }) { throw ForesightError.duplicateDelayed }
        if phase == .delayed, dueAt == nil || dueAt! <= now() { throw ForesightError.invalidSchedule }
        let timestamp = now()
        let checkIn = OutcomeCheckIn(id: makeID(), entry: entry, phase: phase, dueAt: dueAt, createdAt: timestamp, updatedAt: timestamp)
        modelContext.insert(checkIn)
        try persist()
        return checkIn
    }

    func answer(_ checkIn: OutcomeCheckIn, response: OutcomeValue?, notSure: Bool, note: String, excludedFromAnalysis: Bool) throws {
        guard checkIns.contains(where: { $0.id == checkIn.id }) else { throw ForesightError.missingCheckIn }
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanNote.count <= 5_000 else { throw ForesightError.noteTooLong }
        guard notSure || response != nil else { return }
        let timestamp = now()
        checkIn.status = notSure ? .notSure : .answered
        checkIn.overall = notSure ? nil : response
        checkIn.answeredAt = timestamp
        checkIn.note = cleanNote
        checkIn.excludedFromAnalysis = excludedFromAnalysis
        checkIn.updatedAt = timestamp
        try persist()
    }

    func skip(_ checkIn: OutcomeCheckIn) throws {
        guard checkIns.contains(where: { $0.id == checkIn.id }) else { throw ForesightError.missingCheckIn }
        checkIn.status = .skipped
        checkIn.overall = nil
        checkIn.answeredAt = nil
        checkIn.updatedAt = now()
        try persist()
    }

    func reschedule(_ checkIn: OutcomeCheckIn, to dueAt: Date) throws {
        guard checkIns.contains(where: { $0.id == checkIn.id }) else { throw ForesightError.missingCheckIn }
        guard checkIn.phase == .delayed, checkIn.status == .pending, dueAt > now() else { throw ForesightError.invalidSchedule }
        checkIn.dueAt = dueAt
        checkIn.updatedAt = now()
        try persist()
    }

    func removeCheckIn(_ checkIn: OutcomeCheckIn) throws {
        guard checkIns.contains(where: { $0.id == checkIn.id }) else { throw ForesightError.missingCheckIn }
        modelContext.delete(checkIn)
        try persist()
    }

    func demoDataState() -> DemoDataState {
        let fixtures = entries.filter(\.isFixture)
        guard !fixtures.isEmpty else { return .none }
        return fixtures.count >= 89 ? .complete : .partial
    }

    func addDemoHistory() throws {
        let categoryByName = Dictionary(uniqueKeysWithValues: categories.map { ($0.name.lowercased(), $0) })
        let fallbackCategories = DefaultCategories.names.map { name -> JournalCategory in
            if let category = categoryByName[name.lowercased()] { return category }
            let category = JournalCategory(name: name)
            modelContext.insert(category)
            return category
        }
        let workout = fallbackCategories.first { $0.name == "Workout" }!
        let alcohol = fallbackCategories.first { $0.name == "Alcohol" }!
        let social = fallbackCategories.first { $0.name == "Social" }!
        let scrolling = fallbackCategories.first { $0.name == "Scrolling" }!
        let sleep = fallbackCategories.first { $0.name == "Sleep" }!
        let work = fallbackCategories.first { $0.name == "Work" }!
        let timestamp = now()
        let scenarios: [(JournalCategory, String, [OutcomeValue], [OutcomeValue])] = [
            (workout, "Finished a workout even though motivation was low.", [.aLittleBetter, .aLittleBetter, .muchBetter, .same, .aLittleBetter], [.aLittleBetter, .aLittleBetter, .muchBetter, .aLittleBetter, .same]),
            (alcohol, "Had drinks with friends and stayed out late.", [.aLittleBetter, .muchBetter, .aLittleBetter, .aLittleBetter, .same], [.muchWorse, .aLittleWorse, .muchWorse, .aLittleWorse, .same]),
            (scrolling, "Spent the evening switching between short videos.", [.same, .same, .aLittleBetter, .same, .aLittleWorse], [.aLittleWorse, .muchWorse, .aLittleWorse, .same, .aLittleWorse]),
            (social, "Met friends for a relaxed dinner.", [.aLittleBetter, .muchBetter, .aLittleBetter, .same, .aLittleBetter], [.aLittleBetter, .aLittleBetter, .same, .aLittleBetter, .aLittleWorse]),
            (work, "Worked later than planned to finish a task.", [.same, .aLittleBetter, .aLittleWorse, .same, .aLittleBetter], [.aLittleBetter, .aLittleBetter, .aLittleBetter, .aLittleWorse, .aLittleWorse]),
            (sleep, "Went to bed earlier and left my phone outside the room.", [.same, .same, .aLittleBetter, .same, .same], [.aLittleBetter, .aLittleBetter, .same, .aLittleBetter, .aLittleBetter])
        ]
        let existingFixtures = entries.filter(\.isFixture).count
        if existingFixtures < 84 {
            for (scenarioIndex, scenario) in scenarios.enumerated() {
                for index in 0..<14 {
                    let eventAt = Calendar.current.date(byAdding: .day, value: -(3 + index * 4 + scenarioIndex), to: timestamp)!
                    let entry = JournalEntry(id: makeID(), body: scenario.1, eventAt: eventAt, createdAt: eventAt, updatedAt: eventAt, categories: [scenario.0], isFixture: true)
                    modelContext.insert(entry)
                    let immediate = OutcomeCheckIn(id: makeID(), entry: entry, phase: .immediate, status: index == 13 ? .notSure : .answered, dueAt: nil, answeredAt: Calendar.current.date(byAdding: .hour, value: 1, to: eventAt), overall: index == 13 ? nil : scenario.2[index % scenario.2.count], note: index == 13 ? "There were too many other factors to tell." : "", excludedFromAnalysis: index == 12, createdAt: eventAt, updatedAt: eventAt, isFixture: true)
                    let delayed = OutcomeCheckIn(id: makeID(), entry: entry, phase: .delayed, status: index == 13 ? .notSure : .answered, dueAt: Calendar.current.date(byAdding: .hour, value: 12, to: eventAt), answeredAt: Calendar.current.date(byAdding: .hour, value: 20, to: eventAt), overall: index == 13 ? nil : scenario.3[index % scenario.3.count], note: index == 13 ? "There were too many other factors to tell." : "", excludedFromAnalysis: index == 12, createdAt: eventAt, updatedAt: eventAt, isFixture: true)
                    modelContext.insert(immediate)
                    modelContext.insert(delayed)
                }
            }
        }
        if entries.filter(\.isFixture).count < 89 {
            let queue: [(String, JournalCategory, Int, Int?, OutcomeStatus, OutcomeValue?)] = [
                ("Went out for drinks and stayed later than I planned.", alcohol, -72, -48, .pending, nil),
                ("Did a short workout even though I felt low-energy beforehand.", workout, -30, -18, .pending, nil),
                ("Spent longer than I meant to scrolling after lunch.", scrolling, -4, 2, .pending, nil),
                ("Pushed through a late work session to finish a project.", work, -192, -168, .answered, .aLittleWorse),
                ("Had a quiet dinner with friends after a busy week.", social, -96, -72, .skipped, nil)
            ]
            for item in queue {
                let eventAt = Calendar.current.date(byAdding: .hour, value: item.2, to: timestamp)!
                let entry = JournalEntry(id: makeID(), body: item.0, eventAt: eventAt, createdAt: eventAt, updatedAt: eventAt, categories: [item.1], isFixture: true)
                modelContext.insert(entry)
                let dueAt = item.3.map { Calendar.current.date(byAdding: .hour, value: $0, to: timestamp)! }
                let answeredAt = item.4 == .answered ? Calendar.current.date(byAdding: .hour, value: item.3! + 12, to: timestamp) : nil
                let checkIn = OutcomeCheckIn(id: makeID(), entry: entry, phase: .delayed, status: item.4, dueAt: dueAt, answeredAt: answeredAt, overall: item.5, note: item.4 == .answered ? "I finished it, but sleep and focus were worse the next morning." : "", createdAt: eventAt, updatedAt: answeredAt ?? eventAt, isFixture: true)
                modelContext.insert(checkIn)
            }
        }
        try persist()
    }

    func removeDemoHistory() throws {
        checkIns.filter(\.isFixture).forEach(modelContext.delete)
        entries.filter(\.isFixture).forEach(modelContext.delete)
        try persist()
    }

    private func persist() throws {
        try modelContext.save()
        reload()
    }

    private func uniqueCategories(_ list: [JournalCategory]) -> [JournalCategory] {
        var seen = Set<UUID>()
        return list.filter { seen.insert($0.id).inserted }
    }
}

enum DemoDataState: Equatable { case none, partial, complete }

// MARK: - Backups

/// A backup beside the journal, as Settings lists it.
struct JournalBackup: Identifiable, Equatable {
    let url: URL
    let date: Date
    /// Nil when the backup can't be read.
    let logCount: Int?
    let checkInCount: Int?
    var isAutomatic = false

    var id: URL { url }
    var isReadable: Bool { logCount != nil }
}

extension JournalBackup {
    /// The backups in `directory`, newest first, with what each holds.
    static func list(in directory: URL) -> [JournalBackup] {
        SharedJournal.backups(in: directory).map { backup in
            let counts = try? JournalArchive.counts(at: backup.url)
            return JournalBackup(url: backup.url, date: backup.date, logCount: counts?.logs, checkInCount: counts?.checkIns, isAutomatic: backup.isAutomatic)
        }
    }
}

enum JournalBackupError: LocalizedError, Equatable {
    case noBackups

    var errorDescription: String? { "This journal doesn't keep backups." }
}

/// What importing an exported journal changed.
struct JournalImport: Equatable {
    var addedLogs = 0
    var updatedLogs = 0
    var addedCheckIns = 0
    var updatedCheckIns = 0
    /// The journal as it was before the import, saved as a backup.
    var safetyCopy: URL?

    var changedAnything: Bool { addedLogs + updatedLogs + addedCheckIns + updatedCheckIns > 0 }
}

enum JournalImportError: LocalizedError, Equatable {
    case notAnExport
    case newerVersion

    var errorDescription: String? {
        switch self {
        case .notAnExport: "This file isn't a journal exported from Foresight."
        case .newerVersion: "This journal was exported by a newer version of Foresight. Update the app, then import it again."
        }
    }
}

/// What the "Journal unavailable" screen can do with a journal that won't open. Nothing here
/// deletes it: it is moved aside as a backup, where Settings lists it once a journal opens.
enum JournalRecovery {
    /// Moves the store at `url` aside as a backup, if there's one there, and returns where it went.
    /// Other backups are left alone, so one that can't be read never pushes out one that can.
    @discardableResult
    static func moveAside(storeAt url: URL, date: Date = .now) throws -> URL? {
        guard SharedJournal.storeFileSuffixes.contains(where: { FileManager.default.fileExists(atPath: url.path + $0) }) else { return nil }
        return try SharedJournal.backUpStore(at: url, date: date, prune: false)
    }

    /// Replaces the store at `url` with the backup at `backup`, after moving the store aside.
    /// If the backup can't be read or written, the store is put back as it was.
    @discardableResult
    static func restore(backupAt backup: URL, intoStoreAt url: URL, date: Date = .now) throws -> URL? {
        let archive = try JournalArchive.read(from: backup)
        let aside = try moveAside(storeAt: url, date: date)
        do {
            try SharedJournal.writeStore(at: url) { try archive.write(toNewStoreAt: $0) }
        } catch {
            if let aside { try? SharedJournal.moveStore(at: aside, to: url) }
            throw error
        }
        return aside
    }
}

extension JournalStore {
    /// The journal's store file, or nil for a journal kept in memory.
    var storeURL: URL? {
        guard let configuration = modelContainer?.configurations.first, !configuration.isStoredInMemoryOnly else { return nil }
        return configuration.url
    }

    /// The backups beside the journal, newest first, with what each holds.
    func backups() -> [JournalBackup] {
        guard let storeURL else { return [] }
        return JournalBackup.list(in: storeURL.deletingLastPathComponent())
    }

    /// Saves `archive` (the journal as it is now) as a new backup before a change that replaces
    /// or removes records. Nil when there's nothing worth a backup: a journal kept in memory, or
    /// one with no logs but sample history.
    private func saveSafetyCopy(of archive: JournalArchive) throws -> URL? {
        guard let storeURL, archive.entries.contains(where: { !$0.isFixture }) else { return nil }
        let safetyCopy = SharedJournal.newBackupURL(beside: storeURL, date: now())
        do {
            try archive.write(toNewStoreAt: safetyCopy)
        } catch {
            SharedJournal.removeStore(at: safetyCopy)
            throw error
        }
        return safetyCopy
    }

    /// Adds the logs and check-ins in an exported journal to this one, after saving this one as a
    /// backup. Records it already has stay as they are unless the file's copy was changed more
    /// recently, so importing the same file twice changes nothing. Categories are matched by name,
    /// since every install starts its own copies of the starter ones.
    @discardableResult
    func importJournal(_ export: JournalExport) throws -> JournalImport {
        let current = try JournalArchive(context: modelContext)
        let (merged, changes) = try current.merging(export)
        var result = changes
        guard result.changedAnything else { return result }
        result.safetyCopy = try saveSafetyCopy(of: current)
        do {
            try merged.apply(to: modelContext)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            if let safetyCopy = result.safetyCopy { SharedJournal.removeStore(at: safetyCopy) }
            reload()
            throw error
        }
        reload()
        if let safetyCopy = result.safetyCopy, let storeURL { SharedJournal.pruneBackups(in: storeURL.deletingLastPathComponent(), sparing: [safetyCopy]) }
        return result
    }

    /// Takes the day's automatic backup, if one is due (see `SharedJournal.isAutomaticBackupDue`)
    /// and the journal holds a log that isn't sample data. The journal's records are copied out
    /// here, in one go on the main context, then written to the backup off the main thread in the
    /// same format a restore's safety copy uses. It replaces only older automatic backups, or other
    /// backups at least `SharedJournal.protectedBackupAge` old, and is skipped when there's no such
    /// room or the journal has shrunk to under half the newest automatic backup
    /// (`SharedJournal.hasShrunk`). Returns the new backup's URL, or nil when none was kept.
    @discardableResult
    func takeAutomaticBackupIfDue() async -> URL? {
        guard let storeURL, !isTakingAutomaticBackup, entries.contains(where: { !$0.isFixture }) else { return nil }
        let date = now()
        let directory = storeURL.deletingLastPathComponent()
        let existing = SharedJournal.backups(in: directory)
        guard SharedJournal.isAutomaticBackupDue(among: existing, now: date),
              SharedJournal.backupsRemovedForAutomaticBackup(from: existing, now: date) != nil,
              let archive = try? JournalArchive(context: modelContext) else { return nil }
        let url = SharedJournal.newBackupURL(beside: storeURL, date: date, automatic: true)
        isTakingAutomaticBackup = true
        defer { isTakingAutomaticBackup = false }
        return await Task.detached(priority: .utility) { () -> URL? in
            SharedJournal.removeUnfinishedBackups(in: directory)
            let newest = existing.first
            let newestLogCount = newest.flatMap { try? JournalArchive.counts(at: $0.url).logs }
            if SharedJournal.hasShrunk(logCount: archive.entries.count, since: newest, newestLogCount: newestLogCount, now: date) { return nil }
            do {
                try SharedJournal.writeStore(at: url) { try archive.write(toNewStoreAt: $0) }
            } catch {
                return nil
            }
            return SharedJournal.finishAutomaticBackup(at: url, now: date) ? url : nil
        }.value
    }

    /// The backups in `backups` (newest first) that pruning deletes after restoring `restored`:
    /// the new copy and `restored` are kept, then the newest of the rest up to the limit.
    nonisolated static func backupsRemovedByRestoring(_ restored: JournalBackup, from backups: [JournalBackup]) -> [JournalBackup] {
        Array(backups.filter { $0.id != restored.id }.dropFirst(max(0, SharedJournal.backupLimit - 2)))
    }

    /// Replaces the journal with the backup at `url`, after saving the journal as it is now as a
    /// new backup so the restore can be undone the same way. Pruning to the newest
    /// `SharedJournal.backupLimit` afterwards always keeps that copy and the one restored.
    /// Reminders, nudges and widgets follow through the usual reload. Returns the new backup's URL.
    @discardableResult
    func restoreBackup(at url: URL) throws -> URL {
        guard let storeURL else { throw JournalBackupError.noBackups }
        let restored = try JournalArchive.read(from: url)
        let current = try JournalArchive(context: modelContext)
        let safetyCopy = SharedJournal.newBackupURL(beside: storeURL, date: now())
        do {
            try current.write(toNewStoreAt: safetyCopy)
        } catch {
            SharedJournal.removeStore(at: safetyCopy)
            throw error
        }
        do {
            try restored.apply(to: modelContext)
            try modelContext.save()
        } catch {
            // The journal is as it was, so its copy isn't needed and shouldn't crowd out an older backup.
            modelContext.rollback()
            SharedJournal.removeStore(at: safetyCopy)
            reload()
            throw error
        }
        reload()
        SharedJournal.pruneBackups(in: storeURL.deletingLastPathComponent(), sparing: [safetyCopy, url])
        return safetyCopy
    }
}

/// A journal's records copied out of SwiftData, so they can be written into another store.
struct JournalArchive: Sendable {
    struct Category: Sendable {
        let id: UUID
        let name: String
        let archivedAt: Date?
    }

    struct Entry: Sendable {
        let id: UUID
        let body: String
        let eventAt: Date
        let createdAt: Date
        let updatedAt: Date
        let isFixture: Bool
        let categoryIDs: [UUID]
    }

    struct CheckIn: Sendable {
        let id: UUID
        let entryID: UUID?
        let phase: OutcomePhase
        let status: OutcomeStatus
        let dueAt: Date?
        let answeredAt: Date?
        let overall: OutcomeValue?
        let note: String
        let excludedFromAnalysis: Bool
        let createdAt: Date
        let updatedAt: Date
        let isFixture: Bool
    }

    var categories: [Category]
    var entries: [Entry]
    var checkIns: [CheckIn]

    init(context: ModelContext) throws {
        categories = try context.fetch(FetchDescriptor<JournalCategory>()).map { Category(id: $0.id, name: $0.name, archivedAt: $0.archivedAt) }
        entries = try context.fetch(FetchDescriptor<JournalEntry>()).map {
            Entry(id: $0.id, body: $0.body, eventAt: $0.eventAt, createdAt: $0.createdAt, updatedAt: $0.updatedAt, isFixture: $0.isFixture, categoryIDs: $0.categories.map { $0.id })
        }
        checkIns = try context.fetch(FetchDescriptor<OutcomeCheckIn>()).map {
            CheckIn(id: $0.id, entryID: $0.entry?.id, phase: $0.phase, status: $0.status, dueAt: $0.dueAt, answeredAt: $0.answeredAt, overall: $0.overall, note: $0.note, excludedFromAnalysis: $0.excludedFromAnalysis, createdAt: $0.createdAt, updatedAt: $0.updatedAt, isFixture: $0.isFixture)
        }
    }

    /// These records with an exported journal's added, and the records both have replaced by the
    /// file's copy where it was changed more recently. A category is matched by name when its ID
    /// is new here; a log keeps the categories its file copy names. Sample history is never in an
    /// export, so everything added is the user's own.
    func merging(_ export: JournalExport) throws -> (JournalArchive, JournalImport) {
        guard export.format == JournalExport.format else { throw JournalImportError.notAnExport }
        guard export.version <= 1 else { throw JournalImportError.newerVersion }
        var merged = self
        var result = JournalImport()

        func key(_ name: String) -> String {
            name.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        var categoryIDByName: [String: UUID] = [:]
        for category in categories where categoryIDByName[key(category.name)] == nil { categoryIDByName[key(category.name)] = category.id }
        let knownCategoryIDs = Set(categories.map(\.id))
        func addCategory(id: UUID, name: String, archivedAt: Date?) -> UUID {
            if let existing = categoryIDByName[key(name)] { return existing }
            merged.categories.append(Category(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), archivedAt: archivedAt))
            categoryIDByName[key(name)] = id
            return id
        }
        for category in export.categories where !knownCategoryIDs.contains(category.id) && !key(category.name).isEmpty {
            _ = addCategory(id: category.id, name: category.name, archivedAt: category.archivedAt)
        }

        var entryIndex = Dictionary(merged.entries.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var checkInIndex = Dictionary(merged.checkIns.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for entry in export.entries {
            let body = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            var categoryIDs: [UUID] = []
            for name in entry.categories where !key(name).isEmpty {
                let id = addCategory(id: UUID(), name: name, archivedAt: nil)
                if !categoryIDs.contains(id) { categoryIDs.append(id) }
            }
            let item = Entry(id: entry.id, body: body, eventAt: entry.eventAt, createdAt: entry.createdAt, updatedAt: entry.updatedAt, isFixture: false, categoryIDs: categoryIDs)
            if let index = entryIndex[entry.id] {
                if entry.updatedAt > merged.entries[index].updatedAt {
                    merged.entries[index] = item
                    result.updatedLogs += 1
                }
            } else {
                entryIndex[entry.id] = merged.entries.count
                merged.entries.append(item)
                result.addedLogs += 1
            }

            for checkIn in entry.checkIns {
                guard let phase = OutcomePhase(rawValue: checkIn.phase), let status = OutcomeStatus(rawValue: checkIn.status) else { continue }
                let item = CheckIn(id: checkIn.id, entryID: entry.id, phase: phase, status: status, dueAt: checkIn.dueAt, answeredAt: checkIn.answeredAt, overall: checkIn.response.flatMap(OutcomeValue.init(rawValue:)), note: checkIn.note, excludedFromAnalysis: checkIn.excludedFromAnalysis, createdAt: checkIn.createdAt, updatedAt: checkIn.updatedAt, isFixture: false)
                if let index = checkInIndex[checkIn.id] {
                    if checkIn.updatedAt > merged.checkIns[index].updatedAt {
                        merged.checkIns[index] = item
                        result.updatedCheckIns += 1
                    }
                } else {
                    checkInIndex[checkIn.id] = merged.checkIns.count
                    merged.checkIns.append(item)
                    result.addedCheckIns += 1
                }
            }
        }
        return (merged, result)
    }

    /// Reads the store at `url` without changing it.
    static func read(from url: URL) throws -> JournalArchive {
        let container = try ForesightPersistence.makeContainer(storeURL: url, allowsSave: false)
        // A context doesn't keep its container alive.
        return try withExtendedLifetime(container) { try JournalArchive(context: ModelContext(container)) }
    }

    /// How many logs, and check-ins with a log (the ones a restore keeps), the store at `url`
    /// holds, counted without loading them.
    static func counts(at url: URL) throws -> (logs: Int, checkIns: Int) {
        let container = try ForesightPersistence.makeContainer(storeURL: url, allowsSave: false)
        return try withExtendedLifetime(container) {
            let context = ModelContext(container)
            let logs = try context.fetchCount(FetchDescriptor<JournalEntry>())
            let checkIns = try context.fetchCount(FetchDescriptor<OutcomeCheckIn>(predicate: #Predicate<OutcomeCheckIn> { $0.entry != nil }))
            return (logs, checkIns)
        }
    }

    /// Writes these records into a new store at `url`.
    func write(toNewStoreAt url: URL) throws {
        let container = try ForesightPersistence.makeContainer(storeURL: url)
        try withExtendedLifetime(container) {
            let context = ModelContext(container)
            try apply(to: context)
            try context.save()
        }
    }

    /// Makes the journal in `context` match these records without saving: records it shares are
    /// updated in place (so no unique ID is inserted twice), missing ones are added, and the rest
    /// are deleted. A check-in whose log isn't here is left out, as the app never shows one.
    func apply(to context: ModelContext) throws {
        let existingCategories = Dictionary(try context.fetch(FetchDescriptor<JournalCategory>()).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let existingEntries = Dictionary(try context.fetch(FetchDescriptor<JournalEntry>()).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let existingCheckIns = Dictionary(try context.fetch(FetchDescriptor<OutcomeCheckIn>()).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var categoryByID: [UUID: JournalCategory] = [:]
        for item in categories {
            let category: JournalCategory
            if let existing = existingCategories[item.id] {
                category = existing
            } else {
                category = JournalCategory(id: item.id, name: item.name)
                context.insert(category)
            }
            category.name = item.name
            category.archivedAt = item.archivedAt
            categoryByID[item.id] = category
        }

        var entryByID: [UUID: JournalEntry] = [:]
        for item in entries {
            let entry: JournalEntry
            if let existing = existingEntries[item.id] {
                entry = existing
            } else {
                entry = JournalEntry(id: item.id, body: item.body, eventAt: item.eventAt)
                context.insert(entry)
            }
            entry.body = item.body
            entry.eventAt = item.eventAt
            entry.createdAt = item.createdAt
            entry.updatedAt = item.updatedAt
            entry.isFixture = item.isFixture
            entry.categories = item.categoryIDs.compactMap { categoryByID[$0] }
            entryByID[item.id] = entry
        }

        var keptCheckIns = Set<UUID>()
        for item in checkIns {
            guard let entryID = item.entryID, let entry = entryByID[entryID] else { continue }
            let checkIn: OutcomeCheckIn
            if let existing = existingCheckIns[item.id] {
                checkIn = existing
                checkIn.entry = entry
            } else {
                checkIn = OutcomeCheckIn(id: item.id, entry: entry, phase: item.phase)
                context.insert(checkIn)
            }
            checkIn.phase = item.phase
            checkIn.status = item.status
            checkIn.dueAt = item.dueAt
            checkIn.answeredAt = item.answeredAt
            checkIn.overall = item.overall
            checkIn.note = item.note
            checkIn.excludedFromAnalysis = item.excludedFromAnalysis
            checkIn.createdAt = item.createdAt
            checkIn.updatedAt = item.updatedAt
            checkIn.isFixture = item.isFixture
            keptCheckIns.insert(item.id)
        }

        // Check-ins go before logs, so a log's cascade never reaches one that was kept.
        for (id, checkIn) in existingCheckIns where !keptCheckIns.contains(id) { context.delete(checkIn) }
        for (id, entry) in existingEntries where entryByID[id] == nil { context.delete(entry) }
        for (id, category) in existingCategories where categoryByID[id] == nil { context.delete(category) }
    }
}
