#if os(macOS)
import SwiftUI

/// File ▸ Open Quickly… (⇧⌘O): one field that reaches every terminal, SSH
/// host, snippet and command by name, as Xcode's Open Quickly does. ↑ and ↓
/// move through the results while the field keeps the keyboard, Return opens
/// the highlighted one, and Esc closes it. Choices are remembered (as IDs
/// only, never terminal contents) so the next ones are a keystroke away.
///
/// It's a sheet in the shared `SheetScaffold` shape, without a title: the
/// field says what it's for, and a title would push the results down.
struct MacQuickOpenSheet: View {
    let items: [QuickOpenItem]
    /// Items made from what's typed, listed first: an SSH address that isn't
    /// saved yet offers to add it.
    var suggestions: (String) -> [QuickOpenItem] = { _ in [] }
    /// Called with the chosen item; the sheet closes first, so anything the
    /// item opens (another sheet, the keyboard in a terminal) isn't fighting
    /// this one.
    let choose: (QuickOpenItem) -> Void
    let cancel: () -> Void

    @State private var query = ""
    @State private var highlighted: String?
    @State private var recent = QuickOpenRanking.loadRecent()
    @FocusState private var fieldFocused: Bool

    private var results: [QuickOpenItem] {
        suggestions(query) + QuickOpenRanking.rank(items, query: query, recent: recent)
    }

    var body: some View {
        let shown = results
        let current = QuickOpenCursor.current(in: shown, highlighted: highlighted)
        SheetScaffold(nil, width: .form, scrolls: false, onEscape: cancel) {
            VStack(spacing: 0) {
                QuickOpenField(query: $query, focused: $fieldFocused,
                               move: { highlighted = QuickOpenCursor.moved($0, in: results, from: highlighted) },
                               submit: { if let current = QuickOpenCursor.current(in: results, highlighted: highlighted) { open(current) } })
                    .padding(.horizontal, WitermMetrics.sheetInset)
                    .padding(.vertical, WitermMetrics.Space.m)
                Divider()
                QuickOpenResults(results: shown, query: query, highlighted: $highlighted, open: open)
                    .frame(height: 320)
            }
        } trailing: {
            Button(String(localized: "Cancel", bundle: .main), action: cancel)
                .keyboardShortcut(.cancelAction)
            // The verb's own key: "Open" alone is an iOS header (已打开).
            Button(LocalTerminalHelp.open) { if let current { open(current) } }
                .keyboardShortcut(.defaultAction)
                .disabled(current == nil)
                .accessibilityIdentifier("quickOpenOpen")
        }
        .onAppear {
            fieldFocused = true
            highlighted = results.first?.id
        }
        .onChange(of: query) { highlighted = results.first?.id }
    }

    private func open(_ item: QuickOpenItem) {
        recent = QuickOpenRanking.remember(item.id, in: recent)
        QuickOpenRanking.saveRecent(recent)
        choose(item)
    }
}
#endif
