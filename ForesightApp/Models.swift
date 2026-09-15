import Foundation
import SwiftData

enum OutcomePhase: String, Codable, CaseIterable, Identifiable {
    case immediate
    case delayed

    var id: String { rawValue }
    var title: String { self == .immediate ? "Right after" : "Later" }
}

enum OutcomeStatus: String, Codable, CaseIterable, Identifiable {
    case pending
    case answered
    case notSure
    case skipped

    var id: String { rawValue }
}

enum OutcomeValue: Int, Codable, CaseIterable, Identifiable {
    case muchWorse = -2
    case aLittleWorse = -1
    case same = 0
    case aLittleBetter = 1
    case muchBetter = 2

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .muchWorse: "Much worse"
        case .aLittleWorse: "A little worse"
        case .same: "About the same"
        case .aLittleBetter: "A little better"
        case .muchBetter: "Much better"
        }
    }

    var shortTitle: String {
        switch self {
        case .muchWorse: "−2"
        case .aLittleWorse: "−1"
        case .same: "0"
        case .aLittleBetter: "+1"
        case .muchBetter: "+2"
        }
    }
}

@Model
final class JournalCategory {
    @Attribute(.unique) var id: UUID
    var name: String
    var archivedAt: Date?
    var entries: [JournalEntry] = []

    init(id: UUID = UUID(), name: String, archivedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.archivedAt = archivedAt
    }

    var isArchived: Bool { archivedAt != nil }
}

@Model
final class JournalEntry {
    @Attribute(.unique) var id: UUID
    var body: String
    var eventAt: Date
    var createdAt: Date
    var updatedAt: Date
    var isFixture: Bool
    @Relationship(inverse: \JournalCategory.entries) var categories: [JournalCategory] = []
    @Relationship(deleteRule: .cascade, inverse: \OutcomeCheckIn.entry) var checkIns: [OutcomeCheckIn] = []

    init(id: UUID = UUID(), body: String, eventAt: Date, createdAt: Date = .now, updatedAt: Date = .now, categories: [JournalCategory] = [], isFixture: Bool = false) {
        self.id = id
        self.body = body
        self.eventAt = eventAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.categories = categories
        self.isFixture = isFixture
    }
}

@Model
final class OutcomeCheckIn {
    @Attribute(.unique) var id: UUID
    var phase: OutcomePhase
    var status: OutcomeStatus
    var dueAt: Date?
    var answeredAt: Date?
    var overall: OutcomeValue?
    var note: String
    var excludedFromAnalysis: Bool
    var createdAt: Date
    var updatedAt: Date
    var isFixture: Bool
    var entry: JournalEntry?

    init(
        id: UUID = UUID(),
        entry: JournalEntry,
        phase: OutcomePhase,
        status: OutcomeStatus = .pending,
        dueAt: Date? = nil,
        answeredAt: Date? = nil,
        overall: OutcomeValue? = nil,
        note: String = "",
        excludedFromAnalysis: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isFixture: Bool = false
    ) {
        self.id = id
        self.entry = entry
        self.phase = phase
        self.status = status
        self.dueAt = dueAt
        self.answeredAt = answeredAt
        self.overall = overall
        self.note = note
        self.excludedFromAnalysis = excludedFromAnalysis
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isFixture = isFixture
    }

    var isNumericResponse: Bool { status == .answered && overall != nil && !excludedFromAnalysis }
    var responseSummary: String {
        if status == .notSure { return "Not sure yet" }
        if status == .answered, let overall { return overall.title }
        return "No response yet"
    }
}

struct JournalSnapshot {
    var entries: [JournalEntry]
    var categories: [JournalCategory]
    var checkIns: [OutcomeCheckIn]
}

enum ForesightError: LocalizedError, Equatable {
    case emptyEntry
    case entryTooLong
    case noteTooLong
    case invalidSchedule
    case missingEntry
    case missingCheckIn
    case duplicateImmediate
    case duplicateDelayed
    case duplicateCategory
    case emptyCategory
    case missingCategory

    var errorDescription: String? {
        switch self {
        case .emptyEntry: "A journal entry needs text."
        case .entryTooLong: "Keep the journal entry under 5,000 characters."
        case .noteTooLong: "Keep the note under 5,000 characters."
        case .invalidSchedule: "Choose a future check-in time."
        case .missingEntry: "That journal entry no longer exists."
        case .missingCheckIn: "That outcome check-in no longer exists."
        case .duplicateImmediate: "This log already has an immediate check-in."
        case .duplicateDelayed: "This log already has a scheduled check-in."
        case .duplicateCategory: "That category already exists."
        case .emptyCategory: "A category needs a name."
        case .missingCategory: "That category no longer exists."
        }
    }
}

enum DefaultCategories {
    static let names = ["Workout", "Alcohol", "Social", "Scrolling", "Sleep", "Work"]
}
