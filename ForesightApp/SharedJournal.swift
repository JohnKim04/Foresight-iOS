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
    /// Backups kept beside the journal; older ones are deleted as a new one is made.
    static let backupLimit = 3
    /// Ends the name of a backup the app took on its own, before ".store".
    static let automaticBackupSuffix = "-auto"
    /// The app takes an automatic backup when the newest one is at least this old.
    static let automaticBackupInterval: TimeInterval = 24 * 60 * 60
    /// An automatic backup never removes a backup made another way (a restore's safety copy, or a
    /// journal moved aside at launch) until it is this old, so a daily backup can't push one out
    /// before the user has had a chance to find it in Settings.
    static let protectedBackupAge: TimeInterval = 7 * 24 * 60 * 60
    /// No automatic backup is taken while the journal holds under half the logs of the newest
    /// backup, when that one is automatic and younger than this: three days of backups of a
    /// journal mostly deleted by mistake would otherwise push out every good copy. After this
    /// long the smaller journal is taken to be on purpose, and backups resume.
    static let shrunkJournalPause: TimeInterval = 30 * 24 * 60 * 60

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
        defaults.removeObject(forKey: copyingKey)
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

    /// The time in a backup's name, in UTC, to the second.
    static let backupStampStyle = Date.ISO8601FormatStyle().year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted).dateSeparator(.omitted)

    /// A backup beside the journal, and when it was made.
    struct Backup: Equatable, Sendable {
        let url: URL
        let date: Date
        /// Taken by the app on its own, once a day, rather than by a restore or at launch.
        var isAutomatic = false
    }

    /// A free `Foresight-backup-<time>.store` name beside the store at `url`, ending in
    /// `-auto.store` for an automatic backup.
    static func newBackupURL(beside url: URL, date: Date = .now, automatic: Bool = false, fileManager: FileManager = .default) -> URL {
        let stamp = date.formatted(backupStampStyle)
        let ending = (automatic ? automaticBackupSuffix : "") + ".store"
        var backup = url.deletingLastPathComponent().appending(path: "\(backupPrefix)\(stamp)\(ending)")
        var attempt = 1
        while storeFileSuffixes.contains(where: { fileManager.fileExists(atPath: backup.path + $0) }) {
            attempt += 1
            backup = url.deletingLastPathComponent().appending(path: "\(backupPrefix)\(stamp)-\(attempt)\(ending)")
        }
        return backup
    }

    /// Moves a store's files to `Foresight-backup-<time>.store` in the same directory, main file
    /// last so a backup never has a main file without its log. If a move fails, the ones already
    /// made are undone. Only the newest `backupLimit` backups are kept. Returns the backup's URL.
    @discardableResult
    static func backUpStore(at url: URL, date: Date = .now, fileManager: FileManager = .default) throws -> URL {
        let backup = newBackupURL(beside: url, date: date, fileManager: fileManager)
        var moved: [String] = []
        do {
            for suffix in ["-wal", "-shm", ""] where fileManager.fileExists(atPath: url.path + suffix) {
                try fileManager.moveItem(at: URL(fileURLWithPath: url.path + suffix), to: URL(fileURLWithPath: backup.path + suffix))
                moved.append(suffix)
            }
        } catch {
            // Put back what moved, so the store stays whole where it was.
            for suffix in moved {
                try? fileManager.moveItem(at: URL(fileURLWithPath: backup.path + suffix), to: URL(fileURLWithPath: url.path + suffix))
            }
            throw error
        }
        try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + ".partial"))
        pruneBackups(in: url.deletingLastPathComponent(), sparing: [backup], fileManager: fileManager)
        return backup
    }

    /// The backups in `directory`, newest first by the time in their names.
    static func backups(in directory: URL, fileManager: FileManager = .default) -> [Backup] {
        sortedBackupNames(in: directory, fileManager: fileManager).map { name in
            let url = directory.appending(path: name)
            let date = (try? backupStampStyle.parse(backupStamp(of: name).stamp))
                ?? ((try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)
                ?? .distantPast
            return Backup(url: url, date: date, isAutomatic: backupStamp(of: name).automatic)
        }
    }

    /// Whether the app should take an automatic backup now: none of `backups` is an automatic one
    /// from the last `automaticBackupInterval`. One dated after `now` (a clock that moved
    /// backward) doesn't count, so backups resume instead of waiting for the clock to catch up.
    static func isAutomaticBackupDue(among backups: [Backup], now: Date) -> Bool {
        !backups.contains { $0.isAutomatic && $0.date <= now && now.timeIntervalSince($0.date) < automaticBackupInterval }
    }

    /// The backups (from `backups`, newest first) to delete so one more fits within `keeping`,
    /// or nil when it can't fit. Only automatic backups, and others at least `protectedBackupAge`
    /// old, may go, oldest first.
    static func backupsRemovedForAutomaticBackup(from backups: [Backup], now: Date, keeping: Int = backupLimit) -> [Backup]? {
        let excess = backups.count + 1 - keeping
        guard excess > 0 else { return [] }
        let removable = backups.reversed().filter { $0.isAutomatic || now.timeIntervalSince($0.date) >= protectedBackupAge }
        guard removable.count >= excess else { return nil }
        return Array(removable.prefix(excess))
    }

    /// Whether a journal of `logCount` logs has shrunk to under half of `newest` (the newest
    /// backup, holding `newestLogCount` logs) since it was taken, so no automatic backup should
    /// replace the copies from before. Only an automatic `newest` counts: a restore's safety copy
    /// or a journal moved aside marks a change the user chose. See `shrunkJournalPause`.
    static func hasShrunk(logCount: Int, since newest: Backup?, newestLogCount: Int?, now: Date) -> Bool {
        guard let newest, newest.isAutomatic, let newestLogCount, now.timeIntervalSince(newest.date) < shrunkJournalPause else { return false }
        return logCount * 2 < newestLogCount
    }

    /// Writes a store with `write` under a temporary name beside `url`, then moves its files to
    /// `url`, main file last, so a listing of backups never sees one half-written.
    static func writeStore(at url: URL, fileManager: FileManager = .default, using write: (URL) throws -> Void) throws {
        let partial = URL(fileURLWithPath: url.path + ".partial")
        removeStore(at: partial, fileManager: fileManager)
        do {
            try write(partial)
            for suffix in ["-wal", "-shm", ""] where fileManager.fileExists(atPath: partial.path + suffix) {
                try fileManager.moveItem(atPath: partial.path + suffix, toPath: url.path + suffix)
            }
        } catch {
            removeStore(at: partial, fileManager: fileManager)
            removeStore(at: url, fileManager: fileManager)
            throw error
        }
    }

    /// Deletes what `writeStore` left of backups it never finished, say when the app was closed mid-write.
    static func removeUnfinishedBackups(in directory: URL, fileManager: FileManager = .default) {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(backupPrefix) && name.contains(".store.partial") {
            try? fileManager.removeItem(at: directory.appending(path: name))
        }
    }

    /// Makes room for the automatic backup just written at `url` by deleting what
    /// `backupsRemovedForAutomaticBackup` names. If there is no room after all (say, a restore
    /// filled the slots while it was being written), the new backup goes instead. Returns whether
    /// it was kept.
    @discardableResult
    static func finishAutomaticBackup(at url: URL, now: Date, fileManager: FileManager = .default) -> Bool {
        let others = backups(in: url.deletingLastPathComponent(), fileManager: fileManager).filter { $0.url.lastPathComponent != url.lastPathComponent }
        guard let removed = backupsRemovedForAutomaticBackup(from: others, now: now) else {
            removeStore(at: url, fileManager: fileManager)
            return false
        }
        removed.forEach { removeStore(at: $0.url, fileManager: fileManager) }
        return true
    }

    /// Deletes all but the newest `keeping` backups in `directory`, newest by the time in their names.
    /// `sparing` (say, the backup just made) are always kept and count toward `keeping`, even if a
    /// clock that moved backward gave them older names than the rest.
    static func pruneBackups(in directory: URL, keeping: Int = backupLimit, sparing spared: [URL] = [], fileManager: FileManager = .default) {
        let sparedNames = Set(spared.map { $0.lastPathComponent })
        let names = sortedBackupNames(in: directory, fileManager: fileManager)
        let sparedCount = names.filter { sparedNames.contains($0) }.count
        for name in names.filter({ !sparedNames.contains($0) }).dropFirst(max(0, keeping - sparedCount)) {
            removeStore(at: directory.appending(path: name), fileManager: fileManager)
        }
    }

    private static func sortedBackupNames(in directory: URL, fileManager: FileManager) -> [String] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix(backupPrefix) && $0.hasSuffix(".store") }
            .map { name -> (name: String, stamp: String, attempt: Int) in
                let parsed = backupStamp(of: name)
                return (name, parsed.stamp, parsed.attempt)
            }
            .sorted { $0.stamp != $1.stamp ? $0.stamp > $1.stamp : $0.attempt > $1.attempt }
            .map { $0.name }
    }

    /// "Foresight-backup-<stamp>.store", or "-<stamp>-<attempt>.store" for one made in the same
    /// second, either of them with "-auto" before ".store" for an automatic backup.
    private static func backupStamp(of name: String) -> (stamp: String, attempt: Int, automatic: Bool) {
        var base = name.dropFirst(backupPrefix.count).dropLast(".store".count)
        let automatic = base.hasSuffix(automaticBackupSuffix)
        if automatic { base = base.dropLast(automaticBackupSuffix.count) }
        let parts = base.split(separator: "-")
        return (String(parts.first ?? ""), parts.count > 1 ? Int(parts[1]) ?? 1 : 1, automatic)
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
