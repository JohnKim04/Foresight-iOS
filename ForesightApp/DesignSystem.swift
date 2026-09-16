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

struct ForesightMenuLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(ForesightType.control)
            .foregroundStyle(Color.foresightSage)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.foresightRaised, in: Capsule())
            .overlay(Capsule().stroke(Color.foresightLine, lineWidth: 1))
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
