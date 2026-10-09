import Foundation
import SwiftData
import Testing
@testable import Foresight

@MainActor
struct ForesightSchemaTests {
    private func temporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ForesightSchemaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Foresight.store")
    }

    @Test("the migration plan ends at the newest schema version, in increasing order")
    func migrationPlanShape() {
        let versions = ForesightMigrationPlan.schemas.map(\.versionIdentifier)
        #expect(versions.last == ForesightSchemaLatest.versionIdentifier)
        #expect(versions == versions.sorted())
        #expect(ForesightMigrationPlan.stages.count == ForesightMigrationPlan.schemas.count - 1)
    }

    @Test("a journal saved on disk is still there when the store is reopened")
    func reopensOnDiskStore() throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let eventAt = Date(timeIntervalSince1970: 1_725_000_000)

        do {
            let container = try ForesightPersistence.makeContainer(storeURL: url)
            let store = JournalStore(modelContext: container.mainContext, modelContainer: container, now: { eventAt })
            let workout = try #require(store.categories.first { $0.name == "Workout" })
            let entry = try store.saveLog(body: "Morning run", eventAt: eventAt, categoryIDs: [workout.id])
            let checkIn = try store.createCheckIn(for: entry, phase: .immediate)
            try store.answer(checkIn, response: .aLittleBetter, notSure: false, note: "", excludedFromAnalysis: false)
        }

        let reopened = try ForesightPersistence.makeContainer(storeURL: url)
        let entries = try reopened.mainContext.fetch(FetchDescriptor<JournalEntry>())
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.body == "Morning run")
        #expect(entry.categories.map(\.name) == ["Workout"])
        #expect(entry.checkIns.first?.overall == .aLittleBetter)
    }

    @Test("a store written before schema versioning opens as version 1")
    func opensUnversionedStore() throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        do {
            // This is how AppDatabase opened the store before ForesightMigrationPlan existed.
            let schema = Schema([JournalEntry.self, JournalCategory.self, OutcomeCheckIn.self])
            let configuration = ModelConfiguration("Foresight", schema: schema, url: url, allowsSave: true, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            container.mainContext.insert(JournalEntry(body: "Written before versioning", eventAt: .now))
            try container.mainContext.save()
        }

        let reopened = try ForesightPersistence.makeContainer(storeURL: url)
        let entries = try reopened.mainContext.fetch(FetchDescriptor<JournalEntry>())
        #expect(entries.map(\.body) == ["Written before versioning"])
    }
}
