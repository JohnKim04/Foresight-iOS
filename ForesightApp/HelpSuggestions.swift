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
    /// Most of the logs followed by feeling better were on weekends.
    let mostlyWeekends: Bool
    /// The hour most of the logs followed by feeling better cluster around, when they do.
    let usualHour: Int?
    /// How strong the later evidence is, before any adjustment for `now`.
    let strength: Double
    let score: Double
    /// How later check-ins went for your logs without this category, when there are enough of
    /// them to compare with. The pattern beat this rate to qualify.
    var baseline: LaterBaseline? = nil

    var id: UUID { category.id }

    /// Its better rate was above your other logs'. A strong category can qualify against a
    /// baseline just as strong (see `baselineRateCap`), and then the headline doesn't claim this.
    var beatsOtherLogs: Bool {
        guard let baseline, numericCount > 0, baseline.numericCount > 0 else { return false }
        return Double(betterCount) / Double(numericCount) > Double(baseline.betterCount) / Double(baseline.numericCount)
    }

    var headline: String {
        beatsOtherLogs
            ? "\(category.name) has been followed by feeling better later more often than your other logs."
            : "\(category.name) has tended to be followed by feeling better later."
    }
    var evidence: String {
        let others = baseline.map { " (other logs: better in \($0.betterCount) of \($0.numericCount))" } ?? ""
        return "Better or much better in \(betterCount) of \(numericCount) later check-ins\(others) · \(evidenceDepth.rawValue)"
    }

    var context: String? { context(showingUsualTime: true) }

    /// `showingUsualTime` is false when the card already says it once for several suggestions.
    func context(showingUsualTime: Bool) -> String? {
        var notes: [String] = []
        if loggedToday { notes.append("Already logged today.") }
        else if usualTimeOfDay { if showingUsualTime { notes.append("You’ve often logged it around this time of day.") } }
        else if let days = daysSinceLastLog, days >= 2 { notes.append("Last logged \(days) days ago.") }
        if mostlyWeekends { notes.append("Mostly logged on weekends.") }
        if worseRightAfter { notes.append("It tended to feel worse right after.") }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }
}

struct HelpSuggestionReport {
    let suggestions: [HelpSuggestion]
    /// Categories with enough later check-ins to describe a pattern, helpful or not.
    let patternCount: Int
    /// The category closest to enough later check-ins, when no suggestion qualifies yet.
    let progress: InsightProgress?
    /// A category cleared the absolute bar but not your other logs' rate.
    var heldBackByBaseline = false
}

/// Card copy, kept here so the non-causal wording is covered by tests.
enum HelpSuggestionCopy {
    static let title = "Often followed by feeling better"
    static let footnote = "From your later check-ins over the last 90 days. These are patterns, not causes."
    /// Leads the suggestion shown right after a check-in that felt worse.
    static let afterWorseIntro = "One pattern from your own later check-ins, in case it’s useful now:"
    /// The Journal card's dismiss button.
    static let hideForToday = "Hide for today"

    /// One line for the card when two or more suggestions are near their usual time of day.
    static func sharedUsualTimeNote(_ suggestions: [HelpSuggestion]) -> String? {
        let names = suggestions.filter { $0.usualTimeOfDay && !$0.loggedToday }.map(\.category.name)
        guard names.count >= 2 else { return nil }
        return "You’ve often logged \(names.formatted(.list(type: .and))) around this time of day."
    }

    static func emptyMessage(_ report: HelpSuggestionReport) -> String {
        if report.heldBackByBaseline { return "No category has been followed by feeling better more often than your other logs yet. Keep checking in later and this will update." }
        if report.patternCount > 0 { return "No category has been followed by feeling better clearly and recently enough yet. Keep checking in later and this will update." }
        if let progress = report.progress { return "\(progress.category.name) needs \(progress.needed) more later \(progress.needed == 1 ? "check-in" : "check-ins") before Foresight can show what tends to be followed by feeling better." }
        return "Tag your logs and check in later. Foresight will show what has tended to be followed by feeling better."
    }

    /// Journal's line once every logged category has enough later check-ins but none qualifies.
    static let journalNoClearPattern = "No clear pattern yet. Foresight keeps looking as you check in."

