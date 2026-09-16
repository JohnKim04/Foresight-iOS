import SwiftUI
import UIKit

enum JournalDateScope: String, CaseIterable, Identifiable { case recent, all, custom; var id: String { rawValue }; var title: String { self == .recent ? "30 days" : rawValue.capitalized } }

struct JournalRootView: View {
    let store: JournalStore
    @State private var query = ""
    @State private var categoryID: UUID?
    @State private var checkInFilter: JournalCheckInFilter = .all
    @State private var viewMode: JournalViewMode = .timeline
    @State private var dateScope: JournalDateScope = .recent
    @State private var customStart = recentJournalRange().start
    @State private var customEnd = recentJournalRange().end
    @State private var calendarMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: .now))!
    @State private var selectedDay = localDayKey(.now)
    @State private var editor: EditorRequest?

    private var filters: JournalFilters { JournalFilters(query: query, categoryID: categoryID, checkIn: checkInFilter) }
    private var matching: [JournalEntry] { filterJournalEntries(store.entries, categories: store.categories, checkIns: store.checkIns, filters: filters) }
    private var activeRange: JournalDateRange? {
        switch dateScope {
        case .recent: recentJournalRange()
        case .all: nil
        case .custom: JournalDateRange(start: customStart, end: customEnd)
        }
    }
    private var entries: [JournalEntry] { filterEntriesByDateRange(matching, range: activeRange) }
    private var olderCount: Int {
        guard let activeRange else { return 0 }
        let start = localDayKey(activeRange.start)
        return matching.filter { localDayKey($0.eventAt) < start }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                ContentColumn {
                    VStack(alignment: .leading, spacing: 18) {
                        ForesightPageHeader(
                            kicker: "Consequence journal",
                            title: "Notice what follows.",
                            subtitle: "Capture what happened now. Reflect on how it affected you later."
                        ) {
                            ForesightIconButton(title: "New log", systemImage: "plus") {
                                editor = EditorRequest(entryID: nil)
                            }
                        }
                        journalControls
                        if viewMode == .timeline { timeline } else { calendar }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color.foresightCanvas)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search logs and categories")
            .navigationDestination(for: UUID.self) { JournalDetailView(store: store, entryID: $0) }
            .fullScreenCover(item: $editor) { JournalEditorView(store: store, request: $0) }
        }
    }

    private var journalControls: some View {
        ForesightCard {
            VStack(alignment: .leading, spacing: 12) {
                ForesightSegmentedPicker(
                    selection: $viewMode,
                    options: JournalViewMode.allCases.map { ($0, $0.title) }
                )
                HStack {
                    Menu {
                        Button("All categories") { categoryID = nil }
                        ForEach(store.categories, id: \.id) { category in
                            Button(category.name + (category.isArchived ? " (archived)" : "")) { categoryID = category.id }
                        }
                    } label: { ForesightMenuLabel(title: categoryID.flatMap { id in store.categories.first { $0.id == id } }?.name ?? "All categories", systemImage: "tag") }
                    Spacer()
                    Menu {
                        ForEach(JournalCheckInFilter.allCases) { filter in Button(filter.title) { checkInFilter = filter } }
                    } label: { ForesightMenuLabel(title: checkInFilter.title, systemImage: "line.3.horizontal.decrease.circle") }
                }
                ForesightSegmentedPicker(
                    selection: $dateScope,
                    options: JournalDateScope.allCases.map { ($0, $0.title) }
                )
                if dateScope == .custom {
                    DatePicker("From", selection: $customStart, displayedComponents: .date)
                    DatePicker("To", selection: $customEnd, displayedComponents: .date)
                }
            }
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 16) {
            if entries.isEmpty {
                EmptyState(title: matching.isEmpty ? "Start your journal" : "No matching logs", detail: matching.isEmpty ? "Write a short log about something that happened today." : "Try changing the search or filters.", actionTitle: matching.isEmpty ? "Write a log" : nil, action: matching.isEmpty ? { editor = EditorRequest(entryID: nil) } : nil)
            } else {
                if olderCount > 0 {
                    Button("Show \(olderCount) older \(olderCount == 1 ? "log" : "logs")") { dateScope = .all }
                        .buttonStyle(ForesightSecondaryButtonStyle()).frame(maxWidth: .infinity)
                }
                ForEach(groupEntriesByDay(entries)) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(displayDay(group.day)).font(ForesightType.metadata).foregroundStyle(Color.foresightMuted)
                        ForEach(group.entries, id: \.id) { entry in JournalEntryRow(entry: entry, label: entryCheckInLabel(entry: entry, checkIns: store.checkIns)) }
                    }
                }
            }
        }
    }

    private var calendar: some View {
        let days = calendarDays(month: calendarMonth, entries: entries)
        let selectedEntries = entries.filter { localDayKey($0.eventAt) == selectedDay }
        return VStack(alignment: .leading, spacing: 16) {
            ForesightCard {
                VStack(spacing: 12) {
                    HStack {
                        Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(ForesightSecondaryButtonStyle())
                        Spacer()
                        Text(calendarMonth.formatted(.dateTime.month(.wide).year())).font(ForesightType.sectionTitle)
                        Spacer()
                        Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(ForesightSecondaryButtonStyle())
                    }
                    HStack { ForEach(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], id: \.self) { Text($0).font(.caption2.weight(.bold)).foregroundStyle(.secondary).frame(maxWidth: .infinity) } }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 4) {
                        ForEach(days) { day in
                            Button {
                                selectedDay = day.id
                            } label: {
                                VStack(spacing: 2) {
                                    Text(day.date.formatted(.dateTime.day())).font(.subheadline.weight(.semibold))
                                    Circle().fill(day.count > 0 ? (selectedDay == day.id ? Color.white : Color.foresightSage) : Color.clear).frame(width: 4, height: 4)
                                }
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .foregroundStyle(selectedDay == day.id ? Color.white : day.inMonth ? Color.primary : Color.secondary)
                                .background(selectedDay == day.id ? Color.foresightAction : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .accessibilityLabel("\(day.date.formatted(.dateTime.month().day())), \(day.count) logs")
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(displayDay(selectedDay)).font(.headline).foregroundStyle(Color.foresightInk)
                if selectedEntries.isEmpty { Text("No logs on this day.").foregroundStyle(Color.foresightMuted) }
                ForEach(selectedEntries, id: \.id) { JournalEntryRow(entry: $0, label: entryCheckInLabel(entry: $0, checkIns: store.checkIns)) }
            }
        }
    }

    private func moveMonth(_ amount: Int) {
        calendarMonth = Calendar.current.date(byAdding: .month, value: amount, to: calendarMonth)!
        selectedDay = localDayKey(calendarMonth)
    }
}

struct JournalEntryRow: View {
    let entry: JournalEntry
    let label: String?
    var body: some View {
        NavigationLink(value: entry.id) {
            ForesightCard {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(ForesightFormat.listDate(entry.eventAt)).font(.caption.weight(.bold)).foregroundStyle(Color.foresightSage)
                        Spacer()
                        if let label { Text(label).font(.caption2.weight(.bold)).foregroundStyle(label == "Check-in due" ? Color.foresightWarning : Color.foresightSage).padding(.horizontal, 7).padding(.vertical, 4).background(label == "Check-in due" ? Color.foresightWarm : Color.foresightSoftSage, in: Capsule()) }
                    }
                    Text(entry.body).font(ForesightType.journalBody).foregroundStyle(Color.foresightInk).lineLimit(3).multilineTextAlignment(.leading)
                    if !entry.categories.isEmpty { Text(entry.categories.map(\.name).joined(separator: " · ")).font(.caption).foregroundStyle(Color.foresightMuted) }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

enum QueueFilter: String, CaseIterable, Identifiable { case all, due, upcoming, recent; var id: String { rawValue }; var title: String { rawValue.capitalized } }

struct CheckInRootView: View {
    let store: JournalStore
    @State private var filter: QueueFilter = .all
    @State private var answerTarget: CheckInTarget?
    @State private var scheduleTarget: CheckInTarget?
    @State private var checkInToSkip: OutcomeCheckIn?
    @State private var sampleConfirmation = false
    @State private var message: String?

    private var queue: [QueuedCheckIn] { delayedCheckInQueue(store.snapshot) }
    private var due: [QueuedCheckIn] { queue.filter(\.due) }
    private var upcoming: [QueuedCheckIn] { queue.filter { !$0.due } }
    private var recent: [QueuedCheckIn] { recentCompletedCheckIns(store.snapshot, limit: 8) }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView(.vertical) {
                    ContentColumn {
                        VStack(alignment: .leading, spacing: 18) {
                            ForesightPageHeader(
                                kicker: "Action → consequence",
                                title: "Check in",
                                subtitle: "A short reflection now gives your future self better evidence."
                            )
                            ForesightSegmentedPicker(
                                selection: $filter,
                                options: QueueFilter.allCases.map { ($0, $0.title) }
                            )
                            CheckInSummary(due: due.count, upcoming: upcoming.count, recent: recent.count)
                            if let message { Text(message).font(.footnote).foregroundStyle(Color.foresightSage) }
                            queueContent
                            #if ENABLE_DEVELOPMENT_FIXTURES
                            developmentControls
                            #endif
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // A vertical ScrollView otherwise adopts the widest child's ideal size,
                    // which can leave a few horizontally draggable points on compact screens.
                    .frame(width: proxy.size.width)
                }
            }
            .background(Color.foresightCanvas)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { JournalDetailView(store: store, entryID: $0) }
            .sheet(item: $answerTarget) { OutcomeAnswerSheet(store: store, target: $0) }
            .sheet(item: $scheduleTarget) { ScheduleCheckInSheet(store: store, target: $0) }
            .alert("Skip this check-in?", isPresented: Binding(get: { checkInToSkip != nil }, set: { if !$0 { checkInToSkip = nil } })) {
                Button("Skip") { if let checkInToSkip { try? store.skip(checkInToSkip); message = "Check-in skipped." } }
                Button("Cancel", role: .cancel) { }
            } message: { Text("It will stay in recent responses, where you can answer it later.") }
            .alert("Remove sample history?", isPresented: $sampleConfirmation) {
                Button("Remove", role: .destructive) { do { try store.removeDemoHistory(); message = "Sample history removed. Your own logs were kept." } catch { message = error.localizedDescription } }
                Button("Cancel", role: .cancel) { }
            } message: { Text("All development fixtures will be removed. Your own logs and check-ins will stay.") }
        }
    }

    @ViewBuilder private var queueContent: some View {
        if (filter == .all || filter == .due) && !due.isEmpty { QueueGroup(title: "Ready now", items: due, store: store, onAnswer: { answerTarget = CheckInTarget(entryID: $0.entry.id, checkInID: $0.checkIn.id) }, onReschedule: { scheduleTarget = CheckInTarget(entryID: $0.entry.id, checkInID: $0.checkIn.id) }, onSkip: { checkInToSkip = $0.checkIn }) }
        if (filter == .all || filter == .upcoming) && !upcoming.isEmpty { QueueGroup(title: "Coming up", items: upcoming, store: store, onAnswer: { answerTarget = CheckInTarget(entryID: $0.entry.id, checkInID: $0.checkIn.id) }, onReschedule: { scheduleTarget = CheckInTarget(entryID: $0.entry.id, checkInID: $0.checkIn.id) }, onSkip: { checkInToSkip = $0.checkIn }) }
        if (filter == .all || filter == .recent) && !recent.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionKicker(text: "Recent responses")
                ForEach(recent) { item in
                    ForesightCard {
                        HStack(alignment: .top) {
                            NavigationLink(value: item.entry.id) { VStack(alignment: .leading, spacing: 5) { Text("\(item.checkIn.status == .skipped ? "Skipped" : item.checkIn.responseSummary) · \(ForesightFormat.listDate(item.checkIn.updatedAt))").font(.caption.weight(.bold)).foregroundStyle(Color.foresightSage); Text(item.entry.body).font(.subheadline).lineLimit(2).multilineTextAlignment(.leading) } }.buttonStyle(.plain)
                            Spacer()
                            Button(item.checkIn.status == .skipped ? "Answer" : "Update") { answerTarget = CheckInTarget(entryID: item.entry.id, checkInID: item.checkIn.id) }.buttonStyle(ForesightSecondaryButtonStyle())
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if queue.isEmpty && recent.isEmpty { EmptyState(title: filter == .due ? "Nothing due" : "Nothing here yet", detail: filter == .due ? "Your scheduled check-ins are caught up." : "Schedule a follow-up from any saved log and it will appear here.") }
    }

    #if ENABLE_DEVELOPMENT_FIXTURES
    private var developmentControls: some View {
        ForesightCard {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    SectionKicker(text: "Development data")
                    Text(store.demoDataState() == .complete ? "Sample history is loaded." : "Add a 90-day pattern history plus queue states.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(store.demoDataState() == .complete ? "Remove" : "Add history") {
                    if store.demoDataState() == .complete { sampleConfirmation = true }
                    else { do { try store.addDemoHistory(); message = "Sample history added. You can safely run this again." } catch { message = error.localizedDescription } }
                }.buttonStyle(ForesightSecondaryButtonStyle())
            }
        }
    }
    #endif

}

struct QueueGroup: View {
    let title: String
    let items: [QueuedCheckIn]
    let store: JournalStore
    let onAnswer: (QueuedCheckIn) -> Void
    let onReschedule: (QueuedCheckIn) -> Void
    let onSkip: (QueuedCheckIn) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionKicker(text: title)
            ForEach(items) { item in
                ForesightCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.overdue ? "Overdue since \(ForesightFormat.detailDate(item.checkIn.dueAt!))" : item.due ? "Due now" : "Due \(ForesightFormat.detailDate(item.checkIn.dueAt!))")
                            .font(.caption.weight(.bold)).foregroundStyle(item.overdue ? Color.foresightWarning : Color.foresightSage)
                        NavigationLink(value: item.entry.id) { VStack(alignment: .leading, spacing: 3) { Text(item.entry.body).font(ForesightType.journalBody).foregroundStyle(Color.foresightInk).lineLimit(3).multilineTextAlignment(.leading); Text("Happened \(ForesightFormat.listDate(item.entry.eventAt))").font(.caption).foregroundStyle(Color.foresightMuted) } }.buttonStyle(.plain)
                        ViewThatFits(in: .horizontal) {
                            HStack { queueActions(item) }
                            VStack(alignment: .leading) { queueActions(item) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func queueActions(_ item: QueuedCheckIn) -> some View {
        Button(item.due ? "Answer" : "Answer early") { onAnswer(item) }.buttonStyle(ForesightPrimaryButtonStyle())
        Button("Reschedule") { onReschedule(item) }.buttonStyle(ForesightSecondaryButtonStyle())
        Button("Skip") { onSkip(item) }.buttonStyle(ForesightQuietButtonStyle(tone: .foresightWarning))
    }
}

private struct CheckInSummary: View {
    let due: Int
    let upcoming: Int
    let recent: Int

    var body: some View {
        HStack(spacing: 8) {
            metric(due, label: "Ready", emphasized: due > 0)
            metric(upcoming, label: "Upcoming")
            metric(recent, label: "Recent")
        }
        .frame(maxWidth: .infinity)
    }

    private func metric(_ value: Int, label: String, emphasized: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title3.weight(.bold))
                .foregroundStyle(emphasized ? Color.foresightWarning : Color.foresightSage)
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.foresightMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .background(emphasized ? Color.foresightWarm : Color.foresightSoftSage, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
