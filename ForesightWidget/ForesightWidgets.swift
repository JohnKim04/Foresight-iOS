import SwiftData
import SwiftUI
import UIKit
import WidgetKit

@main
struct ForesightWidgets: WidgetBundle {
    var body: some Widget {
        CheckInsWidget()
        QuickLogWidget()
    }
}

// MARK: - Check-ins

struct CheckInsEntry: TimelineEntry, Sendable {
    let date: Date
    /// Nil when the widget can't read the journal: no shared App Group, or a store it can't open.
    let state: CheckInWidgetState?
}

/// Reads the journal the app keeps in the App Group container. It never writes or migrates it;
/// the app reloads every timeline after each change.
enum CheckInWidgetStore {
    static func loadItems() -> [CheckInWidgetItem]? {
        guard let url = SharedJournal.sharedStoreURL else { return nil }
        // No journal yet: the app hasn't been opened. Don't create one here.
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let container = try ForesightPersistence.makeContainer(storeURL: url, allowsSave: false)
            let context = ModelContext(container)
            return CheckInWidgetPlan.items(from: try context.fetch(FetchDescriptor<OutcomeCheckIn>()))
        } catch {
            return nil
        }
    }
}

struct CheckInsProvider: TimelineProvider {
    func placeholder(in context: Context) -> CheckInsEntry {
        CheckInsEntry(date: .now, state: CheckInWidgetState(due: [CheckInWidgetItem(checkInID: UUID(), dueAt: .now, text: "Went for an evening run")], nextDueAt: nil))
    }