    /// The Journal's line while there is no suggestion yet. It counts toward the same minimum the
    /// suggestions use, and doesn't promise a pattern, since five answers may still show none.
    static func journalProgress(_ progress: InsightProgress) -> String {
        "\(progress.category.name): \(progress.numericCount) of \(minimumPatternResponses) later check-ins before Foresight looks for a pattern"
    }

    /// What Journal shows in place of a suggestion, or nil when there is one or nothing is tagged yet.
    static func journalProgress(_ report: HelpSuggestionReport) -> String? {
        guard report.suggestions.isEmpty else { return nil }
        if let progress = report.progress { return journalProgress(progress) }
        return report.patternCount > 0 ? journalNoClearPattern : nil
    }
}

let helpSuggestionRange: OutcomeTrendRange = .ninety
let helpSuggestionHourWindow = 2
/// How many of the most recent later responses decide whether a pattern still holds.
let helpSuggestionRecentResponses = 3

/// Picks categories with positive later evidence and ranks them for `now`.
/// Starts from the Patterns bar (five numeric later responses and the 60% rule), then keeps
/// only patterns that are unlikely to be a small-sample fluke, still hold recently, and stand
/// out from how your other logs' later check-ins usually go.
func helpSuggestions(entries: [JournalEntry], checkIns: [OutcomeCheckIn], categories: [JournalCategory], now: Date = .now, calendar: Calendar = .current, limit: Int = 3) -> HelpSuggestionReport {
    let active = categories.filter { !$0.isArchived }
    let hour = calendar.component(.hour, from: now)
    var patternCount = 0
    var heldBackByBaseline = false
    var suggestions: [HelpSuggestion] = []

    for category in active {
        let later = outcomeTrend(entries: entries, checkIns: checkIns, category: category, phase: .delayed, range: helpSuggestionRange, now: now, calendar: calendar)
        guard later.numericCount >= minimumPatternResponses, let average = later.average else { continue }
        patternCount += 1
        guard outcomeDirection(later) == .positive else { continue }

        // 3 of 5 better clears the 60% rule but is close to a coin flip, so a suggestion needs
        // the low end of its likely better rate to reach half. 6 of 9 lands on it exactly,
        // so allow for rounding.
        let lowerBound = wilsonLowerBound(successes: later.betterCount, trials: later.numericCount)
        guard lowerBound >= 0.5 - 1e-9 else { continue }
        // If "Better" is your usual later answer anyway, every frequent category would pass the
        // bar above, so the pattern also has to beat your other logs.
        let baseline = laterBaseline(entries: entries, checkIns: checkIns, excluding: category, now: now, calendar: calendar)
        guard beatsBaseline(successes: later.betterCount, trials: later.numericCount, baselineSuccesses: baseline.betterCount, baselineTrials: baseline.numericCount) else {
            heldBackByBaseline = true
            continue
        }
        // A pattern whose latest later check-ins were mostly not better may have faded.
        let recent = laterResponses(entries: entries, checkIns: checkIns, sourceIDs: Set(later.sourceEntryIDs)).prefix(helpSuggestionRecentResponses)
        guard recent.count < helpSuggestionRecentResponses || recent.filter({ $0 > 0 }).count * 2 > recent.count else { continue }

        let helped = entriesWithLaterResponse(entries: entries, checkIns: checkIns, sourceIDs: Set(later.sourceEntryIDs)) { $0 > 0 }
        let helpedHours = helped.map { calendar.component(.hour, from: $0.eventAt) }
        let nearNow = helpedHours.filter { hourDistance($0, hour) <= helpSuggestionHourWindow }.count
        let usualTime = nearNow >= 3 && Double(nearNow) / Double(max(1, helpedHours.count)) >= 0.5
        let usualHour = clusteredHour(helpedHours)
        let mostlyWeekends = mostlyOnWeekends(helped, calendar: calendar)

        let daysSince = daysSinceLastLog(entries: entries, category: category, now: now, calendar: calendar)
        let loggedToday = daysSince == 0

        let rightAfter = outcomeTrend(entries: entries, checkIns: checkIns, category: category, phase: .immediate, range: helpSuggestionRange, now: now, calendar: calendar)
        let worseRightAfter = rightAfter.numericCount >= minimumPatternResponses && outcomeDirection(rightAfter) == .negative

        // The lower bound already discounts small samples, so 10 of 10 ranks above 5 of 5.
        let strength = lowerBound * average
        var score = strength
        if usualTime { score *= 1.25 }
        if mostlyWeekends && !calendar.isDateInWeekend(now) { score *= 0.6 }
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
            mostlyWeekends: mostlyWeekends,
            usualHour: usualHour,
            strength: strength,
            score: score,
            baseline: baseline.isComparable ? baseline : nil
        ))
    }

    let ranked = suggestions
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.category.name < $1.category.name }
        .prefix(max(0, limit))
    // Also once another category has a pattern that didn't qualify, so the Journal keeps
    // showing how close the rest are until the first suggestion.
    let progress = ranked.isEmpty
        ? closestInsightProgress(entries: entries, checkIns: checkIns, categories: active, phase: .delayed, range: helpSuggestionRange, now: now, calendar: calendar)
        : nil
    return HelpSuggestionReport(suggestions: Array(ranked), patternCount: patternCount, progress: progress, heldBackByBaseline: heldBackByBaseline && ranked.isEmpty)
}

