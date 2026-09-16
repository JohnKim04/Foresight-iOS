import SwiftUI
import UIKit

struct EditorRequest: Identifiable {
    let entryID: UUID?
    var id: String { entryID?.uuidString ?? "new" }
}

struct JournalEditorView: View {
    let store: JournalStore
    let request: EditorRequest
    @Environment(\.dismiss) private var dismiss
    @State private var bodyText: String
    @State private var eventAt: Date
    @State private var categoryIDs: Set<UUID>
    @State private var newCategory = ""
    @State private var message: String?
    @State private var discardConfirmation = false
    @State private var archiveConfirmation = false
    @State private var categoryToArchive: JournalCategory?
    @FocusState private var isWriting: Bool

    init(store: JournalStore, request: EditorRequest) {
        self.store = store
        self.request = request
        let entry = request.entryID.flatMap { id in store.entries.first { $0.id == id } }
        _bodyText = State(initialValue: entry?.body ?? "")
        _eventAt = State(initialValue: entry?.eventAt ?? .now)
        _categoryIDs = State(initialValue: Set(entry?.categories.map(\.id) ?? []))
    }

    private var entry: JournalEntry? { request.entryID.flatMap { id in store.entries.first { $0.id == id } } }
    private var isEditing: Bool { entry != nil }
    private var isDirty: Bool {
        guard let entry else { return !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !categoryIDs.isEmpty }
        return bodyText != entry.body || eventAt != entry.eventAt || categoryIDs != Set(entry.categories.map(\.id))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                ContentColumn {
                    VStack(alignment: .leading, spacing: 20) {
                        ForesightPageHeader(
                            kicker: isEditing ? "Editing log" : "Private reflection",
                            title: isEditing ? "Refine the moment." : "What happened?",
                            subtitle: isEditing ? "Keep the record true to what you remember." : "Capture the choice, activity, or moment while it is still clear."
                        )
                        ForesightCard {
                            VStack(alignment: .leading, spacing: 18) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Your note").font(.headline).foregroundStyle(Color.foresightInk)
                                    TextEditor(text: $bodyText)
                                        .focused($isWriting)
                                        .onChange(of: bodyText) { _, _ in limitBodyText() }
                                        .frame(minHeight: 180)
                                        .padding(8)
                                        .scrollContentBackground(.hidden)
                                        .background(Color.foresightRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.foresightLine, lineWidth: 1) }
                                        .accessibilityLabel("What happened?")
                                    Text("\(bodyText.count) of 5,000 characters")
                                        .font(.caption).foregroundStyle(bodyText.count > 5_000 ? .red : .secondary)
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("When did it happen?").font(.headline).foregroundStyle(Color.foresightInk)
                                    DatePicker("Event time", selection: $eventAt, displayedComponents: [.date, .hourAndMinute])
                                        .datePickerStyle(.compact)
                                        .accessibilityLabel("Event time")
                                }
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Categories").font(.headline).foregroundStyle(Color.foresightInk)
                                    CategoryPickerGrid(categories: store.activeCategories, selected: $categoryIDs)
                                    HStack(spacing: 8) {
                                        TextField("Create a category", text: $newCategory)
                                            .textFieldStyle(.roundedBorder)
                                            .submitLabel(.done)
                                            .onSubmit(addCategory)
                                        Button("Add", action: addCategory).buttonStyle(ForesightSecondaryButtonStyle())
                                    }
                                    let archived = entry?.categories.filter(\.isArchived) ?? []
                                    if !archived.isEmpty {
                                        Text("Archived on this log: \(archived.map(\.name).joined(separator: ", "))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Button(isEditing ? "Update log" : "Save log", action: save)
                                    .buttonStyle(ForesightPrimaryButtonStyle())
                                    .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bodyText.count > 5_000)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                        ForesightCard {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionKicker(text: "Category management")
                                Text("Archived categories remain on past logs and in Patterns.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                ForEach(store.activeCategories, id: \.id) { category in
                                    HStack {
                                        Text(category.name)
                                        Spacer()
                                        Button("Archive") {
                                            categoryToArchive = category
                                            archiveConfirmation = true
                                        }
                                        .buttonStyle(ForesightQuietButtonStyle(tone: .foresightWarning))
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                        if let message { Text(message).font(.footnote).foregroundStyle(Color.foresightWarning) }
                    }
                    .padding()
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.foresightCanvas)
            .navigationTitle(isEditing ? "Edit log" : "New log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: requestDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Update" : "Save", action: save)
                        .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bodyText.count > 5_000)
                }
            }
            .interactiveDismissDisabled(isDirty)
            .confirmationDialog("Discard unsaved log?", isPresented: $discardConfirmation, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
            } message: { Text("Your changes have not been saved.") }
            .confirmationDialog("Archive \(categoryToArchive?.name ?? "this category")?", isPresented: $archiveConfirmation, titleVisibility: .visible) {
                Button("Archive") {
                    guard let categoryToArchive else { return }
                    do { try store.archiveCategory(categoryToArchive) }
                    catch { message = error.localizedDescription }
                }
            } message: { Text("It will stay attached to past logs and visible in Patterns.") }
        }
    }

    private func requestDismiss() {
        if isDirty { discardConfirmation = true } else { dismiss() }
    }

    private func limitBodyText() {
        if bodyText.count > 5_000 { bodyText = String(bodyText.prefix(5_000)) }
    }

    private func addCategory() {
        do {
            let category = try store.addCategory(named: newCategory)
            categoryIDs.insert(category.id)
            newCategory = ""
            message = nil
        } catch { message = error.localizedDescription }
    }

    private func save() {
        do {
            _ = try store.saveLog(id: entry?.id, body: bodyText, eventAt: eventAt, categoryIDs: categoryIDs)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch { message = error.localizedDescription }
    }
}