    func getSnapshot(in context: Context, completion: @escaping (CheckInsEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        let now = Date.now
        completion(CheckInsEntry(date: now, state: CheckInWidgetStore.loadItems().map { CheckInWidgetPlan.state(for: $0, at: now) }))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CheckInsEntry>) -> Void) {
        let now = Date.now
        guard let items = CheckInWidgetStore.loadItems() else {
            // Try again later in case the app has since moved the journal into the group.
            completion(Timeline(entries: [CheckInsEntry(date: now, state: nil)], policy: .after(now.addingTimeInterval(6 * 60 * 60))))
            return
        }
        let entries = CheckInWidgetPlan.entryDates(for: items, now: now).map { CheckInsEntry(date: $0, state: CheckInWidgetPlan.state(for: items, at: $0)) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct CheckInsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CheckIns", provider: CheckInsProvider()) { entry in
            CheckInsWidgetView(entry: entry)
        }
        .configurationDisplayName("Check-ins")
        .description("Check-ins that are ready to answer, and a quick way to log.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct CheckInsWidgetView: View {
    let entry: CheckInsEntry
    @Environment(\.widgetFamily) private var family

    private var dueCount: Int { entry.state?.due.count ?? 0 }

    /// The first due check-in opens its answer sheet; with nothing due, a tap starts a log.
    private var tapLink: ForesightLink {
        guard let state = entry.state else { return .checkIns }
        return state.due.first.map { .checkIn($0.checkInID) } ?? .newLog
    }

    var body: some View {
        content
            .widgetURL(tapLink.url)
            .containerBackground(for: .widget) {
                if family == .accessoryCircular {
                    AccessoryWidgetBackground()
                } else {
                    WidgetPalette.canvas
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        case .systemMedium: medium
        default: small
        }
    }

    // Lock screen widgets show counts and times only. The log text stays on the home screen.

    private var circular: some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark.circle")
                .font(.caption)
            Text(entry.state == nil ? "–" : "\(dueCount)")
                .font(.title2.weight(.semibold))
                .minimumScaleFactor(0.6)
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Check In")
                .font(.headline)
            Text(headline)
                .font(.subheadline)
            if let next = entry.state?.nextDueAt, dueCount == 0 {
                Text("Next at \(next, style: .time)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inline: some View {
        Label(headline, systemImage: "checkmark.circle")
    }

    private var headline: String {
        guard entry.state != nil else { return "Open Foresight" }
        switch dueCount {
        case 0: return "Nothing to answer"
        case 1: return "1 check-in ready"
        default: return "\(dueCount) check-ins ready"
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            kicker
            if let state = entry.state {
                if let first = state.due.first {
                    Text("\(state.due.count) ready")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(WidgetPalette.ink)
                    Text(first.text)
                        .font(.footnote)
                        .foregroundStyle(WidgetPalette.muted)
                        .lineLimit(3)
                } else {
                    nothingDue
                }
            } else {
                unavailable
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                kicker
                if let state = entry.state {
                    if state.due.isEmpty {
                        nothingDue
                    } else {
                        Text("\(state.due.count) ready")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(WidgetPalette.ink)
                        ForEach(state.due.prefix(2), id: \.checkInID) { item in
                            Link(destination: ForesightLink.checkIn(item.checkInID).url) {
                                Text(item.text)
                                    .font(.footnote)
                                    .foregroundStyle(WidgetPalette.muted)
                                    .lineLimit(1)
                            }
                        }
                    }
                } else {
                    unavailable
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Link(destination: ForesightLink.newLog.url) {
                VStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.title3.weight(.semibold))
                    Text("Log")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(WidgetPalette.onAction)
                .frame(width: 64, height: 64)
                .background(WidgetPalette.action, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private var kicker: some View {
        Text("CHECK IN")
            .font(.caption2.weight(.bold))
            .tracking(0.8)
            .foregroundStyle(WidgetPalette.sage)
    }

    @ViewBuilder private var nothingDue: some View {
        Text("Nothing to answer")
            .font(.headline)
            .foregroundStyle(WidgetPalette.ink)
        if let next = entry.state?.nextDueAt {
            Text("Next at \(next, style: .time)")
                .font(.footnote)
                .foregroundStyle(WidgetPalette.muted)
        } else {
            Text(family == .systemMedium ? "Log what just happened." : "Tap to log.")
                .font(.footnote)
                .foregroundStyle(WidgetPalette.muted)
        }
    }

    private var unavailable: some View {
        Text("Open Foresight to see check-ins here.")
            .font(.footnote)
            .foregroundStyle(WidgetPalette.muted)
    }
}

// MARK: - Quick log

struct QuickLogEntry: TimelineEntry, Sendable {
    let date: Date
}

struct QuickLogProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickLogEntry { QuickLogEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (QuickLogEntry) -> Void) {
        completion(QuickLogEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickLogEntry>) -> Void) {
        completion(Timeline(entries: [QuickLogEntry(date: .now)], policy: .never))
    }
}

struct QuickLogWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "QuickLog", provider: QuickLogProvider()) { _ in
            QuickLogWidgetView()
        }
        .configurationDisplayName("Log")
        .description("Start a new log in one tap.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

struct QuickLogWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(ForesightLink.newLog.url)
            .containerBackground(for: .widget) {
                if family == .accessoryCircular {
                    AccessoryWidgetBackground()
                } else {
                    WidgetPalette.canvas
                }
            }
    }

    @ViewBuilder private var content: some View {
        if family == .accessoryCircular {
            VStack(spacing: 0) {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                Text("Log")
                    .font(.caption2.weight(.semibold))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("FORESIGHT")
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(WidgetPalette.sage)
                Spacer(minLength: 0)
                Image(systemName: "plus.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(WidgetPalette.action)
                Text("Log what happened")
                    .font(.headline)
                    .foregroundStyle(WidgetPalette.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Colors

/// The app's palette, repeated here because the widget doesn't build the design system.
enum WidgetPalette {
    static let canvas = color(light: 0xF5F4EF, dark: 0x1C201C)
    static let ink = color(light: 0x20231F, dark: 0xF2F1EB)
    static let muted = color(light: 0x667067, dark: 0xAAB3AA)
    static let sage = color(light: 0x34503F, dark: 0xA6CFAD)
    static let action = color(light: 0x34503F, dark: 0x42664E)
    static let onAction = Color.white

    private static func color(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        })
    }
}
