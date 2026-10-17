import Foundation
import SwiftData

// Compiled into the app and the widget extension. Keep it to Foundation and SwiftData.

/// Where the journal's store lives. With the App Group entitlement (a signed device build) it sits
/// in the group container so the widget can read it; on a device without one (a team that can't
/// use App Groups) it stays in the app's own Application Support and the widget asks the user to
/// open the app. The simulator hands out a group container even to unsigned builds.
enum SharedJournal {
    static let appGroupInfoKey = "ForesightAppGroup"
    static let storeFileName = "Foresight.store"
    /// SQLite keeps a store in up to three files; they move together.
    static let storeFileSuffixes = ["", "-shm", "-wal"]
    /// Set once the journal has opened from the group container. From then on the group copy is
    /// the journal, and the app-directory copy (if any is left) is not.
    static let inGroupKey = "journalIsInAppGroup"
    /// Set while the app-directory journal is being copied into the group, so a group store left
    /// by an interrupted copy can be told apart from a journal that was already there.
    static let copyingKey = "journalCopyIntoAppGroupStarted"
    static let backupPrefix = "Foresight-backup-"

    static var appGroupIdentifier: String? {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: appGroupInfoKey) as? String,
              !identifier.isEmpty, !identifier.contains("$(") else { return nil }
        return identifier
    }

    /// Application Support inside the group container, when this build may use the group.
    static var groupDirectory: URL? {
        guard let identifier = appGroupIdentifier,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else { return nil }
        return container.appending(path: "Library/Application Support", directoryHint: .isDirectory)
    }

    static var appDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    }

    /// The store the widget reads, or nil when the journal isn't shared with it.
    static var sharedStoreURL: URL? { groupDirectory?.appending(path: storeFileName) }

    /// Opens the journal with `open`, moving it into the group container on the way.
    ///
    /// Until the group copy has opened once, the app-directory store is the journal: each launch
    /// copies it afresh over whatever an interrupted earlier attempt left in the group, and only
    /// deletes it after the group copy opens. If the group copy won't open, it is thrown away and
    /// the app-directory store opens instead, to be tried again next launch.
    ///
    /// A journal already in the group that this copy didn't start (say, one a build without App
    /// Groups was reset away from) is moved to a backup beside it, never overwritten.
    static func open<Value>(
        groupDirectory: URL?,
        appDirectory: URL,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        using open: (URL) throws -> Value
    ) throws -> Value {
        let appStore = appDirectory.appending(path: storeFileName)
        let inGroup = defaults.bool(forKey: inGroupKey)
        guard let groupDirectory else {
            // A journal that moved to the group is unreachable now; don't start an empty one over it.
            if inGroup { throw SharedJournalError.groupUnreachable }
            return try open(appStore)
        }
        let groupStore = groupDirectory.appending(path: storeFileName)
        if !inGroup, fileManager.fileExists(atPath: appStore.path) {
            if !defaults.bool(forKey: copyingKey), fileManager.fileExists(atPath: groupStore.path) {
                // Not ours to replace. If it can't be moved aside, keep using the app-directory store.
                do {
                    try backUpStore(at: groupStore, fileManager: fileManager)
                } catch {
                    return try open(appStore)
                }
            }
            defaults.set(true, forKey: copyingKey)
            do {
                try copyStore(from: appStore, to: groupStore, fileManager: fileManager)
            } catch {
                removeStore(at: groupStore, fileManager: fileManager)
                defaults.removeObject(forKey: copyingKey)
                return try open(appStore)
            }
            let value: Value
            do {
                value = try open(groupStore)
            } catch {
                removeStore(at: groupStore, fileManager: fileManager)
                defaults.removeObject(forKey: copyingKey)
                return try open(appStore)
            }
            defaults.set(true, forKey: inGroupKey)
            defaults.removeObject(forKey: copyingKey)
            removeStore(at: appStore, fileManager: fileManager)
            return value
        }
        let value = try open(groupStore)
        defaults.set(true, forKey: inGroupKey)
        // A copy left behind by a launch that ended between opening the group and cleaning up.
        removeStore(at: appStore, fileManager: fileManager)
        return value
    }

    /// Copies the write-ahead log first and the main file last, through a temporary name and a
    /// rename, so a main file in the group is never half-written.
    static func copyStore(from source: URL, to destination: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        removeStore(at: destination, fileManager: fileManager)
        for suffix in ["-wal", "-shm"] where fileManager.fileExists(atPath: source.path + suffix) {
            try fileManager.copyItem(at: URL(fileURLWithPath: source.path + suffix), to: URL(fileURLWithPath: destination.path + suffix))
        }
        let partial = URL(fileURLWithPath: destination.path + ".partial")
        try fileManager.copyItem(at: source, to: partial)
        try fileManager.moveItem(at: partial, to: destination)
    }

    /// Moves a store's files to `Foresight-backup-<time>.store` in the same directory, main file
    /// last so a backup never has a main file without its log. Returns the backup's URL.
    @discardableResult
    static func backUpStore(at url: URL, date: Date = .now, fileManager: FileManager = .default) throws -> URL {
        let stamp = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted).dateSeparator(.omitted))
        var backup = url.deletingLastPathComponent().appending(path: "\(backupPrefix)\(stamp).store")
        var attempt = 1
        while storeFileSuffixes.contains(where: { fileManager.fileExists(atPath: backup.path + $0) }) {
            attempt += 1
            backup = url.deletingLastPathComponent().appending(path: "\(backupPrefix)\(stamp)-\(attempt).store")
        }
        for suffix in ["-wal", "-shm", ""] where fileManager.fileExists(atPath: url.path + suffix) {
            try fileManager.moveItem(at: URL(fileURLWithPath: url.path + suffix), to: URL(fileURLWithPath: backup.path + suffix))
        }
        try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + ".partial"))
        return backup
    }

    static func removeStore(at url: URL, fileManager: FileManager = .default) {
        for suffix in storeFileSuffixes + [".partial"] {
            try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
}

enum SharedJournalError: LocalizedError, Equatable {
    case groupUnreachable

    var errorDescription: String? {
        "Your journal is in Foresight's shared App Group, which this build can't reach. Turn App Groups back on in signing, or reset to start an empty journal on this build."
    }
}

/// Links into the app, from the widget.
enum ForesightLink: Equatable, Sendable {
    case newLog
    case checkIns
    case checkIn(UUID)

    static let scheme = "foresight"

    var url: URL {
        switch self {
        case .newLog: URL(string: "\(Self.scheme)://log")!
        case .checkIns: URL(string: "\(Self.scheme)://check-in")!
        case .checkIn(let id): URL(string: "\(Self.scheme)://check-in/\(id.uuidString)")!
        }
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        switch (url.host() ?? "", path.count) {
        case ("log", 0): self = .newLog
        case ("check-in", 0): self = .checkIns
        case ("check-in", 1):
            guard let id = UUID(uuidString: path[0]) else { return nil }
            self = .checkIn(id)
        default: return nil
        }
    }
}

/// A later check-in as the widget shows it, copied out of SwiftData.
struct CheckInWidgetItem: Equatable, Sendable {
    let checkInID: UUID
    let dueAt: Date
    /// The log's first line.
    let text: String
}

struct CheckInWidgetState: Equatable, Sendable {
    /// Waiting for an answer, oldest due first.
    var due: [CheckInWidgetItem]
    /// When the next one that isn't due yet falls due.
    var nextDueAt: Date?

    static let empty = CheckInWidgetState(due: [], nextDueAt: nil)
}

/// Pure rules for the check-ins widget. It counts what the Check In tab's badge counts.
enum CheckInWidgetPlan {
    /// A timeline holds at most this many entries; the app reloads it on every journal change.
    static let entryLimit = 24

    static func items(from checkIns: [OutcomeCheckIn]) -> [CheckInWidgetItem] {
        checkIns.compactMap { checkIn in
            guard checkIn.phase == .delayed, checkIn.status == .pending, let dueAt = checkIn.dueAt, let entry = checkIn.entry else { return nil }
            let firstLine = entry.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? entry.body
            return CheckInWidgetItem(checkInID: checkIn.id, dueAt: dueAt, text: firstLine.trimmingCharacters(in: .whitespaces))
        }
    }

    /// The check-ins in the journal at `storeURL`, or nil when the widget can't read it: no shared
    /// App Group, no journal there yet, or a store that won't open. It never writes or migrates
    /// the journal; the app reloads every timeline after each change.
    static func loadItems(storeURL: URL?) -> [CheckInWidgetItem]? {
        guard let storeURL else { return nil }
        // No journal in the group: the app hasn't opened since install, or keeps its journal outside
        // the group. Ask for the app to be opened, and don't create a journal here.
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return nil }
        do {
            let container = try ForesightPersistence.makeContainer(storeURL: storeURL, allowsSave: false)
            let context = ModelContext(container)
            return items(from: try context.fetch(FetchDescriptor<OutcomeCheckIn>()))
        } catch {
            return nil
        }
    }

    static func state(for items: [CheckInWidgetItem], at date: Date) -> CheckInWidgetState {
        let due = items.filter { $0.dueAt <= date }.sorted { ($0.dueAt, $0.checkInID.uuidString) < ($1.dueAt, $1.checkInID.uuidString) }
        return CheckInWidgetState(due: due, nextDueAt: items.map(\.dueAt).filter { $0 > date }.min())
    }

    /// Now, then each moment another check-in falls due.
    static func entryDates(for items: [CheckInWidgetItem], now: Date) -> [Date] {
        let upcoming = Set(items.map(\.dueAt).filter { $0 > now }).sorted()
        return [now] + upcoming.prefix(entryLimit - 1)
    }
}
