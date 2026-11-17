import SwiftUI

/// Asks for a snippet's blanks (`{{name}}`) before it's typed, and shows the
/// command it will type as the values change. One field per blank, the first
/// focused; Return moves to the next and inserts from the last. Seeing the
/// whole command here is its review, so a multiline snippet filled in here
/// isn't reviewed a second time.
struct SnippetFillIn: View {
    let snippet: CommandSnippet
    /// Where typing goes (iOS shows it as on the paste review); nil on the Mac,
    /// where the window already says.
    var destination: String? = nil
    let cancel: () -> Void
    let insert: (CommandSnippet) -> Void

    @State private var values: [String: String]
    @FocusState private var focused: String?

    init(snippet: CommandSnippet, destination: String? = nil, cancel: @escaping () -> Void,
         insert: @escaping (CommandSnippet) -> Void) {
        self.snippet = snippet
        self.destination = destination
        self.cancel = cancel
        self.insert = insert
        _values = State(initialValue: SnippetRecentValues.values(for: snippet))
    }

    private var names: [String] { snippet.placeholders }
    private var filled: CommandSnippet { snippet.filled(names.reduce(into: [:]) { $0[$1] = values[$1, default: ""] }) }
    private var invalid: Bool { names.contains { !SnippetPlaceholders.validValue(values[$0, default: ""]) } }
    private var title: String { String(localized: "Insert “\(snippet.name)”", bundle: .main) }
    private var actionTitle: String {
        snippet.runsImmediately && !snippet.isMultiline ? String(localized: "Run", bundle: .main)
            : String(localized: "Insert", bundle: .main)
    }

    var body: some View {
        #if os(macOS)
        SheetScaffold(title, width: .form, onEscape: cancel) {
            VStack(alignment: .leading, spacing: WitermMetrics.Space.m) {
                Form {
                    ForEach(names, id: \.self) { name in field(name) }
                }
                .formStyle(.columns)
                preview
                if invalid { problem }
            }
        } trailing: {
            Button(String(localized: "Cancel", bundle: .main), action: cancel)
                .keyboardShortcut(.cancelAction)
            Button(actionTitle, action: commit)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(invalid)
                .accessibilityIdentifier("insertFilledSnippet")
        }
        .onAppear { focused = names.first }
        #else
        NavigationStack {
            Form {
                Section {
                    ForEach(names, id: \.self) { name in field(name) }
                } footer: {
                    if invalid { problem }
                }
                Section {
                    preview
                } header: {
                    Text(String(localized: "Command", bundle: .main))
                } footer: {
                    if let destination { Text(String(localized: "Types into \(destination).", bundle: .main)) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .main), action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle, action: commit)
                        .disabled(invalid)
                        .accessibilityIdentifier("insertFilledSnippet")
                }
            }
        }
        .witermTint()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { focused = names.first }
        #endif
    }

    private func field(_ name: String) -> some View {
        TextField(name, text: Binding(get: { values[name, default: ""] }, set: { values[name] = $0 }),
                  prompt: Text(name))
            .font(WitermType.code)
            .autocorrectionDisabled()
            #if os(iOS)
            .sshLiteralInput()
            #endif
            .focused($focused, equals: name)
            .submitLabel(name == names.last ? .done : .next)
            .onSubmit {
                if let index = names.firstIndex(of: name), index + 1 < names.count { focused = names[index + 1] }
                else if !invalid { commit() }
            }
            .accessibilityIdentifier("snippetBlank-\(name)")
    }

    private var preview: some View {
        Text(verbatim: filled.text)
            .font(WitermType.code)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(macOS)
            .padding(WitermMetrics.Space.s)
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: WitermMetrics.Radius.s))
            .witermOutline(cornerRadius: WitermMetrics.Radius.s, hairline: true)
            #endif
            .accessibilityLabel(String(localized: "Command", bundle: .main))
            .accessibilityValue(filled.text)
            .accessibilityIdentifier("filledSnippetPreview")
    }

    private var problem: some View {
        Label(String(localized: "Values can’t contain line breaks or control characters.", bundle: .main),
              systemImage: "exclamationmark.circle")
            .font(WitermType.rowDetail)
            .foregroundStyle(WitermTheme.warning)
    }

    private func commit() {
        guard !invalid else { return }
        SnippetRecentValues.remember(values.filter { names.contains($0.key) }, for: snippet)
        insert(filled)
    }
}
