import Foundation

/// A category whose later check-ins have tended to be better, ranked for "right now".
/// Foresight only says what tended to follow what; the wording never claims a cause.
struct HelpSuggestion: Identifiable {
    let category: JournalCategory
    let betterCount: Int
    let numericCount: Int
    let average: Double
    let evidenceDepth: EvidenceDepth
    /// Most of the logs that were followed by feeling better happened near this time of day.
    let usualTimeOfDay: Bool
    let loggedToday: Bool
    let daysSinceLastLog: Int?
    /// Right-after check-ins for the same logs leaned worse, so it may not feel good at first.
    let worseRightAfter: Bool
    let score: Double

    var id: UUID { category.id }

    var headline: String { "\(category.name) has tended to be followed by feeling better later." }
    var evidence: String { "Better in \(betterCount) of \(numericCount) later check-ins · \(evidenceDepth.rawValue)" }

    var context: String? {
        var notes: [String] = []
        if loggedToday { notes.append("Already logged today.") }
        else if usualTimeOfDay { notes.append("You’ve often logged it around this time of day.") }
        else if let days = daysSinceLastLog, days >= 2 { notes.append("Last logged \(days) days ago.") }
        if worseRightAfter { notes.append("It tended to feel worse right after.") }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }
}

struct HelpSuggestionReport {
    let suggestions: [HelpSuggestion]
    /// Categories with enough later check-ins to describe a pattern, helpful or not.
    let patternCount: Int
    /// The category closest to enough later check-ins, when nothing qualifies yet.
    let progress: InsightProgress?
}

let helpSuggestionRange: OutcomeTrendRange = .ninety
let helpSuggestionHourWindow = 2

/// Picks categories with positive later evidence and ranks them for `now`.
/// Uses the same evidence bar as Patterns: five numeric later responses and the 60% rule.
func helpSuggestions(entries: [JournalEntry], checkIns: [OutcomeCheckIn], categories: [JournalCategory], now: Date = .now, calendar: Calendar = .current, limit: Int = 3) -> HelpSuggestionReport {
    let active = categories.filter { !$0.isArchived }
    let hour = calendar.component(.hour, from: now)
    var patternCount = 0
    var suggestions: [HelpSuggestion] = []

    for category in active {
        let later = outcomeTrend(entries: entries, checkIns: checkIns, category: category, phase: .delayed, range: helpSuggestionRange, now: now, calendar: calendar)
        guard later.numericCount >= minimumPatternResponses, let average = later.average else { continue }
        patternCount += 1
        guard outcomeDirection(later) == .positive else { continue }

        let helpedHours = helpedEntries(entries: entries, checkIns: checkIns, category: category, sourceIDs: Set(later.sourceEntryIDs))
            .map { calendar.component(.hour, from: $0.eventAt) }
        let nearNow = helpedHours.filter { hourDistance($0, hour) <= helpSuggestionHourWindow }.count
        let usualTime = nearNow >= 3 && Double(nearNow) / Double(max(1, helpedHours.count)) >= 0.5

        let lastLog = entries.filter { $0.eventAt <= now && $0.categories.contains(where: { $0.id == category.id }) }.map(\.eventAt).max()
        let daysSince = lastLog.flatMap { calendar.dateComponents([.day], from: startOfDay($0, calendar: calendar), to: startOfDay(now, calendar: calendar)).day }
        let loggedToday = daysSince == 0

        let rightAfter = outcomeTrend(entries: entries, checkIns: checkIns, category: category, phase: .immediate, range: helpSuggestionRange, now: now, calendar: calendar)
        let worseRightAfter = rightAfter.numericCount >= minimumPatternResponses && outcomeDirection(rightAfter) == .negative

        let rate = Double(later.betterCount) / Double(later.numericCount)
        var score = rate * average * sqrt(Double(later.numericCount))
        if usualTime { score *= 1.25 }
        if loggedToday { score *= 0.5 }

        suggestions.append(HelpSuggestion(
            category: category,
            betterCount: later.betterCount,
            numericCount: later.numericCount,
            average: average,
            evidenceDepth: evidenceDepth(later.numericCount),
            usualTimeOfDay: usualTime,
            loggedToday: loggedToday,
            daysSinceLastLog: daysSince,
            worseRightAfter: worseRightAfter,
            score: score
        ))
    }

    let ranked = suggestions
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.category.name < $1.category.name }
        .prefix(max(0, limit))
    let progress = ranked.isEmpty && patternCount == 0
        ? closestInsightProgress(entries: entries, checkIns: checkIns, categories: active, phase: .delayed, range: helpSuggestionRange, now: now)
        : nil
    return HelpSuggestionReport(suggestions: Array(ranked), patternCount: patternCount, progress: progress)
}

/// Logs in the category whose later check-in was answered better.
private func helpedEntries(entries: [JournalEntry], checkIns: [OutcomeCheckIn], category: JournalCategory, sourceIDs: Set<UUID>) -> [JournalEntry] {
    let helpedIDs = Set(checkIns.filter { $0.phase == .delayed && $0.isNumericResponse && ($0.overall?.rawValue ?? 0) > 0 }.compactMap { $0.entry?.id })
    return entries.filter { sourceIDs.contains($0.id) && helpedIDs.contains($0.id) }
}

private func hourDistance(_ first: Int, _ second: Int) -> Int {
    let difference = abs(first - second) % 24
    return min(difference, 24 - difference)
}