/// A category whose later check-ins have tended to be worse, for a heads-up before its usual time.
/// As with suggestions, this only says what tended to follow what, never what caused it.
struct WorsePattern: Identifiable {
    let category: JournalCategory
    let worseCount: Int
    let numericCount: Int
    /// Most of the logs followed by feeling worse were on weekends.
    let mostlyWeekends: Bool
    /// The hour most of the logs followed by feeling worse cluster around, when they do.
    let usualHour: Int?
    let loggedToday: Bool
    let strength: Double

    var id: UUID { category.id }
}

/// Categories whose later check-ins have mostly been worse, held to the same bar as suggestions:
/// five numeric later responses and the 60% rule, a lower bound of a half on the worse rate,
/// a worse rate that beats your other logs', and still holding in the latest later check-ins.
/// Strongest first.
func worsePatterns(entries: [JournalEntry], checkIns: [OutcomeCheckIn], categories: [JournalCategory], now: Date = .now, calendar: Calendar = .current) -> [WorsePattern] {
    categories.filter { !$0.isArchived }.compactMap { category -> WorsePattern? in
        let later = outcomeTrend(entries: entries, checkIns: checkIns, category: category, phase: .delayed, range: helpSuggestionRange, now: now, calendar: calendar)
        guard later.numericCount >= minimumPatternResponses, let average = later.average, outcomeDirection(later) == .negative else { return nil }
        let lowerBound = wilsonLowerBound(successes: later.worseCount, trials: later.numericCount)
        guard lowerBound >= 0.5 - 1e-9 else { return nil }
        let baseline = laterBaseline(entries: entries, checkIns: checkIns, excluding: category, now: now, calendar: calendar)
        guard beatsBaseline(successes: later.worseCount, trials: later.numericCount, baselineSuccesses: baseline.worseCount, baselineTrials: baseline.numericCount) else { return nil }
        let recent = laterResponses(entries: entries, checkIns: checkIns, sourceIDs: Set(later.sourceEntryIDs)).prefix(helpSuggestionRecentResponses)
        guard recent.count < helpSuggestionRecentResponses || recent.filter({ $0 < 0 }).count * 2 > recent.count else { return nil }

        let followedByWorse = entriesWithLaterResponse(entries: entries, checkIns: checkIns, sourceIDs: Set(later.sourceEntryIDs)) { $0 < 0 }
        return WorsePattern(
            category: category,
            worseCount: later.worseCount,
            numericCount: later.numericCount,
            mostlyWeekends: mostlyOnWeekends(followedByWorse, calendar: calendar),
            usualHour: clusteredHour(followedByWorse.map { calendar.component(.hour, from: $0.eventAt) }),
            loggedToday: daysSinceLastLog(entries: entries, category: category, now: now, calendar: calendar) == 0,
            strength: lowerBound * -average
        )
    }
    .sorted { $0.strength != $1.strength ? $0.strength > $1.strength : $0.category.name < $1.category.name }
}

