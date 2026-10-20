import Foundation
import Observation
import UserNotifications

/// Which way a pattern's later check-ins went. Each kind has its own one-a-day budget.
enum NudgeKind: CaseIterable, Sendable {
    /// Often followed by feeling better: a nudge at the usual hour.
    case better
    /// Often followed by feeling worse: a heads-up an hour before the usual hour.
    case worse

    var identifierPrefix: String {
        switch self {
        case .better: "nudge."
        case .worse: "heads-up."
        }
    }
}

/// A suggestion or worse pattern copied out of SwiftData so nudge planning can run in async work.
struct NudgeCandidate: Equatable, Sendable {
    let categoryID: UUID
    let categoryName: String
    let usualHour: Int
    /// Later check-ins that went the pattern's way: better for `.better`, worse for `.worse`.
    let matchingCount: Int
    let numericCount: Int
    let strength: Double
    let loggedToday: Bool
    /// The pattern held mostly on weekends, so weekdays get no nudge for it.
    var weekendsOnly = false
    var kind = NudgeKind.better

    /// A heads-up comes an hour early, so there is time to weigh it before the usual time.
    /// Nil for a heads-up whose usual hour is midnight, which has no earlier hour that day.
    var fireHour: Int? {
        guard kind == .worse else { return usualHour }
        return usualHour > 0 ? usualHour - 1 : nil
    }
}

struct SuggestionNudge: Equatable, Sendable {
    let identifier: String
    let categoryID: UUID
    let fireAt: Date
    /// The wall-clock time the plan picked, in the calendar it planned with. The trigger uses
    /// these without a time zone, so the nudge keeps that local time if the zone changes.
    let wallClock: DateComponents
    let title: String
    let body: String
    var kind = NudgeKind.better
}

/// Nudge copy, kept here so the non-causal wording is covered by tests.
enum SuggestionNudgeCopy {
    enum Style { case specific, generic }

    /// What the lock screen shows. `.generic` keeps category names and counts off it. Follows the
    /// reminders' switch, so one answer sets both.
    static let style: Style = CheckInReminderPlan.showsLogText ? .specific : .generic
    static let title = HelpSuggestionCopy.title

    static func body(categoryName: String, betterCount: Int, numericCount: Int, style: Style = style) -> String {
        switch style {
        case .specific: "\(categoryName) has often been followed by feeling better later: better in \(betterCount) of \(numericCount) later check-ins."
        case .generic: "One of your patterns is worth a look. Tap to see what has tended to be followed by feeling better."
        }
    }

    static let headsUpTitle = "Often followed by feeling worse"

    static func headsUpBody(categoryName: String, worseCount: Int, numericCount: Int, style: Style = style) -> String {
        switch style {
        case .specific: "\(categoryName) has often been followed by feeling worse later: worse or much worse in \(worseCount) of \(numericCount) later check-ins. Something to weigh if it’s coming up."
        case .generic: "One of your patterns has often been followed by feeling worse later. Tap to see which."
        }
    }

    static func title(for kind: NudgeKind) -> String { kind == .worse ? headsUpTitle : Self.title }

    static func body(for candidate: NudgeCandidate) -> String {
        switch candidate.kind {
        case .better: body(categoryName: candidate.categoryName, betterCount: candidate.matchingCount, numericCount: candidate.numericCount)
        case .worse: headsUpBody(categoryName: candidate.categoryName, worseCount: candidate.matchingCount, numericCount: candidate.numericCount)
        }
    }
}

/// Pure planning rules for suggestion nudges and heads-ups: at most one of each a day, around
/// the hour the pattern holds, on the kind of day it holds, outside quiet hours, never for
/// something already logged today, and the same category at most every third day.
enum SuggestionNudgePlan {
    static let identifierPrefix = NudgeKind.better.identifierPrefix
    static let threadIdentifier = "nudges"
    static let headsUpThreadIdentifier = "heads-ups"
    /// Nudges and heads-ups share these actions: "Log it" and "Less often".
    static let categoryIdentifier = "PATTERN_NUDGE"
    static let logActionIdentifier = "NUDGE_LOG_IT"
    static let lessOftenActionIdentifier = "NUDGE_LESS_OFTEN"
    /// A category nudged on one day waits this many days, counting that one, before the next.
    static let cooldownDays = 3
    /// How long "Less often" keeps a category's nudges, or its heads-ups, from coming.
    static let muteInterval: TimeInterval = 14 * 24 * 60 * 60

