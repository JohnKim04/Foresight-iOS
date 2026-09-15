import Foundation
import Testing
@testable import Foresight

@MainActor
struct OutcomeAnalyticsTests {
    private let now = Date(timeIntervalSince1970: 1_725_000_000)

    private func category(_ name: String = "Workout") -> JournalCategory { JournalCategory(name: name) }
    private func entry(_ category: JournalCategory, offsetDays: Int = 0, body: String = "Log") -> JournalEntry {
        let date = Calendar.current.date(byAdding: .day, value: offsetDays, to: now)!
        return JournalEntry(body: body, eventAt: date, createdAt: date, updatedAt: date, categories: [category])
    }
    private func answer(_ entry: JournalEntry, value: OutcomeValue, phase: OutcomePhase = .delayed, excluded: Bool = false, offset: Int = 0) -> OutcomeCheckIn {
        let date = Calendar.current.date(byAdding: .minute, value: offset, to: now)!
        return OutcomeCheckIn(entry: entry, phase: phase, status: .answered, dueAt: phase == .delayed ? date : nil, answeredAt: date, overall: value, excludedFromAnalysis: excluded, createdAt: date, updatedAt: date)
    }

    @Test("counts numeric, unsure, skipped, pending, and excluded outcome records")
    func aggregatesOutcomes() {
        let workout = category()
        let log = entry(workout)
        let numeric = answer(log, value: .muchBetter)
        let excluded = answer(log, value: .muchWorse, excluded: true)
        let unsure = OutcomeCheckIn(entry: log, phase: .delayed, status: .notSure, dueAt: now, answeredAt: now, createdAt: now, updatedAt: now)
        let skipped = OutcomeCheckIn(entry: log, phase: .delayed, status: .skipped, dueAt: now, createdAt: now, updatedAt: now)
        let pending = OutcomeCheckIn(entry: log, phase: .delayed, dueAt: now, createdAt: now, updatedAt: now)
        let trend = outcomeTrend(entries: [log], checkIns: [numeric, excluded, unsure, skipped, pending], category: workout, phase: .delayed, range: .thirty, now: now)
        #expect(trend.scheduledCount == 4)
        #expect(trend.numericCount == 1)
        #expect(trend.notSureCount == 1)
        #expect(trend.skippedCount == 1)
        #expect(trend.pendingCount == 1)
        #expect(trend.average == 2)
    }

    @Test("requires five numeric responses for a pattern")
    func requiresFiveResponses() {
        let workout = category()
        let logs = (0..<4).map { entry(workout, offsetDays: -$0) }
        let checkIns = logs.map { answer($0, value: .aLittleBetter) }
        let trend = outcomeTrend(entries: logs, checkIns: checkIns, category: workout, phase: .delayed, range: .thirty, now: now)
        #expect(!trend.hasEnoughEvidence)
        #expect(categoryOutcomeInsight(entries: logs, checkIns: checkIns, category: workout, phase: .delayed, range: .thirty, now: now)?.numericCount == nil)
    }

    @Test("creates a positive insight with sixty percent agreement")
    func positiveInsight() {
        let workout = category()
        let logs = (0..<5).map { entry(workout, offsetDays: -$0) }
        let values: [OutcomeValue] = [.muchBetter, .aLittleBetter, .aLittleBetter, .same, .aLittleWorse]
        let insight = categoryOutcomeInsight(entries: logs, checkIns: zip(logs, values).map { answer($0.0, value: $0.1) }, category: workout, phase: .delayed, range: .thirty, now: now)
        #expect(insight?.direction == .positive)
        #expect(insight?.headline.contains("followed by") == true)
    }

    @Test("classifies neutral and mixed patterns conservatively")
    func neutralAndMixed() {
        let workout = category()
        let logs = (0..<5).map { entry(workout, offsetDays: -$0) }
        let neutral = outcomeTrend(entries: logs, checkIns: logs.map { answer($0, value: .same) }, category: workout, phase: .delayed, range: .thirty, now: now)
        let mixedValues: [OutcomeValue] = [.muchBetter, .muchWorse, .same, .aLittleBetter, .aLittleWorse]
        let mixed = outcomeTrend(entries: logs, checkIns: zip(logs, mixedValues).map { answer($0.0, value: $0.1) }, category: workout, phase: .delayed, range: .thirty, now: now)
        #expect(outcomeDirection(neutral) == .neutral)
        #expect(outcomeDirection(mixed) == .mixed)
    }