/// The suggestion to show right after a check-in that felt worse: the strongest one that
/// isn't for the log just rated, since that log is what was followed by feeling worse.
func suggestionAfterWorseCheckIn(_ report: HelpSuggestionReport, excluding categoryIDs: Set<UUID>) -> HelpSuggestion? {
    report.suggestions.first { !categoryIDs.contains($0.category.id) }
}

/// The suggestion shown at the top of Journal: the strongest one not already logged today,
/// so the card goes quiet once you've done what it points to.
func journalSuggestion(_ report: HelpSuggestionReport) -> HelpSuggestion? {
    report.suggestions.first { !$0.loggedToday }
}

/// Remembers which categories' Journal suggestions were hidden today, so hiding one doesn't
/// hide a different suggestion that comes up later in the day, and both come back tomorrow.
/// Stored as the day key followed by the hidden category IDs: "2026-10-18 <id>,<id>".
enum JournalSuggestionState {
    static let hiddenKey = "journalSuggestion.hiddenCategories"
    /// Where earlier builds kept the day the whole card was hidden. It named no category, so it's dropped.
    static let legacyHiddenDayKey = "journalSuggestion.hiddenDay"

    static func isHidden(_ categoryID: UUID, stored: String, now: Date = .now, calendar: Calendar = .current) -> Bool {
        hiddenToday(stored, now: now, calendar: calendar).contains(categoryID)
    }

    /// `stored` with `categoryID` added for today; categories hidden on earlier days are dropped.
    static func hiding(_ categoryID: UUID, stored: String, now: Date = .now, calendar: Calendar = .current) -> String {
        let ids = hiddenToday(stored, now: now, calendar: calendar).union([categoryID])
        return "\(localDayKey(now, calendar: calendar)) \(ids.map(\.uuidString).sorted().joined(separator: ","))"
    }

    private static func hiddenToday(_ stored: String, now: Date, calendar: Calendar) -> Set<UUID> {
        let parts = stored.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0] == localDayKey(now, calendar: calendar) else { return [] }
        return Set(parts[1].split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }
}

/// How later check-ins went for logs without a category, over the same window as its pattern.
/// This is the usual rate a category has to beat, since later answers are relative to before
/// and many moods drift back up with time.
struct LaterBaseline: Equatable {
    let numericCount: Int
    let betterCount: Int
    let worseCount: Int

    /// Fewer than five responses give no usual rate to compare with.
    static func isComparable(trials: Int) -> Bool { trials >= minimumPatternResponses }
    var isComparable: Bool { Self.isComparable(trials: numericCount) }
}

func laterBaseline(entries: [JournalEntry], checkIns: [OutcomeCheckIn], excluding category: JournalCategory, range: OutcomeTrendRange = helpSuggestionRange, now: Date = .now, calendar: Calendar = .current) -> LaterBaseline {
    let end = calendar.date(byAdding: .day, value: 1, to: startOfDay(now, calendar: calendar))!
    let start = calendar.date(byAdding: .day, value: -(range.rawValue - 1), to: startOfDay(now, calendar: calendar))!
    let otherIDs = Set(entries.filter { $0.eventAt >= start && $0.eventAt < end && !$0.categories.contains(where: { $0.id == category.id }) }.map(\.id))
    let values = checkIns
        .filter { $0.phase == .delayed && $0.status == .answered && !$0.excludedFromAnalysis && $0.entry.map { otherIDs.contains($0.id) } == true }
        .compactMap(\.overall).map(\.rawValue)
    return LaterBaseline(numericCount: values.count, betterCount: values.filter { $0 > 0 }.count, worseCount: values.filter { $0 < 0 }.count)
}

/// The most a baseline rate can ask of a category. Without a cap, a journal where most logs are
/// followed by feeling better would never show a suggestion, since 5 of 5 can't beat 5 of 5.
let baselineRateCap = 0.7

