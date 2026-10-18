import SwiftUI
import UIKit

enum JournalDateScope: String, CaseIterable, Identifiable { case recent, all, custom; var id: String { rawValue }; var title: String { self == .recent ? "30 days" : rawValue.capitalized } }

struct JournalRootView: View {
    let store: JournalStore
    /// Set by the widget's Log button; opens a new log.
    @Binding var newLogRequest: Bool
    let openSettings: () -> Void
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
    @State private var navigationPath: [UUID] = []
    @State private var suggestion: HelpSuggestion?
    @AppStorage(JournalSuggestionState.hiddenKey) private var hiddenSuggestions = ""
    @State private var clock = Date.now
    @Environment(CheckInReminderRouter.self) private var router
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
        NavigationStack(path: $navigationPath) {
            ScrollView {
                ContentColumn {
                    VStack(alignment: .leading, spacing: 18) {
                        ForesightPageHeader(
                            kicker: "Private journal",
                            title: "Notice what follows.",
                            subtitle: "Write down what happened. Check in later to see how you felt."
                        ) {
                            Button("Settings", systemImage: "gearshape", action: openSettings)
                                .labelStyle(.iconOnly)
                                .font(.title3)
                                .foregroundStyle(Color.foresightInk)
                                .frame(width: 44, height: 44)
                                .glassEffect(.regular, in: Circle())
                        }
                        suggestionCard
                        // Filters have nothing to work on until the first log, so a new
                        // journal opens straight onto the prompt to write one.
                        if !store.entries.isEmpty { journalControls }
                        if viewMode == .timeline { timeline } else { calendar }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.foresightCanvas)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                journalBottomBar
            }
            .navigationDestination(for: UUID.self) { JournalDetailView(store: store, entryID: $0) }
            .fullScreenCover(item: $editor) { JournalEditorView(store: store, request: $0) }
            .onChange(of: newLogRequest, initial: true) { _, requested in
                guard requested else { return }
                editor = EditorRequest(entryID: nil)
                newLogRequest = false
            }
            .onChange(of: HelpReportKey(store: store, now: clock), initial: true) {
                suggestion = journalSuggestion(helpSuggestions(entries: store.entries, checkIns: store.checkIns, categories: store.categories, limit: .max))
            }
            // Keeps the card on today's suggestion, and brings back one hidden yesterday.
            .hourlyClock($clock)
        }
    }

    /// Only shown when there is a confident suggestion; it steps aside while searching.
    @ViewBuilder private var suggestionCard: some View {
        if let suggestion, query.isEmpty, !JournalSuggestionState.isHidden(suggestion.category.id, stored: hiddenSuggestions, now: clock) {
            JournalSuggestionCard(suggestion: suggestion) {
                // The root view switches to Patterns and opens the evidence.
                router.destination = .evidence(suggestion.category.id)
            } onHide: {
                withAnimation(.snappy) { hiddenSuggestions = JournalSuggestionState.hiding(suggestion.category.id, stored: hiddenSuggestions) }
            }
            .transition(.opacity)
        }
    }

