import SwiftUI
import UIKit

/// Shown in place of the editor right after a new log is saved: rate how you feel now
/// and pick when to check in again, without digging through the log's detail page. The later
/// check-in chosen in Settings starts out set, so a log left with Done still feeds Patterns.
struct PostLogCheckInView: View {
    let store: JournalStore
    let entryID: UUID
    let onDone: () -> Void
    private let now: Date
    @State private var laterOptions: [CheckInLaterOption]
    @State private var chosenLater: CheckInLaterOption.Kind?
    @State private var scheduleTarget: CheckInTarget?
    @State private var message: String?
    @State private var didSetDefaultLater = false
    /// Set after a "worse" rating: something else that has tended to be followed by feeling better.
    @State private var worseSuggestion: HelpSuggestion?
    @Environment(CheckInReminderScheduler.self) private var reminders
    @Environment(CheckInReminderRouter.self) private var router

    init(store: JournalStore, entryID: UUID, onDone: @escaping () -> Void, now: Date = .now) {
        self.store = store
        self.entryID = entryID
        self.onDone = onDone
        self.now = now
        _laterOptions = State(initialValue: CheckInLaterOption.options(now: now))
    }

    private var entry: JournalEntry? { store.entries.first { $0.id == entryID } }
    private var immediate: OutcomeCheckIn? { store.checkIns.first { $0.entry?.id == entryID && $0.phase == .immediate } }
    private var pendingLater: OutcomeCheckIn? { store.checkIns.first { $0.entry?.id == entryID && $0.phase == .delayed && $0.status == .pending } }
    private var ratingColumns: [GridItem] { Array(repeating: GridItem(.flexible(minimum: 0), spacing: 6), count: OutcomeValue.allCases.count) }

    var body: some View {
        ScrollView {
            ContentColumn {
                VStack(alignment: .leading, spacing: 18) {
                    ForesightPageHeader(
                        kicker: "Log saved",
                        title: "How do you feel right now?",
                        subtitle: "Rate it now and again later. Over time, Patterns shows what tends to follow."
                    )
                    if let entry {
                        Text(entry.body)
                            .font(ForesightType.journalBody)
                            .foregroundStyle(Color.foresightMuted)
                            .lineLimit(2)
                    }
                    ratingCard
                    if let worseSuggestion { suggestionCard(worseSuggestion) }
                    laterCard
                    if pendingLater != nil, reminders.authorization == .denied { NotificationsOffNote() }
                    if let message { Text(message).font(.footnote).foregroundStyle(Color.foresightWarning) }
                    Button("Done", action: finish)
                        .buttonStyle(ForesightPrimaryButtonStyle())
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("post-log.done")
                }
                .padding()
            }
        }
        .background(Color.foresightCanvas)
        .sheet(item: $scheduleTarget, onDismiss: syncChosenLater) { ScheduleCheckInSheet(store: store, target: $0) }
        .task { setDefaultLater() }
    }

    private var ratingCard: some View {
        ForesightCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionKicker(text: "Right now")
                LazyVGrid(columns: ratingColumns, spacing: 6) {
                    ForEach(OutcomeValue.allCases) { value in
                        let selected = immediate?.status == .answered && immediate?.overall == value
                        Button { rate(value) } label: {
                            Text(value.title)
                                .font(.subheadline.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                                .padding(.horizontal, 2)
                                .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(ForesightChoiceButtonStyle(selected: selected, horizontalPadding: 0))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                Text(immediate?.overall.map { "Saved: \($0.title.lowercased())" } ?? "Compared with before it happened. Optional.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(immediate?.overall == nil ? Color.foresightMuted : Color.foresightSage)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func suggestionCard(_ suggestion: HelpSuggestion) -> some View {
        ForesightCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionKicker(text: HelpSuggestionCopy.title)
                Text(HelpSuggestionCopy.afterWorseIntro)
                    .font(.subheadline)
                    .foregroundStyle(Color.foresightMuted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(suggestion.headline).font(.subheadline.weight(.semibold)).foregroundStyle(Color.foresightInk)
                    Text(suggestion.evidence).font(.caption).foregroundStyle(.secondary)
                    if let context = suggestion.context { Text(context).font(.caption).foregroundStyle(Color.foresightSage) }
                }
                .fixedSize(horizontal: false, vertical: true)
                Button("See the pattern") {
                    // The root view opens it on Patterns once this sheet has closed.
                    router.destination = .evidence(suggestion.category.id)
                    finish()
                }
                .buttonStyle(ForesightQuietButtonStyle())
                .accessibilityIdentifier("post-log.suggestion")
            }
        }
        .transition(.opacity)
    }

    private var laterCard: some View {
        ForesightCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionKicker(text: "Check in later")
                Text("How you feel a few hours on can differ from right after, and later check-ins are what Patterns learns from. Each one waits for you in Check In.")
                    .font(.subheadline)
                    .foregroundStyle(Color.foresightMuted)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 8) {
                    ForEach(laterOptions) { option in
                        laterRow(option)
                    }
                }
                Button(pendingLater != nil && chosenLater == nil ? "Change time" : "Pick a time") {
                    scheduleTarget = CheckInTarget(entryID: entryID, checkInID: pendingLater?.id)
                }
                .buttonStyle(ForesightQuietButtonStyle())
                if let pendingLater, let dueAt = pendingLater.dueAt {
                    let held = reminders.reminderHeldByQuietHours(dueAt: dueAt).map { " " + QuietHoursCopy.reminderNote($0) } ?? ""
                    Text("Check-in set for \(ForesightFormat.detailDate(dueAt)).\(held)\(chosenLater == nil ? "" : " Tap the selected time to cancel.")")
                        .font(.caption)
                        .foregroundStyle(Color.foresightSage)
                }
            }
        }
    }

