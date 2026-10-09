import Foundation
import Testing
@testable import Foresight

@MainActor
struct HelpSuggestionsTests {
    // 2024-08-30 06:40 UTC.
    private let now = Date(timeIntervalSince1970: 1_725_000_000)
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func logs(_ category: JournalCategory, count: Int, firstDay: Int = 1, hourOffset: Int = 0) -> [JournalEntry] {
        (0..<count).map { index in
            let day = calendar.date(byAdding: .day, value: -(firstDay + index), to: now)!
            let date = calendar.date(byAdding: .hour, value: hourOffset, to: day)!
            return JournalEntry(body: "\(category.name) \(index)", eventAt: date, createdAt: date, updatedAt: date, categories: [category])
        }
    }

    private func answers(_ entries: [JournalEntry], _ values: [OutcomeValue], phase: OutcomePhase = .delayed) -> [OutcomeCheckIn] {
        entries.enumerated().map { index, entry in
            let value = values[index % values.count]
            return OutcomeCheckIn(entry: entry, phase: phase, status: .answered, dueAt: phase == .delayed ? entry.eventAt : nil, answeredAt: entry.eventAt, overall: value, createdAt: entry.eventAt, updatedAt: entry.eventAt)
        }
    }

    private func report(_ entries: [JournalEntry], _ checkIns: [OutcomeCheckIn], _ categories: [JournalCategory], limit: Int = 3) -> HelpSuggestionReport {
        helpSuggestions(entries: entries, checkIns: checkIns, categories: categories, now: now, calendar: calendar, limit: limit)
    }

    @Test("waits for five later responses and reports the closest category")
    func coldStart() {
        let workout = JournalCategory(name: "Workout")
        let entries = logs(workout, count: 4)
        let result = report(entries, answers(entries, [.muchBetter]), [workout])
        #expect(result.suggestions.isEmpty)
        #expect(result.patternCount == 0)
        #expect(result.progress?.category.id == workout.id)
        #expect(result.progress?.needed == 1)
    }

    @Test("suggests a category whose later check-ins were mostly better, in non-causal words")
    func suggestsPositiveLaterPattern() throws {
        let workout = JournalCategory(name: "Workout")
        let entries = logs(workout, count: 5)
        let result = report(entries, answers(entries, [.aLittleBetter, .muchBetter, .aLittleBetter, .same, .aLittleBetter]), [workout])
        let suggestion = try #require(result.suggestions.first)
        #expect(suggestion.category.id == workout.id)
        #expect(suggestion.betterCount == 4)
        #expect(suggestion.numericCount == 5)
        #expect(suggestion.headline == "Workout has tended to be followed by feeling better later.")
        #expect(suggestion.evidence.hasPrefix("Better in 4 of 5 later check-ins"))
        expectNonCausal([suggestion.headline, suggestion.evidence, suggestion.context ?? ""])
        #expect(result.progress == nil)
    }

