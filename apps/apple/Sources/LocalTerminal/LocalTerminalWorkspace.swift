#if os(macOS)
import AppKit
import SwiftUI
import WitermCore

/// A selected terminal on this Mac: the live terminal, or a way back into it.
/// The window title names it; its subtitle carries only state worth knowing
/// (Watching, who else has it open and how, private or shared), and the
/// toolbar holds the actions, so the terminal gets the whole pane.
struct LocalTerminalDetail: View {
    @Bindable var service: LocalAgentService
    @Bindable var model: LocalTerminalModel
    let endSession: (LocalSessionInfo) -> Void
    let renameSession: (LocalSessionInfo) -> Void
    let continueSession: (LocalSessionInfo) -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage(TerminalFontSize.key) private var terminalFontSize = TerminalFontSize.standard
    @AppStorage("witerm.terminalHighContrast") private var terminalHighContrast = false
    @AppStorage(TerminalColorScheme.key) private var terminalPalette = TerminalColorScheme.system
    @AppStorage("witerm.terminalAnnounceOutput") private var terminalAnnounceOutput = false

    var body: some View {
        VStack(spacing: 0) {
            LocalStatusBanners(service: service, model: model)
            if service.state == .ready, let client = service.client {
                if !model.tmuxAvailable {
                    LocalDependencyView(model: model, client: client)
                } else if let attachment = model.attachment, let session = model.selectedSession {
                    terminal(attachment, session: session, client: client)
                } else if model.isWorking {
                    LocalProgressView(label: model.busy ?? "", cancel: model.detach)
                } else if let session = model.selectedSession {
                    disconnected(session, client: client)
                } else {
                    Spacer()
                }
            } else {
                LocalServiceSetupView(service: service)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WitermTheme.canvas)
        .navigationTitle(model.selectedSession?.name ?? "Witerm")
        .navigationSubtitle(model.attachment == nil ? "" : model.selectedSession.map(subtitle) ?? "")
        .toolbar {
            if model.attachment != nil, let session = model.selectedSession, let client = service.client {
                toolbar(session, client: client)
            }
        }
        // Another device opening or leaving the terminal is announced once.
        .onChange(of: model.selectedSession?.remoteDeviceNames ?? []) { old, new in
            for name in new where !old.contains(name) {
                AccessibilityNotification.Announcement(String(localized: "\(name) joined", bundle: .main)).post()
            }
            for name in old where !new.contains(name) {
                AccessibilityNotification.Announcement(String(localized: "\(name) left", bundle: .main)).post()
            }
        }
        .onDisappear { model.detach() }
    }

    private func terminal(_ attachment: LocalTerminalAttachment, session: LocalSessionInfo, client: LocalAgentClient) -> some View {
        let attachmentID = model.attachmentID
        return NativeTerminalView(
            attachment: attachment, mode: model.mode,
            fontSize: CGFloat(TerminalFontSize.clamped(terminalFontSize)),
            highContrast: terminalHighContrast || contrast == .increased,
            preferredColorScheme: systemColorScheme,
            palette: terminalPalette,
            announceOutput: terminalAnnounceOutput,
            activity: model.activity(for: session.id),
            focusOnShow: model.focusOnAttach,
            focusRequest: model.focusRequest,
            onFailure: { model.attachmentFailed($0, id: attachmentID) },
            onEnded: { model.attachmentEnded(id: attachmentID, client: client) }
        )
        .id(attachmentID)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private func toolbar(_ session: LocalSessionInfo, client: LocalAgentClient) -> some ToolbarContent {
        let sharing = session.sharing
        ToolbarItemGroup(placement: .primaryAction) {
            // Only while watching: the eye says so, and one click types again.
            if model.mode == .view {
                Button(String(localized: "Start Typing", bundle: .main), systemImage: "keyboard") {
                    model.setTyping(true, using: client)
                }
                .accessibilityIdentifier("startTypingLocal")
                .help(String(localized: "Watching. Start typing here.", bundle: .main))
            }
            // Only while another device can type here, or typing is paused. A
            // toggle, so its pressed look shows that typing is paused.
            if let sharing, !sharing.keepPrivate,
               !sharing.remoteTyping || sharing.attachments.contains(where: { $0.device != nil && $0.mode == .control }) {
                Toggle(isOn: Binding(get: { !sharing.remoteTyping },
                                     set: { model.configure(session, remoteTyping: !$0, using: client) })) {
                    Label(String(localized: "Pause Remote Typing", bundle: .main), systemImage: "hand.raised")
                }
                .toggleStyle(.button)
                .accessibilityIdentifier("toggleRemoteTyping")
                .help(sharing.remoteTyping ? String(localized: "Pause typing from other devices", bundle: .main)
                      : String(localized: "Remote typing is paused. Click to allow it.", bundle: .main))
            }
            // Icon only: the sheet starts at its device step.
            Button(String(localized: "Open on another device", bundle: .main), systemImage: WitermSymbols.openOn) {
                continueSession(session)
            }
            .accessibilityIdentifier("shareLocalSession")
            .help(String(localized: "Open “\(session.name)” on a paired device or a new one", bundle: .main))
            Menu(String(localized: "More", bundle: .main), systemImage: WitermSymbols.more) {
                TypingMenuItems(mode: model.mode) { model.setTyping($0, using: client) }
                Button(String(localized: "Leave", bundle: .main), systemImage: "rectangle.portrait.and.arrow.right", action: model.detach)
                    .accessibilityIdentifier("detachLocalTerminal")
                    .help(String(localized: "Stop showing it here; it keeps running", bundle: .main))
                Divider()
                Button(String(localized: "Rename…", bundle: .main)) { renameSession(session) }
                    .accessibilityIdentifier("renameLocalSessionMenu")
                SharingMenu(keepPrivate: sharing?.keepPrivate == true, remoteTypingPaused: sharing?.remoteTyping == false,
                            shared: sharing?.shared == true,
                            toggleKeepPrivate: { model.configure(session, keepPrivate: sharing?.keepPrivate != true, using: client) },
                            toggleRemoteTyping: { model.configure(session, remoteTyping: sharing?.remoteTyping == false, using: client) },
                            stopSharing: { model.setShared(session, false, using: client) })
                Divider()
                Button(String(localized: "End Terminal…", bundle: .main), role: .destructive) { endSession(session) }
            }
            .accessibilityIdentifier("localTerminalMore")
            .help(String(localized: "More for this terminal", bundle: .main))
        }
    }

    /// State worth a glance, in words; empty when there's nothing to say.
    private func subtitle(_ session: LocalSessionInfo) -> String {
        var parts: [String] = []
        if model.mode == .view { parts.append(String(localized: "Watching", bundle: .main)) }
        guard let sharing = session.sharing else { return parts.joined(separator: " · ") }
        let elsewhere = model.elsewhere(session)
        if !elsewhere.isEmpty {
            parts += elsewhere
        } else if sharing.keepPrivate {
            parts.append(String(localized: "Private", bundle: .main))
        } else if !sharing.remoteTyping {
            parts.append(String(localized: "Remote Typing Paused", bundle: .main))
        } else if sharing.shared {
            if model.relays.isEmpty {
                parts.append(String(localized: "Shared · Remote access off", bundle: .main))
            } else if !model.relays.contains(where: { $0.state == .ready }) {
                parts.append(String(localized: "Shared · Connecting…", bundle: .main))
            } else {
                parts.append(String(localized: "Shared", bundle: .main))
            }
        }
        return parts.joined(separator: " · ")
    }

    private func disconnected(_ session: LocalSessionInfo, client: LocalAgentClient) -> some View {
        ContentUnavailableView {
            Label(model.ended ? String(localized: "Terminal Ended", bundle: .main) : String(localized: "Still Running", bundle: .main), systemImage: "terminal")
        } actions: {
            if !model.ended {
                HStack(spacing: WitermMetrics.Space.m) {
                    PrimaryButton(LocalTerminalHelp.open, systemImage: WitermSymbols.typing) { model.attach(session, using: client, mode: .control) }
                        .accessibilityIdentifier("reconnectLocalTerminal")
                        .help(String(localized: "Open it here and type", bundle: .main))
                    Button(String(localized: "Watch", bundle: .main), systemImage: WitermSymbols.watching) { model.attach(session, using: client, mode: .view) }
                        .buttonStyle(.bordered)
                        .witermControl()
                        .accessibilityIdentifier("viewLocalTerminal")
                        .help(String(localized: "Open it here without typing", bundle: .main))
                }
                .disabled(model.isWorking)
            }
        }
    }
}

/// Shown when nothing is selected: the next useful action for this Mac.
struct LocalOverview: View {
    @Bindable var service: LocalAgentService
    @Bindable var model: LocalTerminalModel
    let canCreate: Bool
    let newSession: () -> Void
    let newSSHConnection: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            LocalStatusBanners(service: service, model: model)
            if service.state == .ready, let client = service.client {
                if !model.tmuxAvailable {
                    LocalDependencyView(model: model, client: client)
                } else if model.isWorking {
                    LocalProgressView(label: model.busy ?? "", cancel: model.detach)
                } else {
                    // Title and actions only; the shortcuts are in the menus.
                    ContentUnavailableView {
                        Label(model.sessions.isEmpty ? String(localized: "No Terminals Yet", bundle: .main) : String(localized: "Choose a Terminal", bundle: .main), systemImage: "terminal")
                    } actions: {
                        VStack(spacing: WitermMetrics.Space.xl) {
                            HStack(spacing: WitermMetrics.Space.m) {
                                PrimaryButton(String(localized: "New Terminal", bundle: .main), action: newSession)
                                    .disabled(!canCreate)
                                    .help(LocalTerminalHelp.newTerminal)
                                Button(String(localized: "Add SSH Host…", bundle: .main), action: newSSHConnection)
                                    .buttonStyle(.bordered)
                                    .witermControl()
                                    .help(LocalTerminalHelp.addSSHHost)
                            }
                            if model.sessions.isEmpty { StartFromTerminalHint() }
                        }
                    }
                }
            } else {
                LocalServiceSetupView(service: service)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WitermTheme.canvas)
        .navigationTitle("Witerm")
    }
}

/// A light pointer to the `witerm` command for starting sessions from Terminal.
private struct StartFromTerminalHint: View {
    private let tool = CommandLineToolModel.shared
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsTab.key) private var settingsTab = SettingsTab.general.rawValue