struct CategoryPickerGrid: View {
    let categories: [JournalCategory]
    @Binding var selected: Set<UUID>
    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 8, alignment: .leading)]
    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(categories, id: \.id) { category in
                let isSelected = selected.contains(category.id)
                let borderColor: Color = isSelected ? .clear : .gray.opacity(0.25)
                Button {
                    if isSelected { selected.remove(category.id) } else { selected.insert(category.id) }
                } label: {
                    Text(category.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.white : Color.foresightInk)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(isSelected ? Color.foresightAction : Color.clear, in: Capsule())
                        .overlay(Capsule().stroke(borderColor, lineWidth: 1))
                }
                .accessibilityLabel(category.name)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

struct JournalDetailView: View {
    let store: JournalStore
    let entryID: UUID
    @State private var editor: EditorRequest?
    @State private var answerTarget: CheckInTarget?
    @State private var scheduleTarget: CheckInTarget?
    @State private var showDelete = false
    @State private var showRemoveCheckIn = false
    @State private var checkInToRemove: OutcomeCheckIn?

    private var entry: JournalEntry? { store.entries.first { $0.id == entryID } }

    var body: some View {
        Group {
            if let entry {
                ScrollView {
                    ContentColumn {
                        VStack(alignment: .leading, spacing: 18) {
                            ForesightCard {
                                VStack(alignment: .leading, spacing: 14) {
                                    Text(ForesightFormat.detailDate(entry.eventAt)).font(.headline)
                                        .foregroundStyle(Color.foresightSage)
                                    if !entry.categories.isEmpty {
                                        FlowLabels(labels: entry.categories.map { $0.name + ($0.isArchived ? " (archived)" : "") })
                                    }
                                    Text(entry.body).font(.system(.title3, design: .serif)).foregroundStyle(Color.foresightInk).fixedSize(horizontal: false, vertical: true)
                                    Divider()
                                    Text("Created \(ForesightFormat.detailDate(entry.createdAt))\nUpdated \(ForesightFormat.detailDate(entry.updatedAt))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Button("Edit log") { editor = EditorRequest(entryID: entry.id) }
                                        .buttonStyle(ForesightPrimaryButtonStyle())
                                }
                            }
                            CheckInDetailCard(
                                title: "Overall feeling", checkIn: latestCheckIn(entry, phase: .immediate), isImmediate: true,
                                onAnswer: { checkIn in answerTarget = CheckInTarget(entryID: entry.id, checkInID: checkIn?.id) },
                                onSchedule: { _ in },
                                onRemove: { checkIn in checkInToRemove = checkIn; showRemoveCheckIn = true }
                            )
                            CheckInDetailCard(
                                title: "Later check-in", checkIn: latestCheckIn(entry, phase: .delayed), isImmediate: false,
                                onAnswer: { checkIn in answerTarget = CheckInTarget(entryID: entry.id, checkInID: checkIn?.id) },
                                onSchedule: { checkIn in scheduleTarget = CheckInTarget(entryID: entry.id, checkInID: checkIn?.id) },
                                onRemove: { checkIn in checkInToRemove = checkIn; showRemoveCheckIn = true }
                            )
                            Button("Delete log", role: .destructive) { showDelete = true }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical)
                        }
                        .padding()
                    }
                }
                .background(Color.foresightCanvas)
                .navigationTitle("Log")
                .navigationBarTitleDisplayMode(.inline)
                .fullScreenCover(item: $editor) { JournalEditorView(store: store, request: $0) }
                .sheet(item: $answerTarget) { OutcomeAnswerSheet(store: store, target: $0) }
                .sheet(item: $scheduleTarget) { ScheduleCheckInSheet(store: store, target: $0) }
                .alert("Delete this log?", isPresented: $showDelete) {
                    Button("Delete", role: .destructive) { try? store.deleteEntry(entry) }
                    Button("Cancel", role: .cancel) { }
                } message: { Text("Its attached check-ins will also be deleted.") }
                .alert("Remove check-in?", isPresented: $showRemoveCheckIn) {
                    Button("Remove", role: .destructive) { if let checkInToRemove { try? store.removeCheckIn(checkInToRemove) } }
                    Button("Cancel", role: .cancel) { }
                } message: { Text("The source log will stay.") }
            } else {
                ContentUnavailableView("Log unavailable", systemImage: "book.closed", description: Text("This log may have been deleted."))
            }
        }
    }

    private func latestCheckIn(_ entry: JournalEntry, phase: OutcomePhase) -> OutcomeCheckIn? {
        entry.checkIns.filter { $0.phase == phase }.sorted { $0.createdAt > $1.createdAt }.first
    }
}

struct FlowLabels: View {
    let labels: [String]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(labels, id: \.self) { label in
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(Color.foresightSage)
                    .padding(.horizontal, 9).padding(.vertical, 5).background(Color.foresightSoftSage, in: Capsule())
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct CheckInDetailCard: View {
    let title: String
    let checkIn: OutcomeCheckIn?
    let isImmediate: Bool
    let onAnswer: (OutcomeCheckIn?) -> Void
    let onSchedule: (OutcomeCheckIn?) -> Void
    let onRemove: (OutcomeCheckIn) -> Void

    var body: some View {
        ForesightCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionKicker(text: title)
                if let checkIn {
                    Text(checkIn.status == .skipped ? "Skipped" : checkIn.responseSummary).font(ForesightType.sectionTitle).foregroundStyle(Color.foresightInk)
                    if checkIn.phase == .delayed, checkIn.status == .pending, let dueAt = checkIn.dueAt {
                        Text("Due \(ForesightFormat.detailDate(dueAt))").foregroundStyle(.secondary)
                    } else if let answeredAt = checkIn.answeredAt {
                        Text("Answered \(ForesightFormat.detailDate(answeredAt))").foregroundStyle(.secondary)
                    }
                    if !checkIn.note.isEmpty { Text(checkIn.note).italic() }
                    if checkIn.excludedFromAnalysis { Text("Left out of pattern summaries").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button(checkIn.status == .skipped ? "Answer now" : "Update") { onAnswer(checkIn) }.buttonStyle(ForesightSecondaryButtonStyle())
                        if !isImmediate && checkIn.status == .pending {
                            Button("Reschedule") { onSchedule(checkIn) }.buttonStyle(ForesightSecondaryButtonStyle())
                        } else if !isImmediate {
                            Button("Check in again") { onSchedule(nil) }.buttonStyle(ForesightSecondaryButtonStyle())
                        }
                        Button(isImmediate ? "Remove" : checkIn.status == .pending ? "Cancel" : "Remove") { onRemove(checkIn) }.buttonStyle(ForesightQuietButtonStyle(tone: .foresightWarning))
                    }
                } else {
                    Text(isImmediate ? "No check-in" : "No scheduled check-in").font(ForesightType.sectionTitle).foregroundStyle(Color.foresightInk)
                    Text(isImmediate ? "Add an overall rating." : "Choose a time to rate this log later.").foregroundStyle(.secondary)
                    Button(isImmediate ? "Check in now" : "Check in later") {
                        isImmediate ? onAnswer(nil) : onSchedule(nil)
                    }.buttonStyle(ForesightSecondaryButtonStyle())
                }
            }
        }
    }
}

struct CheckInTarget: Identifiable {
    let entryID: UUID
    let checkInID: UUID?
    var id: String { "\(entryID.uuidString)-\(checkInID?.uuidString ?? "new")" }
}

struct OutcomeAnswerSheet: View {
    let store: JournalStore
    let target: CheckInTarget
    @Environment(\.dismiss) private var dismiss
    @State private var selectedValue: OutcomeValue?
    @State private var notSure: Bool
    @State private var note: String
    @State private var excluded: Bool
    @State private var message: String?
    @State private var discardConfirmation = false

    init(store: JournalStore, target: CheckInTarget) {
        self.store = store
        self.target = target
        let checkIn = target.checkInID.flatMap { id in store.checkIns.first { $0.id == id } }
        _selectedValue = State(initialValue: checkIn?.overall)
        _notSure = State(initialValue: checkIn?.status == .notSure)
        _note = State(initialValue: checkIn?.note ?? "")
        _excluded = State(initialValue: checkIn?.excludedFromAnalysis ?? false)
    }

    private var entry: JournalEntry? { store.entries.first { $0.id == target.entryID } }
    private var existing: OutcomeCheckIn? { target.checkInID.flatMap { id in store.checkIns.first { $0.id == id } } }
    private var ratingColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: 6),
            count: OutcomeValue.allCases.count
        )
    }
    private var ratingDescription: String {
        if notSure { return "Not sure yet" }
        return selectedValue?.title ?? "Choose a rating"
    }
    private var isDirty: Bool {
        selectedValue != existing?.overall || notSure != (existing?.status == .notSure) || note != (existing?.note ?? "") || excluded != (existing?.excludedFromAnalysis ?? false)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView(.vertical) {
                    ContentColumn {
                        VStack(alignment: .leading, spacing: 18) {
                            ForesightPageHeader(
                                kicker: existing == nil ? "Check in" : "Update check-in",
                                title: "How did this affect you?",
                                subtitle: existing?.phase == .delayed ? "Think about the time since this happened." : "Compare how you feel now with how you felt before."
                            )
                            if let entry { ForesightCard { VStack(alignment: .leading, spacing: 6) { Text(ForesightFormat.detailDate(entry.eventAt)).font(.caption.weight(.bold)).foregroundStyle(Color.foresightSage); Text(entry.body).font(.system(.body, design: .serif)).lineLimit(4) } } }
                            ForesightCard {
                                VStack(alignment: .leading, spacing: 16) {
                                    Text("Rating").font(.headline)
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
                                            Button {
                                                selectedValue = value
                                                notSure = false
                                            } label: {
                                                Text(value.shortTitle)
                                                    .font(.headline)
                                                    .lineLimit(1)
                                                    .minimumScaleFactor(0.75)
                                                    .frame(maxWidth: .infinity, minHeight: 48)
                                            }
                                            .buttonStyle(
                                                ForesightChoiceButtonStyle(
                                                    selected: selectedValue == value && !notSure,
                                                    horizontalPadding: 0
                                                )
                                            )
                                            .accessibilityLabel(value.title)
                                            .accessibilityValue(selectedValue == value && !notSure ? "Selected" : "")
                                        }
                                    }
                                    Text(ratingDescription)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(selectedValue == nil ? Color.foresightMuted : Color.foresightSage)
                                        .frame(maxWidth: .infinity)
                                    Toggle("Not sure yet", isOn: $notSure)
                                        .onChange(of: notSure) { _, active in if active { selectedValue = nil } }
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Note (optional)").font(.headline)
                                        TextField("What else was going on?", text: $note, axis: .vertical)
                                            .onChange(of: note) { _, _ in limitNoteText() }
                                            .lineLimit(3...7).textFieldStyle(.roundedBorder)
                                        Text("\(note.count) of 5,000 characters").font(.caption).foregroundStyle(note.count > 5_000 ? .red : .secondary)
                                    }
                                    Toggle("Leave out of pattern summaries", isOn: $excluded)
                                }
                            }
                            if let message { Text(message).font(.footnote).foregroundStyle(Color.foresightWarning) }
                        }
                        .padding()
                    }
                    .frame(width: proxy.size.width)
                }
            }
            .background(Color.foresightCanvas)
            .navigationTitle("Check in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: requestDismiss) }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled((selectedValue == nil && !notSure) || note.count > 5_000) }
            }
            .interactiveDismissDisabled(isDirty)
            .confirmationDialog("Discard check-in changes?", isPresented: $discardConfirmation) { Button("Discard", role: .destructive) { dismiss() } } message: { Text("Your rating and note have not been saved.") }
        }
    }

    private func requestDismiss() { if isDirty { discardConfirmation = true } else { dismiss() } }
    private func limitNoteText() { if note.count > 5_000 { note = String(note.prefix(5_000)) } }
    private func save() {
        guard let entry else { message = ForesightError.missingEntry.localizedDescription; return }
        do {
            let checkIn: OutcomeCheckIn
            if let existing {
                checkIn = existing
            } else {
                checkIn = try store.createCheckIn(for: entry, phase: .immediate)
            }
            try store.answer(checkIn, response: selectedValue, notSure: notSure, note: note, excludedFromAnalysis: excluded)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch { message = error.localizedDescription }
    }
}