    private var journalBottomBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.foresightMuted)
                TextField("Search logs and categories", text: $query)
                    .submitLabel(.search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Color.foresightMuted)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .glassEffect(.regular, in: Capsule())
            .accessibilityElement(children: .contain)

            Button {
                editor = EditorRequest(entryID: nil)
            } label: {
                ZStack {
                    Circle().fill(.clear)
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .semibold))
                }
                .frame(width: 48, height: 48)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.foresightInk)
            .glassEffect(.regular, in: Circle())
            .accessibilityLabel("New log")
            .zIndex(1)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .foresightDropdownAvoided()
    }

    private var journalControls: some View {
        ForesightCard {
            VStack(alignment: .leading, spacing: 12) {
                ForesightSegmentedPicker(
                    selection: $viewMode,
                    options: JournalViewMode.allCases.map { ($0, $0.title) }
                )
                ForesightSegmentedPicker(
                    selection: $dateScope,
                    options: JournalDateScope.allCases.map { ($0, $0.title) }
                )
                if dateScope == .custom {
                    DatePicker("From", selection: $customStart, displayedComponents: .date)
                    DatePicker("To", selection: $customEnd, displayedComponents: .date)
                }
                journalFilterDropdowns
            }
        }
    }

    @ViewBuilder private var journalFilterDropdowns: some View {
        let categoryOptions = [ForesightDropdownOption<UUID?, String>(id: "all-categories", value: nil, title: "All categories")]
            + store.categories.map { ForesightDropdownOption(id: "category-\($0.id.uuidString)", value: Optional($0.id), title: $0.name, badge: $0.isArchived ? "Archived" : nil) }
        let checkInOptions = JournalCheckInFilter.allCases.map { ForesightDropdownOption(id: $0.rawValue, value: $0, title: $0.title) }
        let categoryDropdown = ForesightDropdown(
            id: "journal.category",
            selection: $categoryID,
            options: categoryOptions,
            style: .compact(systemImage: "tag"),
            accessibilityLabel: "Choose category",
            accessibilityValue: categoryID.flatMap { id in store.categories.first { $0.id == id } }?.name ?? "All categories"
        )
        let checkInDropdown = ForesightDropdown(
            id: "journal.check-in",
            selection: $checkInFilter,
            options: checkInOptions,
            style: .compact(systemImage: "line.3.horizontal.decrease.circle"),
            accessibilityLabel: "Choose check-in filter",
            accessibilityValue: checkInFilter.title
        )

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                categoryDropdown
                checkInDropdown
            }
        } else {
            HStack {
                categoryDropdown
                Spacer()
                checkInDropdown
            }
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 16) {
            if entries.isEmpty {
                EmptyState(title: matching.isEmpty ? "Start your journal" : "No matching logs", detail: matching.isEmpty ? "Write a short log about something that happened today." : "Try changing the search or filters.", actionTitle: matching.isEmpty ? "Write a log" : nil, action: matching.isEmpty ? { editor = EditorRequest(entryID: nil) } : nil)
            } else {
                ForEach(groupEntriesByDay(entries)) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(displayDay(group.day)).font(ForesightType.metadata).foregroundStyle(Color.foresightMuted)
                        ForEach(group.entries, id: \.id) { entry in JournalEntryRow(entry: entry, label: entryCheckInLabel(entry: entry, checkIns: store.checkIns)) { navigationPath.append(entry.id) } }
                    }
                }
                if olderCount > 0 {
                    Button("Show \(olderCount) older \(olderCount == 1 ? "log" : "logs")") { dateScope = .all }
                        .buttonStyle(ForesightSecondaryButtonStyle()).frame(maxWidth: .infinity)
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
                ForEach(selectedEntries, id: \.id) { entry in JournalEntryRow(entry: entry, label: entryCheckInLabel(entry: entry, checkIns: store.checkIns)) { navigationPath.append(entry.id) } }
            }
        }
    }

    private func moveMonth(_ amount: Int) {
        calendarMonth = Calendar.current.date(byAdding: .month, value: amount, to: calendarMonth)!
        selectedDay = localDayKey(calendarMonth)
    }
}

/// A compact version of the Patterns suggestion card for the top of Journal.
struct JournalSuggestionCard: View {
    let suggestion: HelpSuggestion
    let onOpen: () -> Void
    let onHide: () -> Void

