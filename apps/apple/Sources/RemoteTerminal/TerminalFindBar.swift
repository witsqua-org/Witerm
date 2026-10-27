#if os(iOS)
import SwiftTerm
import SwiftUI

/// Where a find bar looks. Renderers register their terminal view; the bar
/// only selects and scrolls within it and never sends input or resizes.
@MainActor final class TerminalFinder {
    weak var terminal: TerminalView?
}

/// Search in the terminal's scrollback, shown under a terminal's header.
struct TerminalFindBar: View {
    let finder: TerminalFinder
    let close: () -> Void
    @State private var term = ""
    @State private var position = 0
    @State private var total = 0
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
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
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("terminalFindCount")
            }
            Button(String(localized: "Previous Match", bundle: .main), systemImage: "chevron.up") { find(next: false, announce: true) }
                .labelStyle(.iconOnly)
                .touchTarget(square: true)
                .disabled(total == 0)
            Button(String(localized: "Next Match", bundle: .main), systemImage: "chevron.down") { find(next: true, announce: true) }
                .labelStyle(.iconOnly)
                .touchTarget(square: true)
                .disabled(total == 0)
            Button(String(localized: "Done", bundle: .main)) {
                finder.terminal?.clearSearch()
                close()
            }
            .touchTarget()
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("terminalFindDone")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(WitermTheme.surface)
        .onAppear { focused = true }
        .onDisappear { finder.terminal?.clearSearch() }
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
