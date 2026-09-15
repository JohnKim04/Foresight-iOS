import Foundation

enum JournalCheckInFilter: String, CaseIterable, Identifiable, Hashable {
    case all
    case none
    case scheduled
    case answered

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum JournalViewMode: String, CaseIterable, Identifiable, Hashable {
    case timeline
    case calendar

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct JournalFilters {
    var query = ""
    var categoryID: UUID?
    var checkIn: JournalCheckInFilter = .all
}

struct JournalDateRange: Equatable {
    var start: Date
    var end: Date
}

struct TimelineGroup: Identifiable {
    let day: String
    let entries: [JournalEntry]
    var id: String { day }
}

struct CalendarDay: Identifiable {
    let date: Date
    let inMonth: Bool
    let count: Int
    var id: String { localDayKey(date) }
}

func localDayKey(_ date: Date, calendar: Calendar = .current) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
}

func startOfDay(_ date: Date, calendar: Calendar = .current) -> Date {
    calendar.startOfDay(for: date)
}

func recentJournalRange(now: Date = .now, calendar: Calendar = .current) -> JournalDateRange {
    let end = startOfDay(now, calendar: calendar)
    return JournalDateRange(start: calendar.date(byAdding: .day, value: -29, to: end)!, end: end)
}

func filterJournalEntries(_ entries: [JournalEntry], categories: [JournalCategory], checkIns: [OutcomeCheckIn], filters: JournalFilters) -> [JournalEntry] {
    let names = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
    let tokens = filters.query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    return entries.filter { entry in
        if let categoryID = filters.categoryID, !entry.categories.contains(where: { $0.id == categoryID }) { return false }
        let related = checkIns.filter { $0.entry?.id == entry.id }
        switch filters.checkIn {
        case .all: break
        case .none where !related.isEmpty: return false
        case .scheduled where !related.contains(where: { $0.phase == .delayed && $0.status == .pending }): return false
        case .answered where !related.contains(where: { $0.status == .answered || $0.status == .notSure }): return false
        default: break
        }
        guard !tokens.isEmpty else { return true }
        let text = ([entry.body] + entry.categories.compactMap { names[$0.id] }).joined(separator: " ").lowercased()
        return tokens.allSatisfy(text.contains)
    }
}

func filterEntriesByDateRange(_ entries: [JournalEntry], range: JournalDateRange?, calendar: Calendar = .current) -> [JournalEntry] {
    guard let range else { return entries }
    let lower = min(localDayKey(range.start, calendar: calendar), localDayKey(range.end, calendar: calendar))
    let upper = max(localDayKey(range.start, calendar: calendar), localDayKey(range.end, calendar: calendar))
    return entries.filter {
        let day = localDayKey($0.eventAt, calendar: calendar)
        return day >= lower && day <= upper
    }
}

func groupEntriesByDay(_ entries: [JournalEntry], calendar: Calendar = .current) -> [TimelineGroup] {
    let groups = Dictionary(grouping: entries, by: { localDayKey($0.eventAt, calendar: calendar) })
    return groups.keys.sorted(by: >).map { key in
        TimelineGroup(day: key, entries: groups[key, default: []].sorted { $0.eventAt > $1.eventAt })
    }
}

func calendarDays(month: Date, entries: [JournalEntry], calendar: Calendar = .current) -> [CalendarDay] {
    let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month))!
    let weekday = calendar.component(.weekday, from: first)
    let gridStart = calendar.date(byAdding: .day, value: -((weekday - 1 + 7) % 7), to: first)!
    let counts = Dictionary(grouping: entries, by: { localDayKey($0.eventAt, calendar: calendar) }).mapValues(\.count)
    return (0..<42).compactMap { offset in
        guard let date = calendar.date(byAdding: .day, value: offset, to: gridStart) else { return nil }
        return CalendarDay(date: date, inMonth: calendar.isDate(date, equalTo: month, toGranularity: .month), count: counts[localDayKey(date, calendar: calendar), default: 0])
    }
}

func entryCheckInLabel(entry: JournalEntry, checkIns: [OutcomeCheckIn], now: Date = .now) -> String? {
    let related = checkIns.filter { $0.entry?.id == entry.id }
    if let pending = related.first(where: { $0.phase == .delayed && $0.status == .pending && $0.dueAt != nil }) {
        return pending.dueAt! <= now ? "Check-in due" : "Check-in scheduled"
    }
    if related.contains(where: { $0.status == .answered || $0.status == .notSure }) { return "Reflected" }
    return nil
}

struct QueuedCheckIn: Identifiable {
    let checkIn: OutcomeCheckIn
    let entry: JournalEntry
    let due: Bool
    let overdue: Bool
    var id: UUID { checkIn.id }
}

func delayedCheckInQueue(_ journal: JournalSnapshot, now: Date = .now) -> [QueuedCheckIn] {
    journal.checkIns.compactMap { checkIn in
        guard checkIn.phase == .delayed, checkIn.status == .pending, let dueAt = checkIn.dueAt, let entry = checkIn.entry else { return nil }
        let due = dueAt <= now
        return QueuedCheckIn(checkIn: checkIn, entry: entry, due: due, overdue: dueAt < now)
    }.sorted { left, right in
        if left.due != right.due { return left.due && !right.due }
        return (left.checkIn.dueAt ?? .distantFuture) < (right.checkIn.dueAt ?? .distantFuture)
    }
}

