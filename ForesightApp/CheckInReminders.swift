import Foundation
import Observation
import Synchronization
import UIKit
import UserNotifications

enum ReminderAuthorization: Equatable, Sendable { case notDetermined, denied, allowed }

/// A pending delayed check-in, copied out of SwiftData so it can cross into async work.
struct ReminderSource: Equatable, Sendable {
    let checkInID: UUID
    let dueAt: Date
    let entryBody: String
}

struct CheckInReminder: Equatable, Sendable {
    let identifier: String
    let checkInID: UUID
    let fireAt: Date
    let title: String
    let body: String
    /// The app icon count to show once this fires: every check-in due by then. Nil leaves the
    /// count as it is.
    var badge: Int? = nil
}

/// A notification request that is already scheduled with the system.
struct ScheduledReminder: Equatable, Sendable {
    let identifier: String
    let fireAt: Date?
    let body: String
    var badge: Int? = nil
    /// Which action buttons it shows, as a notification category identifier.
    var categoryIdentifier: String? = nil
}

struct ReminderChanges: Equatable, Sendable {
    var toAdd: [CheckInReminder]
    var toRemove: [String]
}

/// Pure planning rules for check-in reminders. The scheduler applies them to the
/// system notification center; tests exercise them directly.
enum CheckInReminderPlan {
    static let identifierPrefix = "check-in."
    static let categoryIdentifier = "CHECK_IN_DUE"
    static let snoozeActionIdentifier = "CHECK_IN_SNOOZE"
    static let answerActionPrefix = "CHECK_IN_ANSWER_"
    /// The answers a reminder offers as buttons, best first, so the list reads like the scale.
    static let answerActionValues: [OutcomeValue] = [.muchBetter, .aLittleBetter, .same, .aLittleWorse, .muchWorse]
    static let threadIdentifier = "check-ins"
    /// Later answers are relative to before the log, as the in-app check-in says.
    static let title = "Compared with before, how do you feel now?"
    /// The one switch for what a reminder, and a suggestion nudge, says. With it on, the first
    /// line of the log (or the category and its counts) shows, on the lock screen too when
    /// previews are allowed there; off, the text is generic.
    static let showsLogText = true
    static let genericBody = "A check-in is ready."
    /// iOS keeps at most 64 pending local notifications per app, so only the soonest are
    /// scheduled, leaving room for suggestion nudges and heads-ups.
    static let pendingLimit = 64 - SuggestionNudgePlan.daysAhead * NudgeKind.allCases.count
    static let snoozeInterval: TimeInterval = 60 * 60

    static func identifier(for checkInID: UUID) -> String { identifierPrefix + checkInID.uuidString }

    static func answerActionIdentifier(for value: OutcomeValue) -> String { answerActionPrefix + String(value.rawValue) }

    static func answer(fromActionIdentifier identifier: String) -> OutcomeValue? {
        guard identifier.hasPrefix(answerActionPrefix), let rawValue = Int(identifier.dropFirst(answerActionPrefix.count)) else { return nil }
        return OutcomeValue(rawValue: rawValue)
    }

