import Foundation

enum OutcomeTrendRange: Int, CaseIterable, Identifiable, Hashable {
    case thirty = 30
    case ninety = 90
    var id: Int { rawValue }
    var title: String { "\(rawValue) days" }
}

struct OutcomeTrend {
    let logCount: Int
    let scheduledCount: Int
    let responseCount: Int
    let numericCount: Int
    let notSureCount: Int
    let skippedCount: Int
    let pendingCount: Int
    let betterCount: Int
    let sameCount: Int
    let worseCount: Int
    let average: Double?
    let responseRate: Double?
    let sourceEntryIDs: [UUID]

    var hasEnoughEvidence: Bool { numericCount >= 5 }
}

func outcomeTrend(entries: [JournalEntry], checkIns: [OutcomeCheckIn], category: JournalCategory, phase: OutcomePhase, range: OutcomeTrendRange, now: Date = .now, calendar: Calendar = .current) -> OutcomeTrend {
    let end = calendar.date(byAdding: .day, value: 1, to: startOfDay(now, calendar: calendar))!
    let start = calendar.date(byAdding: .day, value: -(range.rawValue - 1), to: startOfDay(now, calendar: calendar))!
    let selected = entries.filter { $0.eventAt >= start && $0.eventAt < end && $0.categories.contains(where: { $0.id == category.id }) }
    let entryIDs = Set(selected.map(\.id))
    let scoped = checkIns.filter { $0.phase == phase && !($0.excludedFromAnalysis) && $0.entry.map { entryIDs.contains($0.id) } == true }
    let answered = scoped.filter { $0.status == .answered && $0.overall != nil }
    let unsure = scoped.filter { $0.status == .notSure }
    let skipped = scoped.filter { $0.status == .skipped }
    let pending = scoped.filter { $0.status == .pending }
    let values = answered.compactMap(\.overall).map(\.rawValue)
    let numericCount = values.count
    return OutcomeTrend(
        logCount: selected.count,
        scheduledCount: scoped.count,
        responseCount: numericCount + unsure.count,
        numericCount: numericCount,
        notSureCount: unsure.count,
        skippedCount: skipped.count,
        pendingCount: pending.count,
        betterCount: values.filter { $0 > 0 }.count,
        sameCount: values.filter { $0 == 0 }.count,
        worseCount: values.filter { $0 < 0 }.count,
        average: numericCount == 0 ? nil : Double(values.reduce(0, +)) / Double(numericCount),
        responseRate: scoped.isEmpty ? nil : Double(numericCount + unsure.count) / Double(scoped.count),
        sourceEntryIDs: Array(Set(answered.compactMap { $0.entry?.id }))
    )
}

func describeAverageOutcome(_ average: Double) -> String {
    switch average {
    case ...(-1.5): "much worse"
    case ..<(-0.25): "a little worse"
    case ...0.25: "about the same"
    case ..<1.5: "a little better"
    default: "much better"
    }
}

enum OutcomeDirection: String, Equatable { case positive, negative, neutral, mixed }
enum EvidenceDepth: String, Equatable { case early = "Early", building = "Building", established = "Established" }

struct CategoryOutcomeInsight: Identifiable {
    let category: JournalCategory
    let phase: OutcomePhase
    let direction: OutcomeDirection
    let evidenceDepth: EvidenceDepth
    let headline: String
    let detail: String
    let numericCount: Int
    let dominantCount: Int
    let dominantRate: Double
    let average: Double
    let responseRate: Double?
    let score: Double
    let trend: OutcomeTrend
    var id: String { "\(category.id.uuidString)-\(phase.rawValue)" }
}

struct PhaseComparisonInsight {
    let headline: String
    let detail: String
    let immediateAverage: Double
    let delayedAverage: Double
}

struct OutcomeChangeInsight {
    let headline: String
    let detail: String
    let recentAverage: Double
    let earlierAverage: Double
    let recentCount: Int
    let earlierCount: Int
}

struct InsightProgress {
    let category: JournalCategory
    let numericCount: Int
    let needed: Int
}

