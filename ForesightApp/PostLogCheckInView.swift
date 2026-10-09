import SwiftUI
import UIKit

/// Shown in place of the editor right after a new log is saved: rate how you feel now
/// and pick when to check in again, without digging through the log's detail page.
struct PostLogCheckInView: View {
    let store: JournalStore
    let entryID: UUID
    let onDone: () -> Void
    @State private var laterOptions: [CheckInLaterOption]
    @State private var chosenLater: CheckInLaterOption.Kind?
    @State private var scheduleTarget: CheckInTarget?
    @State private var message: String?

    init(store: JournalStore, entryID: UUID, onDone: @escaping () -> Void, now: Date = .now) {
        self.store = store
        self.entryID = entryID
        self.onDone = onDone
        _laterOptions = State(initialValue: CheckInLaterOption.options(now: now))
    }

    private var entry: JournalEntry? { store.entries.first { $0.id == entryID } }
    private var immediate: OutcomeCheckIn? { store.checkIns.first { $0.entry?.id == entryID && $0.phase == .immediate } }
    private var pendingLater: OutcomeCheckIn? { store.checkIns.first { $0.entry?.id == entryID && $0.phase == .delayed && $0.status == .pending } }
    private var ratingColumns: [GridItem] { Array(repeating: GridItem(.flexible(minimum: 0), spacing: 6), count: OutcomeValue.allCases.count) }

    var body: some View {
        NavigationStack {
            ScrollView {
                ContentColumn {
                    VStack(alignment: .leading, spacing: 18) {
                        ForesightPageHeader(
                            kicker: "Log saved",
                            title: "How do you feel right now?",
                            subtitle: "A quick rating now and another later show what this tends to lead to."
                        )
                        if let entry {
                            Text(entry.body)
                                .font(ForesightType.journalBody)
                                .foregroundStyle(Color.foresightMuted)
                                .lineLimit(2)
                        }
                        ratingCard
                        laterCard
                        if let message { Text(message).font(.footnote).foregroundStyle(Color.foresightWarning) }
                        Button("Done", action: onDone)
                            .buttonStyle(ForesightPrimaryButtonStyle())
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("post-log.done")
                    }
                    .padding()
                }
            }
            .background(Color.foresightCanvas)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $scheduleTarget, onDismiss: syncChosenLater) { ScheduleCheckInSheet(store: store, target: $0) }
        }
    }

    private var ratingCard: some View {
        ForesightCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionKicker(text: "Right now")
                HStack {
                    Text("Worse")
                    Spacer()
                    Text("Same")
                    Spacer()
                    Text("Better")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.foresightMuted)
                LazyVGrid(columns: ratingColumns, spacing: 6) {
                    ForEach(OutcomeValue.allCases) { value in
                        let selected = immediate?.status == .answered && immediate?.overall == value
                        Button { rate(value) } label: {
                            Text(value.shortTitle)
                                .font(.headline)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(ForesightChoiceButtonStyle(selected: selected, horizontalPadding: 0))
                        .accessibilityLabel(value.title)
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

    private var laterCard: some View {
        ForesightCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionKicker(text: "Check in later")
                Text("Effects often show up later. Pick a time and it will wait for you in Check In.")
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
                    Text("Check-in set for \(ForesightFormat.detailDate(dueAt)).\(chosenLater == nil ? "" : " Tap it again to cancel.")")
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
                    Text(option.detail).font(.caption).opacity(0.8)
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
        .accessibilityValue(option.detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func rate(_ value: OutcomeValue) {
        guard let entry else { message = ForesightError.missingEntry.localizedDescription; return }
        do {
            let checkIn = try immediate ?? store.createCheckIn(for: entry, phase: .immediate)
            try store.answer(checkIn, response: value, notSure: false, note: checkIn.note, excludedFromAnalysis: checkIn.excludedFromAnalysis)
            UISelectionFeedbackGenerator().selectionChanged()
            message = nil
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
            }
            message = nil
        } catch { message = error.localizedDescription }
    }

    /// A time picked in the full scheduler replaces whichever shortcut was highlighted.
    private func syncChosenLater() {
        guard let dueAt = pendingLater?.dueAt else { chosenLater = nil; return }
        chosenLater = laterOptions.first { $0.dueAt == dueAt }?.kind
    }
}