    static func checkInID(fromIdentifier identifier: String) -> UUID? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        return UUID(uuidString: String(identifier.dropFirst(identifierPrefix.count)))
    }

    static func sources(from checkIns: [OutcomeCheckIn]) -> [ReminderSource] {
        checkIns.compactMap { checkIn in
            // Sample history is for looking around in Debug builds; it should never buzz a phone.
            guard checkIn.phase == .delayed, checkIn.status == .pending, !checkIn.isFixture, let dueAt = checkIn.dueAt, let entry = checkIn.entry else { return nil }
            return ReminderSource(checkInID: checkIn.id, dueAt: dueAt, entryBody: entry.body)
        }
    }

    /// A check-in that falls due in quiet hours is reminded about when they end.
    static func reminders(for sources: [ReminderSource], now: Date, quietHours: QuietHours = .off, calendar: Calendar = .autoupdatingCurrent, limit: Int = pendingLimit) -> [CheckInReminder] {
        sources
            .map { (source: $0, fireAt: fireDate(for: $0.dueAt, quietHours: quietHours, calendar: calendar)) }
            .filter { $0.fireAt > now }
            .sorted { ($0.fireAt, $0.source.checkInID.uuidString) < ($1.fireAt, $1.source.checkInID.uuidString) }
            .prefix(limit)
            .map { CheckInReminder(identifier: identifier(for: $0.source.checkInID), checkInID: $0.source.checkInID, fireAt: $0.fireAt, title: title, body: body(for: $0.source.entryBody), badge: dueCount(sources, at: $0.fireAt)) }
    }

    /// How many check-ins are waiting for an answer at `date`, for the app icon.
    static func dueCount(_ sources: [ReminderSource], at date: Date) -> Int {
        sources.filter { $0.dueAt <= date }.count
    }

    /// Calendar triggers have one-second precision. Rounding up means a reminder never fires
    /// before its check-in is due.
    static func fireDate(for dueAt: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: dueAt.timeIntervalSinceReferenceDate.rounded(.up))
    }

    /// Rounds before checking quiet hours, so a check-in due a fraction of a second before
    /// they start doesn't buzz at their first second.
    static func fireDate(for dueAt: Date, quietHours: QuietHours, calendar: Calendar) -> Date {
        fireDate(for: quietHours.deferring(fireDate(for: dueAt), calendar: calendar))
    }

    /// A check-in is due at an instant, not a wall-clock time. Components in UTC, with the
    /// calendar attached, name exactly one instant: no repeated daylight-saving hour, and the
    /// scheduled trigger's next date matches `fireAt`, so reconciling doesn't re-add it.
    static func triggerComponents(for fireAt: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: fireAt)
    }

    static func body(for entryBody: String, showsLogText: Bool = showsLogText) -> String {
        guard showsLogText else { return genericBody }
        let firstLine = entryBody.split(whereSeparator: \.isNewline).first.map(String.init) ?? entryBody
        let line = firstLine.trimmingCharacters(in: .whitespaces)
        guard line.count > 80 else { return line }
        return line.prefix(79).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Diffs the wanted reminders against what is scheduled. Requests that belong to
    /// something other than a check-in are never touched.
    static func changes(desired: [CheckInReminder], scheduled: [ScheduledReminder]) -> ReminderChanges {
        let ours = scheduled.filter { checkInID(fromIdentifier: $0.identifier) != nil }
        let scheduledByID = Dictionary(ours.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let desiredIDs = Set(desired.map(\.identifier))
        let toRemove = Set(ours.map(\.identifier)).subtracting(desiredIDs).sorted()
        let toAdd = desired.filter { reminder in
            guard let existing = scheduledByID[reminder.identifier], let fireAt = existing.fireAt else { return true }
            return abs(fireAt.timeIntervalSince(reminder.fireAt)) >= 1 || existing.body != reminder.body || existing.badge != reminder.badge
        }
        return ReminderChanges(toAdd: toAdd, toRemove: toRemove)
    }

    /// Delivered reminders whose check-in was answered, skipped or deleted, or moved to later,
    /// since a check-in that isn't due yet has nothing to answer.
    static func staleDelivered(_ delivered: [String], dueCheckInIDs: Set<UUID>) -> [String] {
        delivered.filter { identifier in
            guard let checkInID = checkInID(fromIdentifier: identifier) else { return false }
            return !dueCheckInIDs.contains(checkInID)
        }
    }
}

protocol ReminderNotificationCenter: Sendable {
    func authorization() async -> ReminderAuthorization
    func requestAuthorization() async -> Bool
    /// Whether iOS shows the app icon count, which the user can turn off on its own.
    func badgesEnabled() async -> Bool
    func scheduledReminders() async -> [ScheduledReminder]
    func deliveredIdentifiers() async -> [String]
    func add(_ reminder: CheckInReminder) async throws
    func removeScheduled(_ identifiers: [String]) async
    func removeDelivered(_ identifiers: [String]) async
    func setBadgeCount(_ count: Int) async
}

struct SystemReminderNotificationCenter: ReminderNotificationCenter {
    func authorization() async -> ReminderAuthorization {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .allowed
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Set once badges have been asked for again this launch, so every sync doesn't repeat it.
    private static let askedForBadges = Mutex(false)

    /// Permission given before Foresight asked for badges doesn't include them. Asking again
    /// with badges doesn't show a prompt once the user has chosen, so ask once a launch, then check again.
    func badgesEnabled() async -> Bool {
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .authorized, settings.badgeSetting == .notSupported,
           Self.askedForBadges.withLock({ asked in defer { asked = true }; return !asked }) {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            settings = await center.notificationSettings()
        }
        return settings.badgeSetting == .enabled
    }

    func scheduledReminders() async -> [ScheduledReminder] {
        await UNUserNotificationCenter.current().pendingNotificationRequests().map { request in
            ScheduledReminder(
                identifier: request.identifier,
                fireAt: (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate(),
                body: request.content.body,
                badge: request.content.badge?.intValue,
                categoryIdentifier: request.content.categoryIdentifier
            )
        }
    }

    func deliveredIdentifiers() async -> [String] {
        await UNUserNotificationCenter.current().deliveredNotifications().map(\.request.identifier)
    }

    func add(_ reminder: CheckInReminder) async throws {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        content.categoryIdentifier = CheckInReminderPlan.categoryIdentifier
        content.threadIdentifier = CheckInReminderPlan.threadIdentifier
        content.badge = reminder.badge.map { NSNumber(value: $0) }
        let trigger = UNCalendarNotificationTrigger(dateMatching: CheckInReminderPlan.triggerComponents(for: reminder.fireAt), repeats: false)
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger))
    }

    func removeScheduled(_ identifiers: [String]) async {
        guard !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDelivered(_ identifiers: [String]) async {
        guard !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func setBadgeCount(_ count: Int) async {
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }

    /// Answering from the notification records the check-in in the background, without unlocking,
    /// the same way the log text already shows on the lock screen.
    static var checkInActions: [UNNotificationAction] {
        let answers = CheckInReminderPlan.answerActionValues.map { value in
            UNNotificationAction(identifier: CheckInReminderPlan.answerActionIdentifier(for: value), title: value.title, options: [])
        }
        return answers + [UNNotificationAction(identifier: CheckInReminderPlan.snoozeActionIdentifier, title: "Remind me in an hour", options: [])]
    }

    static var categories: Set<UNNotificationCategory> {
        [UNNotificationCategory(identifier: CheckInReminderPlan.categoryIdentifier, actions: checkInActions, intentIdentifiers: [], options: [])]
    }
}

/// Used with `-in-memory-store`: a disposable journal should never leave real reminders
/// behind, and UI tests must not hit the permission prompt.
struct InertReminderNotificationCenter: ReminderNotificationCenter {
    func authorization() async -> ReminderAuthorization { .allowed }
    func requestAuthorization() async -> Bool { true }
    func badgesEnabled() async -> Bool { true }
    func scheduledReminders() async -> [ScheduledReminder] { [] }
    func deliveredIdentifiers() async -> [String] { [] }
    func add(_ reminder: CheckInReminder) async throws { }
    func removeScheduled(_ identifiers: [String]) async { }
    func removeDelivered(_ identifiers: [String]) async { }
    func setBadgeCount(_ count: Int) async { }
}

/// Keeps the system's scheduled reminders in step with the journal's pending check-ins.
/// Every store change triggers a full reconcile, run one at a time, so the two never drift.
@MainActor
@Observable
final class CheckInReminderScheduler {
    private(set) var authorization: ReminderAuthorization = .notDetermined
    /// False when reminders can arrive but iOS keeps the app icon count off, so Settings can say so.
    private(set) var badgesEnabled = true
    @ObservationIgnored private let center: any ReminderNotificationCenter
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: () -> Calendar
    @ObservationIgnored private let isEnabled: () -> Bool
    @ObservationIgnored private let quietHours: () -> QuietHours
    @ObservationIgnored private let laterDefault: () -> LaterCheckInDefault
    @ObservationIgnored private var sources: [ReminderSource] = []
    @ObservationIgnored private var syncTask: Task<Void, Never>?

    /// The app passes the Settings choices in; the defaults (on, never quiet) keep tests plain.
    init(
        center: any ReminderNotificationCenter,
        now: @escaping () -> Date = { .now },
        calendar: @escaping () -> Calendar = { .autoupdatingCurrent },
        isEnabled: @escaping () -> Bool = { true },
        quietHours: @escaping () -> QuietHours = { .off },
        laterDefault: @escaping () -> LaterCheckInDefault = { .standard }
    ) {
        self.center = center
        self.now = now
        self.calendar = calendar
        self.isEnabled = isEnabled
        self.quietHours = quietHours
        self.laterDefault = laterDefault
    }

    /// The later check-in a new log gets before you tap anything.
    var laterCheckInDefault: LaterCheckInDefault { laterDefault() }

    /// When the reminder for a check-in due at `dueAt` will arrive, if quiet hours hold it past
    /// that time. Nil when it arrives on time, or when reminders are off in Settings or iOS and
    /// none will arrive. Before permission is asked, it assumes the reminder will come.
    func reminderHeldByQuietHours(dueAt: Date) -> Date? {
        guard isEnabled(), authorization != .denied else { return nil }
        let fireAt = CheckInReminderPlan.fireDate(for: dueAt, quietHours: quietHours(), calendar: calendar())
        return fireAt.timeIntervalSince(dueAt) >= 60 ? fireAt : nil
    }

    func attach(to store: JournalStore) {
        store.onCheckInsChanged = { [weak self] checkIns in self?.update(from: checkIns) }
        update(from: store.checkIns)
    }

    func update(from checkIns: [OutcomeCheckIn]) {
        sources = CheckInReminderPlan.sources(from: checkIns)
        resync()
    }

    func resync() {
        let previous = syncTask
        syncTask = Task {
            await previous?.value
            // Read the sources when this sync runs, not when it was queued, so an older
            // sync can't treat a newer check-in's delivered reminder as stale.
            await reconcile(sources)
        }
    }

    /// Asks for permission only the first time; afterwards the user's choice stands. With
    /// reminders turned off in Settings, scheduling a check-in doesn't ask; turning a
    /// notification setting on does, through `evenWhenRemindersAreOff`.
    func requestAuthorizationIfNeeded(evenWhenRemindersAreOff: Bool = false) async {
        if evenWhenRemindersAreOff || isEnabled(), await center.authorization() == .notDetermined {
            _ = await center.requestAuthorization()
        }
        resync()
        await waitForPendingWork()
    }

    func waitForPendingWork() async {
        await syncTask?.value
    }

    /// Snooze for when the journal can't be read: re-post the reminder an hour out from the
    /// notification's own text so the nudge isn't lost. The next reconcile, which only runs
    /// once a store is attached, takes over from there.
    func snoozeWithoutStore(checkInID: UUID, body: String) async {
        guard isEnabled() else { return }
        let fireAt = CheckInReminderPlan.fireDate(for: now().addingTimeInterval(CheckInReminderPlan.snoozeInterval), quietHours: quietHours(), calendar: calendar())
        let reminder = CheckInReminder(identifier: CheckInReminderPlan.identifier(for: checkInID), checkInID: checkInID, fireAt: fireAt, title: CheckInReminderPlan.title, body: body)
        try? await center.add(reminder)
    }

    private func reconcile(_ sources: [ReminderSource]) async {
        authorization = await center.authorization()
        let date = now()
        let active = authorization == .allowed && isEnabled()
        if active { badgesEnabled = await center.badgesEnabled() }
        let delivered = await center.deliveredIdentifiers()
        // With reminders turned off, delivered ones go too, as nudges do.
        let due = isEnabled() ? Set(sources.filter { $0.dueAt <= date }.map(\.checkInID)) : []
        await center.removeDelivered(CheckInReminderPlan.staleDelivered(delivered, dueCheckInIDs: due))
        // The icon counts what is waiting now, including check-ins that fell due while
        // reminders couldn't reach the phone; each scheduled reminder raises it as it fires.
        await center.setBadgeCount(active ? CheckInReminderPlan.dueCount(sources, at: date) : 0)
        let desired = active
            ? CheckInReminderPlan.reminders(for: sources, now: date, quietHours: quietHours(), calendar: calendar())
            : []
        let changes = CheckInReminderPlan.changes(desired: desired, scheduled: await center.scheduledReminders())
        await center.removeScheduled(changes.toRemove)
        for reminder in changes.toAdd {
            try? await center.add(reminder)
        }
    }
}

struct ReminderResponse: Equatable, Sendable {
    enum Action: Equatable, Sendable { case open, snooze, answer(OutcomeValue) }

    let checkInID: UUID
    let action: Action
    /// The delivered notification's text, kept so a snooze, or an answer that can't be saved,
    /// can re-post it without the store.
    let body: String

    init?(requestIdentifier: String, actionIdentifier: String, body: String = "") {
        guard let checkInID = CheckInReminderPlan.checkInID(fromIdentifier: requestIdentifier) else { return nil }
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier: action = .open
        case CheckInReminderPlan.snoozeActionIdentifier: action = .snooze
        default:
            guard let value = CheckInReminderPlan.answer(fromActionIdentifier: actionIdentifier) else { return nil }
            action = .answer(value)
        }
        self.checkInID = checkInID
        self.body = body
    }
}

enum ReminderDestination: Equatable {
    case checkIns
    case answer(CheckInTarget)
    /// A category's later evidence on Patterns, from a tapped suggestion nudge or heads-up.
    case evidence(UUID)
    /// A new log, from the widget.
    case newLog
    /// A new log with the category picked, from a nudge's "Log it".
    case newLogInCategory(UUID)
}

/// Turns a tapped, answered or snoozed reminder into app state. The root view consumes `destination`.
@MainActor
@Observable
final class CheckInReminderRouter {
    var destination: ReminderDestination?
    @ObservationIgnored var store: JournalStore?
    /// Handles a nudge's "Less often".
    @ObservationIgnored weak var nudges: SuggestionNudgeScheduler?
    @ObservationIgnored private let reminders: CheckInReminderScheduler
    @ObservationIgnored private let now: () -> Date

    init(reminders: CheckInReminderScheduler, now: @escaping () -> Date = { .now }) {
        self.reminders = reminders
        self.now = now
    }

    func handle(_ response: ReminderResponse) async {
        let checkIn = store?.checkIns.first { $0.id == response.checkInID }
        switch response.action {
        case .open:
            // Only a pending check-in opens its answer sheet; one already answered or skipped
            // (say, from another reminder or on the Check In tab) falls back to the tab.
            if let checkIn, checkIn.status == .pending, let entry = checkIn.entry {
                destination = .answer(CheckInTarget(entryID: entry.id, checkInID: checkIn.id))
            } else {
                destination = .checkIns
            }
        case .snooze:
            guard let store else {
                await reminders.snoozeWithoutStore(checkInID: response.checkInID, body: response.body.isEmpty ? CheckInReminderPlan.genericBody : response.body)
                return
            }
            guard let checkIn, checkIn.status == .pending else { return }
            try? store.reschedule(checkIn, to: now().addingTimeInterval(CheckInReminderPlan.snoozeInterval))
            // A snooze can run with the app in the background; finish scheduling before returning.
            await reminders.waitForPendingWork()
        case .answer(let value):
            guard let store else {
                // The journal can't be read, so the answer has nowhere to go. Ask again in an hour
                // rather than drop the check-in along with the notification.
                await reminders.snoozeWithoutStore(checkInID: response.checkInID, body: response.body.isEmpty ? CheckInReminderPlan.genericBody : response.body)
                return
            }
            // Answered or skipped elsewhere first: that answer stands.
            guard let checkIn, checkIn.status == .pending else { return }
            try? store.answer(checkIn, response: value, notSure: false, note: "", excludedFromAnalysis: false)
            // The app may only be awake for this; clear the reminder before returning.
            await reminders.waitForPendingWork()
        }
    }
}

extension CheckInReminderRouter {
    /// A widget tap. A check-in link opens like a tapped reminder: its answer sheet while it's
    /// still pending, otherwise the Check In tab.
    func open(_ link: ForesightLink) {
        switch link {
        case .newLog: destination = .newLog
        case .checkIns: destination = .checkIns
        case .checkIn(let id):
            let checkIn = store?.checkIns.first { $0.id == id }
            if let checkIn, checkIn.status == .pending, let entry = checkIn.entry {
                destination = .answer(CheckInTarget(entryID: entry.id, checkInID: checkIn.id))
            } else {
                destination = .checkIns
            }
        }
    }
}

final class CheckInReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = CheckInReminderNotificationDelegate { AppDatabase.shared.router }

    private let router: @MainActor @Sendable () -> CheckInReminderRouter

    init(router: @escaping @MainActor @Sendable () -> CheckInReminderRouter) {
        self.router = router
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }

    // UIKit asserts that this completion handler runs on the main thread. The async form of this
    // method finishes on a background thread and crashed the app when a reminder was tapped.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        let (identifier, action, body) = (request.identifier, response.actionIdentifier, request.content.body)
        // The SDK doesn't mark the handler Sendable; it is only called once, on the main actor.
        nonisolated(unsafe) let completion = completionHandler
        Task { @MainActor in
            // An answer or snooze from the notification saves to the journal in the App Group
            // with the app in the background. Ask for time to finish, so iOS doesn't suspend the
            // app while it holds the store's file lock and kill it for that (0xdead10cc).
            let backgroundTime = BackgroundTime(name: "Check-in reminder response")
            await handle(requestIdentifier: identifier, actionIdentifier: action, body: body)
            completion()
            backgroundTime.end()
        }
    }

    /// The part of `didReceive` that doesn't need a system response object, so tests can drive it.
    @MainActor func handle(requestIdentifier: String, actionIdentifier: String, body: String) async {
        if let reminder = ReminderResponse(requestIdentifier: requestIdentifier, actionIdentifier: actionIdentifier, body: body) {
            await router().handle(reminder)
        } else if let nudge = NudgeResponse(requestIdentifier: requestIdentifier, actionIdentifier: actionIdentifier) {
            await router().handle(nudge)
        }
    }
}

/// A background task held while work finishes. Ends once, by `end()` or when the time runs out.
@MainActor
final class BackgroundTime {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            self.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

final class ForesightAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // The delegate has to be set before launch finishes so a tap that launched the app is delivered.
        let center = UNUserNotificationCenter.current()
        center.delegate = CheckInReminderNotificationDelegate.shared
        center.setNotificationCategories(SystemReminderNotificationCenter.categories.union([SystemReminderNotificationCenter.nudgeCategory]))
        return true
    }
}
