import Charts
import SwiftUI
import UIKit

enum PatternsMode: String, CaseIterable, Identifiable { case activity, outcomes; var id: String { rawValue }; var title: String { rawValue.capitalized } }

struct PatternsRootView: View {
    let store: JournalStore
    @State private var mode: PatternsMode = .outcomes
    @State private var activityGranularity: TrendGranularity = .week
    @State private var activityRange: TrendRange = .thirty
    @State private var activityCategoryID: UUID?
    @State private var outcomeCategoryID: UUID?
    @State private var outcomeRange: OutcomeTrendRange = .ninety
    @State private var outcomePhase: OutcomePhase = .delayed

    private var activityCategory: JournalCategory? { activityCategoryID.flatMap { id in store.categories.first { $0.id == id } } }
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
                            ForesightSegmentedPicker(
                                selection: $mode,
                                options: PatternsMode.allCases.map { ($0, $0.title) }
                            )
                            if mode == .activity { activityView } else { outcomesView }
                        }
                        .padding()
                    }
                }
                .background(Color.foresightCanvas)
                .onChange(of: activityCategoryID) { oldValue, newValue in
                    guard mode == .activity, oldValue != newValue else { return }
                    withAnimation(.snappy) { proxy.scrollTo("activity-controls", anchor: .top) }
                }
                .onChange(of: outcomeCategoryID) { oldValue, newValue in
                    guard mode == .outcomes, oldValue != newValue else { return }
                    withAnimation(.snappy) { proxy.scrollTo("outcome-controls", anchor: .top) }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { JournalDetailView(store: store, entryID: $0) }
        }
    }

    private var activityView: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForesightCard {
                VStack(alignment: .leading, spacing: 13) {
                    SectionKicker(text: "Activity")
                    Text("Choose what to compare").font(ForesightType.sectionTitle).foregroundStyle(Color.foresightInk)
                    Text("The chart and totals below follow this category.").font(.subheadline).foregroundStyle(Color.foresightMuted)
                    Menu { activityCategoryMenu } label: {
                        PatternCategoryMenuLabel(value: activityCategory?.name ?? "All logs")
                    }
                    .accessibilityLabel("Choose category")
                    .accessibilityValue(activityCategory?.name ?? "All logs")
                    ForesightSegmentedPicker(
                        selection: $activityGranularity,
                        options: TrendGranularity.allCases.map { ($0, $0.title) }
                    )
                    let comparison = periodComparison(store.entries, category: activityCategory, granularity: activityGranularity)
                    HStack(spacing: 10) {
                        MetricBox(value: "\(comparison.currentCount)", label: comparison.currentLabel)
                        MetricBox(value: comparison.change == 0 ? "No change" : "\(comparison.change > 0 ? "+" : "")\(comparison.change)", label: "vs. previous \(activityGranularity.rawValue)")
                    }
                    let buckets = activityBuckets(store.entries, category: activityCategory, granularity: activityGranularity)
                    Chart(buckets) { bucket in
                        BarMark(x: .value("Period", bucket.date), y: .value("Logs", bucket.count))
                            .foregroundStyle(Color.foresightSage.gradient)
                            .cornerRadius(4)
                    }
                    .chartYAxis { AxisMarks(position: .leading) }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: activityGranularity == .week ? 4 : 6)) }
                    .frame(height: 200)
                    Text(activityGranularity == .week ? "Eight calendar-aligned weeks" : "Six calendar-aligned months").font(.caption).foregroundStyle(.secondary)
                }
            }
            .id("activity-controls")
            ForesightCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { SectionKicker(text: "Explore another category"); Spacer(); Picker("Range", selection: $activityRange) { ForEach(TrendRange.allCases) { Text($0.title).tag($0) } }.pickerStyle(.menu) }
                    Text("Tap a row to load that category in the chart above.").font(.caption).foregroundStyle(Color.foresightMuted)
                    let trends = categoryTrends(store.entries, categories: store.categories, range: activityRange)
                        .filter { $0.category.id != activityCategoryID }
                    if trends.allSatisfy({ $0.currentCount == 0 && $0.previousCount == 0 }) {
                        Text("Tag logs to compare activity by category.").foregroundStyle(.secondary)
                    } else {
                        ForEach(trends) { trend in
                            Button { activityCategoryID = trend.category.id } label: {
                                HStack {
                                    Text(trend.category.name + (trend.category.isArchived ? " (archived)" : "")).foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(trend.currentCount)").font(.headline).foregroundStyle(Color.foresightSage)
                                    Text(trend.change == 0 ? "—" : "\(trend.change > 0 ? "+" : "")\(trend.change)").font(.caption.weight(.bold)).foregroundStyle(trend.change < 0 ? Color.secondary : Color.foresightSage)
                                    Image(systemName: "chevron.up").font(.caption.weight(.bold)).foregroundStyle(Color.foresightMuted)
                                }
                                .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("View \(trend.category.name) activity")
                            if trend.id != trends.last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var activityCategoryMenu: some View {
        Button("All logs") { activityCategoryID = nil }
        ForEach(store.categories, id: \.id) { category in Button(category.name + (category.isArchived ? " (archived)" : "")) { activityCategoryID = category.id } }
    }

    private var outcomesView: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForesightCard {
                VStack(alignment: .leading, spacing: 13) {
                    SectionKicker(text: "Outcome evidence")
                    Text("Choose what to examine").font(ForesightType.sectionTitle).foregroundStyle(Color.foresightInk)
                    Text("Every card below follows the category selected here.").font(.subheadline).foregroundStyle(Color.foresightMuted)
                    Menu { outcomeCategoryMenu } label: {
                        PatternCategoryMenuLabel(value: outcomeCategory?.name ?? "Select a category")
                    }
                    .accessibilityLabel("Choose category")
                    .accessibilityValue(outcomeCategory?.name ?? "No category selected")
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

    @ViewBuilder private var outcomeCategoryMenu: some View {
        Button("Clear category") { outcomeCategoryID = nil }
        ForEach(store.categories, id: \.id) { category in Button(category.name + (category.isArchived ? " (archived)" : "")) { outcomeCategoryID = category.id } }
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
                                Image(systemName: "chevron.up")
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

private struct PatternCategoryMenuLabel: View {
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tag.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.foresightSage)
                .frame(width: 34, height: 34)
                .background(Color.foresightSoftSage, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Category")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.foresightMuted)
                    .textCase(.uppercase)
                    .tracking(0.7)
                Text(value)
                    .font(ForesightType.control)
                    .foregroundStyle(Color.foresightInk)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.foresightSage)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 58)
        .background(Color.foresightRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.foresightLine, lineWidth: 1) }
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
