#if os(macOS)
import SwiftUI
import WitermCore

/// Orbit's page: conversations and delegated tasks on the left, the chosen
/// one on the right, with what Orbit said and did in its terminals.
struct OrbitView: View {
    @Bindable var orbit: OrbitService
    /// Terminals a new conversation can be about.
    let terminals: [LocalSessionInfo]
    /// Shows a terminal Orbit used.
    let showTerminal: (String) -> Void
    @Environment(\.openSettings) private var openSettings
    @State private var deleting: OrbitThreadSummary?
    @State private var clearing = false

    var body: some View {
        HSplitView {
            threadList
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            conversation
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { orbit.watch() }
        .onDisappear { orbit.unwatch() }
        .alert(String(localized: "Delete “\(deleting?.title ?? "")”?", bundle: .main),
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(String(localized: "Cancel", bundle: .main), role: .cancel) { deleting = nil }
            Button(String(localized: "Delete", bundle: .main), role: .destructive) {
                if let thread = deleting { Task { await orbit.delete(thread.id) } }
                deleting = nil
            }
        } message: {
            Text(String(localized: "Its messages are removed from this Mac. Terminals it used keep running.", bundle: .main))
        }
        .alert(String(localized: "Delete All Conversations?", bundle: .main), isPresented: $clearing) {
            Button(String(localized: "Cancel", bundle: .main), role: .cancel) {}
            Button(String(localized: "Delete All", bundle: .main), role: .destructive) { Task { await orbit.clearAll() } }
        } message: {
            Text(String(localized: "Every conversation and task is removed from this Mac, and running ones stop. Terminals keep running.", bundle: .main))
        }
    }

    // MARK: Threads

    private var threadList: some View {
        List(selection: $orbit.selectedID) {
            ForEach(orbit.threads) { thread in
                OrbitThreadRow(thread: thread)
                    .tag(thread.id)
                    .contextMenu {
                        Button(String(localized: "Delete…", bundle: .main), role: .destructive) { deleting = thread }
                    }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if orbit.threads.isEmpty {
                Text(String(localized: "No conversations yet", bundle: .main))
                    .font(WitermType.rowDetail)
                    .foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Button(String(localized: "New Conversation", bundle: .main), systemImage: "square.and.pencil") {
                    orbit.newThread(about: nil)
                }
                .help(String(localized: "Ask Orbit something, or give it a task", bundle: .main))
                .accessibilityIdentifier("orbitNewThread")
                Spacer()
                Menu {
                    Button(String(localized: "Delete All Conversations…", bundle: .main), role: .destructive) { clearing = true }
                        .disabled(orbit.threads.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(String(localized: "More", bundle: .main))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, WitermMetrics.Space.m)
            .padding(.vertical, WitermMetrics.Space.s)
        }
    }

    // MARK: Conversation

    @ViewBuilder
    private var conversation: some View {
        VStack(spacing: 0) {
            if let problem = orbit.problem {
                IssueBanner(problem, message: nil)
                    .padding([.horizontal, .top], WitermMetrics.Space.l)
            }
            if orbit.keyState == .none && !(orbit.status?.hasKey ?? false) {
                keySetup
            } else if let detail = orbit.detail, orbit.selectedID == detail.summary.id {
                OrbitTranscript(detail: detail, showTerminal: showTerminal, terminals: terminals)
                composer(for: detail.summary)
            } else if orbit.selectedID != nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                newThreadIntro
                composer(for: nil)
            }
        }
        .background(WitermTheme.canvas)
        .navigationTitle(orbit.detail.map { $0.summary.title } ?? String(localized: "Orbit", bundle: .main))
    }

    private var keySetup: some View {
        ContentUnavailableView {
            Label(String(localized: "Orbit Needs an OpenAI API Key", bundle: .main), systemImage: "key")
        } description: {
            Text(String(localized: "Orbit reads and operates your terminals using OpenAI’s models, with your own API key.", bundle: .main))
        } actions: {
            Button(String(localized: "Add API Key…", bundle: .main)) {
                UserDefaults.standard.set(SettingsTab.orbit.rawValue, forKey: SettingsTab.key)
                openSettings()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("orbitAddKey")
        }
    }

    private var newThreadIntro: some View {
        VStack(spacing: WitermMetrics.Space.m) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(String(localized: "What should Orbit do?", bundle: .main))
                .font(WitermType.pageTitle)
            Text(orbit.draftKind == .task
                 ? String(localized: "Describe a task. Orbit plans it, works in your terminals until it’s done, and tells you when it needs you.", bundle: .main)
                 : String(localized: "Ask about your terminals: what failed, what a command did, how to fix it. Orbit can run commands to find out.", bundle: .main))
                .font(WitermType.rowDetail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(WitermMetrics.pagePadding)
    }

    private func composer(for thread: OrbitThreadSummary?) -> some View {
        OrbitComposer(orbit: orbit, thread: thread, terminals: terminals)
    }
}

private struct OrbitThreadRow: View {
    let thread: OrbitThreadSummary

    var body: some View {
        VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
            HStack(spacing: WitermMetrics.Space.xs) {
                Image(systemName: thread.kind == .task ? "checklist" : "bubble.left.and.text.bubble.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(thread.title).lineLimit(1)
            }
            if let status = OrbitText.status(thread) {
                Text(status)
                    .font(WitermType.meta)
                    .foregroundStyle(OrbitText.statusColor(thread.status))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("orbitThread-\(thread.id)")
    }
}

/// Words for what the daemon reports by name.
@MainActor enum OrbitText {
    static func status(_ thread: OrbitThreadSummary) -> String? {
        switch thread.status {
        case .idle: nil
        case .running: String(localized: "Working…", bundle: .main)
        case .waiting: String(localized: "Waiting for you", bundle: .main)
        case .done: String(localized: "Done", bundle: .main)
        case .failed: String(localized: "Didn’t finish", bundle: .main)
        case .stopped: String(localized: "Stopped", bundle: .main)
        case .takenOver: String(localized: "With \(thread.takenOverBy ?? "another agent")", bundle: .main)
        }
    }

    static func statusColor(_ status: OrbitThreadStatus) -> Color {
        switch status {
        case .running, .done: WitermTheme.positive
        case .waiting, .failed: WitermTheme.warning
        default: .secondary
        }
    }

    static func action(_ entry: OrbitEntry) -> String {
        let terminal = entry.terminal ?? String(localized: "a terminal", bundle: .main)
        let command = entry.command ?? ""
        switch entry.tool {
        case "run_command": return String(localized: "Ran \(command) in \(terminal)", bundle: .main)
        case "send_input": return String(localized: "Typed \(command) in \(terminal)", bundle: .main)
        case "read_terminal": return String(localized: "Read \(terminal)", bundle: .main)
        case "wait_for_terminal": return String(localized: "Waited for \(terminal)", bundle: .main)
        case "list_terminals": return String(localized: "Looked at your terminals", bundle: .main)
        case "create_terminal": return String(localized: "Opened the terminal \(command)", bundle: .main)
        case "close_terminal": return String(localized: "Ended \(terminal)", bundle: .main)
        default: return String(localized: "Used \(entry.tool ?? "a tool")", bundle: .main)
        }
    }

    static func symbol(_ tool: String?) -> String {
        switch tool {
        case "run_command": "play.rectangle"
        case "send_input": "keyboard"
        case "read_terminal", "wait_for_terminal": "eye"
        case "list_terminals": "list.bullet"
        case "create_terminal": "plus.rectangle"
        case "close_terminal": "xmark.rectangle"
        default: "wrench.and.screwdriver"
        }
    }

    static func note(_ entry: OrbitEntry) -> String {
        let agent = entry.from ?? String(localized: "Another agent", bundle: .main)
        switch entry.note {
        case .stopped?: return String(localized: "You stopped Orbit.", bundle: .main)
        case .takenOver?: return String(localized: "\(agent) took this over.", bundle: .main)
        case .finishedByAgent?: return String(localized: "\(agent) finished it: \(entry.text ?? "")", bundle: .main)
        case .stepLimit?: return String(localized: "Orbit paused after many steps. Send a message to let it continue.", bundle: .main)
        case .summarized?: return String(localized: "Orbit summarized the earlier messages to keep this conversation short.", bundle: .main)
        case nil: return entry.text ?? ""
        }
    }

    static func failure(_ entry: OrbitEntry) -> String {
        switch entry.failure {
        case .missingKey?: return String(localized: "Add your OpenAI API key in Settings, then send again.", bundle: .main)
        case .keyRejected?: return String(localized: "OpenAI refused the API key. Check it in Settings.", bundle: .main)
        case .limited?: return String(localized: "OpenAI’s rate or usage limit was reached. Try again later.", bundle: .main)
        case .network?: return String(localized: "Couldn’t reach OpenAI. Check your internet connection.", bundle: .main)
        case .terminalsUnavailable?: return String(localized: "Terminals on this Mac are off. Turn them on in Settings.", bundle: .main)
        case .api?, nil: return String(localized: "OpenAI returned an error.", bundle: .main)
        }
    }
}

/// The plan and every entry, scrolled to the latest.
private struct OrbitTranscript: View {
    let detail: OrbitThreadDetail
    let showTerminal: (String) -> Void
    let terminals: [LocalSessionInfo]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: WitermMetrics.Space.m) {
                    if !detail.plan.isEmpty { plan }
                    if detail.earlierEntries > 0 {
                        Text(String(localized: "\(detail.earlierEntries) earlier entries aren’t shown", bundle: .main))
                            .font(WitermType.meta)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(detail.entries) { entry in
                        OrbitEntryView(entry: entry, showTerminal: terminalAction(entry))
                            .id(entry.id)
                    }
                    if detail.summary.status == .running {
                        HStack(spacing: WitermMetrics.Space.s) {
                            ProgressView().controlSize(.small)
                            Text(String(localized: "Orbit is working…", bundle: .main))
                                .font(WitermType.rowDetail)
                                .foregroundStyle(.secondary)
                        }
                        .id("working")
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(WitermMetrics.pagePadding)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: detail.summary.revision) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }

    private func terminalAction(_ entry: OrbitEntry) -> (() -> Void)? {
        guard let name = entry.terminal, let session = terminals.first(where: { $0.name == name }) else { return nil }
        return { showTerminal(session.id) }
    }

    private var plan: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: WitermMetrics.Space.xs) {
                ForEach(Array(detail.plan.enumerated()), id: \.offset) { _, step in
                    Label {
                        Text(step.text).strikethrough(step.status == .done, color: .secondary)
                    } icon: {
                        Image(systemName: step.status == .done ? "checkmark.circle.fill"
                              : step.status == .active ? "circle.dotted.circle" : "circle")
                            .foregroundStyle(step.status == .done ? WitermTheme.positive : .secondary)
                    }
                    .accessibilityValue(step.status == .done ? String(localized: "Done", bundle: .main)
                                        : step.status == .active ? String(localized: "In progress", bundle: .main)
                                        : String(localized: "Not started", bundle: .main))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(String(localized: "Plan", bundle: .main)).font(WitermType.cardTitle)
        }
    }
}

private struct OrbitEntryView: View {
    let entry: OrbitEntry
    let showTerminal: (() -> Void)?
    @State private var expanded = false

    var body: some View {
        switch entry.kind {
        case .user:
            VStack(alignment: .trailing, spacing: WitermMetrics.Space.xxs) {
                if let from = entry.from {
                    Text(String(localized: "From \(from)", bundle: .main))
                        .font(WitermType.meta)
                        .foregroundStyle(.secondary)
                }
                Text(entry.text ?? "")
                    .textSelection(.enabled)
                    .padding(.horizontal, WitermMetrics.Space.m)
                    .padding(.vertical, WitermMetrics.Space.s)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: WitermMetrics.Radius.l))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 80)
        case .assistant:
            Text(Self.markdown(entry.text ?? ""))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .action:
            VStack(alignment: .leading, spacing: WitermMetrics.Space.xs) {
                HStack(spacing: WitermMetrics.Space.s) {
                    Image(systemName: OrbitText.symbol(entry.tool))
                        .foregroundStyle(entry.failed == true ? WitermTheme.warning : .secondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text(OrbitText.action(entry))
                        .font(WitermType.rowDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if entry.failed == true {
                        Text(String(localized: "Failed", bundle: .main))
                            .font(WitermType.meta)
                            .foregroundStyle(WitermTheme.warning)
                    }
                    Spacer(minLength: 0)
                    if let showTerminal {
                        Button(String(localized: "Show", bundle: .main), action: showTerminal)
                            .buttonStyle(.link)
                            .font(WitermType.meta)
                            .help(String(localized: "Show this terminal", bundle: .main))
                    }
                    if entry.detail != nil {
                        Button {
                            expanded.toggle()
                        } label: {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(expanded ? String(localized: "Hide Output", bundle: .main)
                                                     : String(localized: "Show Output", bundle: .main))
                    }
                }
                if expanded, let detail = entry.detail {
                    Text(detail)
                        .font(WitermType.codeInline)
                        .textSelection(.enabled)
                        .padding(WitermMetrics.Space.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(WitermTheme.statusFill, in: RoundedRectangle(cornerRadius: WitermMetrics.Radius.m))
                }
            }
        case .note:
            Text(OrbitText.note(entry))
                .font(WitermType.meta)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        case .error:
            Label {
                VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
                    Text(OrbitText.failure(entry))
                    if let message = entry.text {
                        Text(message).font(WitermType.meta).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            } icon: {
                Image(systemName: WitermSymbols.problem).foregroundStyle(WitermTheme.warning)
            }
            .font(WitermType.rowDetail)
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Where the user writes: a new conversation or task (with what it's
/// about), or the next message in the one shown.
private struct OrbitComposer: View {
    @Bindable var orbit: OrbitService
    let thread: OrbitThreadSummary?
    let terminals: [LocalSessionInfo]
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: WitermMetrics.Space.s) {
            if thread == nil {
                HStack(spacing: WitermMetrics.Space.m) {
                    Picker(String(localized: "Kind", bundle: .main), selection: $orbit.draftKind) {
                        Text(String(localized: "Ask", bundle: .main)).tag(OrbitThreadKind.chat)
                        Text(String(localized: "Delegate a Task", bundle: .main)).tag(OrbitThreadKind.task)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("orbitKind")
                    Picker(String(localized: "About", bundle: .main), selection: $orbit.draftTerminalID) {
                        Text(String(localized: "All Terminals", bundle: .main)).tag(String?.none)
                        ForEach(terminals) { session in
                            Text(session.name).tag(Optional(session.id))
                        }
                    }
                    .fixedSize()
                    .help(String(localized: "The terminal “this terminal” means. Orbit can still use every terminal.", bundle: .main))
                    Spacer()
                }
            }
            HStack(alignment: .bottom, spacing: WitermMetrics.Space.s) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(WitermMetrics.Space.s)
                    .background(.background, in: RoundedRectangle(cornerRadius: WitermMetrics.Radius.m))
                    .overlay(RoundedRectangle(cornerRadius: WitermMetrics.Radius.m).strokeBorder(WitermTheme.divider))
                    .accessibilityIdentifier("orbitMessage")
                if thread?.status == .running {
                    Button(String(localized: "Stop", bundle: .main), systemImage: "stop.circle") { Task { await orbit.stop() } }
                        .help(String(localized: "Stop Orbit; what it already did stays done", bundle: .main))
                        .accessibilityIdentifier("orbitStop")
                }
                Button(String(localized: "Send", bundle: .main), systemImage: "arrow.up.circle.fill", action: send)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(trimmed.isEmpty || orbit.sending)
                    .help(String(localized: "Send (⌘↩)", bundle: .main))
                    .accessibilityIdentifier("orbitSend")
            }
            Text(String(localized: "Orbit can read and type in every terminal on this Mac. What it reads is sent to OpenAI.", bundle: .main))
                .font(WitermType.meta)
                .foregroundStyle(.secondary)
        }
        .padding(WitermMetrics.Space.l)
        .background(.bar)
        .onAppear { focused = true }
    }

    private var placeholder: String {
        if let thread {
            return thread.status == .running ? String(localized: "Guide Orbit while it works…", bundle: .main)
                                             : String(localized: "Reply to Orbit…", bundle: .main)
        }
        return orbit.draftKind == .task ? String(localized: "Describe the task…", bundle: .main)
                                        : String(localized: "Ask about your terminals…", bundle: .main)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send() {
        let message = trimmed
        guard !message.isEmpty, !orbit.sending else { return }
        Task {
            let sent = thread == nil ? await orbit.start(message) : await orbit.send(message)
            if sent { text = "" }
        }
    }
}
#endif
