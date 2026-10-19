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
    var fireHour: Int { kind == .worse ? max(usualHour - 1, 0) : usualHour }
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
/// the hour the pattern holds, on the kind of day it holds, outside quiet hours, and never for
/// something already logged today.
enum SuggestionNudgePlan {
    static let identifierPrefix = NudgeKind.better.identifierPrefix
    static let threadIdentifier = "nudges"
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
    /// strongest candidate it can, preferring a different category from the day before so it
    /// doesn't repeat. `usedToday` means one of this kind already went out today.
    static func nudges(for candidates: [NudgeCandidate], now: Date, calendar: Calendar, quietHours: QuietHours = .standard, usedToday: Bool) -> [SuggestionNudge] {
        let ranked = candidates
            .filter { !quietHours.contains(hour: $0.fireHour) }
            .sorted { $0.strength != $1.strength ? $0.strength > $1.strength : $0.categoryName < $1.categoryName }
        let today = calendar.startOfDay(for: now)
        var previous: UUID?
        var nudges: [SuggestionNudge] = []

        for offset in 0..<daysAhead {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            if offset == 0 && usedToday { continue }
            let options = ranked.compactMap { candidate -> (NudgeCandidate, Date)? in
                guard let fireAt = calendar.date(bySettingHour: candidate.fireHour, minute: 0, second: 0, of: day), fireAt > now else { return nil }
                if offset == 0 && candidate.loggedToday { return nil }
                if candidate.weekendsOnly && !calendar.isDateInWeekend(day) { return nil }
                return (candidate, fireAt)
            }
            guard let pick = options.first(where: { $0.0.categoryID != previous }) ?? options.first else {
                previous = nil
                continue
            }
            previous = pick.0.categoryID
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
            return abs(fireAt.timeIntervalSince(nudge.fireAt)) >= 1 || existing.body != nudge.body
        }
        return (toAdd, toRemove)
    }
}

/// Remembers when scheduled nudges fire, so a nudge that already went out today
/// still counts after it leaves the pending list. It keeps the wall-clock time the trigger
/// uses, not an instant: after a time zone change the trigger fires at that local time, so
/// the ledger has to read it in the current zone too.
protocol NudgeLedger: AnyObject {
    var fireTimes: [DateComponents] { get set }
}

final class UserDefaultsNudgeLedger: NudgeLedger {
    private let defaults: UserDefaults
    private let key: String
    /// The earlier format stored instants. It is read once, converted, and then removed.
    private let legacyKey: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "suggestionNudgeWallClockTimes"
        legacyKey = "suggestionNudgeFireDates"
    }

    private init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
        legacyKey = nil
    }

    /// Heads-ups keep their own ledger, since they have their own one-a-day budget.
    static func headsUps(defaults: UserDefaults = .standard) -> UserDefaultsNudgeLedger {
        UserDefaultsNudgeLedger(defaults: defaults, key: "headsUpWallClockTimes")
    }

    var fireTimes: [DateComponents] {
        get {
            // Upgrade day: read the old instants as wall-clock times here, so a nudge that
            // already went out today still counts.
            if defaults.object(forKey: key) == nil, let legacyKey, let legacy = defaults.array(forKey: legacyKey) as? [Double] {
                let calendar = Calendar.autoupdatingCurrent
                return legacy.map { calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSinceReferenceDate: $0)) }
            }
            return (defaults.array(forKey: key) as? [[Int]] ?? []).compactMap { parts in
                guard parts.count == 6 else { return nil }
                return DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4], second: parts[5])
            }
        }
        set {
            if let legacyKey { defaults.removeObject(forKey: legacyKey) }
            defaults.set(newValue.map { [$0.year ?? 0, $0.month ?? 0, $0.day ?? 0, $0.hour ?? 0, $0.minute ?? 0, $0.second ?? 0] }, forKey: key)
        }
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
        content.threadIdentifier = SuggestionNudgePlan.threadIdentifier
        let trigger = UNCalendarNotificationTrigger(dateMatching: nudge.wallClock, repeats: false)
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: nudge.identifier, content: content, trigger: trigger))
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
            for ledger in ledgers.values { ledger.fireTimes = [] }
            let delivered = await center.deliveredIdentifiers()
            await center.removeDelivered(delivered.filter(SuggestionNudgePlan.isNudge))
        }
        resync()
    }

    private func reconcile(_ candidates: [NudgeCandidate], now: Date, calendar: Calendar, enabled: Set<NudgeKind>) async {
        let allowed = await center.authorization() == .allowed
        let today = SuggestionNudgePlan.dayKey(now, calendar: calendar)
        let delivered = await center.deliveredIdentifiers()
        var fired: [NudgeKind: [DateComponents]] = [:]
        var desired: [SuggestionNudge] = []
        for kind in NudgeKind.allCases {
            // A nudge whose fire time has passed went out; keep those from today and yesterday.
            // Each is read in the current zone, as its floating trigger was.
            let firedOfKind = (ledgers[kind]?.fireTimes ?? []).compactMap { time in calendar.date(from: time).map { (time, $0) } }
                .filter { $0.1 <= now && $0.1 > now.addingTimeInterval(-2 * 24 * 60 * 60) }
            fired[kind] = firedOfKind.map { $0.0 }
            // One for today already in Notification Center also counts: it covers a floating
            // trigger that fired early after travelling east, and a suspension before the ledger write.
            let usedToday = firedOfKind.contains { calendar.isDate($0.1, inSameDayAs: now) }
                || delivered.contains { $0.hasPrefix(kind.identifierPrefix + today + ".") }
            await center.removeDelivered(SuggestionNudgePlan.staleDelivered(delivered, today: today, enabled: enabled.contains(kind) && allowed, kind: kind))
            if allowed {
                desired += SuggestionNudgePlan.nudges(for: candidates.filter { $0.kind == kind }, now: now, calendar: calendar, quietHours: quietHours(), usedToday: usedToday)
            }
        }
        let changes = SuggestionNudgePlan.changes(desired: desired, scheduled: await center.scheduledReminders())
        await center.removeScheduled(changes.toRemove)
        var failed = Set<String>()
        for nudge in changes.toAdd {
            do { try await center.addNudge(nudge) } catch { failed.insert(nudge.identifier) }
        }
        for (kind, ledger) in ledgers {
            ledger.fireTimes = (fired[kind] ?? []) + desired.filter { $0.kind == kind && !failed.contains($0.identifier) }.map(\.wallClock)
        }
    }
}

struct NudgeResponse: Equatable, Sendable {
    let categoryID: UUID

    init?(requestIdentifier: String, actionIdentifier: String) {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier,
              let categoryID = SuggestionNudgePlan.categoryID(fromIdentifier: requestIdentifier) else { return nil }
        self.categoryID = categoryID
    }
}

extension CheckInReminderRouter {
    /// A tapped nudge or heads-up opens that category's later evidence on Patterns.
    func handle(_ response: NudgeResponse) {
        destination = .evidence(response.categoryID)
    }
}