    /// Heads-ups group apart from feel-better nudges in Notification Center.
    static func threadIdentifier(for kind: NudgeKind) -> String {
        kind == .worse ? headsUpThreadIdentifier : threadIdentifier
    }
    /// Today plus the next two days, so a nudge still arrives if the app isn't opened.
    static let daysAhead = 3

    static func candidates(from report: HelpSuggestionReport) -> [NudgeCandidate] {
        report.suggestions.compactMap { suggestion in
            guard let hour = suggestion.usualHour else { return nil }
            return NudgeCandidate(
                categoryID: suggestion.category.id,
                categoryName: suggestion.category.name,
                usualHour: hour,
                matchingCount: suggestion.betterCount,
                numericCount: suggestion.numericCount,
                strength: suggestion.strength,
                loggedToday: suggestion.loggedToday,
                weekendsOnly: suggestion.mostlyWeekends
            )
        }
    }

    static func candidates(from patterns: [WorsePattern]) -> [NudgeCandidate] {
        patterns.compactMap { pattern in
            guard let hour = pattern.usualHour else { return nil }
            return NudgeCandidate(
                categoryID: pattern.category.id,
                categoryName: pattern.category.name,
                usualHour: hour,
                matchingCount: pattern.worseCount,
                numericCount: pattern.numericCount,
                strength: pattern.strength,
                loggedToday: pattern.loggedToday,
                weekendsOnly: pattern.mostlyWeekends,
                kind: .worse
            )
        }
    }

    static func identifier(day: String, categoryID: UUID, kind: NudgeKind = .better) -> String { kind.identifierPrefix + day + "." + categoryID.uuidString }

    /// Any nudge or heads-up, as opposed to a check-in reminder.
    static func isNudge(_ identifier: String) -> Bool {
        NudgeKind.allCases.contains { identifier.hasPrefix($0.identifierPrefix) }
    }

    static func categoryID(fromIdentifier identifier: String) -> UUID? {
        guard isNudge(identifier) else { return nil }
        return identifier.split(separator: ".").last.flatMap { UUID(uuidString: String($0)) }
    }

    /// Delivered nudges of `kind` for one category, from any day.
    static func delivered(_ delivered: [String], categoryID: UUID, kind: NudgeKind) -> [String] {
        delivered.filter { $0.hasPrefix(kind.identifierPrefix) && Self.categoryID(fromIdentifier: $0) == categoryID }
    }

    /// Delivered nudges of `kind` from an earlier day, or every one of them once that kind is off.
    static func staleDelivered(_ delivered: [String], today: String, enabled: Bool, kind: NudgeKind = .better) -> [String] {
        delivered.filter { identifier in
            guard identifier.hasPrefix(kind.identifierPrefix) else { return false }
            let parts = identifier.split(separator: ".")
            return !enabled || parts.count != 3 || String(parts[1]) < today
        }
    }

