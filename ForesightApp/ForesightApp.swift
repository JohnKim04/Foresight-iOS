import Combine
import Foundation
import Observation
import SwiftData
import SwiftUI
import UIKit
import WidgetKit

@main
struct ForesightApp: App {
    @UIApplicationDelegateAdaptor(ForesightAppDelegate.self) private var appDelegate
    @State private var database = AppDatabase.shared

    init() {
        if ProcessInfo.processInfo.arguments.contains(OnboardingState.resetArgument) {
            UserDefaults.standard.removeObject(forKey: OnboardingState.completedKey)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let store = database.store, let container = database.container {
                    ForesightRootView(store: store, reminders: database.reminders, nudges: database.nudges, router: database.router, preferences: database.preferences)
                        .modelContainer(container)
                        .environment(database.reminders)
                        .environment(database.router)
                } else {
                    StoreRecoveryView(message: database.errorMessage ?? "Your journal could not be opened.") {
                        database.open()
                    } onReset: {
                        database.reset()
                    }
                }
            }
            .tint(Color.foresightSage)
        }
    }
}

@MainActor
@Observable
final class AppDatabase {
    /// Shared so a notification response that launches the app reaches the same store as the UI.
    static let shared = AppDatabase()

    private(set) var container: ModelContainer?
    private(set) var store: JournalStore?
    private(set) var errorMessage: String?
    let reminders: CheckInReminderScheduler
    let nudges: SuggestionNudgeScheduler
    let router: CheckInReminderRouter
    let preferences: NotificationPreferences

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let inMemory = arguments.contains("-in-memory-store")
        let preferences = NotificationPreferences.forLaunch(inMemory: inMemory)
        self.preferences = preferences
        reminders = CheckInReminderScheduler(
            center: inMemory ? InertReminderNotificationCenter() : SystemReminderNotificationCenter(),
            isEnabled: { preferences.remindersEnabled },
            quietHours: { preferences.quietHours }
        )
        nudges = SuggestionNudgeScheduler(
            center: inMemory ? InertReminderNotificationCenter() : SystemReminderNotificationCenter(),
            isEnabled: { preferences.nudgesEnabled },
            quietHours: { preferences.quietHours }
        )
        router = CheckInReminderRouter(reminders: reminders)
        open(inMemory: inMemory)
    }

    func open(inMemory: Bool = ProcessInfo.processInfo.arguments.contains("-in-memory-store")) {
        do {
            let (newContainer, newStore): (ModelContainer, JournalStore)
            if inMemory {
                (newContainer, newStore) = try Self.openStore(at: nil)
            } else {
                (newContainer, newStore) = try SharedJournal.open(groupDirectory: SharedJournal.groupDirectory, appDirectory: SharedJournal.appDirectory) { url in
                    lastStoreURL = url
                    return try Self.openStore(at: url)
                }
            }
            container = newContainer
            store = newStore
            errorMessage = nil
            reminders.attach(to: newStore)
            nudges.attach(to: newStore)
            router.store = newStore
            if !inMemory {
                newStore.onLoaded = { WidgetCenter.shared.reloadAllTimelines() }
                WidgetCenter.shared.reloadAllTimelines()
            }
        } catch {
            container = nil
            store = nil
            errorMessage = error.localizedDescription
        }
    }

    func reset() {
        if let store {
            store.resetStore()
            errorMessage = store.initializationError
        } else {
            // Resetting a build that can't reach the group starts a new journal outside it.
            if SharedJournal.groupDirectory == nil { UserDefaults.standard.removeObject(forKey: SharedJournal.inGroupKey) }
            if let lastStoreURL { SharedJournal.removeStore(at: lastStoreURL) }
            open(inMemory: false)
        }
    }

    /// The store the last open tried, so a reset removes the one that wouldn't open.
    @ObservationIgnored private var lastStoreURL: URL?

    /// A container and a store that loaded, or an error saying why not.
    private static func openStore(at url: URL?) throws -> (ModelContainer, JournalStore) {
        let container = try ForesightPersistence.makeContainer(storeURL: url)
        let store = JournalStore(modelContext: container.mainContext, modelContainer: container)
        if let error = store.initializationError { throw StoreOpenError(message: error) }
        return (container, store)
    }
}

private struct StoreOpenError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum AppTab: Hashable { case journal, checkIns, patterns }