    var body: some View {
        Group {
            if tool.state == .installed {
                CopyableCommand("witerm new")
                    .frame(maxWidth: 260)
                    .help(String(localized: "Starts a terminal in the folder you run it in", bundle: .main))
            } else {
                // Always the Command Line tab, whichever tab Settings showed last.
                Button(String(localized: "Install the witerm Command…", bundle: .main)) {
                    settingsTab = SettingsTab.commandLine.rawValue
                    openSettings()
                }
                .accessibilityIdentifier("installCommandLineHint")
            }
        }
        .onAppear(perform: tool.refresh)
        // Picks up an install made outside the app, such as a manual link.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in tool.refresh() }
    }
}

/// Recoverable local-terminal problems and in-flight work above the content.
private struct LocalStatusBanners: View {
    @Bindable var service: LocalAgentService
    @Bindable var model: LocalTerminalModel

    var body: some View {
        if let issue = model.issue, service.state == .ready {
            IssueBanner(issue.title, message: issue.recovery) {
                if issue.canViewReadOnly, let session = model.selectedSession, let client = service.client {
                    Button(String(localized: "Watch", bundle: .main), systemImage: WitermSymbols.watching) { model.attach(session, using: client, mode: .view) }
                        .disabled(model.isWorking)
                }
            }
            .accessibilityIdentifier("localTerminalError")
            .padding(.horizontal, WitermMetrics.Space.l)
            .padding(.vertical, WitermMetrics.Space.m)
        }
        if let busy = model.busy, model.attachment != nil {
            ActivityRow(busy)
                .padding(.horizontal, WitermMetrics.Space.l)
                .padding(.vertical, WitermMetrics.Space.xs)
            Divider()
        }
    }
}

