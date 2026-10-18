import Charts
import SwiftUI
import UIKit

struct PatternsRootView: View {
    let store: JournalStore
    /// Set when a suggestion nudge is tapped; opens that category's later evidence.
    @Binding var evidenceRequest: UUID?
    @State private var outcomeCategoryID: UUID?
    @State private var outcomeRange: OutcomeTrendRange = .ninety
    @State private var outcomePhase: OutcomePhase = .delayed
    @State private var helpReport: HelpSuggestionReport?
    /// Set once Outcomes has picked a category on its own, so clearing it later sticks.
    @State private var didPickDefaultCategory = false
    /// True while the app, not the user, changes the Outcomes category, so the page doesn't jump.
    @State private var isPickingCategoryForUser = false
    /// Bumped to scroll to the evidence, even when the category it shows was already selected.
    @State private var evidenceScrollRequest = 0
    @State private var clock = Date.now

    private var outcomeCategory: JournalCategory? { outcomeCategoryID.flatMap { id in store.categories.first { $0.id == id } } }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    ContentColumn {
                        VStack(alignment: .leading, spacing: 18) {
                            ForesightPageHeader(
                                kicker: "Reflect, don’t conclude",
                                title: "See what repeats.",
                                subtitle: "Foresight describes associations in your own logs. It does not claim causes."
                            )
                            helpedCard
                            if store.entries.isEmpty {
                                // Charts and category pickers have nothing to show before the first log.
                                EmptyState(title: "Nothing to compare yet", detail: "Write a few logs with categories and check in later. Patterns describes what tended to follow them.")
                            } else {
                                outcomesView
                            }
                        }
                        .padding()
                    }
                }
                .background(Color.foresightCanvas)
                .onChange(of: outcomeCategoryID) { oldValue, newValue in
                    if isPickingCategoryForUser { isPickingCategoryForUser = false; return }
                    guard oldValue != newValue else { return }
                    withAnimation(.snappy) { proxy.scrollTo("outcome-controls", anchor: .top) }
                }
                .onChange(of: evidenceScrollRequest) {
                    // Waits a turn so the evidence has laid out for a newly picked category.
                    Task { @MainActor in withAnimation(.snappy) { proxy.scrollTo("outcome-controls", anchor: .top) } }
                }
            }
            .onChange(of: evidenceRequest, initial: true) { _, request in
                guard let request else { return }
                if let category = store.categories.first(where: { $0.id == request }) { showHelpEvidence(category) }
                evidenceRequest = nil
            }
            .onChange(of: HelpReportKey(store: store, now: clock), initial: true) {
                helpReport = helpSuggestions(entries: store.entries, checkIns: store.checkIns, categories: store.categories)
                pickDefaultOutcomeCategory()
            }
            .hourlyClock($clock)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { JournalDetailView(store: store, entryID: $0) }
        }
    }

    private var outcomesView: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForesightCard {
                VStack(alignment: .leading, spacing: 13) {
                    SectionKicker(text: "Outcome evidence")
                    Text("Choose what to examine").font(ForesightType.sectionTitle).foregroundStyle(Color.foresightInk)
                    Text("Every card below follows the category selected here.").font(.subheadline).foregroundStyle(Color.foresightMuted)
                    ForesightDropdown(
                        id: "patterns.outcomes.category",
                        selection: $outcomeCategoryID,
                        options: categoryOptions(firstTitle: "Clear category", firstID: "clear-category"),
                        style: .fullWidth(systemImage: "tag.fill", label: "Category"),
                        title: outcomeCategory?.name ?? "Select a category",
                        accessibilityLabel: "Choose category",
                        accessibilityValue: outcomeCategory?.name ?? "No category selected"
                    )
                    SectionKicker(text: "Time window")
                    ForesightSegmentedPicker(
                        selection: $outcomeRange,
                        options: OutcomeTrendRange.allCases.map { ($0, $0.title) }
                    )
                    SectionKicker(text: "Reflection timing")
                    ForesightSegmentedPicker(
                        selection: $outcomePhase,
                        options: OutcomePhase.allCases.map { ($0, $0.title) }
                    )
                }
            }
            .id("outcome-controls")
            if let category = outcomeCategory { outcomeDetail(category) }
            else { EmptyState(title: "Choose a category", detail: "Select a category to see its outcome evidence and source logs.") }
            rankedInsights
        }
    }

    private func categoryOptions(firstTitle: String, firstID: String) -> [ForesightDropdownOption<UUID?, String>] {
        [ForesightDropdownOption(id: firstID, value: nil, title: firstTitle)]
            + store.categories.map {
                ForesightDropdownOption(id: "category-\($0.id.uuidString)", value: Optional($0.id), title: $0.name, badge: $0.isArchived ? "Archived" : nil)
            }
    }

    private func outcomeDetail(_ category: JournalCategory) -> some View {
        let trend = outcomeTrend(entries: store.entries, checkIns: store.checkIns, category: category, phase: outcomePhase, range: outcomeRange)
        let insight = categoryOutcomeInsight(entries: store.entries, checkIns: store.checkIns, category: category, phase: outcomePhase, range: outcomeRange)
        let sourceEntries = store.entries.filter { trend.sourceEntryIDs.contains($0.id) }.sorted { $0.eventAt > $1.eventAt }
        return VStack(alignment: .leading, spacing: 14) {
            ForesightCard {
                VStack(alignment: .leading, spacing: 13) {
                    HStack { SectionKicker(text: "Category evidence"); Spacer(); if let insight { Text(insight.evidenceDepth.rawValue).font(.caption.weight(.bold)).foregroundStyle(Color.foresightSage).padding(.horizontal, 9).padding(.vertical, 5).background(Color.foresightSoftSage, in: Capsule()) } }
                    Text("\(trend.logCount) \(trend.logCount == 1 ? "log" : "logs") in the last \(outcomeRange.rawValue) days · \(outcomePhase == .immediate ? "right after" : "later")").font(.subheadline).foregroundStyle(.secondary)
                    if let insight {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(insight.headline).font(ForesightType.insight).foregroundStyle(Color.foresightInk)
                            Text(insight.detail).font(.caption).foregroundStyle(.secondary)
                        }.padding(13).background(insightBackground(insight.direction), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else if trend.scheduledCount == 0 {
                        Text("No \(outcomePhase == .immediate ? "right-after" : "later") check-ins for these logs.").foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Keep checking in").font(.headline)
                            Text("\(max(0, minimumPatternResponses - trend.numericCount)) more numeric \(max(0, minimumPatternResponses - trend.numericCount) == 1 ? "response" : "responses") needed before Foresight describes a pattern.").font(.subheadline).foregroundStyle(.secondary)
                            ProgressView(value: Double(trend.numericCount), total: Double(minimumPatternResponses)).tint(Color.foresightSage)
                        }.padding(13).background(Color.foresightSoftSage, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    HStack(spacing: 8) {
                        MetricBox(value: "\(trend.numericCount)", label: "numeric responses")
                        MetricBox(value: trend.responseRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", label: "coverage")
                        MetricBox(value: trend.average.map(describeAverageOutcome) ?? "—", label: "average")
                    }
                    OutcomeDistribution(trend: trend)
                    if trend.notSureCount + trend.skippedCount + trend.pendingCount > 0 { Text("\(trend.notSureCount) unsure · \(trend.skippedCount) skipped · \(trend.pendingCount) pending are not included in the average").font(.caption).foregroundStyle(.secondary) }
                }
            }
            logFrequencyCard(category)
            if let shift = phaseComparisonInsight(entries: store.entries, checkIns: store.checkIns, category: category, range: outcomeRange) { NarrativeCard(kicker: "Timing shift", headline: shift.headline, detail: shift.detail, color: Color.foresightSoftSage) }
            if let change = outcomeChangeInsight(entries: store.entries, checkIns: store.checkIns, category: category, phase: outcomePhase, range: outcomeRange) { NarrativeCard(kicker: "Changing over time", headline: change.headline, detail: change.detail, color: Color.foresightWarm) }
            if !sourceEntries.isEmpty {
                ForesightCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionKicker(text: "Evidence")
                        Text("Source logs").font(ForesightType.sectionTitle).foregroundStyle(Color.foresightInk)
                        Text("Showing \(min(8, sourceEntries.count)) of \(sourceEntries.count) numeric responses.").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(sourceEntries.prefix(8)), id: \.id) { entry in
                            NavigationLink(value: entry.id) {
                                VStack(alignment: .leading, spacing: 4) { Text(ForesightFormat.listDate(entry.eventAt)).font(.caption.weight(.bold)).foregroundStyle(Color.foresightSage); Text(entry.body).font(.subheadline).lineLimit(2).multilineTextAlignment(.leading) }
                            }.buttonStyle(.plain).accessibilityLabel("Open source log")
                            Divider()
                        }
                    }
                }
            }
        }
    }

    /// How often the category is logged, so its evidence can be read against how much of it there is.
    private func logFrequencyCard(_ category: JournalCategory) -> some View {
        let weeks = activityBuckets(store.entries, category: category, granularity: .week)
        let thisWeek = weeks.last?.count ?? 0
        let lastWeek = weeks.dropLast().last?.count ?? 0
        // Every other week, ending on this one, so the labels don't crowd.
        let axisLabels = weeks.indices.filter { (weeks.count - 1 - $0) % 2 == 0 }.map { weeks[$0].label }
        return ForesightCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionKicker(text: "How often")
                Text("\(category.name) logs per week").font(.subheadline.weight(.semibold)).foregroundStyle(Color.foresightInk)
                HStack(spacing: 8) {
                    MetricBox(value: "\(thisWeek)", label: "this week")
                    MetricBox(value: "\(lastWeek)", label: "last week")
                    MetricBox(value: "\(weeks.reduce(0) { $0 + $1.count })", label: "last 8 weeks")
                }
                // Labels, not dates, on the x axis: a band per week keeps the last bar off the edge.
                Chart(weeks) { week in
                    BarMark(x: .value("Week", week.label), y: .value("Logs", week.count))
                        .foregroundStyle(Color.foresightSage.gradient)
                        .cornerRadius(4)
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .chartXAxis { AxisMarks(values: axisLabels) }
                .frame(height: 140)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(category.name) logs per week")
                Text("Eight weeks, each starting on Monday.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var helpedCard: some View {
        if let report = helpReport { helpedCardContent(report) }
    }

    private func helpedCardContent(_ report: HelpSuggestionReport) -> some View {
        ForesightCard {
            VStack(alignment: .leading, spacing: 11) {
                SectionKicker(text: HelpSuggestionCopy.title)
                if report.suggestions.isEmpty {
                    Text(HelpSuggestionCopy.emptyMessage(report)).font(.subheadline).foregroundStyle(Color.foresightMuted)
                } else {
                    // Said once for the card when several suggestions share it, instead of on each row.
                    let sharedTimeNote = HelpSuggestionCopy.sharedUsualTimeNote(report.suggestions)
                    if let sharedTimeNote { Text(sharedTimeNote).font(.caption).foregroundStyle(Color.foresightSage) }
                    ForEach(report.suggestions) { suggestion in
                        Button { showHelpEvidence(suggestion.category) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Capsule().fill(Color.foresightSageMid).frame(width: 5, height: 38)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(suggestion.headline).font(.subheadline).foregroundStyle(Color.foresightInk).multilineTextAlignment(.leading)
                                    Text(suggestion.evidence).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                    if let context = suggestion.context(showingUsualTime: sharedTimeNote == nil) { Text(context).font(.caption).foregroundStyle(Color.foresightSage).multilineTextAlignment(.leading) }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Color.foresightMuted)
                            }
                            .padding(12)
                            .background(Color.foresightSoftSage, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("See \(suggestion.category.name) later evidence")
                    }
                    Text(HelpSuggestionCopy.footnote).font(.caption2).foregroundStyle(Color.foresightMuted)
                }
            }
        }
    }

    /// Opens Outcomes on something worth reading instead of an empty "choose a category" card:
    /// the top suggestion, else the clearest pattern, else the category closest to having one.
    private func pickDefaultOutcomeCategory() {
        // After an erase the old pick no longer exists; start over as if nothing was chosen.
        if let id = outcomeCategoryID, !store.categories.contains(where: { $0.id == id }) {
            isPickingCategoryForUser = true
            outcomeCategoryID = nil
            didPickDefaultCategory = false
        }
        guard outcomeCategoryID == nil, !didPickDefaultCategory else { return }
        let pick = helpReport?.suggestions.first?.category
            ?? categoryOutcomeInsights(entries: store.entries, checkIns: store.checkIns, categories: store.categories, phase: outcomePhase, range: outcomeRange).first?.category
            ?? closestInsightProgress(entries: store.entries, checkIns: store.checkIns, categories: store.activeCategories, phase: outcomePhase, range: outcomeRange, now: .now)?.category
        guard let pick else { return }
        isPickingCategoryForUser = true
        outcomeCategoryID = pick.id
        didPickDefaultCategory = true
    }

    private func showHelpEvidence(_ category: JournalCategory) {
        outcomePhase = .delayed
        outcomeRange = helpSuggestionRange
        outcomeCategoryID = category.id
        evidenceScrollRequest += 1
    }

    private var rankedInsights: some View {
        let insights = categoryOutcomeInsights(entries: store.entries, checkIns: store.checkIns, categories: store.categories, phase: outcomePhase, range: outcomeRange)
        let shortcuts = insights.filter { $0.category.id != outcomeCategoryID }
        let progress = closestInsightProgress(entries: store.entries, checkIns: store.checkIns, categories: store.categories, phase: outcomePhase, range: outcomeRange)
        return ForesightCard {
            VStack(alignment: .leading, spacing: 11) {
                SectionKicker(text: insights.isEmpty ? "What stands out" : "Explore another category")
                if insights.isEmpty {
                    if let progress { Text("\(progress.category.name) is closest: \(progress.needed) more numeric \(progress.needed == 1 ? "response" : "responses") needed for a pattern.").foregroundStyle(.secondary) }
                    else { Text("Add tagged logs and check-ins to begin building evidence.").foregroundStyle(.secondary) }
                } else if shortcuts.isEmpty {
                    Text("You’re viewing the only category with a clear pattern in this time window.")
                        .font(.subheadline)
                        .foregroundStyle(Color.foresightMuted)
                } else {
                    Text("These are shortcuts. Tap one to load its evidence above.")
                        .font(.caption)
                        .foregroundStyle(Color.foresightMuted)
                    ForEach(shortcuts.prefix(5)) { insight in
                        Button { outcomeCategoryID = insight.category.id } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Capsule().fill(insightMarker(insight.direction)).frame(width: 5, height: 38)
                                VStack(alignment: .leading, spacing: 3) { Text(insight.headline).font(.subheadline).multilineTextAlignment(.leading); Text("\(insight.evidenceDepth.rawValue) · \(insight.detail)").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading) }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.foresightMuted)
                            }
                            .padding(12)
                            .background(Color.foresightRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("View \(insight.category.name) outcome evidence")
                    }
                }
            }
        }
    }

    private func insightBackground(_ direction: OutcomeDirection) -> Color { switch direction { case .positive: .foresightSoftSage; case .negative: .foresightNegative.opacity(0.14); case .neutral: .foresightRaised; case .mixed: .foresightWarm } }
    private func insightMarker(_ direction: OutcomeDirection) -> Color { switch direction { case .positive: .foresightSageMid; case .negative: .foresightNegative; case .neutral: .foresightMuted; case .mixed: .foresightWarning } }
}

