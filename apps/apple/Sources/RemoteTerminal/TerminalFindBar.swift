#if os(iOS)
import SwiftTerm
import UIKit
import SwiftUI

/// Where a find bar looks. Renderers register their terminal view; the bar
/// only selects and scrolls within it and never sends input or resizes.
@MainActor final class TerminalFinder {
    weak var terminal: TerminalView?
}

/// The terminal's own background, so the area under the home indicator
/// continues the terminal instead of showing a band of another color.
enum TerminalBackdrop {
    static func color(dark: Bool, highContrast: Bool, palette: TerminalColorScheme) -> SwiftUI.Color {
        if highContrast { return dark ? .black : .white }
        guard let values = palette.values(dark: dark) else { return SwiftUI.Color(uiColor: .systemBackground) }
        return SwiftUI.Color(uiColor: UIColor(terminalRGB: values.background))
    }
}

/// Terminal text follows Dynamic Type up to xxxLarge and no further, so the
/// accessibility sizes enlarge the interface without shrinking the terminal
/// to a few columns; pinch and the size setting still zoom past it.
enum TerminalTextScale {
    static let largest = DynamicTypeSize.xxxLarge

    static func factor(_ size: DynamicTypeSize) -> CGFloat {
        let category = UIContentSizeCategory(min(size, largest))
        return UIFontMetrics(forTextStyle: .body)
            .scaledValue(for: 100, compatibleWith: UITraitCollection(preferredContentSizeCategory: category)) / 100
    }

    /// The UIKit category with the same cap, for the key row.
    static func capped(_ category: UIContentSizeCategory) -> UIContentSizeCategory {
        category > UIContentSizeCategory(largest) ? UIContentSizeCategory(largest) : category
    }
}

/// Text size and colors in one submenu of a terminal's actions: smaller and
/// larger text side by side, then the color scheme. Like pinching, it
/// changes only this device's view; Settings ▸ Text and Colors has the same
/// preference with previews.
struct TerminalTextAndColorsMenu: View {
    @AppStorage(TerminalFontSize.key) private var fontSize = TerminalFontSize.standard
    @AppStorage(TerminalColorScheme.key) private var palette = TerminalColorScheme.system

    var body: some View {
        Menu {
            ControlGroup {
                Button(String(localized: "Decrease Text Size", bundle: .main), systemImage: "textformat.size.smaller") {
                    fontSize = TerminalFontSize.clamped(fontSize - 1)
                }
                .disabled(fontSize <= TerminalFontSize.range.lowerBound)
                .accessibilityIdentifier("terminalSmallerText")
                Button(String(localized: "Increase Text Size", bundle: .main), systemImage: "textformat.size.larger") {
                    fontSize = TerminalFontSize.clamped(fontSize + 1)
                }
                .disabled(fontSize >= TerminalFontSize.range.upperBound)
                .accessibilityIdentifier("terminalLargerText")
            }
            .controlGroupStyle(.compactMenu)
            Picker(String(localized: "Color Scheme", bundle: .main), selection: $palette) {
                ForEach(TerminalColorScheme.allCases) { scheme in
                    Text(scheme.title).tag(scheme)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(String(localized: "Text and Colors", bundle: .main), systemImage: "textformat.size")
        }
        .accessibilityIdentifier("terminalTextAndColors")
    }
}

/// A chevron beside a terminal's title that lists the other terminals one tap
/// away, so switching needs no trip back to the list.
struct TerminalSwitcher: View {
    let names: [String]
    let choose: (Int) -> Void

    var body: some View {
        Menu {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                Button(name, systemImage: "terminal") { choose(index) }
            }
        } label: {
            Image(systemName: "chevron.down.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(WitermTheme.secondary)
                .touchTarget(square: true)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(String(localized: "Switch Terminal", bundle: .main))
        .accessibilityIdentifier("terminalSwitcher")
    }
}

/// On iPhone in landscape the keyboard leaves a terminal a handful of
/// rows, and the navigation bar takes 78 pt of them. While the terminal has
/// the keyboard, the bar steps aside; the key row then ends with Hide
/// Keyboard (which brings the bar back) and the bar's actions. The bar stays
/// in portrait, on iPad and other regular widths, and while VoiceOver runs,
/// so the title and state stay where VoiceOver finds them.
struct TerminalTypingBar: ViewModifier {
    /// The input view whose focus this follows.
    let terminal: () -> UIView?
    /// Changes when another terminal view is shown.
    let identity: AnyHashable?
    /// A terminal that can type is shown in the compact layout.
    let enabled: Bool
    @Binding var barHidden: Bool
    @Environment(\.horizontalSizeClass) private var horizontal
    @Environment(\.verticalSizeClass) private var vertical
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    /// Whether the terminal has (or is about to have) the keyboard focus.
    /// Plain storage: it's read right after it's written, in the same event.
    @State private var focus = Focus()

    private final class Focus {
        var focused = false
    }

    static func hidesBar(enabled: Bool, horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?,
                         voiceOver: Bool, focused: Bool) -> Bool {
        enabled && horizontal == .compact && vertical == .compact && !voiceOver && focused
    }

    func body(content: Content) -> some View {
        content
            .toolbar(barHidden ? .hidden : .automatic, for: .navigationBar)
            // The bar leaves as the terminal is about to take the keyboard,
            // ahead of the keyboard's own inset, and returns once the keyboard
            // has gone, next to the inset's removal rather than a keyboard
            // animation apart. When no keyboard notification comes (focus
            // moving while the keyboard stays), it follows a moment later.
            .onReceive(NotificationCenter.default.publisher(for: .witermTerminalFocusWillChange)) { note in
                focusChanged(note)
                update(hideOnly: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .witermTerminalFocusChanged)) { note in
                focusChanged(note)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { update() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in update() }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { _ in update() }
            .onChange(of: identity, initial: true) {
                focus.focused = terminal()?.isFirstResponder ?? false
                update()
            }
            .onChange(of: enabled) { update() }
            .onChange(of: horizontal) { update() }
            .onChange(of: vertical) { update() }
            .onChange(of: voiceOver) { update() }
    }

    private func focusChanged(_ note: Notification) {
        guard let view = terminal(), (note.object as AnyObject?) === view else { return }
        focus.focused = note.userInfo?["focused"] as? Bool ?? false
    }

    /// Without an animation of its own. `hideOnly` before the keyboard
    /// moves: the bar may leave then, but returns only once it has gone.
    private func update(hideOnly: Bool = false) {
        let hide = Self.hidesBar(enabled: enabled, horizontal: horizontal, vertical: vertical,
                                 voiceOver: voiceOver, focused: focus.focused)
        guard hide != barHidden, hide || !hideOnly else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { barHidden = hide }
    }
}

/// Search in the terminal's scrollback, shown under a terminal's header.
struct TerminalFindBar: View {
    let finder: TerminalFinder
    let close: () -> Void
    @State private var term = ""
    @State private var position = 0
    @State private var total = 0
    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At accessibility sizes the field keeps the whole width and the
        // controls move to a second row.
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: WitermMetrics.Space.xs) {
                    field
                    HStack(spacing: WitermMetrics.Space.s) { controls }
                }
            } else {
                HStack(spacing: WitermMetrics.Space.s) {
                    field
                    controls
                }
            }
        }
        .padding(.horizontal, WitermMetrics.Space.m)
        .padding(.vertical, WitermMetrics.Space.xs)
        .background(WitermTheme.surface)
        .onAppear { focused = true }
        .onDisappear { finder.terminal?.clearSearch() }
        // ⌘G and ⇧⌘G with a hardware keyboard, from the Terminal menu.
        .onReceive(NotificationCenter.default.publisher(for: .witermFindStep)) { note in
            find(next: (note.object as? Int ?? 1) > 0, announce: true)
        }
    }

