import SwiftUI

// Open Quickly's field, results and row, shared by the Mac sheet, Mac Home's
// command bar and the iPhone and iPad sheet (Round 28).

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
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
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
                Group {
                #if os(macOS)
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
                #else
                // iOS: a tap opens; ↑ and ↓ on a hardware keyboard move a
                // highlight drawn on the row, since a List here only selects
                // while editing.
                let current = QuickOpenCursor.current(in: results, highlighted: highlighted)?.id
                List(results) { item in
                    Button { open(item) } label: { QuickOpenRow(item: item) }
                        .foregroundStyle(.primary)
                        .id(item.id)
                        .listRowBackground(item.id == current ? Color.accentColor.opacity(0.14) : nil)
                }
                .listStyle(.plain)
                #endif
                }
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