struct ForesightRootView: View {
    let store: JournalStore
    let reminders: CheckInReminderScheduler
    let nudges: SuggestionNudgeScheduler
    let router: CheckInReminderRouter
    let preferences: NotificationPreferences
    @State private var tab: AppTab = .journal
    @State private var showsSettings = false
    @AppStorage(OnboardingState.completedKey) private var hasCompletedOnboarding = false
    /// Advanced when the next check-in falls due, so the badge appears without any polling.
    @State private var badgeClock = Date.now
    @State private var checkInAnswerRequest: CheckInTarget?
    @State private var newLogRequest = false
    @State private var evidenceRequest: UUID?
    @Environment(\.scenePhase) private var scenePhase

    private var dueCount: Int { dueCheckInCount(store.snapshot, now: badgeClock) }
    private var nextDue: Date? { nextCheckInDueDate(store.snapshot, after: badgeClock) }

    var body: some View {
        // Each tab gets its own dropdown host, inside the TabView, so the tab bar counts as
        // safe area and an open panel stops above it instead of running underneath.
        TabView(selection: $tab) {
            ForesightDropdownHost(isActive: tab == .journal) { JournalRootView(store: store, newLogRequest: $newLogRequest) { showsSettings = true } }
                .tabItem { Label("Journal", systemImage: "book.closed") }
                .tag(AppTab.journal)
            ForesightDropdownHost(isActive: tab == .checkIns) { CheckInRootView(store: store, answerRequest: $checkInAnswerRequest) }
                .tabItem { Label("Check In", systemImage: "checkmark.circle") }
                .badge(dueCount)
                .tag(AppTab.checkIns)
            ForesightDropdownHost(isActive: tab == .patterns) { PatternsRootView(store: store, evidenceRequest: $evidenceRequest) }
                .tabItem { Label("Patterns", systemImage: "chart.xyaxis.line") }
                .tag(AppTab.patterns)
        }
        .background(Color.foresightCanvas)
        .task(id: nextDue) {
            guard let nextDue else { return }
            try? await Task.sleep(for: .seconds(max(0, nextDue.timeIntervalSinceNow) + 0.5))
            if !Task.isCancelled { badgeClock = .now }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            // Task.sleep pauses while the app is suspended, so catch up on return.
            badgeClock = .now
            // Catches permission changed in Settings and reminders past the 64-request limit.
            reminders.resync()
            // Suggestions depend on the time of day, so re-plan nudges too.
            nudges.resync()
        }
        // Significant time changes cover time zone changes, daylight saving and midnight.
        // Reminders move with them too, since quiet hours are local times.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification).receive(on: DispatchQueue.main)) { _ in
            reminders.resync()
            nudges.resync()
        }
        // Nudges share the reminders' permission; plan them as soon as it's granted.
        .onChange(of: reminders.authorization) { nudges.resync() }
        .task(id: router.destination) {
            // A reminder tap waits until nothing is presented (onboarding, the editor, any
            // sheet), so it never switches tabs under a modal or replaces unsaved work.
            while let destination = router.destination, !Task.isCancelled {
                if hasCompletedOnboarding && !Self.isPresentingModal() {
                    switch destination {
                    case .checkIns: tab = .checkIns
                    case .answer(let target): tab = .checkIns; checkInAnswerRequest = target
                    case .evidence(let categoryID): tab = .patterns; evidenceRequest = categoryID
                    case .newLog: tab = .journal; newLogRequest = true
                    }
                    router.destination = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        // Widget taps arrive as foresight:// links and go through the same waiting as reminder taps.
        .onOpenURL { url in
            guard let link = ForesightLink(url: url) else { return }
            router.open(link)
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView(store: store, reminders: reminders, nudges: nudges, preferences: preferences)
        }
        .fullScreenCover(isPresented: Binding(get: { !hasCompletedOnboarding }, set: { if !$0 { hasCompletedOnboarding = true } })) {
            OnboardingView { hasCompletedOnboarding = true }
        }
    }
}

extension ForesightRootView {
    static func isPresentingModal() -> Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { $0.isKeyWindow && $0.rootViewController?.presentedViewController != nil }
    }
}

struct StoreRecoveryView: View {
    let message: String
    let onRetry: () -> Void
    let onReset: () -> Void
    @State private var confirmReset = false

    var body: some View {
        VStack(spacing: 18) {
            ForesightMark(size: 54)
            Text("Journal unavailable")
                .font(ForesightType.sectionTitle)
                .foregroundStyle(Color.foresightInk)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Try again", action: onRetry)
                .buttonStyle(ForesightPrimaryButtonStyle())
            Button("Reset local journal", role: .destructive) { confirmReset = true }
                .buttonStyle(ForesightSecondaryButtonStyle())
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.foresightCanvas)
        .alert("Reset local journal?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive, action: onReset)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the unreadable local store and starts Foresight empty.")
        }
    }
}
