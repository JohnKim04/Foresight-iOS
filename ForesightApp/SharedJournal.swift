import Foundation
import SwiftData

// Compiled into the app and the widget extension. Keep it to Foundation and SwiftData.

/// Where the journal's store lives. With the App Group entitlement (a signed build) it sits in the
/// group container so the widget can read it; without one (unsigned simulator builds, or a team
/// that can't use App Groups) it stays in the app's own Application Support and the widget asks
/// the user to open the app.
enum SharedJournal {
    static let appGroupInfoKey = "ForesightAppGroup"
    static let storeFileName = "Foresight.store"
    /// SQLite keeps a store in up to three files; they move together.
    static let storeFileSuffixes = ["", "-shm", "-wal"]

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

    /// The store the app opens. Call once, before any container is made.
    static func appStoreURL() -> URL {
        resolveStoreURL(groupDirectory: groupDirectory, appDirectory: appDirectory)
    }

    /// Picks the group store when there is a group, first moving a journal that an earlier build
    /// kept in the app's own directory. The move copies every file before removing any, so a
    /// failure part way leaves the old store where it was, and the app keeps using it.
    static func resolveStoreURL(groupDirectory: URL?, appDirectory: URL, fileManager: FileManager = .default) -> URL {
        let appStore = appDirectory.appending(path: storeFileName)
        guard let groupDirectory else { return appStore }
        let groupStore = groupDirectory.appending(path: storeFileName)
        guard !fileManager.fileExists(atPath: groupStore.path), fileManager.fileExists(atPath: appStore.path) else { return groupStore }
        let moves = storeFileSuffixes
            .map { (from: URL(fileURLWithPath: appStore.path + $0), to: URL(fileURLWithPath: groupStore.path + $0)) }
            .filter { fileManager.fileExists(atPath: $0.from.path) }
        do {
            try fileManager.createDirectory(at: groupDirectory, withIntermediateDirectories: true)
            for move in moves {
                if fileManager.fileExists(atPath: move.to.path) { try fileManager.removeItem(at: move.to) }
                try fileManager.copyItem(at: move.from, to: move.to)
            }
        } catch {
            moves.forEach { try? fileManager.removeItem(at: $0.to) }
            return appStore
        }
        moves.forEach { try? fileManager.removeItem(at: $0.from) }
        return groupStore
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
