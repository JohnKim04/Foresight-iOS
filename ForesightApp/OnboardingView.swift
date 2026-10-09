import SwiftUI

/// A short first-run walkthrough of the core loop: log, check in, see patterns.
struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var page = 0

    private struct Page {
        let symbol: String?
        let kicker: String
        let title: String
        let detail: String
    }

    private let pages = [
        Page(symbol: nil, kicker: "Welcome to Foresight", title: "See what your choices lead to.", detail: "A private journal for the things you do and how they turn out. Everything stays on this phone."),
        Page(symbol: "square.and.pencil", kicker: "1 · Log", title: "Write down what happened.", detail: "A line is enough: a workout, a late night, an hour of scrolling. Add a category so similar moments line up later."),
        Page(symbol: "checkmark.circle", kicker: "2 · Check in", title: "Say how it felt, twice.", detail: "Rate how you feel right after you log, then again a few hours later once the effects have settled. Check In shows what's due."),
        Page(symbol: "chart.xyaxis.line", kicker: "3 · Patterns", title: "See what tends to help.", detail: "After a handful of check-ins, Patterns shows what usually came before feeling better or worse. It describes what happened, not what caused it.")
    ]

    private var isLastPage: Bool { page == pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if !isLastPage {
                    Button("Skip", action: onFinish)
                        .buttonStyle(ForesightQuietButtonStyle(tone: .foresightMuted))
                }
            }
            .frame(minHeight: 44)
            .padding(.horizontal)

            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    pageView(pages[index]).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 7) {
                ForEach(pages.indices, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? Color.foresightSage : Color.foresightLine)
                        .frame(width: index == page ? 22 : 7, height: 7)
                }
            }
            .animation(.snappy(duration: 0.25), value: page)
            .accessibilityHidden(true)
            .padding(.bottom, 20)

            Button(isLastPage ? "Start journaling" : "Next") {
                if isLastPage { onFinish() } else { withAnimation(.snappy(duration: 0.3)) { page += 1 } }
            }
            .buttonStyle(ForesightPrimaryButtonStyle())
            .frame(maxWidth: 420)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Color.foresightCanvas)
    }

    private func pageView(_ page: Page) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    if let symbol = page.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(Color.foresightSage)
                            .frame(width: 76, height: 76)
                            .background(Color.foresightSoftSage, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .accessibilityHidden(true)
                    } else {
                        ForesightMark(size: 76)
                    }
                }
                .padding(.bottom, 8)
                SectionKicker(text: page.kicker)
                Text(page.title)
                    .font(ForesightType.pageTitle)
                    .foregroundStyle(Color.foresightInk)
                    .tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)
                Text(page.detail)
                    .font(.body)
                    .foregroundStyle(Color.foresightMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 48)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
