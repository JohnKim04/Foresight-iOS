import Foundation

/// A one-tap "check in later" time offered right after a log is saved.
struct CheckInLaterOption: Identifiable, Equatable {
    enum Kind: String { case inTwoHours, tonight, morning }

    let kind: Kind
    let title: String
    let detail: String
    let dueAt: Date
    var id: String { kind.rawValue }

    /// Offers at most three distinct times. "Tonight" and the morning option are only
    /// offered when they land at least three hours out, so they never duplicate "In 2 hours".
    static func options(now: Date, calendar: Calendar = .current) -> [CheckInLaterOption] {
        let minimumGap: TimeInterval = 3 * 60 * 60
        var options = [CheckInLaterOption(kind: .inTwoHours, title: "In 2 hours", detail: time(now.addingTimeInterval(2 * 60 * 60), calendar: calendar), dueAt: now.addingTimeInterval(2 * 60 * 60))]
        if let tonight = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now), tonight.timeIntervalSince(now) >= minimumGap {
            options.append(CheckInLaterOption(kind: .tonight, title: "Tonight", detail: time(tonight, calendar: calendar), dueAt: tonight))
        }
        if let morning = nextMorning(after: now, minimumGap: minimumGap, calendar: calendar) {
            let title = calendar.isDate(morning, inSameDayAs: now) ? "This morning" : "Tomorrow morning"
            options.append(CheckInLaterOption(kind: .morning, title: title, detail: time(morning, calendar: calendar), dueAt: morning))
        }
        return options
    }

    private static func nextMorning(after now: Date, minimumGap: TimeInterval, calendar: Calendar) -> Date? {
        for dayOffset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now),
                  let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) else { continue }
            if morning.timeIntervalSince(now) >= minimumGap { return morning }
        }
        return nil
    }

    private static func time(_ date: Date, calendar: Calendar) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}

/// Which later check-in the post-log step sets before you tap anything, chosen in Settings.
/// Predictions learn only from later check-ins, so one is set unless you turn this off.
enum LaterCheckInDefault: String, CaseIterable, Identifiable, Sendable {
    // Stored as "none" so a choice saved before the rename still reads back.
    case inTwoHours, tonight, morning
    case off = "none"

    static let standard = LaterCheckInDefault.inTwoHours

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inTwoHours: "In 2 hours"
        case .tonight: "Tonight"
        case .morning: "Next morning"
        case .off: "Don't schedule"
        }
    }

    /// The shortcut to set among those offered now. Tonight isn't offered once 8 PM is less
    /// than three hours away; then the morning stands in.
    func option(in options: [CheckInLaterOption]) -> CheckInLaterOption? {
        guard let kind = CheckInLaterOption.Kind(rawValue: rawValue) else { return nil }
        return options.first { $0.kind == kind } ?? options.first { $0.kind == .morning } ?? options.first
    }
}

/// Wording for a reminder that quiet hours hold past its check-in's due time.
enum QuietHoursCopy {
    static func reminderNote(_ fireAt: Date) -> String {
        "Quiet hours hold the reminder until \(ForesightFormat.detailDate(fireAt))."
    }

    /// The short form under a later-time shortcut. Says the day when quiet hours push the
    /// reminder past today, so "8:00 AM" never reads as this morning.
    static func shortcutReminder(_ fireAt: Date, now: Date, calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        let time = fireAt.formatted(style)
        if calendar.isDate(fireAt, inSameDayAs: now) { return "reminder at \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(fireAt, inSameDayAs: tomorrow) {
            return "reminder tomorrow at \(time)"
        }
        return "reminder \(ForesightFormat.detailDate(fireAt, now: now, calendar: calendar))"
    }
}

/// Later check-ins that are waiting for an answer right now: the "Ready now" group on Check In.
func dueCheckInCount(_ journal: JournalSnapshot, now: Date) -> Int {
    delayedCheckInQueue(journal, now: now).filter(\.due).count
}

/// When the next waiting check-in becomes due, so the tab badge can update without polling.
func nextCheckInDueDate(_ journal: JournalSnapshot, after now: Date) -> Date? {
    delayedCheckInQueue(journal, now: now).first { !$0.due }?.checkIn.dueAt
}

enum OnboardingState {
    static let completedKey = "hasCompletedOnboarding"
    /// UI tests pass this to see onboarding again. A `-hasCompletedOnboarding NO` launch argument
    /// would pin the value and keep the finished onboarding on screen.
    static let resetArgument = "-reset-onboarding"
}
