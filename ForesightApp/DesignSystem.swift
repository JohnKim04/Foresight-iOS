import SwiftUI
import UIKit

// MARK: - Brand tokens

extension Color {
    /// Warm, low-contrast surfaces keep the journal feeling personal rather than clinical.
    static let foresightCanvas = Color(light: 0xF5F4EF, dark: 0x1C201C)
    static let foresightSurface = Color(light: 0xFFFEFA, dark: 0x252A25)
    static let foresightRaised = Color(light: 0xF6F7F3, dark: 0x2B312B)
    static let foresightInk = Color(light: 0x20231F, dark: 0xF2F1EB)
    static let foresightMuted = Color(light: 0x667067, dark: 0xAAB3AA)
    static let foresightLine = Color(light: 0xD9DDD5, dark: 0x3E473F)
    static let foresightSage = Color(light: 0x34503F, dark: 0xA6CFAD)
    static let foresightAction = Color(light: 0x34503F, dark: 0x42664E)
    static let foresightSageMid = Color(light: 0x55715F, dark: 0x82A889)
    static let foresightSoftSage = Color(light: 0xE8EEE7, dark: 0x2C3B30)
    static let foresightWarm = Color(light: 0xFAF2DF, dark: 0x3D3426)
    static let foresightWarning = Color(light: 0x714F20, dark: 0xE6BE7A)
    static let foresightNegative = Color(light: 0xA56A55, dark: 0xD9A18B)

    // Compatibility for existing call sites and the former asset-backed canvas name.
    static let foresightCream = Color.foresightCanvas

    init(light: UInt, dark: UInt) {
        self.init(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(rgb: UInt) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: 1
        )
    }
}

enum ForesightType {
    static let pageTitle = Font.system(.largeTitle, design: .serif).weight(.semibold)
    static let sectionTitle = Font.system(.title3, design: .serif).weight(.semibold)
    static let journalBody = Font.system(.body, design: .serif)
    static let insight = Font.system(.headline, design: .serif)
    static let control = Font.subheadline.weight(.semibold)
    static let metadata = Font.caption.weight(.semibold)
}

struct ForesightMark: View {
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            Circle().fill(Color.foresightSurface)
            Circle()
                .fill(Color.foresightSoftSage)
                .frame(width: size * 0.24, height: size * 0.24)
                .offset(y: -size * 0.14)
            ForesightHill(crest: 0.48, trough: 0.68)
                .fill(Color.foresightSageMid.opacity(0.55))
            ForesightHill(crest: 0.62, trough: 0.49)
                .fill(Color.foresightSageMid.opacity(0.78))
            ForesightHill(crest: 0.76, trough: 0.56)
                .fill(Color.foresightSage)
            Circle().stroke(Color.foresightLine, lineWidth: max(1, size * 0.035))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

private struct ForesightHill: Shape {
    let crest: CGFloat
    let trough: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.height * trough))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.height * crest),
            control1: CGPoint(x: rect.width * 0.28, y: rect.height * (crest - 0.16)),
            control2: CGPoint(x: rect.width * 0.65, y: rect.height * (trough + 0.12))
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Layout and hierarchy

struct ContentColumn<Content: View>: View {
    @ViewBuilder let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct ForesightPageHeader<Trailing: View>: View {
    let kicker: String
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: Trailing

    init(kicker: String, title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) {
        self.kicker = kicker
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    SectionKicker(text: kicker)
                    Text(title)
                        .font(ForesightType.pageTitle)
                        .foregroundStyle(Color.foresightInk)
                        .tracking(-0.8)
                }
                Spacer(minLength: 8)
                trailing
            }
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Color.foresightMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension ForesightPageHeader where Trailing == EmptyView {
    init(kicker: String, title: String, subtitle: String) {
        self.init(kicker: kicker, title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct ForesightCard<Content: View>: View {
    @ViewBuilder let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.foresightSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.foresightLine, lineWidth: 1)
            }
    }
}

struct SectionKicker: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.heavy))
            .tracking(1.3)
            .foregroundStyle(Color.foresightSage)
    }
}