    private var field: some View {
        HStack(spacing: WitermMetrics.Space.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(WitermTheme.secondary).accessibilityHidden(true)
            TextField(String(localized: "Find in Terminal", bundle: .main), text: $term)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .onSubmit { find(next: true, announce: true) }
                .onChange(of: term) { find(next: true, restart: true) }
                .accessibilityIdentifier("terminalFindField")
            if !term.isEmpty {
                Text(total == 0 ? String(localized: "No Matches", bundle: .main)
                     : String(localized: "\(position) of \(total)", bundle: .main))
                    .font(WitermType.meta.monospacedDigit())
                    .foregroundStyle(WitermTheme.secondary)
                    .accessibilityIdentifier("terminalFindCount")
            }
        }
    }

    @ViewBuilder private var controls: some View {
        Button(String(localized: "Previous Match", bundle: .main), systemImage: "chevron.up") { find(next: false, announce: true) }
            .labelStyle(.iconOnly)
            .touchTarget(square: true)
            .disabled(total == 0)
        Button(String(localized: "Next Match", bundle: .main), systemImage: "chevron.down") { find(next: true, announce: true) }
            .labelStyle(.iconOnly)
            .touchTarget(square: true)
            .disabled(total == 0)
        if typeSize.isAccessibilitySize { Spacer(minLength: 0) }
        Button(String(localized: "Done", bundle: .main)) {
            finder.terminal?.clearSearch()
            close()
        }
        .fontWeight(.semibold)
        .touchTarget()
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("terminalFindDone")
    }

    /// Typing updates the count silently; moving between matches announces it.
    private func find(next: Bool, restart: Bool = false, announce: Bool = false) {
        guard let terminal = finder.terminal else { return }
        guard !term.isEmpty else { terminal.clearSearch(); position = 0; total = 0; return }
        if restart { terminal.clearSearch() }
        _ = next ? terminal.findNext(term) : terminal.findPrevious(term)
        let summary = terminal.searchMatchSummary(term)
        position = summary.index
        total = summary.total
        guard announce else { return }
        AccessibilityNotification.Announcement(total == 0 ? String(localized: "No Matches", bundle: .main)
            : String(localized: "\(position) of \(total)", bundle: .main)).post()
    }
}
#endif
