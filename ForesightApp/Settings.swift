import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Hours when nothing should buzz. Check-in reminders that fall inside wait until the end;
/// suggestion nudges skip them. A start equal to the end means never quiet.
struct QuietHours: Equatable, Sendable {
    var start: Int
    var end: Int

    static let standard = QuietHours(start: 22, end: 8)
    static let off = QuietHours(start: 0, end: 0)

    func contains(hour: Int) -> Bool {
        start > end ? (hour >= start || hour < end) : (hour >= start && hour < end)
    }

    /// `date` itself when it falls outside quiet hours, otherwise the moment they end.
    func deferring(_ date: Date, calendar: Calendar) -> Date {
        guard contains(hour: calendar.component(.hour, from: date)) else { return date }
        return calendar.nextDate(after: date, matching: DateComponents(hour: end, minute: 0, second: 0), matchingPolicy: .nextTime) ?? date
    }
}

/// The notification choices made on the Settings screen. Nothing observes these keys, so
/// whatever changes one must resync the reminder and nudge schedulers afterwards.
struct NotificationPreferences {
    static let remindersEnabledKey = "checkInRemindersEnabled"
    static let nudgesEnabledKey = "suggestionNudgesEnabled"
    static let quietHoursEnabledKey = "quietHoursEnabled"
    static let quietHoursStartKey = "quietHoursStart"
    static let quietHoursEndKey = "quietHoursEnd"

    let defaults: UserDefaults

    /// A disposable journal (`-in-memory-store`, as UI tests use) gets disposable preferences,
    /// so toggling one in a test never carries over to the next launch.
    static func forLaunch(inMemory: Bool) -> NotificationPreferences {
        guard inMemory else { return NotificationPreferences(defaults: .standard) }
        let suite = "com.foresight.in-memory-preferences"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return NotificationPreferences(defaults: UserDefaults(suiteName: suite) ?? .standard)
    }

    var remindersEnabled: Bool {
        get { bool(Self.remindersEnabledKey, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Self.remindersEnabledKey) }
    }

    var nudgesEnabled: Bool {
        get { bool(Self.nudgesEnabledKey, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Self.nudgesEnabledKey) }
    }

    var quietHoursEnabled: Bool {
        get { bool(Self.quietHoursEnabledKey, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Self.quietHoursEnabledKey) }
    }

    var quietHoursStart: Int {
        get { hour(Self.quietHoursStartKey, default: QuietHours.standard.start) }
        nonmutating set { defaults.set(newValue, forKey: Self.quietHoursStartKey) }
    }

    var quietHoursEnd: Int {
        get { hour(Self.quietHoursEndKey, default: QuietHours.standard.end) }
        nonmutating set { defaults.set(newValue, forKey: Self.quietHoursEndKey) }
    }

    /// The window both schedulers use.
    var quietHours: QuietHours {
        quietHoursEnabled ? QuietHours(start: quietHoursStart, end: quietHoursEnd) : .off
    }

    private func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }

    private func hour(_ key: String, default value: Int) -> Int {
        guard let stored = defaults.object(forKey: key) as? Int, (0..<24).contains(stored) else { return value }
        return stored
    }
}

/// Everything the user wrote, as JSON they can keep or open elsewhere. Sample history is left out.
struct JournalExport: Codable, Equatable, Sendable {
    struct Category: Codable, Equatable, Sendable {
        let id: UUID
        let name: String
        let archivedAt: Date?
    }

    struct CheckIn: Codable, Equatable, Sendable {
        let id: UUID
        let phase: String
        let status: String
        let dueAt: Date?
        let answeredAt: Date?
        /// −2 (much worse) to +2 (much better).
        let response: Int?
        let responseLabel: String?
        let note: String
        let excludedFromAnalysis: Bool
        let createdAt: Date
        let updatedAt: Date
    }

    struct Entry: Codable, Equatable, Sendable {
        let id: UUID
        let body: String
        let eventAt: Date
        let createdAt: Date
        let updatedAt: Date
        let categories: [String]
        let checkIns: [CheckIn]
    }

    static let format = "foresight-journal"

    let format: String
    let version: Int
    let exportedAt: Date
    let categories: [Category]
    let entries: [Entry]

    @MainActor
    init(snapshot: JournalSnapshot, exportedAt: Date) {
        format = Self.format
        version = 1
        self.exportedAt = exportedAt
        categories = snapshot.categories
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { Category(id: $0.id, name: $0.name, archivedAt: $0.archivedAt) }
        entries = snapshot.entries
            .filter { !$0.isFixture }
            .sorted { ($0.eventAt, $0.id.uuidString) < ($1.eventAt, $1.id.uuidString) }
            .map { entry in
                Entry(
                    id: entry.id,
                    body: entry.body,
                    eventAt: entry.eventAt,
                    createdAt: entry.createdAt,
                    updatedAt: entry.updatedAt,
                    categories: entry.categories.map(\.name).sorted(),
                    checkIns: entry.checkIns
                        .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
                        .map { checkIn in
                            CheckIn(
                                id: checkIn.id,
                                phase: checkIn.phase.rawValue,
                                status: checkIn.status.rawValue,
                                dueAt: checkIn.dueAt,
                                answeredAt: checkIn.answeredAt,
                                response: checkIn.overall?.rawValue,
                                responseLabel: checkIn.overall?.title,
                                note: checkIn.note,
                                excludedFromAnalysis: checkIn.excludedFromAnalysis,
                                createdAt: checkIn.createdAt,
                                updatedAt: checkIn.updatedAt
                            )
                        }
                )
            }
    }

    var checkInCount: Int { entries.reduce(0) { $0 + $1.checkIns.count } }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> JournalExport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(JournalExport.self, from: data)
    }
}

extension JournalExport: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { try $0.jsonData() }
            .suggestedFileName("Foresight journal.json")
    }
}
