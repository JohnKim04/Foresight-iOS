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