    private func laterRow(_ option: CheckInLaterOption) -> some View {
        let selected = chosenLater == option.kind && pendingLater != nil
        return Button { toggleLater(option) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title).font(ForesightType.control)
                    Text(rowDetail(option)).font(.caption).opacity(0.8)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(selected ? Color.white : Color.foresightInk)
            .padding(.horizontal, 14)
            .frame(minHeight: 54)
            .background(selected ? Color.foresightAction : Color.foresightRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityValue(rowDetail(option))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// "11:00 PM" alone would promise a buzz at 11 that quiet hours hold until morning.
    private func rowDetail(_ option: CheckInLaterOption) -> String {
        guard let fireAt = reminders.reminderHeldByQuietHours(dueAt: option.dueAt) else { return option.detail }
        return "\(option.detail), reminder at \(fireAt.formatted(date: .omitted, time: .shortened))"
    }

    /// Sets the Settings default once, when the step first appears. Tapping it turns it off.
    private func setDefaultLater() {
        guard !didSetDefaultLater else { return }
        didSetDefaultLater = true
        guard pendingLater == nil, let entry,
              let option = reminders.laterCheckInDefault.option(in: laterOptions), option.dueAt > .now else { return }
        do {
            _ = try store.createCheckIn(for: entry, phase: .delayed, dueAt: option.dueAt)
            chosenLater = option.kind
        } catch { message = error.localizedDescription }
    }

    /// A check-in set by default still needs permission for its reminder. Asking on the way out
    /// keeps the system prompt off the rating buttons.
    private func finish() {
        if pendingLater != nil { Task { await reminders.requestAuthorizationIfNeeded() } }
        onDone()
    }

    private func rate(_ value: OutcomeValue) {
        guard let entry else { message = ForesightError.missingEntry.localizedDescription; return }
        do {
            let checkIn = try immediate ?? store.createCheckIn(for: entry, phase: .immediate)
            try store.answer(checkIn, response: value, notSure: false, note: checkIn.note, excludedFromAnalysis: checkIn.excludedFromAnalysis)
            UISelectionFeedbackGenerator().selectionChanged()
            message = nil
            withAnimation(.snappy) { worseSuggestion = value.rawValue < 0 ? suggestionAfterWorse(entry) : nil }
        } catch { message = error.localizedDescription }
    }

    private func toggleLater(_ option: CheckInLaterOption) {
        guard let entry else { message = ForesightError.missingEntry.localizedDescription; return }
        do {
            if chosenLater == option.kind, let pendingLater {
                try store.removeCheckIn(pendingLater)
                chosenLater = nil
            } else {
                // An option offered a while ago may have slipped into the past.
                guard option.dueAt > .now else { laterOptions = CheckInLaterOption.options(now: .now); return }
                if let pendingLater { try store.reschedule(pendingLater, to: option.dueAt) }
                else { _ = try store.createCheckIn(for: entry, phase: .delayed, dueAt: option.dueAt) }
                chosenLater = option.kind
                UISelectionFeedbackGenerator().selectionChanged()
                // Picking a later time is when a reminder starts to matter, so ask here, once.
                Task { await reminders.requestAuthorizationIfNeeded() }
            }
            message = nil
        } catch { message = error.localizedDescription }
    }

    private func suggestionAfterWorse(_ entry: JournalEntry) -> HelpSuggestion? {
        let report = helpSuggestions(entries: store.entries, checkIns: store.checkIns, categories: store.categories, now: now, limit: .max)
        return suggestionAfterWorseCheckIn(report, excluding: Set(entry.categories.map(\.id)))
    }

    /// A time picked in the full scheduler replaces whichever shortcut was highlighted.
    private func syncChosenLater() {
        guard let dueAt = pendingLater?.dueAt else { chosenLater = nil; return }
        chosenLater = laterOptions.first { $0.dueAt == dueAt }?.kind
    }
}