struct ScheduleCheckInSheet: View {
    let store: JournalStore
    let target: CheckInTarget
    @Environment(\.dismiss) private var dismiss
    @State private var dueAt: Date
    @State private var message: String?
    @State private var discardConfirmation = false

    init(store: JournalStore, target: CheckInTarget) {
        self.store = store
        self.target = target
        let existing = target.checkInID.flatMap { id in store.checkIns.first { $0.id == id } }
        _dueAt = State(initialValue: existing?.dueAt ?? Calendar.current.date(byAdding: .hour, value: 2, to: .now)!)
    }

    private var existing: OutcomeCheckIn? { target.checkInID.flatMap { id in store.checkIns.first { $0.id == id } } }
    private var isDirty: Bool { dueAt != existing?.dueAt }

    var body: some View {
        NavigationStack {
            ScrollView {
                ContentColumn {
                    VStack(alignment: .leading, spacing: 18) {
                        ForesightPageHeader(
                            kicker: existing == nil ? "Future reflection" : "Adjust timing",
                            title: existing == nil ? "Check in later." : "Choose a better time.",
                            subtitle: "Give the outcome enough time to become clear, then return with fresh perspective."
                        )
                        ForesightCard {
                            VStack(alignment: .leading, spacing: 14) {
                                SectionKicker(text: "Quick schedule")
                                VStack(spacing: 9) {
                                    scheduleShortcut("Later today", detail: "In about two hours") {
                                        Calendar.current.date(byAdding: .hour, value: 2, to: .now)!
                                    }
                                    scheduleShortcut("Tomorrow morning", detail: "At 9:00 AM") {
                                        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Calendar.current.date(byAdding: .day, value: 1, to: .now)!)!
                                    }
                                    scheduleShortcut("Tomorrow evening", detail: "At 7:00 PM") {
                                        Calendar.current.date(bySettingHour: 19, minute: 0, second: 0, of: Calendar.current.date(byAdding: .day, value: 1, to: .now)!)!
                                    }
                                }
                                Divider().overlay(Color.foresightLine)
                                SectionKicker(text: "Custom time")
                                DatePicker("Check in", selection: $dueAt, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                                    .font(ForesightType.control)
                                    .tint(Color.foresightSage)
                                Text("Scheduled for \(ForesightFormat.detailDate(dueAt))")
                                    .font(.caption)
                                    .foregroundStyle(Color.foresightMuted)
                            }
                        }
                        if let message { Text(message).font(.footnote).foregroundStyle(Color.foresightWarning) }
                    }
                    .padding()
                }
            }
            .background(Color.foresightCanvas)
            .navigationTitle(existing == nil ? "Schedule check-in" : "Reschedule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: requestDismiss) }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .interactiveDismissDisabled(isDirty)
            .confirmationDialog("Discard schedule changes?", isPresented: $discardConfirmation) { Button("Discard", role: .destructive) { dismiss() } } message: { Text("Your schedule has not been saved.") }
        }
    }

    private func scheduleShortcut(_ title: String, detail: String, date: @escaping () -> Date) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { dueAt = date() }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(ForesightType.control).foregroundStyle(Color.foresightInk)
                    Text(detail).font(.caption).foregroundStyle(Color.foresightMuted)
                }
                Spacer()
                Image(systemName: "arrow.forward")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.foresightSage)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 54)
            .background(Color.foresightRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }

    private func requestDismiss() { if isDirty { discardConfirmation = true } else { dismiss() } }
    private func save() {
        guard let entry = store.entries.first(where: { $0.id == target.entryID }) else { message = ForesightError.missingEntry.localizedDescription; return }
        do {
            if let existing { try store.reschedule(existing, to: dueAt) }
            else { _ = try store.createCheckIn(for: entry, phase: .delayed, dueAt: dueAt) }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch { message = error.localizedDescription }
    }
}
