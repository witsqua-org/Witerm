import SwiftUI

/// Saved commands, embeddable in any grouped Form.
struct SnippetSections: View {
    @AppStorage(CommandSnippets.key) private var stored = Data()
    @State private var editing: CommandSnippet?

    private var snippets: [CommandSnippet] { CommandSnippets.decode(stored) }

    var body: some View {
        Section {
            if snippets.isEmpty {
                Text(String(localized: "No snippets yet. Save a command you type often, then insert it from a terminal.", bundle: .main))
                    .foregroundStyle(.secondary)
            }
            ForEach(snippets) { snippet in
                Button { editing = snippet } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: snippet.name).foregroundStyle(WitermTheme.ink)
                        Text(verbatim: snippet.text)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    #if os(macOS)
                    .witermHover(cornerRadius: 6)
                    #endif
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .help(String(localized: "Edit snippet", bundle: .main))
                #endif
                .accessibilityHint(String(localized: "Edit snippet", bundle: .main))
                .contextMenu {
                    Button(String(localized: "Delete", bundle: .main), systemImage: "trash", role: .destructive) { remove(snippet.id) }
                }
            }
            .onDelete { offsets in save(snippets.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)) }
            .onMove { from, to in
                var reordered = snippets
                reordered.move(fromOffsets: from, toOffset: to)
                save(reordered)
            }
            Button(String(localized: "Add Snippet", bundle: .main), systemImage: "plus") {
                editing = CommandSnippet(name: "", text: "")
            }
            .disabled(snippets.count >= CommandSnippets.limit)
            .accessibilityIdentifier("addSnippet")
        } header: {
            Text(String(localized: "Snippets", bundle: .main))
        } footer: {
            Text(String(localized: "Snippets stay on this device and are never sent to a continuation server. Avoid saving passwords or other secrets.", bundle: .main))
        }
        .sheet(item: $editing) { snippet in
            SnippetEditor(snippet: snippet, isNew: !snippets.contains { $0.id == snippet.id },
                          save: { saved in
                              var next = snippets
                              if let index = next.firstIndex(where: { $0.id == saved.id }) { next[index] = saved } else { next.append(saved) }
                              save(next)
                          },
                          delete: { remove(snippet.id) })
        }
    }

    private func remove(_ id: UUID) { save(snippets.filter { $0.id != id }) }
    private func save(_ snippets: [CommandSnippet]) { stored = CommandSnippets.encode(snippets) }
}

private struct SnippetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var snippet: CommandSnippet
    @State private var issue: String?
    let isNew: Bool
    let save: (CommandSnippet) -> Void
    let delete: () -> Void

    init(snippet: CommandSnippet, isNew: Bool, save: @escaping (CommandSnippet) -> Void, delete: @escaping () -> Void) {
        _snippet = State(initialValue: snippet)
        self.isNew = isNew
        self.save = save
        self.delete = delete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Name", bundle: .main), text: $snippet.name)
                        .accessibilityIdentifier("snippetName")
                    TextEditor(text: $snippet.text)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
                        .autocorrectionDisabled()
                        .sshLiteralInput()
                        .accessibilityLabel(String(localized: "Command", bundle: .main))
                        .accessibilityIdentifier("snippetText")
                    Toggle(String(localized: "Press Return After Inserting", bundle: .main), isOn: $snippet.runsImmediately)
                        .disabled(snippet.isMultiline)
                        .tint(WitermTheme.positive)
                } footer: {
                    Text(snippet.isMultiline
                         ? String(localized: "Multiline snippets are inserted like a paste and never press Return. On iPhone and iPad they're shown for review first.", bundle: .main)
                         : String(localized: "Without Return, the command waits on the line for you to check it.", bundle: .main))
                }
                if let issue {
                    Section { Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(WitermTheme.warning) }
                }
                if !isNew {
                    Section {
                        Button(String(localized: "Delete Snippet", bundle: .main), role: .destructive) { delete(); dismiss() }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? String(localized: "New Snippet", bundle: .main) : String(localized: "Edit Snippet", bundle: .main))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .main)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save", bundle: .main)) {
                        snippet.name = snippet.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let problem = CommandSnippets.validate(name: snippet.name, text: snippet.text) { issue = problem; return }
                        if snippet.isMultiline { snippet.runsImmediately = false }
                        save(snippet)
                        dismiss()
                    }
                    .accessibilityIdentifier("saveSnippet")
                }
            }
        }
        .witermTint()
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 360)
        #endif
    }
}

#if os(iOS)
/// The snippet list as its own page, with reordering.
struct SnippetSettingsView: View {
    var body: some View {
        Form { SnippetSections() }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Snippets", bundle: .main))
            .toolbar { EditButton() }
    }
}

/// Chooses and orders the keys above the iOS keyboard.
struct MobileKeyRowSettings: View {
    @AppStorage(MobileKey.key) private var raw = ""

    private var shown: [MobileKey] { MobileKey.decode(raw) }
    private var hidden: [MobileKey] { MobileKey.allCases.filter { !shown.contains($0) } }

    var body: some View {
        List {
            Section {
                ForEach(shown) { key in
                    LabeledContent(key.label) { Text(verbatim: key.face).font(.callout.monospaced()).foregroundStyle(.secondary) }
                        .deleteDisabled(shown.count == 1)
                }
                .onMove { from, to in
                    var keys = shown
                    keys.move(fromOffsets: from, toOffset: to)
                    raw = MobileKey.encode(keys)
                }
                .onDelete { offsets in
                    raw = MobileKey.encode(shown.enumerated().filter { !offsets.contains($0.offset) }.map(\.element))
                }
            } header: {
                Text(String(localized: "Shown", bundle: .main))
            } footer: {
                Text(String(localized: "Drag to reorder. The row scrolls sideways when it's wider than the screen.", bundle: .main))
            }
            if !hidden.isEmpty {
                Section(String(localized: "More Keys", bundle: .main)) {
                    ForEach(hidden) { key in
                        Button { raw = MobileKey.encode(shown + [key]) } label: {
                            Label {
                                LabeledContent(key.label) { Text(verbatim: key.face).font(.callout.monospaced()).foregroundStyle(.secondary) }
                            } icon: {
                                Image(systemName: "plus.circle.fill").foregroundStyle(WitermTheme.positive)
                            }
                        }
                        .accessibilityLabel(String(localized: "Add \(key.label)", bundle: .main))
                    }
                }
            }
            Section {
                Button(String(localized: "Restore Default Keys", bundle: .main)) { raw = "" }
                    .disabled(raw.isEmpty)
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle(String(localized: "Keyboard Row", bundle: .main))
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
