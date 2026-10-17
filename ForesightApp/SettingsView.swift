import SwiftUI
import UIKit

/// Notification choices, quiet hours, and the user's data. Opened from the Journal header.
struct SettingsView: View {
    let store: JournalStore
    let reminders: CheckInReminderScheduler
    let nudges: SuggestionNudgeScheduler
    let preferences: NotificationPreferences

    @State private var remindersEnabled: Bool
    @State private var nudgesEnabled: Bool
    @State private var quietHoursEnabled: Bool
    @State private var quietStart: Int
    @State private var quietEnd: Int
    @State private var confirmErase = false
    @State private var confirmRemoveSample = false
    @State private var message: String?
    /// Kept apart from `message` so it shows under the button that caused it.
    @State private var sampleMessage: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(store: JournalStore, reminders: CheckInReminderScheduler, nudges: SuggestionNudgeScheduler, preferences: NotificationPreferences) {
        self.store = store
        self.reminders = reminders
        self.nudges = nudges
        self.preferences = preferences
        _remindersEnabled = State(initialValue: preferences.remindersEnabled)
        _nudgesEnabled = State(initialValue: preferences.nudgesEnabled)
        _quietHoursEnabled = State(initialValue: preferences.quietHoursEnabled)
        _quietStart = State(initialValue: preferences.quietHoursStart)
        _quietEnd = State(initialValue: preferences.quietHoursEnd)
    }

    private var export: JournalExport { JournalExport(snapshot: store.snapshot, exportedAt: .now) }

