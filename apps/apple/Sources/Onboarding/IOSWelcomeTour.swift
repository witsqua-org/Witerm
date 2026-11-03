#if os(iOS)
import SwiftUI

/// The first-launch Welcome Tour: three short pages (SSH, continuing from a
/// Mac, keys and gestures), skippable at any point, and reopened from
/// Settings → Help. It explains; the Terminals screen behind it acts.
struct IOSWelcomeTour: View {
    /// Shared with the Mac tour: the version of the tour last finished or skipped.
    static let completedVersionKey = "witerm.onboarding.completedVersion"
    static let version = 1

    /// Whether this launch should show the tour on its own.
    static var needsShowing: Bool { UserDefaults.standard.integer(forKey: completedVersionKey) < version }

    /// Called on Skip and on Get Started, after the tour is marked done.
    let finish: () -> Void
    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Page {
        let symbol: String
        let title: String
        let line: String
        var showsKeys = false
    }

    private var pages: [Page] {
        [
            Page(symbol: "terminal",
                 title: String(localized: "Connect over SSH", bundle: .main),
                 line: String(localized: "Tap +, enter user@host, and connect directly. No server needed.", bundle: .main)),
            Page(symbol: "laptopcomputer.and.iphone",
                 title: String(localized: "Add Device", bundle: .main),
                 line: String(localized: "On the other device, choose Open On ▸ New Device, then scan its QR code.", bundle: .main)),
            Page(symbol: "hand.tap",
                 title: String(localized: "Keys and Gestures", bundle: .main),
                 line: String(localized: "Tap to type, touch and hold to select, pinch to zoom.", bundle: .main),
                 showsKeys: true),
        ]
    }

    private var isLast: Bool { page == pages.count - 1 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                        pageView(item)
                            .tag(index)
                            .accessibilityIdentifier("welcomeTourPage-\(index)")
                    }
                }
                // Our own dots, below the page rather than over it, in ink
                // so the current page reads at 3:1 or more.
                .tabViewStyle(.page(indexDisplayMode: .never))
                PageDots(count: pages.count, page: $page, reduceMotion: reduceMotion)
                PrimaryButton(isLast ? String(localized: "Get Started", bundle: .main) : String(localized: "Next", bundle: .main),
                              fullWidth: true) {
                    if isLast { done() } else { advance() }
                }
                .accessibilityIdentifier(isLast ? "welcomeTourStart" : "welcomeTourNext")
                .padding(.horizontal, WitermMetrics.pagePadding)
                .padding(.bottom, WitermMetrics.Space.l)
                .frame(maxWidth: WitermMetrics.readableWidth)
            }
            .background(WitermTheme.canvas)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Skip", bundle: .main), action: done)
                        .accessibilityIdentifier("welcomeTourSkip")
                }
            }
        }
        .witermTint()
        .accessibilityIdentifier("welcomeTour")
    }

    private func advance() {
        if reduceMotion { page += 1 } else { withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) { page += 1 } }
    }

    private func done() {
        UserDefaults.standard.set(Self.version, forKey: Self.completedVersionKey)
        finish()
    }

    /// One symbol (or the key row), a short title, and one line. Scrolls at
    /// the largest text sizes instead of truncating.
    private func pageView(_ item: Page) -> some View {
        ScrollView {
            VStack(spacing: WitermMetrics.Space.xl) {
                Image(systemName: item.symbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(WitermTheme.ink)
                    .frame(width: 112, height: 112)
                    .background(WitermTheme.surface, in: .rect(cornerRadius: WitermMetrics.Radius.xl, style: .continuous))
                    .witermOutline(cornerRadius: WitermMetrics.Radius.xl)
                    .accessibilityHidden(true)
                VStack(spacing: WitermMetrics.Space.s) {
                    Text(item.title)
                        .font(WitermType.heroTitle)
                        .foregroundStyle(WitermTheme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(item.line)
                        .font(WitermType.rowTitle)
                        .foregroundStyle(WitermTheme.secondary)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                if item.showsKeys { WelcomeKeyRow() }
            }
            .padding(.horizontal, WitermMetrics.pagePadding)
            .padding(.vertical, WitermMetrics.Space.xxl)
            .frame(maxWidth: WitermMetrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Presents the tour full screen on first launch and whenever `touring` is
/// set (Settings → Help). Whether to show it is decided once per launch: the
/// stored version may come from launch arguments, which a write can't override.
struct IOSWelcomeTourPresentation: ViewModifier {
    @Binding var touring: Bool
    /// Runs after Skip or Get Started.
    let finished: () -> Void
    @State private var checked = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !checked else { return }
                checked = true
                if IOSWelcomeTour.needsShowing { touring = true }
            }
            .fullScreenCover(isPresented: $touring) {
                IOSWelcomeTour {
                    touring = false
                    finished()
                }
            }
    }
}

/// The tour's page indicator: ink for the current page, and one adjustable
/// element for VoiceOver ("Page 2 of 3"); a dot also goes to its page.
private struct PageDots: View {
    let count: Int
    @Binding var page: Int
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: WitermMetrics.Space.s) {
            ForEach(0..<count, id: \.self) { index in
                // The current page is longer as well as darker, so it never
                // depends on color alone.
                Capsule()
                    .fill(index == page ? WitermTheme.ink : WitermTheme.secondary)
                    .frame(width: index == page ? 20 : 8, height: 8)
                    .frame(width: 28, height: 44)
                    .contentShape(Rectangle())
                    .onTapGesture { go(index) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Page", bundle: .main))
        .accessibilityValue(String(localized: "\(page + 1) of \(count)", bundle: .main))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: go(min(count - 1, page + 1))
            case .decrement: go(max(0, page - 1))
            @unknown default: break
            }
        }
        .accessibilityIdentifier("welcomeTourPageDots")
    }

    private func go(_ index: Int) {
        if reduceMotion { page = index } else { withAnimation(WitermMotion.transition(reduceMotion: false)) { page = index } }
    }
}

/// A miniature of the keys above the terminal keyboard, drawn like them.
private struct WelcomeKeyRow: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: WitermMetrics.Space.s) { keys(faces[...]) }
            VStack(spacing: WitermMetrics.Space.s) {
                HStack(spacing: WitermMetrics.Space.s) { keys(faces.prefix(3)) }
                HStack(spacing: WitermMetrics.Space.s) { keys(faces.suffix(4)) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Esc, Ctrl, Tab and arrow keys sit above the keyboard.", bundle: .main))
    }

    private let faces = ["Esc", "Ctrl", "Tab", "←", "↑", "↓", "→"]

    private func keys(_ slice: ArraySlice<String>) -> some View {
        ForEach(Array(slice), id: \.self) { face in
            Text(verbatim: face)
                .font(WitermType.rowTitle)
                .foregroundStyle(WitermTheme.ink)
                .padding(.horizontal, WitermMetrics.Space.s)
                .frame(minWidth: 40, minHeight: 36)
                .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: WitermMetrics.Radius.s))
                .witermOutline(cornerRadius: WitermMetrics.Radius.s)
        }
    }
}
#endif