func recentCompletedCheckIns(_ journal: JournalSnapshot, limit: Int = 10) -> [QueuedCheckIn] {
    journal.checkIns.compactMap { checkIn in
        guard checkIn.phase == .delayed, checkIn.status != .pending, let entry = checkIn.entry else { return nil }
        return QueuedCheckIn(checkIn: checkIn, entry: entry, due: false, overdue: false)
    }.sorted { $0.checkIn.updatedAt > $1.checkIn.updatedAt }.prefix(max(0, limit)).map { $0 }
}

enum TrendGranularity: String, CaseIterable, Identifiable, Hashable { case week, month; var id: String { rawValue }; var title: String { rawValue.capitalized } }
enum TrendRange: Int, CaseIterable, Identifiable, Hashable { case seven = 7, thirty = 30, ninety = 90; var id: Int { rawValue }; var title: String { "\(rawValue)d" } }

struct ActivityBucket: Identifiable { let date: Date; let label: String; let count: Int; var id: Date { date } }
struct PeriodComparison { let currentCount: Int; let previousCount: Int; let change: Int; let currentLabel: String }
struct CategoryActivityTrend: Identifiable { let category: JournalCategory; let currentCount: Int; let previousCount: Int; var change: Int { currentCount - previousCount }; var id: UUID { category.id } }

func startOfPeriod(_ date: Date, granularity: TrendGranularity, calendar: Calendar = .current) -> Date {
    let day = startOfDay(date, calendar: calendar)
    if granularity == .month { return calendar.date(from: calendar.dateComponents([.year, .month], from: day))! }
    let weekday = calendar.component(.weekday, from: day)
    let offset = (weekday + 5) % 7
    return calendar.date(byAdding: .day, value: -offset, to: day)!
}

func shiftPeriod(_ date: Date, by amount: Int, granularity: TrendGranularity, calendar: Calendar = .current) -> Date {
    calendar.date(byAdding: granularity == .week ? .day : .month, value: granularity == .week ? amount * 7 : amount, to: date)!
}

func activityBuckets(_ entries: [JournalEntry], category: JournalCategory?, granularity: TrendGranularity, now: Date = .now, calendar: Calendar = .current) -> [ActivityBucket] {
    let count = granularity == .week ? 8 : 6
    let current = startOfPeriod(now, granularity: granularity, calendar: calendar)
    let first = shiftPeriod(current, by: -(count - 1), granularity: granularity, calendar: calendar)
    return (0..<count).map { index in
        let start = shiftPeriod(first, by: index, granularity: granularity, calendar: calendar)
        let end = shiftPeriod(start, by: 1, granularity: granularity, calendar: calendar)
        let logs = entries.filter { entry in
            (category == nil || entry.categories.contains(where: { $0.id == category!.id })) && entry.eventAt >= start && entry.eventAt < end
        }
        let format = Date.FormatStyle().month(.abbreviated).day()
        return ActivityBucket(date: start, label: granularity == .week ? start.formatted(format) : start.formatted(.dateTime.month(.abbreviated)), count: logs.count)
    }
}

func periodComparison(_ entries: [JournalEntry], category: JournalCategory?, granularity: TrendGranularity, now: Date = .now, calendar: Calendar = .current) -> PeriodComparison {
    let current = startOfPeriod(now, granularity: granularity, calendar: calendar)
    let next = shiftPeriod(current, by: 1, granularity: granularity, calendar: calendar)
    let previous = shiftPeriod(current, by: -1, granularity: granularity, calendar: calendar)
    func count(_ start: Date, _ end: Date) -> Int { entries.filter { (category == nil || $0.categories.contains(where: { $0.id == category!.id })) && $0.eventAt >= start && $0.eventAt < end }.count }
    let currentCount = count(current, next)
    let previousCount = count(previous, current)
    return PeriodComparison(currentCount: currentCount, previousCount: previousCount, change: currentCount - previousCount, currentLabel: current.formatted(granularity == .week ? .dateTime.month(.abbreviated).day() : .dateTime.month(.wide).year()))
}

func categoryTrends(_ entries: [JournalEntry], categories: [JournalCategory], range: TrendRange, now: Date = .now, calendar: Calendar = .current) -> [CategoryActivityTrend] {
    let currentStart = calendar.date(byAdding: .day, value: -(range.rawValue - 1), to: startOfDay(now, calendar: calendar))!
    let end = calendar.date(byAdding: .day, value: 1, to: startOfDay(now, calendar: calendar))!
    let prior = calendar.date(byAdding: .day, value: -range.rawValue, to: currentStart)!
    return categories.map { category in
        let current = entries.filter { $0.eventAt >= currentStart && $0.eventAt < end && $0.categories.contains(where: { $0.id == category.id }) }.count
        let previous = entries.filter { $0.eventAt >= prior && $0.eventAt < currentStart && $0.categories.contains(where: { $0.id == category.id }) }.count
        return CategoryActivityTrend(category: category, currentCount: current, previousCount: previous)
    }.sorted { $0.currentCount != $1.currentCount ? $0.currentCount > $1.currentCount : $0.category.name < $1.category.name }
}
