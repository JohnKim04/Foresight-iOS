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
        } catch {
            initializationError = "Your journal could not be opened. \(error.localizedDescription)"
        }
    }

    func resetStore() {
        do {
            try modelContext.fetch(FetchDescriptor<OutcomeCheckIn>()).forEach(modelContext.delete)
            try modelContext.fetch(FetchDescriptor<JournalEntry>()).forEach(modelContext.delete)
            try modelContext.fetch(FetchDescriptor<JournalCategory>()).forEach(modelContext.delete)
            try modelContext.save()
            reload()
        } catch {
            initializationError = "The journal could not be reset. \(error.localizedDescription)"
        }
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
