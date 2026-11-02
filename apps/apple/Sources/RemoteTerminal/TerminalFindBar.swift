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

/// Smaller and larger terminal text, side by side at the top of a terminal's
/// actions menu. Like pinching, it changes only this device's view.
struct TerminalTextSizeControls: View {
    @AppStorage(TerminalFontSize.key) private var fontSize = TerminalFontSize.standard

    var body: some View {
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

/// Shows or hides one terminal's keyboard, and says which it will do: the
/// symbol and label follow the terminal's real keyboard focus.
struct TerminalKeyboardButton: View {
    /// The input view whose focus this button follows.
    let terminal: () -> UIView?
    let action: () -> Void
    @State private var shown = false

    var body: some View {
        Button(shown ? String(localized: "Hide Keyboard", bundle: .main) : String(localized: "Show Keyboard", bundle: .main),
               systemImage: shown ? "keyboard.chevron.compact.down" : "keyboard", action: action)
            .onAppear { shown = terminal()?.isFirstResponder ?? false }
            .onReceive(NotificationCenter.default.publisher(for: .witermTerminalFocusChanged)) { note in
                guard let view = terminal(), (note.object as AnyObject?) === view else { return }
                shown = note.userInfo?["focused"] as? Bool ?? false
            }
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
