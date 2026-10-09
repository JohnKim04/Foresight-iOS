import Foundation
import Observation
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
}

/// A notification request that is already scheduled with the system.
struct ScheduledReminder: Equatable, Sendable {
    let identifier: String
    let fireAt: Date?
    let body: String
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
    static let threadIdentifier = "check-ins"
    static let title = "How did this affect you?"
    /// The one switch for what a reminder, and a suggestion nudge, says. With it on, the first
    /// line of the log (or the category and its counts) shows, on the lock screen too when
    /// previews are allowed there; off, the text is generic.
    static let showsLogText = true
    static let genericBody = "A check-in is ready."
    /// iOS keeps at most 64 pending local notifications per app, so only the soonest are
    /// scheduled, leaving room for suggestion nudges.
    static let pendingLimit = 64 - SuggestionNudgePlan.daysAhead
    static let snoozeInterval: TimeInterval = 60 * 60

    static func identifier(for checkInID: UUID) -> String { identifierPrefix + checkInID.uuidString }

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

    static func reminders(for sources: [ReminderSource], now: Date, limit: Int = pendingLimit) -> [CheckInReminder] {
        sources
            .map { (source: $0, fireAt: fireDate(for: $0.dueAt)) }
            .filter { $0.fireAt > now }
            .sorted { ($0.fireAt, $0.source.checkInID.uuidString) < ($1.fireAt, $1.source.checkInID.uuidString) }
            .prefix(limit)
            .map { CheckInReminder(identifier: identifier(for: $0.source.checkInID), checkInID: $0.source.checkInID, fireAt: $0.fireAt, title: title, body: body(for: $0.source.entryBody)) }
    }

    /// Calendar triggers have one-second precision. Rounding up means a reminder never fires
    /// before its check-in is due.
    static func fireDate(for dueAt: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: dueAt.timeIntervalSinceReferenceDate.rounded(.up))
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
            return abs(fireAt.timeIntervalSince(reminder.fireAt)) >= 1 || existing.body != reminder.body
        }
        return ReminderChanges(toAdd: toAdd, toRemove: toRemove)
    }

    /// Delivered reminders whose check-in was answered, skipped or deleted.
    static func staleDelivered(_ delivered: [String], pendingCheckInIDs: Set<UUID>) -> [String] {
        delivered.filter { identifier in
            guard let checkInID = checkInID(fromIdentifier: identifier) else { return false }
            return !pendingCheckInIDs.contains(checkInID)
        }
    }
}

