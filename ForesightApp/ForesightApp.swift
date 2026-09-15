import Foundation
import Observation
import SwiftData
import SwiftUI

@main
struct ForesightApp: App {
    @State private var database = AppDatabase()

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
            let schema = Schema([JournalEntry.self, JournalCategory.self, OutcomeCheckIn.self])
            let configuration: ModelConfiguration
            if inMemory {
                configuration = ModelConfiguration("Foresight", schema: schema, isStoredInMemoryOnly: true, allowsSave: true, cloudKitDatabase: .none)
            } else {
                try FileManager.default.createDirectory(at: Self.storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                configuration = ModelConfiguration("Foresight", schema: schema, url: Self.storeURL, allowsSave: true, cloudKitDatabase: .none)
            }
            let newContainer = try ModelContainer(for: schema, configurations: [configuration])
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

    var body: some View {
        TabView(selection: $tab) {
            JournalRootView(store: store)
                .tabItem { Label("Journal", systemImage: "book.closed") }
                .tag(AppTab.journal)
            CheckInRootView(store: store)
                .tabItem { Label("Check In", systemImage: "checkmark.circle") }
                .tag(AppTab.checkIns)
            PatternsRootView(store: store)
                .tabItem { Label("Patterns", systemImage: "chart.xyaxis.line") }
                .tag(AppTab.patterns)
        }
        .background(Color.foresightCream)
    }
}

struct StoreRecoveryView: View {
    let message: String
    let onRetry: () -> Void
    let onReset: () -> Void
    @State private var confirmReset = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 42))
                .foregroundStyle(Color.foresightSage)
            Text("Journal unavailable")
                .font(.system(.title2, design: .serif).weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Try again", action: onRetry)
                .buttonStyle(.borderedProminent)
            Button("Reset local journal", role: .destructive) { confirmReset = true }
                .buttonStyle(.bordered)
        }
        .padding(32)
        .alert("Reset local journal?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive, action: onReset)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the unreadable local store and starts Foresight empty.")
        }
    }
}
