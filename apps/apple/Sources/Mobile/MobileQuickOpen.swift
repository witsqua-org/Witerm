#if os(iOS)
import SwiftUI

/// Open Quickly on iPhone and iPad (Round 28): ⇧⌘O from a hardware keyboard
/// (it's listed while ⌘ is held). The same field, ranking and recent choices
/// as the Mac: every paired terminal and SSH host by name, the commands that
/// work now, and an unsaved `user@host` to add. ↑ and ↓ move, Return opens.
struct MobileQuickOpenSheet: View {
    let items: [QuickOpenItem]
    var suggestions: (String) -> [QuickOpenItem] = { _ in [] }
    /// Called with the chosen item; the sheet closes first.
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
        NavigationStack {
            VStack(spacing: 0) {
                QuickOpenField(query: $query, focused: $fieldFocused,
                               prompt: String(localized: "Terminals, hosts and commands", bundle: .main),
                               move: { highlighted = QuickOpenCursor.moved($0, in: results, from: highlighted) },
                               submit: { if let item = QuickOpenCursor.current(in: results, highlighted: highlighted) { open(item) } })
                    .padding(.horizontal, WitermMetrics.Space.l)
                    .padding(.vertical, WitermMetrics.Space.m)
                Divider()
                QuickOpenResults(results: results, query: query, highlighted: $highlighted, open: open)
            }
            .navigationTitle(String(localized: "Open Quickly", bundle: .main))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .main), action: cancel)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .witermTint()
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
