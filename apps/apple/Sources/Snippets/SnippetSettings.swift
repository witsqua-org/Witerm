import SwiftUI

/// Saved commands, embeddable in any grouped Form.
struct SnippetSections: View {
    /// The iOS page has its own title, so its one section needs no header.
    var showsHeader = true
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
                    VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
                        Text(verbatim: snippet.name).foregroundStyle(WitermTheme.ink)
                        Text(verbatim: snippet.text)
                            .font(WitermType.codeInline)
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
            #if os(iOS)
            Button { editing = CommandSnippet(name: "", text: "") } label: {
                ContentActionLabel(String(localized: "Add Snippet", bundle: .main), systemImage: "plus")
            }
            .disabled(snippets.count >= CommandSnippets.limit)
            .accessibilityIdentifier("addSnippet")
            #else
            Button(String(localized: "Add Snippet", bundle: .main), systemImage: "plus") {
                editing = CommandSnippet(name: "", text: "")
            }
            .disabled(snippets.count >= CommandSnippets.limit)
            .accessibilityIdentifier("addSnippet")
            #endif
        } header: {
            if showsHeader { Text(String(localized: "Snippets", bundle: .main)) }
        } footer: {
            Text(String(localized: "Snippets stay on this device and are never sent to a relay server. Avoid saving passwords or other secrets.", bundle: .main))
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
                        .font(WitermType.code)
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
        #else
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
}

#if os(iOS)
/// The snippet list as its own page, with reordering.
struct SnippetSettingsView: View {
    @AppStorage(CommandSnippets.key) private var stored = Data()

    var body: some View {
        Form { SnippetSections(showsHeader: false) }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Snippets", bundle: .main))
            .navigationBarTitleDisplayMode(.inline)
            // Reordering needs something to reorder.
            .toolbar { if !CommandSnippets.decode(stored).isEmpty { EditButton() } }
    }
}

/// Chooses and orders the keys above the iOS keyboard: a checkmark shows a
/// key, Edit reorders the shown ones. Nothing here deletes anything.
struct MobileKeyRowSettings: View {
    @AppStorage(MobileKey.key) private var raw = ""
    @State private var editMode = EditMode.inactive

    private var shown: [MobileKey] { MobileKey.decode(raw) }
    private var hidden: [MobileKey] { MobileKey.allCases.filter { !shown.contains($0) } }

    var body: some View {
        List {
            Section {
                ForEach(shown) { key in
                    keyRow(key, shown: true)
                }
                .onMove { from, to in
                    var keys = shown
                    keys.move(fromOffsets: from, toOffset: to)
                    raw = MobileKey.encode(keys)
                }
                .deleteDisabled(true)
            } header: {
                Text(String(localized: "Shown", bundle: .main))
            }
            if !hidden.isEmpty, editMode == .inactive {
                Section(String(localized: "More Keys", bundle: .main)) {
                    ForEach(hidden) { key in keyRow(key, shown: false) }
                }
            }
            if editMode == .inactive {
                Section {
                    Button { raw = "" } label: {
                        ContentActionLabel(String(localized: "Restore Default Keys", bundle: .main), systemImage: "arrow.counterclockwise")
                    }
                    .disabled(raw.isEmpty)
                }
            }
        }
        .environment(\.editMode, $editMode)
        .toolbar { EditButton() }
        .navigationTitle(String(localized: "Keyboard Row", bundle: .main))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Tapping a key shows or hides it; the last shown key stays.
    private func keyRow(_ key: MobileKey, shown isShown: Bool) -> some View {
        Button {
            if isShown {
                guard shown.count > 1 else { return }
                raw = MobileKey.encode(shown.filter { $0 != key })
            } else {
                raw = MobileKey.encode(shown + [key])
            }
        } label: {
            HStack(spacing: WitermMetrics.Space.m) {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(WitermTheme.ink)
                    .opacity(isShown ? 1 : 0)
                    .accessibilityHidden(true)
                LabeledContent(key.label) {
                    Text(verbatim: key.face).font(WitermType.code).foregroundStyle(WitermTheme.secondary)
                }
                .foregroundStyle(WitermTheme.ink)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isShown && shown.count == 1)
        .accessibilityAddTraits(isShown ? .isSelected : [])
        .accessibilityHint(isShown ? String(localized: "Hides it from the key row.", bundle: .main)
                           : String(localized: "Adds it to the key row.", bundle: .main))
    }
}
#endif
