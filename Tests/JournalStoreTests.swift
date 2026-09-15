import Foundation
import SwiftData
import Testing
@testable import Foresight

@MainActor
struct JournalStoreTests {
    private let fixedNow = Date(timeIntervalSince1970: 1_725_000_000)

    private func makeStore(now: Date? = nil) throws -> JournalStore {
        let schema = Schema([JournalEntry.self, JournalCategory.self, OutcomeCheckIn.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return JournalStore(modelContext: container.mainContext, modelContainer: container, now: { now ?? fixedNow })
    }

    private func category(_ name: String, in store: JournalStore) -> JournalCategory {
        store.categories.first { $0.name == name }!
    }

    @Test("seeds the six default categories")
    func defaultCategories() throws {
        let store = try makeStore()
        #expect(Set(store.categories.map(\.name)) == Set(DefaultCategories.names))
    }

    @Test("creates an uncategorized log")
    func createsLog() throws {
        let store = try makeStore()
        let entry = try store.saveLog(body: "A quiet morning", eventAt: fixedNow, categoryIDs: [])
        #expect(store.entries.count == 1)
        #expect(entry.body == "A quiet morning")
        #expect(entry.categories.isEmpty)
    }

    @Test("trims log text")
    func trimsLog() throws {
        let store = try makeStore()
        let entry = try store.saveLog(body: "  Kept a promise  ", eventAt: fixedNow, categoryIDs: [])
        #expect(entry.body == "Kept a promise")
    }

    @Test("rejects blank logs")
    func rejectsBlankLog() throws {
        let store = try makeStore()
        do { _ = try store.saveLog(body: "  ", eventAt: fixedNow, categoryIDs: []) ; Issue.record("Expected empty-entry error") }
        catch { #expect(error as? ForesightError == .emptyEntry) }
    }

    @Test("rejects logs longer than five thousand characters")
    func logLengthLimit() throws {
        let store = try makeStore()
        do { _ = try store.saveLog(body: String(repeating: "x", count: 5_001), eventAt: fixedNow, categoryIDs: []) ; Issue.record("Expected length error") }
        catch { #expect(error as? ForesightError == .entryTooLong) }
    }

    @Test("edits a log without replacing its creation date")
    func editsLog() throws {
        let store = try makeStore()
        let entry = try store.saveLog(body: "Before", eventAt: fixedNow, categoryIDs: [])
        let createdAt = entry.createdAt
        let originalEventAt = entry.eventAt
        let updated = try store.saveLog(id: entry.id, body: "After", eventAt: fixedNow.addingTimeInterval(60), categoryIDs: [])
        #expect(updated.body == "After")
        #expect(updated.createdAt == createdAt)
        #expect(updated.eventAt > originalEventAt)
    }

    @Test("sorts new logs by event date")
    func sortsLogs() throws {
        let store = try makeStore()
        _ = try store.saveLog(body: "Older", eventAt: fixedNow.addingTimeInterval(-1_000), categoryIDs: [])
        _ = try store.saveLog(body: "Newer", eventAt: fixedNow, categoryIDs: [])
        #expect(store.entries.map(\.body) == ["Newer", "Older"])
    }

    @Test("adds a custom category")
    func addsCategory() throws {
        let store = try makeStore()
        let category = try store.addCategory(named: "Reading")
        #expect(category.name == "Reading")
        #expect(store.categories.contains { $0.id == category.id })
    }

    @Test("rejects empty category names")
    func rejectsEmptyCategory() throws {
        let store = try makeStore()
        do { _ = try store.addCategory(named: " ") ; Issue.record("Expected empty category") }
        catch { #expect(error as? ForesightError == .emptyCategory) }
    }

    @Test("enforces case-insensitive unique category names")
    func uniqueCategoryNames() throws {
        let store = try makeStore()
        do { _ = try store.addCategory(named: "workout") ; Issue.record("Expected duplicate category") }
        catch { #expect(error as? ForesightError == .duplicateCategory) }
    }

    @Test("attaches more than one category")
    func multipleCategories() throws {
        let store = try makeStore()
        let entry = try store.saveLog(body: "Walked home", eventAt: fixedNow, categoryIDs: [category("Workout", in: store).id, category("Social", in: store).id])
        #expect(Set(entry.categories.map(\.name)) == Set(["Workout", "Social"]))
    }

    @Test("archives categories without removing log history")
    func archivesCategory() throws {
        let store = try makeStore()
        let workout = category("Workout", in: store)
        let entry = try store.saveLog(body: "Run", eventAt: fixedNow, categoryIDs: [workout.id])
        try store.archiveCategory(workout)
        #expect(workout.isArchived)
        #expect(entry.categories.contains { $0.id == workout.id })
        #expect(!store.activeCategories.contains { $0.id == workout.id })
    }

    @Test("keeps archived categories while editing history")
    func preservesArchivedOnEdit() throws {
        let store = try makeStore()
        let workout = category("Workout", in: store)
        let entry = try store.saveLog(body: "Run", eventAt: fixedNow, categoryIDs: [workout.id])
        try store.archiveCategory(workout)
        let updated = try store.saveLog(id: entry.id, body: "Long run", eventAt: fixedNow, categoryIDs: [])
        #expect(updated.categories.map(\.id) == [workout.id])
    }

    @Test("does not add archived categories to new logs")
    func blocksArchivedOnNewLog() throws {
        let store = try makeStore()
        let workout = category("Workout", in: store)
        try store.archiveCategory(workout)
        let entry = try store.saveLog(body: "Run", eventAt: fixedNow, categoryIDs: [workout.id])
        #expect(entry.categories.isEmpty)
    }

    @Test("creates an immediate check-in")
    func createsImmediateCheckIn() throws {
        let store = try makeStore()
        let entry = try store.saveLog(body: "Run", eventAt: fixedNow, categoryIDs: [])
        let checkIn = try store.createCheckIn(for: entry, phase: .immediate)
        #expect(checkIn.phase == .immediate)
        #expect(checkIn.dueAt == nil)
        #expect(checkIn.status == .pending)
    }

    @Test("permits only one immediate check-in per log")
    func oneImmediateCheckIn() throws {
        let store = try makeStore()
        let entry = try store.saveLog(body: "Run", eventAt: fixedNow, categoryIDs: [])
        _ = try store.createCheckIn(for: entry, phase: .immediate)
        do { _ = try store.createCheckIn(for: entry, phase: .immediate); Issue.record("Expected immediate duplicate") }
        catch { #expect(error as? ForesightError == .duplicateImmediate) }
    }

    @Test("creates a future delayed check-in")
    func createsDelayedCheckIn() throws {
        let store = try makeStore()
        let entry = try store.saveLog(body: "Run", eventAt: fixedNow, categoryIDs: [])
        let checkIn = try store.createCheckIn(for: entry, phase: .delayed, dueAt: fixedNow.addingTimeInterval(3_600))
        #expect(checkIn.phase == .delayed)
        #expect(checkIn.dueAt == fixedNow.addingTimeInterval(3_600))
    }

    @Test("rejects a past delayed schedule")
    func rejectsPastSchedule() throws {
        let store = try makeStore()
        let entry = try store.saveLog(body: "Run", eventAt: fixedNow, categoryIDs: [])
        do { _ = try store.createCheckIn(for: entry, phase: .delayed, dueAt: fixedNow); Issue.record("Expected invalid schedule") }
        catch { #expect(error as? ForesightError == .invalidSchedule) }
    }

    @Test("permits only one pending delayed check-in per log")
    func onePendingDelayedCheckIn() throws {
        let store = try makeStore()
        let entry = try store.saveLog(body: "Run", eventAt: fixedNow, categoryIDs: [])
        _ = try store.createCheckIn(for: entry, phase: .delayed, dueAt: fixedNow.addingTimeInterval(3_600))
        do { _ = try store.createCheckIn(for: entry, phase: .delayed, dueAt: fixedNow.addingTimeInterval(7_200)); Issue.record("Expected delayed duplicate") }
        catch { #expect(error as? ForesightError == .duplicateDelayed) }
    }

    @Test("answers a check-in with a rating and note")
    func answersCheckIn() throws {
        let store = try makeStore()
        let entry = try store.saveLog(body: "Run", eventAt: fixedNow, categoryIDs: [])
        let checkIn = try store.createCheckIn(for: entry, phase: .immediate)
        try store.answer(checkIn, response: .muchBetter, notSure: false, note: "Good energy", excludedFromAnalysis: false)
        #expect(checkIn.status == .answered)
        #expect(checkIn.overall == .muchBetter)
        #expect(checkIn.note == "Good energy")
    }

    @Test("records a not-sure response without a numeric score")
    func answersNotSure() throws {
        let store = try makeStore()
        let entry = try store.saveLog(body: "Run", eventAt: fixedNow, categoryIDs: [])
        let checkIn = try store.createCheckIn(for: entry, phase: .immediate)
        try store.answer(checkIn, response: nil, notSure: true, note: "Too many variables", excludedFromAnalysis: false)
        #expect(checkIn.status == .notSure)
        #expect(checkIn.overall == nil)
    }

    @Test("edits a completed response")
    func editsResponse() throws {
        let store = try makeStore()
        let entry = try store.saveLog(body: "Run", eventAt: fixedNow, categoryIDs: [])
        let checkIn = try store.createCheckIn(for: entry, phase: .immediate)
        try store.answer(checkIn, response: .aLittleBetter, notSure: false, note: "Fine", excludedFromAnalysis: false)
        try store.answer(checkIn, response: .muchBetter, notSure: false, note: "Great", excludedFromAnalysis: true)
        #expect(checkIn.overall == .muchBetter)
        #expect(checkIn.excludedFromAnalysis)
    }

    @Test("rejects outcome notes longer than five thousand characters")
    func noteLengthLimit() throws {
        let store = try makeStore()
        let entry = try store.saveLog(body: "Run", eventAt: fixedNow, categoryIDs: [])
        let checkIn = try store.createCheckIn(for: entry, phase: .immediate)
        do { try store.answer(checkIn, response: .same, notSure: false, note: String(repeating: "x", count: 5_001), excludedFromAnalysis: false); Issue.record("Expected note error") }
        catch { #expect(error as? ForesightError == .noteTooLong) }
    }

    @Test("skips a delayed check-in")
    func skipsCheckIn() throws {
        let store = try makeStore()
        let entry = try store.saveLog(body: "Run", eventAt: fixedNow, categoryIDs: [])
        let checkIn = try store.createCheckIn(for: entry, phase: .delayed, dueAt: fixedNow.addingTimeInterval(3_600))
        try store.skip(checkIn)
        #expect(checkIn.status == .skipped)
        #expect(checkIn.overall == nil)
        #expect(checkIn.answeredAt == nil)
    }

    @Test("reschedules only a pending delayed check-in")
    func reschedulesCheckIn() throws {
        let store = try makeStore()
        let entry = try store.saveLog(body: "Run", eventAt: fixedNow, categoryIDs: [])
        let checkIn = try store.createCheckIn(for: entry, phase: .delayed, dueAt: fixedNow.addingTimeInterval(3_600))
        try store.reschedule(checkIn, to: fixedNow.addingTimeInterval(7_200))
        #expect(checkIn.dueAt == fixedNow.addingTimeInterval(7_200))
        try store.skip(checkIn)
        do { try store.reschedule(checkIn, to: fixedNow.addingTimeInterval(10_800)); Issue.record("Expected invalid schedule") }
        catch { #expect(error as? ForesightError == .invalidSchedule) }
    }

    @Test("removes a single check-in without deleting its log")
    func removesCheckIn() throws {
        let store = try makeStore()
        let entry = try store.saveLog(body: "Run", eventAt: fixedNow, categoryIDs: [])
        let checkIn = try store.createCheckIn(for: entry, phase: .immediate)
        try store.removeCheckIn(checkIn)
        #expect(store.entries.count == 1)
        #expect(store.checkIns.isEmpty)
    }

    @Test("deletes a log and cascades attached check-ins")
    func cascadeDelete() throws {
        let store = try makeStore()
        let entry = try store.saveLog(body: "Run", eventAt: fixedNow, categoryIDs: [])
        _ = try store.createCheckIn(for: entry, phase: .immediate)
        _ = try store.createCheckIn(for: entry, phase: .delayed, dueAt: fixedNow.addingTimeInterval(3_600))
        try store.deleteEntry(entry)
        #expect(store.entries.isEmpty)
        #expect(store.checkIns.isEmpty)
    }

    @Test("adds idempotent demo history")
    func addsDemoHistory() throws {
        let store = try makeStore()
        try store.addDemoHistory()
        let count = store.entries.count
        try store.addDemoHistory()
        #expect(store.entries.count == count)
        #expect(store.demoDataState() == .complete)
    }

    @Test("removes only demo history")
    func removesDemoHistory() throws {
        let store = try makeStore()
        let ownLog = try store.saveLog(body: "Keep me", eventAt: fixedNow, categoryIDs: [])
        try store.addDemoHistory()
        try store.removeDemoHistory()
        #expect(store.entries.map(\.id) == [ownLog.id])
        #expect(store.checkIns.isEmpty)
        #expect(store.demoDataState() == .none)
    }

    @Test("resets the local store and restores defaults")
    func resetStore() throws {
        let store = try makeStore()
        _ = try store.saveLog(body: "Reset me", eventAt: fixedNow, categoryIDs: [])
        store.resetStore()
        #expect(store.entries.isEmpty)
        #expect(store.categories.count == DefaultCategories.names.count)
    }
}
