#if os(macOS)
import AppKit
import SwiftUI
import WitermCore

/// A selected local tmux session: the live terminal, or a way back into it.
/// The window title names the session; its subtitle carries only state worth
/// knowing (view only, who else is on it, private or shared), and the
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
        .navigationTitle(model.selectedSession?.name ?? String(localized: "Local Terminal", bundle: .main))
        .navigationSubtitle(model.attachment == nil ? "" : model.selectedSession.map(subtitle) ?? "")
        .toolbar {
            if model.attachment != nil, let session = model.selectedSession, let client = service.client {
                toolbar(session, client: client)
            }
        }
        // Another device opening or leaving the session is announced once.
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
            // Only while another device can type here, or typing is paused.
            if let sharing, !sharing.keepPrivate,
               !sharing.remoteTyping || sharing.attachments.contains(where: { $0.device != nil && $0.mode == .control }) {
                let title = sharing.remoteTyping ? String(localized: "Pause Remote Typing", bundle: .main)
                    : String(localized: "Allow Remote Typing", bundle: .main)
                Button(title, systemImage: sharing.remoteTyping ? "hand.raised" : "hand.raised.slash") {
                    model.configure(session, remoteTyping: !sharing.remoteTyping, using: client)
                }
                .accessibilityIdentifier("toggleRemoteTyping")
                .help(title)
            }
            Button(String(localized: "Continue on Another Device…", bundle: .main), systemImage: "laptopcomputer.and.iphone") {
                continueSession(session)
            }
            .accessibilityIdentifier("shareLocalSession")
            .help(String(localized: "Continue on Another Device…", bundle: .main))
            Menu(String(localized: "More", bundle: .main), systemImage: "ellipsis.circle") {
                Button(String(localized: "Rename…", bundle: .main)) { renameSession(session) }
                    .accessibilityIdentifier("renameLocalSessionMenu")
                RemoteAccessMenuItems(session: session) { keepPrivate, typing in
                    model.configure(session, keepPrivate: keepPrivate, remoteTyping: typing, using: client)
                }
                if sharing?.shared == true {
                    Button(String(localized: "Stop Sharing", bundle: .main)) { model.setShared(session, false, using: client) }
                        .accessibilityIdentifier("stopSharingLocalSession")
                }
                Divider()
                Button(String(localized: "Leave", bundle: .main), action: model.detach)
                    .accessibilityIdentifier("detachLocalTerminal")
                    .help(String(localized: "Leave this session; it keeps running", bundle: .main))
                Button(String(localized: "End Session", bundle: .main), role: .destructive) { endSession(session) }
            }
            .accessibilityIdentifier("localTerminalMore")
            .help(String(localized: "More", bundle: .main))
        }
    }

    /// State worth a glance, in words; empty when there's nothing to say.
    private func subtitle(_ session: LocalSessionInfo) -> String {
        var parts: [String] = []
        if model.mode == .view { parts.append(String(localized: "View Only", bundle: .main)) }
        guard let sharing = session.sharing else { return parts.joined(separator: " · ") }
        let remote = sharing.attachments.filter { $0.device != nil }
        if !remote.isEmpty {
            parts += remote.map { attachment in
                let name = attachment.device?.name ?? ""
                return attachment.mode == .control ? String(localized: "\(name) can type", bundle: .main)
                    : String(localized: "\(name) is viewing", bundle: .main)
            }
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
            Label(model.ended ? String(localized: "Session Ended", bundle: .main) : String(localized: "Session Still Running", bundle: .main), systemImage: "terminal")
        } actions: {
            if !model.ended {
                HStack(spacing: 12) {
                    PrimaryButton(String(localized: "Connect", bundle: .main)) { model.attach(session, using: client, mode: .control) }
                        .accessibilityIdentifier("reconnectLocalTerminal")
                    Button(String(localized: "View Only", bundle: .main)) { model.attach(session, using: client, mode: .view) }
                        .buttonStyle(.bordered)
                        .witermControl()
                        .accessibilityIdentifier("viewLocalTerminal")
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
                        Label(model.sessions.isEmpty ? String(localized: "No Terminal Sessions Yet", bundle: .main) : String(localized: "Choose a Session", bundle: .main), systemImage: "terminal")
                    } actions: {
                        VStack(spacing: 20) {
                            HStack(spacing: 12) {
                                PrimaryButton(String(localized: "New Session", bundle: .main), action: newSession)
                                    .disabled(!canCreate)
                                Button(String(localized: "New SSH Connection", bundle: .main), action: newSSHConnection)
                                    .buttonStyle(.bordered)
                                    .witermControl()
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
                    .help(String(localized: "Start a session from Terminal in any folder", bundle: .main))
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
                    Button(String(localized: "View Only", bundle: .main)) { model.attach(session, using: client, mode: .view) }
                        .disabled(model.isWorking)
                }
            }
            .accessibilityIdentifier("localTerminalError")
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        if let busy = model.busy, model.attachment != nil {
            ActivityRow(busy)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            Divider()
        }
    }
}

private struct LocalProgressView: View {
    let label: String
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(label).font(.subheadline).foregroundStyle(WitermTheme.secondary)
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
                    Label(String(localized: "Local Terminal Off", bundle: .main), systemImage: "terminal")
                } actions: {
                    PrimaryButton(String(localized: "Enable Local Terminal", bundle: .main)) { Task { await service.start() } }
                        .accessibilityIdentifier("enableLocalTerminal")
                }
            case .requiresApproval:
                ContentUnavailableView {
                    Label(String(localized: "Allow Witerm to Run in the Background", bundle: .main), systemImage: "checkmark.shield")
                } actions: {
                    PrimaryButton(String(localized: "Open System Settings", bundle: .main), action: service.openSettings)
                }
            case .starting:
                ProgressView(String(localized: "Enabling local terminal…", bundle: .main))
            case .unavailable, .ready:
                ContentUnavailableView {
                    Label(String(localized: "Local Terminal Unavailable", bundle: .main), systemImage: "exclamationmark.circle")
                } description: {
                    Text(service.issue ?? String(localized: "Check local service status, then try again.", bundle: .main))
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
            VStack(spacing: 16) {
                Text("brew install tmux")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(WitermTheme.statusFill, in: .rect(cornerRadius: 8))
                PrimaryButton(String(localized: "Check Again", bundle: .main)) { model.refresh(using: client) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Renames a session. New sessions are named for you (⌘N), so naming never
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
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Rename Session", bundle: .main)).font(.headline)
            TextField(String(localized: "Session Name", bundle: .main), text: $name)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit(rename)
                .onChange(of: name) { invalid = false }
                .accessibilityLabel(String(localized: "Session Name", bundle: .main))
                .accessibilityIdentifier("localSessionName")
            if invalid {
                Text(String(localized: "Use 1–64 characters without control characters.", bundle: .main))
                    .font(.subheadline).foregroundStyle(WitermTheme.warning)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel", bundle: .main), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                PrimaryButton(String(localized: "Rename", bundle: .main), action: rename)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("renameLocalSession")
            }
            .witermControl()
        }
        .padding(WitermMetrics.pagePadding)
        .frame(width: 360)
        .witermTint()
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

/// Per-session remote access in a menu: keeping a session from every paired
/// device, and pausing their typing.
struct RemoteAccessMenuItems: View {
    let session: LocalSessionInfo
    /// (keepPrivate, remoteTyping): the one that changed is non-nil.
    let configure: (Bool?, Bool?) -> Void

    var body: some View {
        let sharing = session.sharing
        Toggle(String(localized: "Keep Private", bundle: .main), isOn: Binding(
            get: { sharing?.keepPrivate == true }, set: { configure($0, nil) }))
            .help(String(localized: "Hide this session from every paired device", bundle: .main))
            .accessibilityIdentifier("keepSessionPrivate")
        Toggle(String(localized: "Pause Remote Typing", bundle: .main), isOn: Binding(
            get: { sharing?.remoteTyping == false }, set: { configure(nil, !$0) }))
            .disabled(sharing?.keepPrivate == true)
            .accessibilityIdentifier("pauseRemoteTyping")
    }
}
#endif