    /// Always Gregorian in the plan's zone, so keys compare as dates whatever the system calendar.
    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// One nudge per day for the next few days, from candidates of one kind. Each day takes the
    /// strongest candidate that hasn't had one in the last `cooldownDays` days, so one strong
    /// pattern doesn't send the same sentence every day. `usedToday` means one of this kind
    /// already went out today; `lastNudged` holds the day each category's last one went out;
    /// `muted` categories were turned down with "Less often".
    static func nudges(for candidates: [NudgeCandidate], now: Date, calendar: Calendar, quietHours: QuietHours = .standard, usedToday: Bool, lastNudged: [UUID: Date] = [:], muted: Set<UUID> = [], cooldownDays: Int = SuggestionNudgePlan.cooldownDays) -> [SuggestionNudge] {
        let ranked = candidates
            .filter { candidate in !muted.contains(candidate.categoryID) && (candidate.fireHour.map { !quietHours.contains(hour: $0) } ?? false) }
            .sorted { $0.strength != $1.strength ? $0.strength > $1.strength : $0.categoryName < $1.categoryName }
        let today = calendar.startOfDay(for: now)
        var last = lastNudged.mapValues { calendar.startOfDay(for: $0) }
        var nudges: [SuggestionNudge] = []

        for offset in 0..<daysAhead {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            if offset == 0 && usedToday { continue }
            let options = ranked.compactMap { candidate -> (NudgeCandidate, Date)? in
                guard let hour = candidate.fireHour, let fireAt = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day), fireAt > now else { return nil }
                if offset == 0 && candidate.loggedToday { return nil }
                if candidate.weekendsOnly && !calendar.isDateInWeekend(day) { return nil }
                if let lastDay = last[candidate.categoryID], let gap = calendar.dateComponents([.day], from: lastDay, to: day).day, gap < cooldownDays { return nil }
                return (candidate, fireAt)
            }
            guard let pick = options.first else { continue }
            last[pick.0.categoryID] = day
            nudges.append(SuggestionNudge(
                identifier: identifier(day: dayKey(day, calendar: calendar), categoryID: pick.0.categoryID, kind: pick.0.kind),
                categoryID: pick.0.categoryID,
                fireAt: pick.1,
                wallClock: calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: pick.1),
                title: SuggestionNudgeCopy.title(for: pick.0.kind),
                body: SuggestionNudgeCopy.body(for: pick.0),
                kind: pick.0.kind
            ))
        }
        return nudges
    }

    /// Diffs the wanted nudges against what is scheduled. Check-in reminders are never touched.
    static func changes(desired: [SuggestionNudge], scheduled: [ScheduledReminder]) -> (toAdd: [SuggestionNudge], toRemove: [String]) {
        let ours = scheduled.filter { isNudge($0.identifier) }
        let scheduledByID = Dictionary(ours.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let toRemove = Set(ours.map(\.identifier)).subtracting(desired.map(\.identifier)).sorted()
        let toAdd = desired.filter { nudge in
            guard let existing = scheduledByID[nudge.identifier], let fireAt = existing.fireAt else { return true }
            // One scheduled by an older build has no action buttons; replace it so it gets them.
            return abs(fireAt.timeIntervalSince(nudge.fireAt)) >= 1 || existing.body != nudge.body || existing.categoryIdentifier != SuggestionNudgePlan.categoryIdentifier
        }
        return (toAdd, toRemove)
    }
}

/// A planned nudge's wall-clock time and the category it was for.
struct NudgeFire: Equatable, Sendable {
    var wallClock: DateComponents
    /// Nil for times stored before the ledger kept categories; those count toward the one a
    /// day but not toward any category's cooldown.
    var categoryID: UUID?
}

/// Remembers when scheduled nudges fire and for which category, so a nudge that already went
/// out still counts toward the one a day and the category's cooldown after it leaves the
/// pending list. It keeps the wall-clock time the trigger uses, not an instant: after a time
/// zone change the trigger fires at that local time, so the ledger has to read it in the
/// current zone too. It also holds the categories muted with "Less often".
protocol NudgeLedger: AnyObject {
    var fires: [NudgeFire] { get set }
    /// When each muted category may be nudged again.
    var mutedUntil: [UUID: Date] { get set }
}

final class UserDefaultsNudgeLedger: NudgeLedger {
    private let defaults: UserDefaults
    private let key: String
    private let muteKey: String
    /// Earlier formats: wall-clock times without categories, and before those, instants. Each
    /// is read until the first write, converted, and then removed.
    private let wallClockKey: String
    private let legacyKey: String?

    convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, key: "suggestionNudgeFires", muteKey: "suggestionNudgeMutedUntil", wallClockKey: "suggestionNudgeWallClockTimes", legacyKey: "suggestionNudgeFireDates")
    }

    private init(defaults: UserDefaults, key: String, muteKey: String, wallClockKey: String, legacyKey: String?) {
        self.defaults = defaults
        self.key = key
        self.muteKey = muteKey
        self.wallClockKey = wallClockKey
        self.legacyKey = legacyKey
    }

    /// Heads-ups keep their own ledger, since they have their own one-a-day budget.
    static func headsUps(defaults: UserDefaults = .standard) -> UserDefaultsNudgeLedger {
        UserDefaultsNudgeLedger(defaults: defaults, key: "headsUpFires", muteKey: "headsUpMutedUntil", wallClockKey: "headsUpWallClockTimes", legacyKey: nil)
    }

    var fires: [NudgeFire] {
        get {
            if let stored = defaults.array(forKey: key) as? [[String: Any]] {
                return stored.compactMap { record in
                    guard let time = record["time"] as? [Int], let wallClock = Self.wallClock(time) else { return nil }
                    return NudgeFire(wallClock: wallClock, categoryID: (record["category"] as? String).flatMap(UUID.init(uuidString:)))
                }
            }
            if let times = defaults.array(forKey: wallClockKey) as? [[Int]] {
                return times.compactMap(Self.wallClock).map { NudgeFire(wallClock: $0) }
            }
            // Upgrade day: read the old instants as wall-clock times here, so a nudge that
            // already went out today still counts.
            if let legacyKey, let legacy = defaults.array(forKey: legacyKey) as? [Double] {
                let calendar = Calendar.autoupdatingCurrent
                return legacy.map { NudgeFire(wallClock: calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSinceReferenceDate: $0))) }
            }
            return []
        }
        set {
            defaults.removeObject(forKey: wallClockKey)
            if let legacyKey { defaults.removeObject(forKey: legacyKey) }
            defaults.set(newValue.map { fire -> [String: Any] in
                let time = [fire.wallClock.year ?? 0, fire.wallClock.month ?? 0, fire.wallClock.day ?? 0, fire.wallClock.hour ?? 0, fire.wallClock.minute ?? 0, fire.wallClock.second ?? 0]
                guard let categoryID = fire.categoryID else { return ["time": time] }
                return ["time": time, "category": categoryID.uuidString]
            }, forKey: key)
        }
    }

    var mutedUntil: [UUID: Date] {
        get {
            let stored = defaults.dictionary(forKey: muteKey) as? [String: Double] ?? [:]
            return Dictionary(stored.compactMap { key, value in UUID(uuidString: key).map { ($0, Date(timeIntervalSinceReferenceDate: value)) } }, uniquingKeysWith: { max($0, $1) })
        }
        set {
            defaults.set(Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.uuidString, $0.value.timeIntervalSinceReferenceDate) }), forKey: muteKey)
        }
    }

    private static func wallClock(_ parts: [Int]) -> DateComponents? {
        guard parts.count == 6 else { return nil }
        return DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4], second: parts[5])
    }
}

protocol NudgeNotificationCenter: Sendable {
    func authorization() async -> ReminderAuthorization
    func scheduledReminders() async -> [ScheduledReminder]
    func deliveredIdentifiers() async -> [String]
    func addNudge(_ nudge: SuggestionNudge) async throws
    func removeScheduled(_ identifiers: [String]) async
    func removeDelivered(_ identifiers: [String]) async
}

extension SystemReminderNotificationCenter: NudgeNotificationCenter {
    func addNudge(_ nudge: SuggestionNudge) async throws {
        let content = UNMutableNotificationContent()
        content.title = nudge.title
        content.body = nudge.body
        content.sound = .default
        content.threadIdentifier = SuggestionNudgePlan.threadIdentifier(for: nudge.kind)
        content.categoryIdentifier = SuggestionNudgePlan.categoryIdentifier
        let trigger = UNCalendarNotificationTrigger(dateMatching: nudge.wallClock, repeats: false)
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: nudge.identifier, content: content, trigger: trigger))
    }
}

extension SystemReminderNotificationCenter {
    /// "Log it" opens the app on a new log; "Less often" mutes the category without opening it.
    static var nudgeCategory: UNNotificationCategory {
        UNNotificationCategory(identifier: SuggestionNudgePlan.categoryIdentifier, actions: [
            UNNotificationAction(identifier: SuggestionNudgePlan.logActionIdentifier, title: "Log it", options: [.foreground]),
            UNNotificationAction(identifier: SuggestionNudgePlan.lessOftenActionIdentifier, title: "Less often", options: []),
        ], intentIdentifiers: [], options: [])
    }
}

extension InertReminderNotificationCenter: NudgeNotificationCenter {
    func addNudge(_ nudge: SuggestionNudge) async throws { }
}

