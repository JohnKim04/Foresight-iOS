import Foundation
import Observation
import SwiftData
import SwiftUI

@main
struct ForesightApp: App {
    @State private var database = AppDatabase()

    init() {
        if ProcessInfo.processInfo.arguments.contains(OnboardingState.resetArgument) {
            UserDefaults.standard.removeObject(forKey: OnboardingState.completedKey)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let store = database.store, let container = database.container {
                    ForesightRootView(store: store)
                        .modelContainer(container)
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
    private(set) var container: ModelContainer?
    private(set) var store: JournalStore?
    private(set) var errorMessage: String?

    init() { open() }

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
    @State private var tab: AppTab = .journal
    @AppStorage(OnboardingState.completedKey) private var hasCompletedOnboarding = false
    /// Advanced when the next check-in falls due, so the badge appears without any polling.
    @State private var badgeClock = Date.now
    @Environment(\.scenePhase) private var scenePhase

    private var dueCount: Int { dueCheckInCount(store.checkIns, now: badgeClock) }
    private var nextDue: Date? { nextCheckInDueDate(store.checkIns, after: badgeClock) }

    var body: some View {
        ForesightDropdownHost {
            TabView(selection: $tab) {
                JournalRootView(store: store)
                    .tabItem { Label("Journal", systemImage: "book.closed") }
                    .tag(AppTab.journal)
                CheckInRootView(store: store)
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
            // Task.sleep pauses while the app is suspended, so catch up on return.
            if phase == .active { badgeClock = .now }
        }
        .fullScreenCover(isPresented: Binding(get: { !hasCompletedOnboarding }, set: { if !$0 { hasCompletedOnboarding = true } })) {
            OnboardingView { hasCompletedOnboarding = true }
        }
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