let minimumPatternResponses = 5
let minimumChangeResponsesPerWindow = 3

func evidenceDepth(_ numericCount: Int) -> EvidenceDepth {
    numericCount >= 15 ? .established : numericCount >= 8 ? .building : .early
}

func outcomeDirection(_ trend: OutcomeTrend) -> OutcomeDirection {
    guard trend.numericCount > 0, let average = trend.average else { return .mixed }
    let better = Double(trend.betterCount) / Double(trend.numericCount)
    let worse = Double(trend.worseCount) / Double(trend.numericCount)
    let same = Double(trend.sameCount) / Double(trend.numericCount)
    if better >= 0.6 && average >= 0.35 { return .positive }
    if worse >= 0.6 && average <= -0.35 { return .negative }
    if same >= 0.5 && abs(average) <= 0.35 { return .neutral }
    return .mixed
}

func categoryOutcomeInsight(entries: [JournalEntry], checkIns: [OutcomeCheckIn], category: JournalCategory, phase: OutcomePhase, range: OutcomeTrendRange, now: Date = .now) -> CategoryOutcomeInsight? {
    let trend = outcomeTrend(entries: entries, checkIns: checkIns, category: category, phase: phase, range: range, now: now)
    guard trend.numericCount >= minimumPatternResponses, let average = trend.average else { return nil }
    let direction = outcomeDirection(trend)
    let dominantCount: Int
    switch direction {
    case .positive: dominantCount = trend.betterCount
    case .negative: dominantCount = trend.worseCount
    case .neutral: dominantCount = trend.sameCount
    case .mixed: dominantCount = max(trend.betterCount, trend.sameCount, trend.worseCount)
    }
    let timing = phase == .immediate ? "right-after" : "later"
    let headline: String
    switch direction {
    case .positive: headline = "\(category.name) was followed by feeling better in \(trend.betterCount) of \(trend.numericCount) \(timing) check-ins."
    case .negative: headline = "\(category.name) was followed by feeling worse in \(trend.worseCount) of \(trend.numericCount) \(timing) check-ins."
    case .neutral: headline = "\(category.name) was followed by feeling about the same in \(trend.sameCount) of \(trend.numericCount) \(timing) check-ins."
    case .mixed: headline = "\(category.name) had mixed \(timing) outcomes."
    }
    let dominantRate = Double(dominantCount) / Double(trend.numericCount)
    let detail: String
    if direction == .mixed {
        detail = "\(trend.betterCount) better · \(trend.sameCount) same · \(trend.worseCount) worse"
    } else {
        let label = direction == .positive ? "better" : direction == .negative ? "worse" : "about the same"
        detail = "\(Int((dominantRate * 100).rounded()))% \(label) · average \(describeAverageOutcome(average))"
    }
    let directionWeight = (direction == .positive || direction == .negative) ? 1.0 : direction == .mixed ? 0.35 : 0.2
    let score = directionWeight * abs(average == 0 ? 0.2 : average) * sqrt(Double(trend.numericCount))
    return CategoryOutcomeInsight(category: category, phase: phase, direction: direction, evidenceDepth: evidenceDepth(trend.numericCount), headline: headline, detail: detail, numericCount: trend.numericCount, dominantCount: dominantCount, dominantRate: dominantRate, average: average, responseRate: trend.responseRate, score: score, trend: trend)
}

func categoryOutcomeInsights(entries: [JournalEntry], checkIns: [OutcomeCheckIn], categories: [JournalCategory], phase: OutcomePhase, range: OutcomeTrendRange, now: Date = .now) -> [CategoryOutcomeInsight] {
    categories.compactMap { categoryOutcomeInsight(entries: entries, checkIns: checkIns, category: $0, phase: phase, range: range, now: now) }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.numericCount != $1.numericCount ? $0.numericCount > $1.numericCount : $0.category.name < $1.category.name }
}

