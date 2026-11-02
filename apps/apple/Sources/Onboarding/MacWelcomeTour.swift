#if os(macOS)
import SwiftUI

/// The first-launch tour's shared conventions (iOS uses the same key).
enum WelcomeTour {
    /// The tour version a person finished or skipped; shown while it's lower.
    static let key = "witerm.onboarding.completedVersion"
    static let version = 1
}

extension Notification.Name {
    /// Help → Welcome Tour.
    static let witermShowWelcomeTour = Notification.Name("witerm.showWelcomeTour")
}

/// Four short pages: terminals outlive the app, the background service that
/// makes that so (switched on right here), continuing on another device, and
/// `witerm new`. Esc skips, Return moves on, ← and → page.
struct MacWelcomeTour: View {
    let service: LocalAgentService
    /// True when the person reached Get Started, false when they skipped.
    let onClose: (_ finished: Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var closed = false

    private struct Page {
        let symbol: String
        let title: String
        let line: AttributedString
    }

    private var pages: [Page] {
        [
            Page(symbol: "terminal", title: String(localized: "Terminals keep running", bundle: .main),
                 line: AttributedString(String(localized: "Quit Witerm anytime. Your shells and programs keep going.", bundle: .main))),
            Page(symbol: "gearshape.2", title: String(localized: "Run in the background", bundle: .main),
                 line: AttributedString(String(localized: "Witerm keeps your terminals running in the background.", bundle: .main))),
            Page(symbol: "laptopcomputer.and.iphone", title: String(localized: "Open on another device", bundle: .main),
                 line: AttributedString(String(localized: "Choose Open On ▸ and a device, or press ⌥⌘P.", bundle: .main))),
            Page(symbol: "apple.terminal", title: String(localized: "Start from any folder", bundle: .main),
                 line: (try? AttributedString(markdown: String(localized: "Type `witerm new` in any shell to start a terminal in that folder.", bundle: .main)))
                    ?? AttributedString(String(localized: "Type `witerm new` in any shell to start a terminal in that folder.", bundle: .main))),
        ]
    }

    private var last: Bool { page == pages.count - 1 }

    var body: some View {
        // A fixed height, so changing pages never resizes the sheet.
        SheetScaffold(nil, width: .compact, height: 320) {
            let current = pages[page]
            VStack(spacing: WitermMetrics.Space.m) {
                Image(systemName: current.symbol)
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(WitermTheme.ink)
                    .frame(height: 56)
                    .accessibilityHidden(true)
                Text(current.title)
                    .font(WitermType.heroTitle)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("welcomeTourTitle")
                Text(current.line)
                    .font(WitermType.rowTitle)
                    .foregroundStyle(WitermTheme.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if page == 1 { serviceControl.padding(.top, WitermMetrics.Space.xs) }
            }
            .padding(.horizontal, WitermMetrics.Space.l)
            .frame(maxWidth: .infinity, minHeight: 220)
            .id(page)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 5)))
        } leading: {
            Button(String(localized: "Skip", bundle: .main)) { close(finished: false) }
                .keyboardShortcut(.cancelAction)
                .focusEffectDisabled(false)
                .accessibilityIdentifier("welcomeTourSkip")
        } trailing: {
            PageDots(count: pages.count, current: page) { show($0) }
                .padding(.trailing, WitermMetrics.Space.s)
            Button(last ? String(localized: "Get Started", bundle: .main) : String(localized: "Next", bundle: .main)) {
                if last { close(finished: true) } else { move(1) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .focusEffectDisabled(false)
            .accessibilityIdentifier("welcomeTourPrimary")
        }
        // The sheet itself takes the arrow keys; its own focus ring is hidden,
        // its buttons keep theirs for Full Keyboard Access.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.rightArrow) { move(1) ? .handled : .ignored }
        .onKeyPress(.leftArrow) { move(-1) ? .handled : .ignored }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Welcome Tour", bundle: .main))
        .accessibilityIdentifier("welcomeTour")
        .onChange(of: page) { _, page in
            AccessibilityNotification.Announcement(pages[page].title).post()
        }
        // Closing the sheet any other way counts as skipping.
        .onDisappear { if !closed { closed = true; onClose(false) } }
    }

    /// Turns the service on in place instead of describing where to do it.
    @ViewBuilder private var serviceControl: some View {
        switch service.state {
        case .ready:
            Label(String(localized: "On", bundle: .main), systemImage: "checkmark.circle.fill")
                .foregroundStyle(WitermTheme.positive)
                .accessibilityIdentifier("welcomeTourServiceOn")
        case .starting:
            ProgressView().controlSize(.small)
        case .requiresApproval:
            Button(String(localized: "Open Login Items Settings", bundle: .main), action: service.openSettings)
        case .notRegistered, .unavailable:
            Button(String(localized: "Turn On", bundle: .main)) { Task { await service.start() } }
                .help(String(localized: "Lets Witerm keep terminals running on this Mac, even after you quit it", bundle: .main))
                .accessibilityIdentifier("welcomeTourService")
        }
    }

    @discardableResult private func move(_ step: Int) -> Bool {
        let next = page + step
        guard pages.indices.contains(next) else { return false }
        show(next)
        return true
    }

    /// Only the page cross-fades; the buttons and dots change in place.
    private func show(_ next: Int) {
        withAnimation(WitermMotion.transition(reduceMotion: reduceMotion)) { page = next }
    }

    private func close(finished: Bool) {
        guard !closed else { return }
        closed = true
        onClose(finished)
    }
}

/// Where you are in the tour, as dots and as "Page 2 of 4" for VoiceOver.
/// Each dot also goes to its page, with hover feedback like other custom
/// controls; Next and the arrow keys remain the main way through.
private struct PageDots: View {
    let count: Int
    let current: Int
    let show: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                Button { show(index) } label: {
                    // The current page filled; the others as rings in the
                    // secondary ink, which keeps 3:1 on both appearances.
                    Circle()
                        .fill(index == current ? WitermTheme.ink : .clear)
                        .overlay { if index != current { Circle().strokeBorder(WitermTheme.secondary, lineWidth: 1) } }
                        .frame(width: 7, height: 7)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                        .witermHover(cornerRadius: WitermMetrics.Radius.s)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Page \(index + 1) of \(count)", bundle: .main))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Page \(current + 1) of \(count)", bundle: .main))
    }
}
#endif
