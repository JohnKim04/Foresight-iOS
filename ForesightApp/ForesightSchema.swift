import Foundation
import SwiftData

// MARK: - Schema versions
//
// Foresight's SwiftData store is versioned so a journal kept on a phone survives every new build.
// SwiftData identifies a store's version by the shape of its models, finds the matching entry in
// `ForesightMigrationPlan.schemas`, and runs the stages from there up to the newest version.
//
// Adding a stored property:
//
// 1. While the newest version has not been installed on a real device yet (V1 is in this state
//    until the first phone install), edit the model in Models.swift directly. Give the property a
//    default value or make it optional, and add its name to `versionOneShape` in
//    ForesightSchemaTests. A simulator store made by an earlier build will no longer
//    match and opens on the recovery screen; "Reset local journal" clears it.
// 2. Once the newest version has shipped to a device it is frozen. To change it:
//    a. Copy the current model classes from Models.swift into a new `extension ForesightSchemaV1`
//       file (SchemaV1Models.swift) so V1 keeps its exact shipped shape.
//    b. Add `enum ForesightSchemaV2: VersionedSchema` below with version 2.0.0, change
//       `extension ForesightSchemaV1` in Models.swift to `extension ForesightSchemaV2`, and make
//       the change there.
//    c. Point `ForesightSchemaLatest` at V2, append V2 to `schemas`, and append
//       `.lightweight(fromVersion: ForesightSchemaV1.self, toVersion: ForesightSchemaV2.self)` to
//       `stages`. New optional or defaulted properties, new models and deleted properties are all
//       lightweight; a rename needs `@Attribute(originalName:)`; a value transform needs `.custom`.
//    d. Add a case to ForesightSchemaTests that opens a store written by the previous version.
//
// New @Model types go in `models` of the newest version and in `JournalStore.resetStore()`.
// Stored enums (OutcomePhase, OutcomeStatus, OutcomeValue) persist their raw values: adding a case
// is safe, renaming or removing a raw value is a data migration.

enum ForesightSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [JournalEntry.self, JournalCategory.self, OutcomeCheckIn.self]
    }
}

typealias ForesightSchemaLatest = ForesightSchemaV1
typealias JournalEntry = ForesightSchemaLatest.JournalEntry
typealias JournalCategory = ForesightSchemaLatest.JournalCategory
typealias OutcomeCheckIn = ForesightSchemaLatest.OutcomeCheckIn

enum ForesightMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [ForesightSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

// MARK: - Containers

enum ForesightPersistence {
    static var schema: Schema { Schema(versionedSchema: ForesightSchemaLatest.self) }

    /// Opens the store at `url`, migrating it to the newest schema version, or an in-memory store when `url` is nil.
    static func makeContainer(storeURL url: URL?) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            configuration = ModelConfiguration("Foresight", schema: schema, url: url, allowsSave: true, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration("Foresight", schema: schema, isStoredInMemoryOnly: true, allowsSave: true, cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, migrationPlan: ForesightMigrationPlan.self, configurations: [configuration])
    }
}