protocol ReminderNotificationCenter: Sendable {
    func authorization() async -> ReminderAuthorization
    func requestAuthorization() async -> Bool
    func scheduledReminders() async -> [ScheduledReminder]
    func deliveredIdentifiers() async -> [String]
    func add(_ reminder: CheckInReminder) async throws
    func removeScheduled(_ identifiers: [String]) async
    func removeDelivered(_ identifiers: [String]) async
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
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func scheduledReminders() async -> [ScheduledReminder] {
        await UNUserNotificationCenter.current().pendingNotificationRequests().map { request in
            ScheduledReminder(
                identifier: request.identifier,
                fireAt: (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate(),
                body: request.content.body
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
        let components = Calendar.current.dateComponents([.timeZone, .year, .month, .day, .hour, .minute, .second], from: reminder.fireAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
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

    static var categories: Set<UNNotificationCategory> {
        let snooze = UNNotificationAction(identifier: CheckInReminderPlan.snoozeActionIdentifier, title: "Remind me in an hour", options: [])
        return [UNNotificationCategory(identifier: CheckInReminderPlan.categoryIdentifier, actions: [snooze], intentIdentifiers: [], options: [])]
    }
}

/// Used with `-in-memory-store`: a disposable journal should never leave real reminders
/// behind, and UI tests must not hit the permission prompt.
struct InertReminderNotificationCenter: ReminderNotificationCenter {
    func authorization() async -> ReminderAuthorization { .allowed }
    func requestAuthorization() async -> Bool { true }
    func scheduledReminders() async -> [ScheduledReminder] { [] }
    func deliveredIdentifiers() async -> [String] { [] }
    func add(_ reminder: CheckInReminder) async throws { }
    func removeScheduled(_ identifiers: [String]) async { }
    func removeDelivered(_ identifiers: [String]) async { }
}

/// Keeps the system's scheduled reminders in step with the journal's pending check-ins.
/// Every store change triggers a full reconcile, run one at a time, so the two never drift.
@MainActor
@Observable
final class CheckInReminderScheduler {
    private(set) var authorization: ReminderAuthorization = .notDetermined
    @ObservationIgnored private let center: any ReminderNotificationCenter
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var sources: [ReminderSource] = []
    @ObservationIgnored private var syncTask: Task<Void, Never>?

    init(center: any ReminderNotificationCenter, now: @escaping () -> Date = { .now }) {
        self.center = center
        self.now = now
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

    /// Asks for permission only the first time; afterwards the user's choice stands.
    func requestAuthorizationIfNeeded() async {
        if await center.authorization() == .notDetermined {
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
        let fireAt = CheckInReminderPlan.fireDate(for: now().addingTimeInterval(CheckInReminderPlan.snoozeInterval))
        let reminder = CheckInReminder(identifier: CheckInReminderPlan.identifier(for: checkInID), checkInID: checkInID, fireAt: fireAt, title: CheckInReminderPlan.title, body: body)
        try? await center.add(reminder)
    }

    private func reconcile(_ sources: [ReminderSource]) async {
        authorization = await center.authorization()
        let delivered = await center.deliveredIdentifiers()
        await center.removeDelivered(CheckInReminderPlan.staleDelivered(delivered, pendingCheckInIDs: Set(sources.map(\.checkInID))))
        let desired = authorization == .allowed ? CheckInReminderPlan.reminders(for: sources, now: now()) : []
        let changes = CheckInReminderPlan.changes(desired: desired, scheduled: await center.scheduledReminders())
        await center.removeScheduled(changes.toRemove)
        for reminder in changes.toAdd {
            try? await center.add(reminder)
        }
    }
}

struct ReminderResponse: Equatable, Sendable {
    enum Action: Equatable, Sendable { case open, snooze }

    let checkInID: UUID
    let action: Action
    /// The delivered notification's text, kept so a snooze can re-post it without the store.
    let body: String

    init?(requestIdentifier: String, actionIdentifier: String, body: String = "") {
        guard let checkInID = CheckInReminderPlan.checkInID(fromIdentifier: requestIdentifier) else { return nil }
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier: action = .open
        case CheckInReminderPlan.snoozeActionIdentifier: action = .snooze
        default: return nil
        }
        self.checkInID = checkInID
        self.body = body
    }
}

enum ReminderDestination: Equatable {
    case checkIns
    case answer(CheckInTarget)
    /// A category's later evidence on Patterns, from a tapped suggestion nudge.
    case evidence(UUID)
}

/// Turns a tapped or snoozed reminder into app state. The root view consumes `destination`.
@MainActor
@Observable
final class CheckInReminderRouter {
    var destination: ReminderDestination?
    @ObservationIgnored var store: JournalStore?
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
            if let checkIn, let entry = checkIn.entry {
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
        [.banner, .list, .sound]
    }

    // UIKit asserts that this completion handler runs on the main thread. The async form of this
    // method finishes on a background thread and crashed the app when a reminder was tapped.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        let (identifier, action, body) = (request.identifier, response.actionIdentifier, request.content.body)
        // The SDK doesn't mark the handler Sendable; it is only called once, on the main actor.
        nonisolated(unsafe) let completion = completionHandler
        Task { @MainActor in
            await handle(requestIdentifier: identifier, actionIdentifier: action, body: body)
            completion()
        }
    }

    /// The part of `didReceive` that doesn't need a system response object, so tests can drive it.
    @MainActor func handle(requestIdentifier: String, actionIdentifier: String, body: String) async {
        if let reminder = ReminderResponse(requestIdentifier: requestIdentifier, actionIdentifier: actionIdentifier, body: body) {
            await router().handle(reminder)
        } else if let nudge = NudgeResponse(requestIdentifier: requestIdentifier, actionIdentifier: actionIdentifier) {
            router().handle(nudge)
        }
    }
}

final class ForesightAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // The delegate has to be set before launch finishes so a tap that launched the app is delivered.
        let center = UNUserNotificationCenter.current()
        center.delegate = CheckInReminderNotificationDelegate.shared
        center.setNotificationCategories(SystemReminderNotificationCenter.categories)
        return true
    }
}