private struct LocalProgressView: View {
    let label: String
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: WitermMetrics.Space.m) {
            ProgressView()
            Text(label).font(WitermType.rowDetail).foregroundStyle(WitermTheme.secondary)
            Button(String(localized: "Cancel", bundle: .main), action: cancel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LocalServiceSetupView: View {
    @Bindable var service: LocalAgentService

    var body: some View {
        Group {
            switch service.state {
            case .notRegistered:
                ContentUnavailableView {
                    Label(String(localized: "Terminals Are Off", bundle: .main), systemImage: "terminal")
                } actions: {
                    PrimaryButton(String(localized: "Turn On Terminals", bundle: .main)) { Task { await service.start() } }
                        .accessibilityIdentifier("enableLocalTerminal")
                        .help(String(localized: "Lets Witerm keep terminals running on this Mac, even after you quit it", bundle: .main))
                }
            case .requiresApproval:
                ContentUnavailableView {
                    Label(String(localized: "Allow Witerm to Run in the Background", bundle: .main), systemImage: "checkmark.shield")
                } actions: {
                    PrimaryButton(String(localized: "Open System Settings", bundle: .main), action: service.openSettings)
                }
            case .starting:
                ProgressView(String(localized: "Turning on terminals…", bundle: .main))
            case .unavailable, .ready:
                ContentUnavailableView {
                    Label(String(localized: "Terminals Not Responding", bundle: .main), systemImage: "exclamationmark.circle")
                } description: {
                    Text(service.issue ?? String(localized: "Try again. If it keeps happening, turn terminals off and on in Settings → General.", bundle: .main))
                } actions: {
                    PrimaryButton(String(localized: "Try Again", bundle: .main)) { Task { await service.start() } }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LocalDependencyView: View {
    let model: LocalTerminalModel
    let client: LocalAgentClient

    var body: some View {
        ContentUnavailableView {
            Label(String(localized: "tmux Required", bundle: .main), systemImage: "terminal")
        } actions: {
            VStack(spacing: WitermMetrics.Space.l) {
                Text("brew install tmux")
                    .font(WitermType.code)
                    .textSelection(.enabled)
                    .padding(.horizontal, WitermMetrics.Space.m)
                    .padding(.vertical, WitermMetrics.Space.s)
                    .background(WitermTheme.statusFill, in: .rect(cornerRadius: WitermMetrics.Radius.m, style: .continuous))
                    .witermOutline(cornerRadius: WitermMetrics.Radius.m)
                PrimaryButton(String(localized: "Check Again", bundle: .main)) { model.refresh(using: client) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Renames a terminal. New terminals are named for you (⌘N), so naming never
/// stands between a person and the prompt.
struct RenameSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var invalid = false
    let onRename: (String) -> Void

    init(current: String, onRename: @escaping (String) -> Void) {
        _name = State(initialValue: current)
        self.onRename = onRename
    }

    var body: some View {
        SheetScaffold(String(localized: "Rename Terminal", bundle: .main), width: .compact) {
            VStack(alignment: .leading, spacing: WitermMetrics.Space.s) {
                TextField(String(localized: "Name", bundle: .main), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit(rename)
                    .onChange(of: name) { invalid = false }
                    .accessibilityLabel(String(localized: "Terminal Name", bundle: .main))
                    .accessibilityIdentifier("localSessionName")
                if invalid {
                    Text(String(localized: "Use 1–64 characters without control characters.", bundle: .main))
                        .font(WitermType.rowDetail).foregroundStyle(WitermTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } trailing: {
            Button(String(localized: "Cancel", bundle: .main), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Rename", bundle: .main), action: rename)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("renameLocalSession")
        }
    }

    private func rename() {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(name.unicodeScalars.count),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            invalid = true
            return
        }
        onRename(name)
        dismiss()
    }
}

/// Start Typing or Stop Typing for the terminal shown here: one item whose
/// title is the switch, so the menu reads differently before and after.
struct TypingMenuItems: View {
    let mode: LocalAttachmentMode
    let setTyping: (Bool) -> Void

    var body: some View {
        if mode == .control {
            Button(String(localized: "Stop Typing", bundle: .main), systemImage: "eye") { setTyping(false) }
                .accessibilityIdentifier("watchLocalSession")
                .help(String(localized: "Keep watching; nothing you press is sent", bundle: .main))
        } else {
            Button(String(localized: "Start Typing", bundle: .main), systemImage: "keyboard") { setTyping(true) }
                .accessibilityIdentifier("typeLocalSession")
        }
    }
}

/// Help that explains what a short label can't, and labels that need their
/// own catalog key.
enum LocalTerminalHelp {
    /// The verb, opening a terminal to type. "Open" alone is already the
    /// iOS section header (已打开), so the verb has its own key.
    static var open: String {
        String(localized: "terminal.open", defaultValue: "Open", bundle: .main,
               comment: "Verb: open a terminal here so you can type in it")
    }
    static var newTerminal: String {
        String(localized: "A new shell on this Mac. It keeps running after you close it or quit Witerm.", bundle: .main)
    }
    static var addSSHHost: String {
        String(localized: "Sign in to another computer with SSH", bundle: .main)
    }
}
#endif
