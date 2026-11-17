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

/// Which result is highlighted, shared by the sheet and Home's command bar:
/// the one ↑ and ↓ moved to, or the best one.
enum QuickOpenCursor {
    static func current(in results: [QuickOpenItem], highlighted: String?) -> QuickOpenItem? {
        results.first { $0.id == highlighted } ?? results.first
    }

    static func moved(_ step: Int, in results: [QuickOpenItem], from highlighted: String?) -> String? {
        guard !results.isEmpty else { return nil }
        let index = results.firstIndex { $0.id == current(in: results, highlighted: highlighted)?.id } ?? 0
        return results[min(max(index + step, 0), results.count - 1)].id
    }
}

/// The field: ↑ and ↓ move through the results while it keeps the keyboard,
/// Return opens the highlighted one.
struct QuickOpenField: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    var prompt = String(localized: "Terminals, hosts, snippets and commands", bundle: .main)
    let move: (Int) -> Void
    let submit: () -> Void

    var body: some View {
        HStack(spacing: WitermMetrics.Space.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(WitermTheme.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused(focused)
                .onSubmit(submit)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .accessibilityIdentifier("quickOpenField")
                .accessibilityLabel(String(localized: "Open Quickly", bundle: .main))
        }
    }
}

/// The ranked results; a click opens, as in Xcode, and arrows only move.
struct QuickOpenResults: View {
    let results: [QuickOpenItem]
    let query: String
    @Binding var highlighted: String?
    let open: (QuickOpenItem) -> Void

    var body: some View {
        if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ScrollViewReader { proxy in
                List(selection: Binding(get: { QuickOpenCursor.current(in: results, highlighted: highlighted)?.id },
                                        set: { highlighted = $0 })) {
                    ForEach(results) { item in
                        QuickOpenRow(item: item)
                            .tag(item.id)
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture { open(item) }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .onChange(of: highlighted) { _, id in if let id { proxy.scrollTo(id) } }
                .accessibilityIdentifier("quickOpenResults")
            }
        }
    }
}

struct QuickOpenRow: View {
    let item: QuickOpenItem

    var body: some View {
        HStack(spacing: WitermMetrics.Space.m) {
            Image(systemName: item.symbol)
                .foregroundStyle(item.tint ?? WitermTheme.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
                Text(item.title).lineLimit(1)
                if let detail = item.detail {
                    Text(verbatim: detail)
                        .font(item.kind == .command ? WitermType.rowDetail : WitermType.codeInline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: WitermMetrics.Space.s)
            if let shortcut = item.shortcut {
                Text(verbatim: shortcut)
                    .font(WitermType.rowDetail)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(kindName)
                .font(WitermType.meta)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, WitermMetrics.Space.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
        .accessibilityValue([kindName, item.detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("quickOpen-\(item.id)")
    }

    private var kindName: String {
        switch item.kind {
        case .terminal: String(localized: "Terminal", bundle: .main)
        case .host: String(localized: "SSH Host", bundle: .main)
        case .command: String(localized: "Command", bundle: .main)
        case .snippet: String(localized: "Snippet", bundle: .main)
        }
    }
}
#endif