    private func expectNonCausal(_ strings: [String]) {
        let text = strings.joined(separator: " ").lowercased()
        for causal in ["help", "because", "causes", "makes you", "leads to"] { #expect(!text.contains(causal), "\(causal) in \(text)") }
    }

    @Test("keeps the card and nudge copy non-causal in every state")
    func cardCopyIsNonCausal() {
        let workout = JournalCategory(name: "Workout")
        let progress = InsightProgress(category: workout, numericCount: 4, needed: 1)
        let messages = [
            HelpSuggestionCopy.emptyMessage(HelpSuggestionReport(suggestions: [], patternCount: 1, progress: nil)),
            HelpSuggestionCopy.emptyMessage(HelpSuggestionReport(suggestions: [], patternCount: 0, progress: progress)),
            HelpSuggestionCopy.emptyMessage(HelpSuggestionReport(suggestions: [], patternCount: 0, progress: nil))
        ]
        #expect(Set(messages).count == 3)
        #expect(messages[1].contains("Workout needs 1 more later check-in "))
        expectNonCausal([HelpSuggestionCopy.title] + messages)
        expectNonCausal([SuggestionNudgeCopy.title, SuggestionNudgeCopy.body(categoryName: "Workout", betterCount: 4, numericCount: 5, style: .specific), SuggestionNudgeCopy.body(categoryName: "Workout", betterCount: 4, numericCount: 5, style: .generic)])
        // The footnote is the disclaimer itself, so it names "causes" on purpose.
        #expect(HelpSuggestionCopy.footnote.hasSuffix("These are patterns, not causes."))
    }

    @Test("finds the hour most better-followed logs cluster around")
    func usualHour() throws {
        let walk = JournalCategory(name: "Walk")
        let read = JournalCategory(name: "Read")
        let day = calendar.startOfDay(for: now)
        func log(_ category: JournalCategory, daysAgo: Int, hour: Int) -> JournalEntry {
            let date = calendar.date(byAdding: .hour, value: hour - 24 * daysAgo, to: day)!
            return JournalEntry(body: category.name, eventAt: date, createdAt: date, updatedAt: date, categories: [category])
        }
        let walks = [17, 18, 18, 19, 9].enumerated().map { log(walk, daysAgo: $0.offset + 1, hour: $0.element) }
        let reads = [7, 12, 16, 20, 23].enumerated().map { log(read, daysAgo: $0.offset + 1, hour: $0.element) }
        let result = report(walks + reads, answers(walks, [.aLittleBetter]) + answers(reads, [.aLittleBetter]), [walk, read])
        #expect(try #require(result.suggestions.first { $0.category.id == walk.id }).usualHour == 18)
        #expect(try #require(result.suggestions.first { $0.category.id == read.id }).usualHour == nil)
    }

    @Test("qualifies at exactly 60 percent better but not at 40 percent")
    func sixtyPercentBoundary() {
        let workout = JournalCategory(name: "Workout")
        let social = JournalCategory(name: "Social")
        let workoutLogs = logs(workout, count: 5)
        let socialLogs = logs(social, count: 5)
        let checkIns = answers(workoutLogs, [.aLittleBetter, .aLittleBetter, .aLittleBetter, .same, .same])
            + answers(socialLogs, [.muchBetter, .muchBetter, .same, .same, .same])
        let result = report(workoutLogs + socialLogs, checkIns, [workout, social])
        #expect(result.suggestions.map(\.category.name) == ["Workout"])
        #expect(result.suggestions.first?.betterCount == 3)
        #expect(result.patternCount == 2)
    }

    @Test("breaks equal scores by category name")
    func tieBreaksByName() {
        let beta = JournalCategory(name: "Beta")
        let alpha = JournalCategory(name: "Alpha")
        let betaLogs = logs(beta, count: 5, hourOffset: 12)
        let alphaLogs = logs(alpha, count: 5, hourOffset: 12)
        let result = report(betaLogs + alphaLogs, answers(betaLogs, [.aLittleBetter]) + answers(alphaLogs, [.aLittleBetter]), [beta, alpha])
        #expect(result.suggestions.map(\.category.name) == ["Alpha", "Beta"])
        #expect(result.suggestions[0].score == result.suggestions[1].score)
    }

    @Test("does not count skipped or pending later check-ins")
    func ignoresSkippedAndPending() {
        let workout = JournalCategory(name: "Workout")
        let entries = logs(workout, count: 6)
        let answered = answers(Array(entries.prefix(4)), [.muchBetter])
        let skipped = OutcomeCheckIn(entry: entries[4], phase: .delayed, status: .skipped, dueAt: entries[4].eventAt, createdAt: entries[4].eventAt, updatedAt: entries[4].eventAt)
        let pending = OutcomeCheckIn(entry: entries[5], phase: .delayed, dueAt: now.addingTimeInterval(3600), createdAt: entries[5].eventAt, updatedAt: entries[5].eventAt)
        let result = report(entries, answered + [skipped, pending], [workout])
        #expect(result.suggestions.isEmpty)
        #expect(result.patternCount == 0)
        #expect(result.progress?.numericCount == 4)
        #expect(result.progress?.needed == 1)
    }

    @Test("ignores a category that felt better right after but worse later")
    func ignoresRightAfterOnly() {
        let alcohol = JournalCategory(name: "Alcohol")
        let entries = logs(alcohol, count: 6)
        let checkIns = answers(entries, [.muchBetter], phase: .immediate) + answers(entries, [.aLittleWorse], phase: .delayed)
        let result = report(entries, checkIns, [alcohol])
        #expect(result.suggestions.isEmpty)
        #expect(result.patternCount == 1)
        #expect(result.progress == nil)
    }

    @Test("does not suggest mixed or neutral patterns")
    func ignoresMixedAndNeutral() {
        let work = JournalCategory(name: "Work")
        let sleep = JournalCategory(name: "Sleep")
        let workLogs = logs(work, count: 5)
        let sleepLogs = logs(sleep, count: 5)
        let checkIns = answers(workLogs, [.aLittleBetter, .aLittleBetter, .aLittleBetter, .aLittleWorse, .aLittleWorse])
            + answers(sleepLogs, [.same])
        let result = report(workLogs + sleepLogs, checkIns, [work, sleep])
        #expect(result.suggestions.isEmpty)
        #expect(result.patternCount == 2)
    }

    @Test("skips archived categories")
    func skipsArchived() {
        let workout = JournalCategory(name: "Workout", archivedAt: now)
        let entries = logs(workout, count: 6)
        #expect(report(entries, answers(entries, [.muchBetter]), [workout]).suggestions.isEmpty)
    }

    @Test("only counts later responses from the last 90 days")
    func usesNinetyDayWindow() {
        let workout = JournalCategory(name: "Workout")
        let old = logs(workout, count: 5, firstDay: 100)
        let recent = logs(workout, count: 2)
        let result = report(old + recent, answers(old + recent, [.muchBetter]), [workout])
        #expect(result.suggestions.isEmpty)
        #expect(result.progress?.numericCount == 2)
    }

    @Test("ranks stronger and deeper evidence first and respects the limit")
    func ranksAndLimits() {
        let workout = JournalCategory(name: "Workout")
        let social = JournalCategory(name: "Social")
        let sleep = JournalCategory(name: "Sleep")
        let workoutLogs = logs(workout, count: 10, hourOffset: 12)
        let socialLogs = logs(social, count: 5, hourOffset: 12)
        let sleepLogs = logs(sleep, count: 5, hourOffset: 12)
        let checkIns = answers(workoutLogs, [.muchBetter]) + answers(socialLogs, [.aLittleBetter, .aLittleBetter, .aLittleBetter, .same, .same]) + answers(sleepLogs, [.muchBetter, .aLittleBetter])
        let result = report(workoutLogs + socialLogs + sleepLogs, checkIns, [social, sleep, workout], limit: 2)
        #expect(result.suggestions.map(\.category.name) == ["Workout", "Sleep"])
        #expect(result.patternCount == 3)
    }

    @Test("moves a category already logged today below one that was not")
    func demotesLoggedToday() {
        let workout = JournalCategory(name: "Workout")
        let social = JournalCategory(name: "Social")
        let workoutLogs = logs(workout, count: 6, hourOffset: 12)
        let socialLogs = logs(social, count: 6, hourOffset: 12)
        let todayDate = calendar.date(byAdding: .hour, value: -1, to: now)!
        let today = JournalEntry(body: "Morning run", eventAt: todayDate, createdAt: todayDate, updatedAt: todayDate, categories: [workout])
        let checkIns = answers(workoutLogs, [.aLittleBetter]) + answers(socialLogs, [.aLittleBetter])
        let result = report(workoutLogs + socialLogs + [today], checkIns, [workout, social])
        #expect(result.suggestions.map(\.category.name) == ["Social", "Workout"])
        #expect(result.suggestions.last?.loggedToday == true)
        #expect(result.suggestions.last?.context == "Already logged today.")
        #expect(result.suggestions.first?.daysSinceLastLog == 1)
    }

    @Test("notices when helpful logs usually happen around this time of day")
    func timeOfDay() throws {
        let walk = JournalCategory(name: "Walk")
        let read = JournalCategory(name: "Reading")
        let walkLogs = logs(walk, count: 5, firstDay: 3)
        let readLogs = logs(read, count: 5, firstDay: 3, hourOffset: 12)
        let result = report(walkLogs + readLogs, answers(walkLogs, [.aLittleBetter]) + answers(readLogs, [.aLittleBetter]), [read, walk])
        let first = try #require(result.suggestions.first)
        #expect(first.category.id == walk.id)
        #expect(first.usualTimeOfDay)
        #expect(first.context == "You’ve often logged it around this time of day.")
        let second = try #require(result.suggestions.last)
        #expect(!second.usualTimeOfDay)
        #expect(second.context == "Last logged 3 days ago.")
    }

    @Test("says when it tended to feel worse right after")
    func rightAfterCaveat() throws {
        let workout = JournalCategory(name: "Workout")
        let entries = logs(workout, count: 5, hourOffset: 12)
        let checkIns = answers(entries, [.aLittleWorse], phase: .immediate) + answers(entries, [.muchBetter])
        let suggestion = try #require(report(entries, checkIns, [workout]).suggestions.first)
        #expect(suggestion.worseRightAfter)
        #expect(suggestion.context?.contains("It tended to feel worse right after.") == true)
    }

    @Test("ignores excluded and unsure check-ins")
    func ignoresExcluded() {
        let workout = JournalCategory(name: "Workout")
        let entries = logs(workout, count: 6)
        let checkIns = answers(entries, [.muchBetter])
        checkIns[0].excludedFromAnalysis = true
        checkIns[1].status = .notSure
        checkIns[1].overall = nil
        let result = report(entries, checkIns, [workout])
        #expect(result.suggestions.isEmpty)
        #expect(result.progress?.numericCount == 4)
    }
}