struct ForesightSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = selection == option.value
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selected ? Color.foresightInk : Color.foresightMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .allowsTightening(true)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(selected ? Color.foresightSurface : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity)
        .background(Color.foresightLine.opacity(0.62), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Anchored dropdowns

/// The data shown by a Foresight dropdown. `ID` is intentionally separate from
/// `Value`: selectors whose "all" state is `nil` still need a stable row ID.
struct ForesightDropdownOption<Value: Hashable, ID: Hashable>: Identifiable {
    let id: ID
    let value: Value
    let title: String
    var badge: String?

    init(id: ID, value: Value, title: String, badge: String? = nil) {
        self.id = id
        self.value = value
        self.title = title
        self.badge = badge
    }
}

enum ForesightDropdownStyle {
    case compact(systemImage: String)
    case fullWidth(systemImage: String, label: String)
}

@MainActor
final class ForesightDropdownCoordinator: ObservableObject {
    struct Presentation {
        let id: String
        let style: ForesightDropdownStyle
        let panel: AnyView
        let preferredHeight: CGFloat
        let contentWidth: CGFloat
    }

    @Published private(set) var active: Presentation?

    func toggle(_ presentation: Presentation) {
        active = active?.id == presentation.id ? nil : presentation
    }

    func dismiss() { active = nil }
}

private struct ForesightDropdownAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// Installs a single screen-level presentation surface. Keeping the panel here
/// avoids menu sheets and prevents a card or scroll view from clipping it.
struct ForesightDropdownHost<Content: View>: View {
    @StateObject private var coordinator = ForesightDropdownCoordinator()
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .environmentObject(coordinator)
            .overlayPreferenceValue(ForesightDropdownAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    if let active = coordinator.active, let anchor = anchors[active.id] {
                        ForesightDropdownOverlay(
                            active: active,
                            triggerFrame: proxy[anchor],
                            allTriggerFrames: anchors.values.map { proxy[$0] },
                            containerSize: proxy.size,
                            safeAreaInsets: proxy.safeAreaInsets,
                            dismiss: coordinator.dismiss
                        )
                    }
                }
            }
    }
}

struct ForesightDropdown<Value: Hashable, ID: Hashable>: View {
    @Binding private var selection: Value
    private let id: String
    private let options: [ForesightDropdownOption<Value, ID>]
    private let style: ForesightDropdownStyle
    private let title: String
    private let accessibilityLabel: String
    private let accessibilityValue: String
    @EnvironmentObject private var coordinator: ForesightDropdownCoordinator

    init(
        id: String,
        selection: Binding<Value>,
        options: [ForesightDropdownOption<Value, ID>],
        style: ForesightDropdownStyle,
        title: String? = nil,
        accessibilityLabel: String,
        accessibilityValue: String
    ) {
        self.id = id
        self.title = title ?? accessibilityValue
        _selection = selection
        self.options = options
        self.style = style
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
    }