/// Changes whenever the data or the hour does, so suggestions are recomputed
/// on edits rather than on every render.
struct HelpReportKey: Equatable {
    let entryCount: Int
    let latestEntryEdit: Date?
    let checkInCount: Int
    let latestCheckInEdit: Date?
    let categoryCount: Int
    let archivedCount: Int
    /// The start of the current local hour.
    let hour: Date?

    @MainActor init(store: JournalStore, now: Date = .now, calendar: Calendar = .current) {
        entryCount = store.entries.count
        latestEntryEdit = store.entries.map(\.updatedAt).max()
        checkInCount = store.checkIns.count
        latestCheckInEdit = store.checkIns.map(\.updatedAt).max()
        categoryCount = store.categories.count
        archivedCount = store.categories.filter(\.isArchived).count
        hour = calendar.dateInterval(of: .hour, for: now)?.start
    }
}

struct MetricBox: View {
    let value: String
    let label: String
    var body: some View { VStack(alignment: .leading, spacing: 3) { Text(value).font(.headline).foregroundStyle(Color.foresightSage).lineLimit(2); Text(label).font(.caption2).foregroundStyle(Color.foresightMuted).lineLimit(2) }.frame(maxWidth: .infinity, minHeight: 54, alignment: .leading).padding(10).background(Color.foresightRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous)) }
}

struct OutcomeDistribution: View {
    let trend: OutcomeTrend
    var body: some View {
        let total = max(1, trend.numericCount)
        VStack(alignment: .leading, spacing: 7) {
            Text("Outcome mix").font(.subheadline.weight(.semibold))
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    Color.foresightSage.frame(width: proxy.size.width * CGFloat(trend.betterCount) / CGFloat(total))
                    Color.foresightMuted.opacity(0.45).frame(width: proxy.size.width * CGFloat(trend.sameCount) / CGFloat(total))
                    Color.foresightNegative.frame(width: proxy.size.width * CGFloat(trend.worseCount) / CGFloat(total))
                }
            }.frame(height: 10).clipShape(Capsule())
            Text("Better \(trend.betterCount) · Same \(trend.sameCount) · Worse \(trend.worseCount)").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct NarrativeCard: View {
    let kicker: String
    let headline: String
    let detail: String
    let color: Color
    var body: some View { VStack(alignment: .leading, spacing: 7) { SectionKicker(text: kicker); Text(headline).font(ForesightType.insight).foregroundStyle(Color.foresightInk); Text(detail).font(.caption).foregroundStyle(Color.foresightMuted) }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(color, in: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
}