func phaseComparisonInsight(entries: [JournalEntry], checkIns: [OutcomeCheckIn], category: JournalCategory, range: OutcomeTrendRange, now: Date = .now) -> PhaseComparisonInsight? {
    let immediate = outcomeTrend(entries: entries, checkIns: checkIns, category: category, phase: .immediate, range: range, now: now)
    let delayed = outcomeTrend(entries: entries, checkIns: checkIns, category: category, phase: .delayed, range: range, now: now)
    guard immediate.numericCount >= minimumPatternResponses, delayed.numericCount >= minimumPatternResponses, let first = immediate.average, let second = delayed.average, abs(first - second) >= 0.75 else { return nil }
    return PhaseComparisonInsight(headline: "\(category.name) shifted from \(describeAverageOutcome(first)) right after to \(describeAverageOutcome(second)) later.", detail: "\(immediate.numericCount) right-after and \(delayed.numericCount) later responses", immediateAverage: first, delayedAverage: second)
}

func outcomeChangeInsight(entries: [JournalEntry], checkIns: [OutcomeCheckIn], category: JournalCategory, phase: OutcomePhase, range: OutcomeTrendRange, now: Date = .now, calendar: Calendar = .current) -> OutcomeChangeInsight? {
    let end = calendar.date(byAdding: .day, value: 1, to: startOfDay(now, calendar: calendar))!
    let start = calendar.date(byAdding: .day, value: -range.rawValue, to: end)!
    let midpoint = Date(timeIntervalSince1970: (start.timeIntervalSince1970 + end.timeIntervalSince1970) / 2)
    func values(in window: Range<Date>) -> [Int] {
        let ids = Set(entries.filter { $0.eventAt >= window.lowerBound && $0.eventAt < window.upperBound && $0.categories.contains(where: { $0.id == category.id }) }.map(\.id))
        return checkIns.filter { $0.phase == phase && $0.status == .answered && !$0.excludedFromAnalysis && $0.entry.map { ids.contains($0.id) } == true }.compactMap(\.overall).map(\.rawValue)
    }
    let earlier = values(in: start..<midpoint)
    let recent = values(in: midpoint..<end)
    guard earlier.count >= minimumChangeResponsesPerWindow, recent.count >= minimumChangeResponsesPerWindow else { return nil }
    let earlierAverage = Double(earlier.reduce(0, +)) / Double(earlier.count)
    let recentAverage = Double(recent.reduce(0, +)) / Double(recent.count)
    guard abs(recentAverage - earlierAverage) >= 0.5 else { return nil }
    let timing = phase == .immediate ? "right-after" : "later"
    return OutcomeChangeInsight(headline: "\(category.name)'s recent \(timing) responses were \(recentAverage > earlierAverage ? "more positive" : "more negative") than earlier in this period.", detail: "Recent: \(describeAverageOutcome(recentAverage)) (\(recent.count)) · Earlier: \(describeAverageOutcome(earlierAverage)) (\(earlier.count))", recentAverage: recentAverage, earlierAverage: earlierAverage, recentCount: recent.count, earlierCount: earlier.count)
}

func closestInsightProgress(entries: [JournalEntry], checkIns: [OutcomeCheckIn], categories: [JournalCategory], phase: OutcomePhase, range: OutcomeTrendRange, now: Date = .now) -> InsightProgress? {
    let candidates = categories.map { category in (category, outcomeTrend(entries: entries, checkIns: checkIns, category: category, phase: phase, range: range, now: now)) }
        .filter { $0.1.numericCount < minimumPatternResponses && $0.1.logCount > 0 }
        .sorted { $0.1.numericCount != $1.1.numericCount ? $0.1.numericCount > $1.1.numericCount : $0.0.name < $1.0.name }
    guard let candidate = candidates.first else { return nil }
    return InsightProgress(category: candidate.0, numericCount: candidate.1.numericCount, needed: minimumPatternResponses - candidate.1.numericCount)
}

enum ForesightFormat {
    static func listDate(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day().hour().minute()) }
    static func detailDate(_ date: Date) -> String { date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute()) }
    static func accessibleDate(_ date: Date) -> String { date.formatted(.dateTime.weekday(.wide).year().month(.wide).day().hour().minute()) }
}