/// Whether a category's rate stands out from the baseline's: the low end of its likely rate has
/// to be above the rate your other logs actually had, capped at `baselineRateCap`. This is the
/// one place to tune the comparison once there is real data. With no comparable baseline yet,
/// the absolute bar decides on its own.
func beatsBaseline(successes: Int, trials: Int, baselineSuccesses: Int, baselineTrials: Int) -> Bool {
    guard LaterBaseline.isComparable(trials: baselineTrials) else { return true }
    let bar = min(Double(baselineSuccesses) / Double(baselineTrials), baselineRateCap)
    return wilsonLowerBound(successes: successes, trials: trials) > bar
}

/// The lower end of the Wilson score interval for `successes` out of `trials`, at about 84%
/// one-sided confidence (z = 1). Small samples land well below their raw rate.
func wilsonLowerBound(successes: Int, trials: Int, z: Double = 1) -> Double {
    guard trials > 0 else { return 0 }
    let n = Double(trials)
    let rate = Double(successes) / n
    let zSquared = z * z
    let centre = rate + zSquared / (2 * n)
    let margin = z * sqrt(rate * (1 - rate) / n + zSquared / (4 * n * n))
    return (centre - margin) / (1 + zSquared / n)
}

/// Numeric later responses for `sourceIDs`, newest log first.
private func laterResponses(entries: [JournalEntry], checkIns: [OutcomeCheckIn], sourceIDs: Set<UUID>) -> [Int] {
    let eventAt = Dictionary(entries.filter { sourceIDs.contains($0.id) }.map { ($0.id, $0.eventAt) }, uniquingKeysWith: { first, _ in first })
    return checkIns
        .compactMap { checkIn -> (Date, Int)? in
            guard checkIn.phase == .delayed, checkIn.isNumericResponse, let id = checkIn.entry?.id, let date = eventAt[id], let value = checkIn.overall else { return nil }
            return (date, value.rawValue)
        }
        .sorted { $0.0 > $1.0 }
        .map(\.1)
}

/// Logs in `sourceIDs` whose later check-in answer passes `matches`, such as better or worse.
private func entriesWithLaterResponse(entries: [JournalEntry], checkIns: [OutcomeCheckIn], sourceIDs: Set<UUID>, matches: (Int) -> Bool) -> [JournalEntry] {
    let matchingIDs = Set(checkIns.filter { checkIn in
        guard checkIn.phase == .delayed, checkIn.isNumericResponse, let value = checkIn.overall else { return false }
        return matches(value.rawValue)
    }.compactMap { $0.entry?.id })
    return entries.filter { sourceIDs.contains($0.id) && matchingIDs.contains($0.id) }
}

/// Weekends are 2 of 7 days, so two thirds on weekends is a clear lean.
private func mostlyOnWeekends(_ entries: [JournalEntry], calendar: Calendar) -> Bool {
    let weekendCount = entries.filter { calendar.isDateInWeekend($0.eventAt) }.count
    return weekendCount >= 3 && Double(weekendCount) / Double(entries.count) >= 2.0 / 3.0
}

/// Whole days since the category was last logged, 0 when it was logged today.
private func daysSinceLastLog(entries: [JournalEntry], category: JournalCategory, now: Date, calendar: Calendar) -> Int? {
    let lastLog = entries.filter { $0.eventAt <= now && $0.categories.contains(where: { $0.id == category.id }) }.map(\.eventAt).max()
    return lastLog.flatMap { calendar.dateComponents([.day], from: startOfDay($0, calendar: calendar), to: startOfDay(now, calendar: calendar)).day }
}

/// The hour that at least three, and at least half, of `hours` fall within the window of.
/// Among equally covered hours, the one closest to all of them wins, then the earliest.
private func clusteredHour(_ hours: [Int]) -> Int? {
    let candidates = Set(hours).sorted().map { hour in
        (hour: hour,
         covered: hours.filter { hourDistance($0, hour) <= helpSuggestionHourWindow }.count,
         spread: hours.reduce(0) { $0 + hourDistance($1, hour) })
    }
    guard let best = candidates.min(by: { $0.covered != $1.covered ? $0.covered > $1.covered : $0.spread < $1.spread }),
          best.covered >= 3, Double(best.covered) / Double(hours.count) >= 0.5 else { return nil }
    return best.hour
}

private func hourDistance(_ first: Int, _ second: Int) -> Int {
    let difference = abs(first - second) % 24
    return min(difference, 24 - difference)
}
