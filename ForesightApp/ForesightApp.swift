import Foundation
import Observation
import SwiftData
import SwiftUI
import UIKit

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
                    ForesightRootView(store: store, reminders: database.reminders, router: database.router)
                        .modelContainer(container)
                        .environment(database.reminders)
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
    let router: CheckInReminderRouter

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let center: any ReminderNotificationCenter = arguments.contains("-in-memory-store") ? InertReminderNotificationCenter() : SystemReminderNotificationCenter()
        reminders = CheckInReminderScheduler(center: center)
        router = CheckInReminderRouter(reminders: reminders)
        open(inMemory: arguments.contains("-in-memory-store"))
    }

    func open(inMemory: Bool = ProcessInfo.processInfo.arguments.contains("-in-memory-store")) {
        do {
            let newContainer = try ForesightPersistence.makeContainer(storeURL: inMemory ? nil : Self.storeURL)
            let newStore = JournalStore(modelContext: newContainer.mainContext, modelContainer: newContainer)
            if let error = newStore.initializationError {
                container = nil
                store = nil
                errorMessage = error
            } else {
                container = newContainer
                store = newStore
                errorMessage = nil
                reminders.attach(to: newStore)
                router.store = newStore
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
            do {
                for suffix in ["", "-shm", "-wal"] {
                    let url = URL(fileURLWithPath: Self.storeURL.path + suffix)
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                }
                open(inMemory: false)
            } catch {
                errorMessage = "The journal could not be reset. \(error.localizedDescription)"
            }
        }
    }

    private static var storeURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return directory.appendingPathComponent("Foresight.store")
    }
}

enum AppTab: Hashable { case journal, checkIns, patterns }

struct ForesightRootView: View {
    let store: JournalStore
    let reminders: CheckInReminderScheduler
    let router: CheckInReminderRouter
    @State private var tab: AppTab = .journal
    @AppStorage(OnboardingState.completedKey) private var hasCompletedOnboarding = false
    /// Advanced when the next check-in falls due, so the badge appears without any polling.
    @State private var badgeClock = Date.now
    @State private var checkInAnswerRequest: CheckInTarget?
    @Environment(\.scenePhase) private var scenePhase

    private var dueCount: Int { dueCheckInCount(store.snapshot, now: badgeClock) }
    private var nextDue: Date? { nextCheckInDueDate(store.snapshot, after: badgeClock) }

    var body: some View {
        ForesightDropdownHost {
            TabView(selection: $tab) {
                JournalRootView(store: store)
                    .tabItem { Label("Journal", systemImage: "book.closed") }
                    .tag(AppTab.journal)
                CheckInRootView(store: store, answerRequest: $checkInAnswerRequest)
                    .tabItem { Label("Check In", systemImage: "checkmark.circle") }
                    .badge(dueCount)
                    .tag(AppTab.checkIns)
                PatternsRootView(store: store)
                    .tabItem { Label("Patterns", systemImage: "chart.xyaxis.line") }
                    .tag(AppTab.patterns)
            }
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
        }
        .task(id: router.destination) {
            // A reminder tap waits until nothing is presented (onboarding, the editor, any
            // sheet), so it never switches tabs under a modal or replaces unsaved work.
            while let destination = router.destination, !Task.isCancelled {
                if hasCompletedOnboarding && !Self.isPresentingModal() {
                    tab = .checkIns
                    if case .answer(let target) = destination { checkInAnswerRequest = target }
                    router.destination = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
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