/// Keeps scheduled nudges and heads-ups in step with the journal's patterns. It never asks for
/// permission: check-in reminders own that prompt, and nudges follow whatever was chosen.
@MainActor
final class SuggestionNudgeScheduler {
    private let center: any NudgeNotificationCenter
    private let ledgers: [NudgeKind: any NudgeLedger]
    private let now: () -> Date
    private let calendar: () -> Calendar
    private let isEnabled: () -> Bool
    private let headsUpsEnabled: () -> Bool
    private let quietHours: () -> QuietHours
    private weak var store: JournalStore?
    private var syncTask: Task<Void, Never>?

    init(
        center: any NudgeNotificationCenter,
        ledger: any NudgeLedger = UserDefaultsNudgeLedger(),
        headsUpLedger: any NudgeLedger = UserDefaultsNudgeLedger.headsUps(),
        now: @escaping () -> Date = { .now },
        calendar: @escaping () -> Calendar = { .autoupdatingCurrent },
        isEnabled: @escaping () -> Bool = { true },
        headsUpsEnabled: @escaping () -> Bool = { true },
        quietHours: @escaping () -> QuietHours = { .standard }
    ) {
        self.center = center
        ledgers = [.better: ledger, .worse: headsUpLedger]
        self.now = now
        self.calendar = calendar
        self.isEnabled = isEnabled
        self.headsUpsEnabled = headsUpsEnabled
        self.quietHours = quietHours
    }

    func attach(to store: JournalStore) {
        self.store = store
        store.onJournalChanged = { [weak self] _ in self?.resync() }
        store.onReset = { [weak self] in self?.journalWasReset() }
        resync()
    }

    /// Recomputes patterns for the current time and zone and reschedules. Call on
    /// foreground, after a time zone or permission change, and after a preference changes.
    func resync() {
        let date = now()
        let calendar = self.calendar()
        var enabled: Set<NudgeKind> = []
        if isEnabled() { enabled.insert(.better) }
        if headsUpsEnabled() { enabled.insert(.worse) }
        var candidates: [NudgeCandidate] = []
        if let store, !enabled.isEmpty {
            // Sample history never drives real notifications, as with reminders.
            let entries = store.entries.filter { !$0.isFixture }
            let checkIns = store.checkIns.filter { !$0.isFixture }
            if enabled.contains(.better) {
                let report = helpSuggestions(entries: entries, checkIns: checkIns, categories: store.categories, now: date, calendar: calendar, limit: .max)
                candidates += SuggestionNudgePlan.candidates(from: report)
            }
            if enabled.contains(.worse) {
                candidates += SuggestionNudgePlan.candidates(from: worsePatterns(entries: entries, checkIns: checkIns, categories: store.categories, now: date, calendar: calendar))
            }
        }
        let previous = syncTask
        syncTask = Task {
            await previous?.value
            await reconcile(candidates, now: date, calendar: calendar, enabled: enabled)
        }
    }

    func waitForPendingWork() async {
        await syncTask?.value
    }

    /// After the journal is erased: forget which nudges went out and clear any still in
    /// Notification Center, since their categories no longer exist.
    func journalWasReset() {
        let previous = syncTask
        let center = self.center
        syncTask = Task {
            // Clear after any sync already running, which would otherwise write old entries back.
            await previous?.value
            for ledger in ledgers.values {
                ledger.fires = []
                ledger.mutedUntil = [:]
            }
            let delivered = await center.deliveredIdentifiers()
            await center.removeDelivered(delivered.filter(SuggestionNudgePlan.isNudge))
        }
        resync()
    }

    /// "Less often": no nudges of `kind` for the category for two weeks, starting with any
    /// already scheduled, and its ones still in Notification Center go too. Finishes before it
    /// returns, since the app may only be awake for this.
    func lessOften(categoryID: UUID, kind: NudgeKind) async {
        guard let ledger = ledgers[kind] else { return }
        ledger.mutedUntil[categoryID] = now().addingTimeInterval(SuggestionNudgePlan.muteInterval)
        resync()
        let previous = syncTask
        let center = self.center
        syncTask = Task {
            await previous?.value
            let delivered = await center.deliveredIdentifiers()
            await center.removeDelivered(SuggestionNudgePlan.delivered(delivered, categoryID: categoryID, kind: kind))
        }
        await waitForPendingWork()
    }

