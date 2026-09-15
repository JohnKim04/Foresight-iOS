import SwiftUI

extension Color {
    static let foresightCream = Color("Cream")
    static let foresightSage = Color("Sage")
    static let foresightMuted = Color.secondary
    static let foresightWarm = Color(red: 0.96, green: 0.95, blue: 0.91)
    static let foresightSoftSage = Color(red: 0.91, green: 0.94, blue: 0.90)
    static let foresightWarning = Color(red: 0.47, green: 0.29, blue: 0.17)
}

struct ContentColumn<Content: View>: View {
    @ViewBuilder let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct ForesightCard<Content: View>: View {
    @ViewBuilder let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(18)
            .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.quaternary, lineWidth: 1) }
    }
}

struct SectionKicker: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.bold))
            .tracking(1.2)
            .foregroundStyle(Color.foresightSage)
    }
}

struct EmptyState: View {
    let title: String
    let detail: String
    var actionTitle: String?
    var action: (() -> Void)?
    var body: some View {
        ForesightCard {
            VStack(spacing: 8) {
                Text(title).font(.system(.title3, design: .serif).weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.bordered) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }
}

func displayDay(_ day: String) -> String {
    let parts = day.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3, let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return day }
    return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
}