    var body: some View {
        Button {
            withAnimation(.spring(duration: 0.22, bounce: 0.16)) {
                coordinator.toggle(presentation)
            }
        } label: {
            ForesightDropdownTrigger(
                title: title,
                style: style,
                isExpanded: coordinator.active?.id == id
            )
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .anchorPreference(key: ForesightDropdownAnchorKey.self, value: .bounds) { [id: $0] }
        .onDisappear { coordinator.dismiss() }
    }

    private var presentation: ForesightDropdownCoordinator.Presentation {
        let rowHeight: CGFloat = 44
        let rowSpacing: CGFloat = 2
        let panelPadding: CGFloat = 12
        let contentHeight = CGFloat(options.count) * rowHeight
            + CGFloat(max(0, options.count - 1)) * rowSpacing
            + panelPadding
        return ForesightDropdownCoordinator.Presentation(
            id: id,
            style: style,
            panel: AnyView(ForesightDropdownPanel(selection: $selection, options: options, dismiss: coordinator.dismiss)),
            preferredHeight: contentHeight,
            contentWidth: Self.measuredContentWidth(options)
        )
    }

    /// Widest row (title + optional badge + reserved checkmark slot) so the panel
    /// hugs short option lists instead of always padding out to a fixed minimum.
    private static func measuredContentWidth(_ options: [ForesightDropdownOption<Value, ID>]) -> CGFloat {
        // UIFontMetrics mirrors SwiftUI's own Dynamic Type scaling curve more closely
        // than a plain systemFont(ofSize:), so the estimate stays accurate as text size changes.
        let titleFont = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .medium))
        let badgeFont = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .systemFont(ofSize: 11, weight: .bold))
        let rowPadding: CGFloat = 28 // 14pt leading + 14pt trailing row padding
        let itemSpacing: CGFloat = 10 // HStack(spacing: 10) in ForesightDropdownPanel
        let spacerMin: CGFloat = 8 // Spacer(minLength: 8)
        let badgeHorizontalPadding: CGFloat = 14 // 7pt + 7pt capsule padding
        let checkmarkWidth: CGFloat = 18 // reserved so width doesn't shift when selection changes
        let measurementSlack: CGFloat = 40 // covers kerning/rounding drift between NSString sizing and SwiftUI's Text layout

        return options.reduce(CGFloat(0)) { widest, option in
            var width = rowPadding + measurementSlack
            width += (option.title as NSString).size(withAttributes: [.font: titleFont]).width
            width += itemSpacing + spacerMin
            if let badge = option.badge {
                width += itemSpacing + badgeHorizontalPadding + (badge as NSString).size(withAttributes: [.font: badgeFont]).width
            }
            width += itemSpacing + checkmarkWidth
            return max(widest, width.rounded(.up))
        }
    }
}

private struct ForesightDropdownTrigger: View {
    let title: String
    let style: ForesightDropdownStyle
    let isExpanded: Bool

    var body: some View {
        switch style {
        case let .compact(systemImage):
            Label {
                HStack(spacing: 6) {
                    Text(title).lineLimit(1)
                    chevron
                }
            } icon: {
                Image(systemName: systemImage)
            }
            .font(ForesightType.control)
            .foregroundStyle(Color.foresightSage)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.foresightRaised, in: Capsule())
            .overlay(Capsule().stroke(Color.foresightLine, lineWidth: 1))
        case let .fullWidth(systemImage, label):
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.foresightSage)
                    .frame(width: 34, height: 34)
                    .background(Color.foresightSoftSage, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.caption2.weight(.bold)).foregroundStyle(Color.foresightMuted).textCase(.uppercase).tracking(0.7)
                    Text(title).font(ForesightType.control).foregroundStyle(Color.foresightInk).lineLimit(1)
                }
                Spacer(minLength: 8)
                chevron
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(Color.foresightRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.foresightLine, lineWidth: 1) }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.caption.weight(.bold))
            .foregroundStyle(Color.foresightSage)
            .rotationEffect(.degrees(isExpanded ? 180 : 0))
            .animation(.spring(duration: 0.22, bounce: 0.16), value: isExpanded)
    }
}

private struct ForesightDropdownOverlay: View {
    let active: ForesightDropdownCoordinator.Presentation
    let triggerFrame: CGRect
    let allTriggerFrames: [CGRect]
    let containerSize: CGSize
    let safeAreaInsets: EdgeInsets
    let dismiss: () -> Void