    private func reconcile(_ candidates: [NudgeCandidate], now: Date, calendar: Calendar, enabled: Set<NudgeKind>) async {
        let allowed = await center.authorization() == .allowed
        let today = SuggestionNudgePlan.dayKey(now, calendar: calendar)
        let delivered = await center.deliveredIdentifiers()
        // Fires from the cooldown's earlier days are kept, so a category waits its turn.
        let keepSince = calendar.date(byAdding: .day, value: 1 - SuggestionNudgePlan.cooldownDays, to: calendar.startOfDay(for: now)) ?? now
        var fired: [NudgeKind: [NudgeFire]] = [:]
        var desired: [SuggestionNudge] = []
        for kind in NudgeKind.allCases {
            guard let ledger = ledgers[kind] else { continue }
            // A nudge whose fire time has passed went out. Each is read in the current zone, as
            // its floating trigger was.
            let firedOfKind = ledger.fires.compactMap { fire in calendar.date(from: fire.wallClock).map { (fire, $0) } }
                .filter { $0.1 <= now && $0.1 >= keepSince }
            fired[kind] = firedOfKind.map { $0.0 }
            // One for today already in Notification Center also counts: it covers a floating
            // trigger that fired early after travelling east, and a suspension before the ledger write.
            let deliveredToday = delivered.filter { $0.hasPrefix(kind.identifierPrefix + today + ".") }
            let usedToday = firedOfKind.contains { calendar.isDate($0.1, inSameDayAs: now) } || !deliveredToday.isEmpty
            var lastNudged: [UUID: Date] = [:]
            for (fire, date) in firedOfKind {
                guard let categoryID = fire.categoryID else { continue }
                lastNudged[categoryID] = max(lastNudged[categoryID] ?? date, date)
            }
            for categoryID in deliveredToday.compactMap(SuggestionNudgePlan.categoryID(fromIdentifier:)) {
                lastNudged[categoryID] = max(lastNudged[categoryID] ?? now, now)
            }
            let mutes = ledger.mutedUntil
            let activeMutes = mutes.filter { $0.value > now }
            if activeMutes.count != mutes.count { ledger.mutedUntil = activeMutes }
            await center.removeDelivered(SuggestionNudgePlan.staleDelivered(delivered, today: today, enabled: enabled.contains(kind) && allowed, kind: kind))
            if allowed {
                desired += SuggestionNudgePlan.nudges(for: candidates.filter { $0.kind == kind }, now: now, calendar: calendar, quietHours: quietHours(), usedToday: usedToday, lastNudged: lastNudged, muted: Set(activeMutes.keys))
            }
        }
        let changes = SuggestionNudgePlan.changes(desired: desired, scheduled: await center.scheduledReminders())
        await center.removeScheduled(changes.toRemove)
        var failed = Set<String>()
        for nudge in changes.toAdd {
            do { try await center.addNudge(nudge) } catch { failed.insert(nudge.identifier) }
        }
        for (kind, ledger) in ledgers {
            ledger.fires = (fired[kind] ?? []) + desired.filter { $0.kind == kind && !failed.contains($0.identifier) }.map { NudgeFire(wallClock: $0.wallClock, categoryID: $0.categoryID) }
        }
    }
}

struct NudgeResponse: Equatable, Sendable {
    enum Action: Equatable, Sendable { case open, logIt, lessOften }

    let categoryID: UUID
    let kind: NudgeKind
    let action: Action

    init?(requestIdentifier: String, actionIdentifier: String) {
        guard let categoryID = SuggestionNudgePlan.categoryID(fromIdentifier: requestIdentifier),
              let kind = NudgeKind.allCases.first(where: { requestIdentifier.hasPrefix($0.identifierPrefix) }) else { return nil }
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier: action = .open
        case SuggestionNudgePlan.logActionIdentifier: action = .logIt
        case SuggestionNudgePlan.lessOftenActionIdentifier: action = .lessOften
        default: return nil
        }
        self.categoryID = categoryID
        self.kind = kind
    }
}

extension CheckInReminderRouter {
    /// A tapped nudge or heads-up opens that category's later evidence on Patterns; "Log it"
    /// opens a new log with the category picked; "Less often" mutes the category for two weeks.
    func handle(_ response: NudgeResponse) async {
        switch response.action {
        case .open: destination = .evidence(response.categoryID)
        case .logIt: destination = .newLogInCategory(response.categoryID)
        case .lessOften: await nudges?.lessOften(categoryID: response.categoryID, kind: response.kind)
        }
    }
}
