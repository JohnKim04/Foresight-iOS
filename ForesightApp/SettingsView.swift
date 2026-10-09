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
    @State private var message: String?
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
                dataSection
                privacySection
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
                SettingLabel(title: "Check-in reminders", detail: "A notification when a scheduled check-in is ready.")
            }
            Toggle(isOn: $nudgesEnabled) {
                SettingLabel(title: "Pattern nudges", detail: "At most one a day, around the time you usually log something that has often been followed by feeling better.")
            }
        } header: {
            Text("Notifications")
        }
    }

    private var quietHoursSection: some View {
        Section {
            Toggle(isOn: $quietHoursEnabled) {
                SettingLabel(title: "Quiet hours", detail: quietHoursEnabled ? "Reminders due \(Self.hourLabel(quietStart))–\(Self.hourLabel(quietEnd)) arrive at \(Self.hourLabel(quietEnd)). Nudges skip these hours." : "Reminders and nudges can arrive at any hour.")
            }
            if quietHoursEnabled {
                Picker("From", selection: $quietStart) {
                    ForEach(0..<24, id: \.self) { hour in Text(Self.hourLabel(hour)).tag(hour).disabled(hour == quietEnd) }
                }
                Picker("Until", selection: $quietEnd) {
                    ForEach(0..<24, id: \.self) { hour in Text(Self.hourLabel(hour)).tag(hour).disabled(hour == quietStart) }
                }
            }
        } header: {
            Text("Quiet hours")
        }
    }

    private var dataSection: some View {
        Section {
            let current = export
            ShareLink(item: current, preview: SharePreview("Foresight journal")) {
                SettingLabel(title: "Export journal", detail: "\(current.entries.count) \(current.entries.count == 1 ? "log" : "logs") and \(current.checkInCount) \(current.checkInCount == 1 ? "check-in" : "check-ins") as a JSON file.", systemImage: "square.and.arrow.up")
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

    private var privacySection: some View {
        Section {
            Text("Your journal stays on this device. Foresight has no account and sends nothing anywhere; an export goes only where you share it.")
                .font(.subheadline)
                .foregroundStyle(Color.foresightMuted)
            LabeledContent("Version", value: Self.version)
        } header: {
            Text("Privacy")
        }
    }

    private func preferencesChanged(turnedOn: Bool = false) {
        reminders.resync()
        nudges.resync()
        // Turning a notification on is a clear moment to ask, if iOS hasn't asked yet.
        if turnedOn { Task { await reminders.requestAuthorizationIfNeeded(evenWhenRemindersAreOff: true) } }
    }

    private func erase() {
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