    @Test("uses early building and established evidence labels")
    func evidenceLabels() {
        #expect(evidenceDepth(5) == .early)
        #expect(evidenceDepth(8) == .building)
        #expect(evidenceDepth(15) == .established)
    }

    @Test("ranks stronger category insights first")
    func ranksInsights() {
        let workout = category("Workout")
        let alcohol = category("Alcohol")
        let workoutLogs = (0..<5).map { entry(workout, offsetDays: -$0) }
        let alcoholLogs = (0..<5).map { entry(alcohol, offsetDays: -$0) }
        let insights = categoryOutcomeInsights(entries: workoutLogs + alcoholLogs, checkIns: workoutLogs.map { answer($0, value: .muchBetter) } + alcoholLogs.map { answer($0, value: .same) }, categories: [alcohol, workout], phase: .delayed, range: .thirty, now: now)
        #expect(insights.first?.category.id == workout.id)
    }

    @Test("detects a meaningful immediate-to-later timing shift")
    func timingShift() {
        let alcohol = category("Alcohol")
        let logs = (0..<5).map { entry(alcohol, offsetDays: -$0) }
        let checkIns = logs.flatMap { [answer($0, value: .muchBetter, phase: .immediate), answer($0, value: .muchWorse, phase: .delayed)] }
        let shift = phaseComparisonInsight(entries: logs, checkIns: checkIns, category: alcohol, range: .thirty, now: now)
        #expect(shift != nil)
        #expect(shift?.headline.contains("shifted") == true)
    }

    @Test("finds a recent outcome change only with three responses in each window")
    func recentChange() {
        let work = category("Work")
        let earlier = (0..<3).map { entry(work, offsetDays: -80 + $0) }
        let recent = (0..<3).map { entry(work, offsetDays: -5 - $0) }
        let checkIns = earlier.map { answer($0, value: .muchWorse) } + recent.map { answer($0, value: .muchBetter) }
        let change = outcomeChangeInsight(entries: earlier + recent, checkIns: checkIns, category: work, phase: .delayed, range: .ninety, now: now)
        #expect(change?.recentAverage == 2)
        #expect(change?.earlierAverage == -2)
    }

    @Test("finds closest progress when evidence is sparse")
    func closestProgress() {
        let sleep = category("Sleep")
        let logs = (0..<3).map { entry(sleep, offsetDays: -$0) }
        let progress = closestInsightProgress(entries: logs, checkIns: logs.map { answer($0, value: .aLittleBetter) }, categories: [sleep], phase: .delayed, range: .thirty, now: now)
        #expect(progress?.numericCount == 3)
        #expect(progress?.needed == 2)
    }

    @Test("keeps source log IDs unique")
    func sourceLogIDs() {
        let social = category("Social")
        let log = entry(social)
        let trend = outcomeTrend(entries: [log], checkIns: [answer(log, value: .same), answer(log, value: .aLittleBetter, phase: .delayed, offset: 1)], category: social, phase: .delayed, range: .thirty, now: now)
        #expect(trend.sourceEntryIDs == [log.id])
    }

    @Test("describes averages with stable wording")
    func averageDescriptions() {
        #expect(describeAverageOutcome(-2) == "much worse")
        #expect(describeAverageOutcome(-1) == "a little worse")
        #expect(describeAverageOutcome(0) == "about the same")
        #expect(describeAverageOutcome(1) == "a little better")
        #expect(describeAverageOutcome(2) == "much better")
    }

    @Test("compares calendar-aligned activity weeks")
    func weekComparison() {
        let workout = category()
        let current = entry(workout, offsetDays: 0)
        let comparison = periodComparison([current], category: workout, granularity: .week, now: now)
        #expect(comparison.currentCount == 1)
        #expect(comparison.previousCount == 0)
    }

    @Test("builds eight weekly and six monthly buckets")
    func activityBucketCounts() {
        #expect(activityBuckets([], category: nil, granularity: .week, now: now).count == 8)
        #expect(activityBuckets([], category: nil, granularity: .month, now: now).count == 6)
    }

    @Test("calculates category activity changes")
    func activityTrends() {
        let workout = category()
        let log = entry(workout)
        let trends = categoryTrends([log], categories: [workout], range: .thirty, now: now)
        #expect(trends.first?.currentCount == 1)
        #expect(trends.first?.change == 1)
    }
}