    var body: some View {
        NavigationStack {
            Form {
                notificationsSection
                quietHoursSection
                categoriesSection
                dataSection
                #if ENABLE_DEVELOPMENT_FIXTURES
                sampleDataSection
                #endif
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.foresightCanvas)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            // Picks up a permission changed in iOS Settings while this screen was away.
            .task { reminders.resync() }
            .onChange(of: remindersEnabled) { _, isOn in
                preferences.remindersEnabled = isOn
                preferencesChanged(turnedOn: isOn)
            }
            .onChange(of: nudgesEnabled) { _, isOn in
                preferences.nudgesEnabled = isOn
                preferencesChanged(turnedOn: isOn)
            }
            .onChange(of: quietHoursEnabled) { _, isOn in
                preferences.quietHoursEnabled = isOn
                preferencesChanged()
            }
            .onChange(of: quietStart) { _, hour in
                preferences.quietHoursStart = hour
                preferencesChanged()
            }
            .onChange(of: quietEnd) { _, hour in
                preferences.quietHoursEnd = hour
                preferencesChanged()
            }
            .alert("Remove sample history?", isPresented: $confirmRemoveSample) {
                Button("Remove", role: .destructive) {
                    do { try store.removeDemoHistory(); sampleMessage = "Sample history removed. Your own logs were kept." }
                    catch { sampleMessage = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) { }
            } message: { Text("All sample logs and check-ins will be removed. Your own logs and check-ins will stay.") }
            .alert("Erase your journal?", isPresented: $confirmErase) {
                Button("Erase", role: .destructive, action: erase)
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This deletes every log, check-in and category you added on this device and can't be undone. The starter categories come back. Export first if you want a copy.")
            }
        }
    }

    private var notificationsSection: some View {
        Section {
            if reminders.authorization == .denied {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Notifications are off for Foresight in iOS Settings, so nothing below can reach you.")
                        .font(.subheadline)
                        .foregroundStyle(Color.foresightInk)
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    }
                }
                .padding(.vertical, 4)
            }
            Toggle(isOn: $remindersEnabled) {
                SettingLabel(title: "Check-in reminders", detail: "A notification when a scheduled check-in is ready, and a count on the app icon while any wait.")
            }
            .tint(Color.foresightSwitch)
            Toggle(isOn: $nudgesEnabled) {
                SettingLabel(title: "Pattern nudges", detail: "At most one a day, around the time you usually log something that has often been followed by feeling better.")
            }
            .tint(Color.foresightSwitch)
        } header: {
            Text("Notifications")
        }
    }

    private var quietHoursSection: some View {
        Section {
            Toggle(isOn: $quietHoursEnabled) {
                SettingLabel(title: "Quiet hours", detail: quietHoursEnabled ? "Reminders due \(Self.hourLabel(quietStart))–\(Self.hourLabel(quietEnd)) arrive at \(Self.hourLabel(quietEnd)). Nudges skip these hours." : "Reminders and nudges can arrive at any hour.")
            }
            .tint(Color.foresightSwitch)
            if quietHoursEnabled {
                // Two short wheels side by side read like a time range, where a pair of
                // 24-row menus meant a long scroll for each end.
                HStack(spacing: 12) {
                    hourWheel("From", selection: $quietStart, excluding: quietEnd)
                    hourWheel("Until", selection: $quietEnd, excluding: quietStart)
                }
            }
        } header: {
            Text("Quiet hours")
        }
    }

    private func hourWheel(_ title: String, selection: Binding<Int>, excluding other: Int) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.foresightMuted)
            // The other end's hour is left out, since equal ends would mean never quiet.
            LoopingHourWheel(title: title, selection: selection, hours: (0..<24).filter { $0 != other }, label: Self.hourLabel)
                .frame(height: 120)
                // Wheels keep their full-size touch area unless clipped to it, so side by side
                // they would steal each other's drags.
                .compositingGroup()
                .clipped()
                .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity)
    }

    private var categoriesSection: some View {
        Section {
            NavigationLink {
                CategorySettingsView(store: store)
            } label: {
                SettingLabel(title: "Categories", detail: "\(store.activeCategories.count) in use\(archivedCount > 0 ? ", \(archivedCount) archived" : ""). Archive ones you no longer log, or bring them back.")
            }
        } header: {
            Text("Journal")
        }
    }

    private var archivedCount: Int { store.categories.filter(\.isArchived).count }

    #if ENABLE_DEVELOPMENT_FIXTURES
    private var sampleDataSection: some View {
        let complete = store.demoDataState() == .complete
        return Section {
            Button(complete ? "Remove sample history" : "Add history") {
                if complete { confirmRemoveSample = true }
                else {
                    do { try store.addDemoHistory(); sampleMessage = "Sample history added." }
                    catch { sampleMessage = error.localizedDescription }
                }
            }
            .accessibilityIdentifier("settings.sample-history")
            if let sampleMessage {
                Text(sampleMessage).font(.footnote).foregroundStyle(Color.foresightSage)
            }
        } header: {
            Text("Development data")
        } footer: {
            Text(complete
                ? "Debug builds only. Removing it keeps your own logs and check-ins."
                : "Debug builds only. Adds a 90-day pattern history plus due and upcoming check-ins.")
                .padding(.bottom, 8)
        }
    }
    #endif

    private func exportDetail(_ export: JournalExport) -> String {
        // Sample history is left out of exports, so a journal of only samples has nothing to send.
        if export.entries.isEmpty && !store.entries.isEmpty { return "Sample history isn't exported. Your own logs will appear here." }
        return "\(export.entries.count) \(export.entries.count == 1 ? "log" : "logs") and \(export.checkInCount) \(export.checkInCount == 1 ? "check-in" : "check-ins") as a JSON file."
    }

    private var dataSection: some View {
        Section {
            let current = export
            ShareLink(item: current, preview: SharePreview("Foresight journal")) {
                SettingLabel(title: "Export journal", detail: exportDetail(current), systemImage: "square.and.arrow.up")
            }
            .disabled(current.entries.isEmpty)
            .accessibilityIdentifier("settings.export")
            Button(role: .destructive) { confirmErase = true } label: {
                SettingLabel(title: "Erase journal", detail: "Delete every log, check-in and category you added, and start over with the starter categories.", systemImage: "trash", tint: .red)
            }
            .accessibilityIdentifier("settings.erase")
            if let message {
                Text(message).font(.footnote).foregroundStyle(Color.foresightSage)
            }
        } header: {
            Text("Your data")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Self.version)
        } header: {
            Text("About")
        }
    }

    private func preferencesChanged(turnedOn: Bool = false) {
        reminders.resync()
        nudges.resync()
        // Turning a notification on is a clear moment to ask, if iOS hasn't asked yet.
        if turnedOn { Task { await reminders.requestAuthorizationIfNeeded(evenWhenRemindersAreOff: true) } }
    }

    private func erase() {
        sampleMessage = nil
        store.resetStore()
        if let error = store.initializationError {
            message = error
        } else {
            message = "Your journal was erased."
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    static func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

private struct SettingLabel: View {
    let title: String
    let detail: String
    var systemImage: String?
    var tint: Color = .foresightInk
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(tint)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Color.foresightMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // A disabled row (Export with nothing to export) should look it.
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Archive categories you no longer log, or bring them back. Archived ones stay on past logs
/// and in Patterns; they just stop being offered when you write a new log.
private struct CategorySettingsView: View {
    let store: JournalStore
    @State private var newCategory = ""
    @State private var categoryToArchive: JournalCategory?
    @State private var message: String?

    private var archived: [JournalCategory] { store.categories.filter(\.isArchived) }

    var body: some View {
        Form {
            Section {
                ForEach(store.activeCategories, id: \.id) { category in
                    HStack {
                        Text(category.name).foregroundStyle(Color.foresightInk)
                        Spacer()
                        Button("Archive") { categoryToArchive = category }
                            .buttonStyle(ForesightQuietButtonStyle(tone: .foresightWarning))
                            .accessibilityLabel("Archive \(category.name)")
                    }
                }
                HStack(spacing: 8) {
                    TextField("New category", text: $newCategory)
                        .submitLabel(.done)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("In use")
            } footer: {
                if let message { Text(message).foregroundStyle(Color.foresightWarning) }
            }
            if !archived.isEmpty {
                Section {
                    ForEach(archived, id: \.id) { category in
                        HStack {
                            Text(category.name).foregroundStyle(Color.foresightMuted)
                            Spacer()
                            Button("Restore") { perform { try store.restoreCategory(category) } }
                                .buttonStyle(ForesightQuietButtonStyle())
                                .accessibilityLabel("Restore \(category.name)")
                        }
                    }
                } header: {
                    Text("Archived")
                } footer: {
                    Text("Archived categories stay on past logs and in Patterns. They aren't offered on new logs.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.foresightCanvas)
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Archive \(categoryToArchive?.name ?? "this category")?", isPresented: Binding(get: { categoryToArchive != nil }, set: { if !$0 { categoryToArchive = nil } }), titleVisibility: .visible) {
            Button("Archive") {
                guard let category = categoryToArchive else { return }
                perform { try store.archiveCategory(category) }
            }
        } message: { Text("It stays on past logs and in Patterns, and you can restore it here.") }
    }

    private func add() {
        perform {
            _ = try store.addCategory(named: newCategory)
            newCategory = ""
        }
    }

    private func perform(_ change: () throws -> Void) {
        do { try change(); message = nil }
        catch { message = error.localizedDescription }
    }
}

/// Row math for a wheel that repeats its values, so scrolling past the last one comes back
/// round to the first, like the Clock app's wheels.
struct LoopingWheelRows {
    static let copies = 200
    let count: Int

    var rowCount: Int { count * Self.copies }
    func index(ofRow row: Int) -> Int { ((row % count) + count) % count }
    /// The row in the middle copy for an index, so there's room to scroll either way.
    func centeredRow(for index: Int) -> Int { count * (Self.copies / 2) + index }
}

/// An hour wheel that wraps from 11 PM back to 12 AM. SwiftUI's wheel picker stops at
/// either end, so 11 PM to 12 AM meant scrolling through every hour in between.
struct LoopingHourWheel: UIViewRepresentable {
    let title: String
    @Binding var selection: Int
    let hours: [Int]
    let label: @MainActor (Int) -> String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIPickerView {
        let picker = UIPickerView()
        picker.dataSource = context.coordinator
        picker.delegate = context.coordinator
        picker.accessibilityLabel = title
        picker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        picker.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return picker
    }

    func updateUIView(_ picker: UIPickerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.hours != hours {
            coordinator.hours = hours
            picker.reloadAllComponents()
        }
        coordinator.show(selection, in: picker)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIPickerView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 140, height: proposal.height ?? 120)
    }

    @MainActor
    final class Coordinator: NSObject, UIPickerViewDataSource, UIPickerViewDelegate {
        var parent: LoopingHourWheel
        var hours: [Int]
        private var rows: LoopingWheelRows { LoopingWheelRows(count: hours.count) }

        init(_ parent: LoopingHourWheel) {
            self.parent = parent
            hours = parent.hours
        }

        func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }
        func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int { rows.rowCount }

        func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
            parent.label(hours[rows.index(ofRow: row)])
        }

        func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
            let index = rows.index(ofRow: row)
            // Jump back to the middle copy (it looks the same) so the wheel never runs out.
            pickerView.selectRow(rows.centeredRow(for: index), inComponent: 0, animated: false)
            if parent.selection != hours[index] { parent.selection = hours[index] }
        }

        /// Turns the wheel to an hour set from outside, leaving it alone if it's already there.
        func show(_ hour: Int, in picker: UIPickerView) {
            guard let index = hours.firstIndex(of: hour) else { return }
            let current = picker.selectedRow(inComponent: 0)
            if current >= 0, current < rows.rowCount, rows.index(ofRow: current) == index { return }
            picker.selectRow(rows.centeredRow(for: index), inComponent: 0, animated: false)
        }
    }
}