    var body: some View {
        ForesightCard {
            HStack(alignment: .top, spacing: 8) {
                Button(action: onOpen) {
                    HStack(alignment: .top, spacing: 10) {
                        Capsule().fill(Color.foresightSageMid).frame(width: 5).frame(minHeight: 38)
                        VStack(alignment: .leading, spacing: 4) {
                            SectionKicker(text: HelpSuggestionCopy.title)
                            Text(suggestion.headline).font(.subheadline).foregroundStyle(Color.foresightInk).multilineTextAlignment(.leading)
                            Text(suggestion.evidence).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                            if let context = suggestion.context { Text(context).font(.caption).foregroundStyle(Color.foresightSage).multilineTextAlignment(.leading) }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("See the \(suggestion.category.name) pattern")
                .accessibilityIdentifier("journal.suggestion")
                Button(HelpSuggestionCopy.hideForToday, systemImage: "xmark", action: onHide)
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.foresightMuted)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("journal.suggestion.hide")
            }
        }
    }
}

struct JournalEntryRow: View {
    let entry: JournalEntry
    let label: String?
    let onOpen: () -> Void
    @State private var cardSize: CGSize = .zero
    @GestureState private var isPressed = false

    var body: some View {
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
        .scaleEffect(isPressed ? 0.985 : 1)
        .opacity(isPressed ? 0.85 : 1)
        .animation(.easeOut(duration: 0.12), value: isPressed)
        .contentShape(.interaction, RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
        .gesture(SpatialTapGesture().onEnded { tap in
            // SwiftUI can deliver taps from just outside the drawn card.
            guard contains(tap.location) else { return }
            onOpen()
        })
        // Never completes; it only tracks touch-down for the pressed state and
        // fails once the finger moves, so scrolling and the tap above still work.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: .infinity, maximumDistance: 10)
                .updating($isPressed) { _, pressed, _ in pressed = true }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
    }

    private func contains(_ point: CGPoint) -> Bool {
        RoundedRectangle(cornerRadius: 18, style: .continuous).path(in: CGRect(origin: .zero, size: cardSize)).contains(point)
    }
}

enum QueueFilter: String, CaseIterable, Identifiable {
    case all, due, upcoming, recent
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    func title(count: Int) -> String { self == .all || count == 0 ? title : "\(title) \(count)" }

    var emptyTitle: String {
        switch self {
        case .all: "Nothing here yet"
        case .due: "Nothing due"
        case .upcoming: "Nothing upcoming"
        case .recent: "No answers yet"
        }
    }

    var emptyDetail: String {
        switch self {
        case .all: "Check-ins you schedule will show up here."
        case .due: "You're caught up. Upcoming check-ins appear here when their time comes."
        case .upcoming: "Pick a later time after you save a log and it will wait here."
        case .recent: "Check-ins you answer or skip show up here, so you can change them."
        }
    }
}

struct CheckInRootView: View {
    let store: JournalStore
    /// Set when a reminder is tapped; opens that check-in's answer sheet.
    @Binding var answerRequest: CheckInTarget?
    @State private var filter: QueueFilter = .all
    @State private var answerTarget: CheckInTarget?
    @State private var scheduleTarget: CheckInTarget?
    @State private var checkInToSkip: OutcomeCheckIn?
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
                                kicker: "Follow up",
                                title: "How did it go?",
                                subtitle: "Rate how you feel a while after each log. Patterns builds on these answers."
                            )
                            if !queue.isEmpty || !recent.isEmpty {
                                ForesightSegmentedPicker(
                                    selection: $filter,
                                    options: QueueFilter.allCases.map { ($0, $0.title(count: count(for: $0))) }
                                )
                            }
                            if let message { Text(message).font(.footnote).foregroundStyle(Color.foresightSage) }
                            queueContent
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
            .onChange(of: answerRequest, initial: true) { _, request in
                guard let request else { return }
                answerTarget = request
                answerRequest = nil
            }
            .alert("Skip this check-in?", isPresented: Binding(get: { checkInToSkip != nil }, set: { if !$0 { checkInToSkip = nil } })) {
                Button("Skip") { if let checkInToSkip { try? store.skip(checkInToSkip); message = "Check-in skipped." } }
                Button("Cancel", role: .cancel) { }
            } message: { Text("It moves to Recent, where you can still answer it.") }
        }
    }

    @ViewBuilder private var queueContent: some View {
        if (filter == .all || filter == .due) && !due.isEmpty { QueueGroup(title: "Due · \(due.count)", items: due, store: store, onAnswer: { answerTarget = CheckInTarget(entryID: $0.entry.id, checkInID: $0.checkIn.id) }, onReschedule: { scheduleTarget = CheckInTarget(entryID: $0.entry.id, checkInID: $0.checkIn.id) }, onSkip: { checkInToSkip = $0.checkIn }) }
        if (filter == .all || filter == .upcoming) && !upcoming.isEmpty { QueueGroup(title: "Upcoming · \(upcoming.count)", items: upcoming, store: store, onAnswer: { answerTarget = CheckInTarget(entryID: $0.entry.id, checkInID: $0.checkIn.id) }, onReschedule: { scheduleTarget = CheckInTarget(entryID: $0.entry.id, checkInID: $0.checkIn.id) }, onSkip: { checkInToSkip = $0.checkIn }) }
        if (filter == .all || filter == .recent) && !recent.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionKicker(text: "Recent · \(recent.count)")
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
        if queue.isEmpty && recent.isEmpty {
            EmptyState(title: "Nothing to check in on yet", detail: "After you save a log, pick a time to check in later. It will wait here, and Foresight can remind you.")
        } else if count(for: filter) == 0 {
            EmptyState(title: filter.emptyTitle, detail: filter.emptyDetail)
        }
    }

    private func count(for filter: QueueFilter) -> Int {
        switch filter {
        case .all: queue.count + recent.count
        case .due: due.count
        case .upcoming: upcoming.count
        case .recent: recent.count
        }
    }
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
