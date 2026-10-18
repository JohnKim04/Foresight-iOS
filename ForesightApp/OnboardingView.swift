import SwiftUI

/// A short first-run walkthrough of the core loop: log, check in, see patterns.
/// It ends on the first log, so a new journal doesn't open empty.
struct OnboardingView: View {
    /// Called with `true` when the person chose to write their first log right away.
    let onFinish: (_ startFirstLog: Bool) -> Void
    @State private var page = 0

    private struct Page {
        let symbol: String?
        let kicker: String
        let title: String
        let detail: String
        let preview: OnboardingPreview
    }

    private let pages = [
        Page(symbol: nil, kicker: "Welcome to Foresight", title: "See what tends to follow.", detail: "A journal for the things you do and how they turn out.", preview: .loop),
        Page(symbol: "square.and.pencil", kicker: "1 · Log", title: "Write down what happened.", detail: "A line is enough: a workout, a late night, an hour of scrolling. Add a category so similar moments line up later.", preview: .log),
        Page(symbol: "checkmark.circle", kicker: "2 · Check in", title: "Say how it felt, twice.", detail: "Rate how you feel right after you log, then again a few hours later. Check In shows what's due, and a reminder can tell you.", preview: .checkIn),
        Page(symbol: "chart.xyaxis.line", kicker: "3 · Patterns", title: "Spot what repeats.", detail: "After a handful of check-ins, Patterns shows what usually came before feeling better or worse. It describes what happened, not what caused it.", preview: .pattern)
    ]

    private var isLastPage: Bool { page == pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if !isLastPage {
                    Button("Skip") { onFinish(false) }
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

            Button(isLastPage ? "Write your first log" : "Next") {
                if isLastPage { onFinish(true) } else { withAnimation(.snappy(duration: 0.3)) { page += 1 } }
            }
            .buttonStyle(ForesightPrimaryButtonStyle())
            .frame(maxWidth: 420)
            .padding(.horizontal, 24)

            // The slot keeps its height on every page so the pages don't jump at the end.
            ZStack {
                if isLastPage {
                    Button("Look around first") { onFinish(false) }
                        .buttonStyle(ForesightQuietButtonStyle(tone: .foresightMuted))
                }
            }
            .frame(minHeight: 44)
            .padding(.top, 4)
            .padding(.bottom, 12)
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
                OnboardingPreviewCard(preview: page.preview)
                    .padding(.top, 20)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// A small, made-up example of each step, so the page shows what the step looks like.
private enum OnboardingPreview { case loop, log, checkIn, pattern }

private struct OnboardingPreviewCard: View {
    let preview: OnboardingPreview

    var body: some View {
        ForesightCard {
            switch preview {
            case .loop: loop
            case .log: log
            case .checkIn: checkIn
            case .pattern: pattern
            }
        }
        // Decorative: the page text already says everything the example shows.
        .accessibilityHidden(true)
    }

    private var loop: some View {
        VStack(alignment: .leading, spacing: 14) {
            loopRow("square.and.pencil", "Log what you did")
            loopRow("checkmark.circle", "Check in on how it felt")
            loopRow("chart.xyaxis.line", "See what tends to follow")
        }
    }

    private func loopRow(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.foresightSage)
                .frame(width: 34, height: 34)
                .background(Color.foresightSoftSage, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.foresightInk)
        }
    }

    private var log: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today, 6:40 PM")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.foresightSage)
            Text("Went for an evening run by the river.")
                .font(ForesightType.journalBody)
                .foregroundStyle(Color.foresightInk)
            chip("Exercise")
        }
    }

    private var checkIn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How do you feel now?")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.foresightInk)
            HStack(spacing: 6) {
                ForEach(OutcomeValue.allCases) { value in
                    let selected = value == .aLittleBetter
                    Text(value.title)
                        .font(.caption.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(selected ? Color.white : Color.foresightInk)
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(selected ? Color.foresightAction : Color.foresightRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            Label("Check in again in 2 hours", systemImage: "bell")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.foresightSage)
        }
    }

    private var pattern: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Often followed by feeling better")
                .font(ForesightType.insight)
                .foregroundStyle(Color.foresightInk)
            patternRow("Exercise", count: 4, of: 5)
            patternRow("Time outside", count: 3, of: 4)
        }
    }

    private func patternRow(_ name: String, count: Int, of total: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(Color.foresightInk)
                Spacer()
                Text("Better \(count) of \(total) times").font(.caption).foregroundStyle(Color.foresightMuted)
            }
            GeometryReader { proxy in
                Capsule().fill(Color.foresightLine)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.foresightSageMid).frame(width: proxy.size.width * CGFloat(count) / CGFloat(total))
                    }
            }
            .frame(height: 6)
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.foresightSage)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.foresightSoftSage, in: Capsule())
    }
}