    var body: some View {
        let margin: CGFloat = 12
        let width = min(containerSize.width - safeAreaInsets.leading - safeAreaInsets.trailing - (margin * 2), preferredWidth)
        let below = containerSize.height - safeAreaInsets.bottom - margin - triggerFrame.maxY - 6
        let above = triggerFrame.minY - safeAreaInsets.top - margin - 6
        let placeAbove = below < 220 && above > below
        let available = placeAbove ? above : below
        let height = max(44, min(active.preferredHeight, min(360, available)))
        let left = min(max(triggerFrame.minX, safeAreaInsets.leading + margin), containerSize.width - safeAreaInsets.trailing - margin - width)
        let centerY = placeAbove ? triggerFrame.minY - 6 - height / 2 : triggerFrame.maxY + 6 + height / 2

        ZStack(alignment: .topLeading) {
            // Catches taps outside the panel so they close it without reaching the
            // content underneath. Triggers are left uncovered, so tapping one
            // still toggles or switches panels through its own button action.
            Color.clear
                .contentShape(ForesightDropdownDismissShape(holes: allTriggerFrames), eoFill: true)
                .onTapGesture(perform: dismiss)
                .accessibilityHidden(true)
            active.panel
                .frame(width: width, height: height)
                .position(x: left + width / 2, y: centerY)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: placeAbove ? .bottom : .top)))
        }
        .accessibilityAction(.escape, dismiss)
        .animation(.spring(duration: 0.22, bounce: 0.16), value: active.id)
    }

    private var preferredWidth: CGFloat {
        switch active.style {
        case .compact: max(triggerFrame.width, active.contentWidth)
        case .fullWidth: triggerFrame.width
        }
    }

}

private struct ForesightDropdownDismissShape: Shape {
    let holes: [CGRect]

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        holes.forEach { path.addRect($0) }
        return path
    }
}

private struct ForesightDropdownPanel<Value: Hashable, ID: Hashable>: View {
    @Binding var selection: Value
    let options: [ForesightDropdownOption<Value, ID>]
    let dismiss: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(options) { option in
                    let selected = selection == option.value
                    Button {
                        selection = option.value
                        UISelectionFeedbackGenerator().selectionChanged()
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Text(option.title).font(.body.weight(.medium)).foregroundStyle(Color.foresightInk).lineLimit(1).multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            if let badge = option.badge {
                                Text(badge).font(.caption2.weight(.bold)).foregroundStyle(Color.foresightSage).padding(.horizontal, 7).padding(.vertical, 4).background(Color.foresightSoftSage, in: Capsule())
                            }
                            if selected { Image(systemName: "checkmark").font(.subheadline.weight(.bold)).foregroundStyle(Color.foresightSage) }
                        }
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(selected ? Color.foresightSoftSage : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.badge.map { "\(option.title) (\($0.lowercased()))" } ?? option.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(6)
        }
        .scrollIndicators(.automatic)
        .background(Color.foresightSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.foresightLine, lineWidth: 1) }
        .shadow(color: .black.opacity(0.14), radius: 14, y: 7)
    }
}

struct ForesightIconButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Color.foresightAction, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct ForesightPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ForesightType.control)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(Color.foresightAction.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.42), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct ForesightSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ForesightType.control)
            .foregroundStyle(Color.foresightSage)
            .padding(.horizontal, 15)
            .frame(minHeight: 42)
            .background(Color.foresightSurface.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
            .overlay(Capsule().stroke(Color.foresightLine, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

struct ForesightQuietButtonStyle: ButtonStyle {
    var tone: Color = .foresightSage

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ForesightType.control)
            .foregroundStyle(tone.opacity(configuration.isPressed ? 0.62 : 1))
            .padding(.horizontal, 6)
            .frame(minHeight: 40)
    }
}

struct ForesightChoiceButtonStyle: ButtonStyle {
    let selected: Bool
    var horizontalPadding: CGFloat = 12
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ForesightType.control)
            .foregroundStyle(selected ? Color.white : Color.foresightInk)
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                selected ? Color.foresightAction : Color.foresightSurface,
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(selected ? Color.foresightAction : Color.foresightLine, lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.76 : 1) : 0.45)
    }
}

struct EmptyState: View {
    let title: String
    let detail: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            ForesightMark(size: 32)
                .padding(.bottom, 2)
            Text(title)
                .font(ForesightType.sectionTitle)
                .foregroundStyle(Color.foresightInk)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(Color.foresightMuted)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(ForesightSecondaryButtonStyle())
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 30)
        .background(Color.foresightSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.foresightLine, lineWidth: 1) }
    }
}

func displayDay(_ day: String) -> String {
    let parts = day.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3, let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return day }
    return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
}
