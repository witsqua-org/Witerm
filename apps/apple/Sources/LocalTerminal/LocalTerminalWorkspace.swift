#if os(macOS)
import AppKit
import SwiftUI
import WitermCore

/// A selected local tmux session: the live terminal, or a way back into it.
struct LocalTerminalDetail: View {
    @Bindable var service: LocalAgentService
    @Bindable var model: LocalTerminalModel
    let endSession: (LocalSessionInfo) -> Void
    let renameSession: (LocalSessionInfo) -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage(TerminalFontSize.key) private var terminalFontSize = TerminalFontSize.standard
    @AppStorage("witerm.terminalHighContrast") private var terminalHighContrast = false
    @AppStorage(TerminalColorScheme.key) private var terminalPalette = TerminalColorScheme.system
    @AppStorage("witerm.terminalAnnounceOutput") private var terminalAnnounceOutput = false
    @State private var continuing = false

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
        .onDisappear { model.detach() }
        .sheet(isPresented: $continuing) {
            if let session = model.selectedSession {
                ContinueOnDeviceSheet(service: service, sessionID: session.id) { id in
                    model.activity(for: id).summary(home: NSHomeDirectory())
                }
            }
        }
    }

    private func terminal(_ attachment: LocalTerminalAttachment, session: LocalSessionInfo, client: LocalAgentClient) -> some View {
        let attachmentID = model.attachmentID
        return VStack(spacing: 0) {
            TerminalHeader(
                nil,
                destination: String(localized: "This Mac", bundle: .main),
                status: model.mode == .view ? String(localized: "View Only", bundle: .main) : String(localized: "Input Enabled", bundle: .main),
                statusImage: model.mode == .view ? "eye" : "keyboard",
                live: true
            ) {
                let shared = session.sharing?.shared == true
                Button(String(localized: "Continue on Another Device…", bundle: .main),
                       systemImage: "laptopcomputer.and.iphone") { continuing = true }
                .touchTarget()
                .accessibilityIdentifier("shareLocalSession")
                .help(String(localized: "Open this session on another device", bundle: .main))
                if shared {
                    Button(String(localized: "Stop Sharing", bundle: .main), systemImage: "antenna.radiowaves.left.and.right.slash") {
                        model.setShared(session, false, using: client)
                    }
                    .accessibilityIdentifier("stopSharingLocalSession")
                }
                Button(String(localized: "Leave", bundle: .main), systemImage: "rectangle.portrait.and.arrow.right", action: model.detach)
                    .touchTarget()
                    .accessibilityIdentifier("detachLocalTerminal")
                    .help(String(localized: "Leave this session; it keeps running", bundle: .main))
                Menu(String(localized: "More", bundle: .main), systemImage: "ellipsis") {
                    Button(String(localized: "Rename…", bundle: .main), systemImage: "pencil") { renameSession(session) }
                        .accessibilityIdentifier("renameLocalSessionMenu")
                    RemoteAccessMenuItems(session: session) { keepPrivate, typing in
                        model.configure(session, keepPrivate: keepPrivate, remoteTyping: typing, using: client)
                    }
                    Button(String(localized: "End Session", bundle: .main), systemImage: "xmark.circle", role: .destructive) { endSession(session) }
                }
                .menuStyle(.borderlessButton)
                .help(String(localized: "Terminal Actions", bundle: .main))
            }
            .buttonStyle(.borderless)
            // Shown whenever paired devices can or do reach this session, or
            // it's kept from all of them.
            if let sharing = session.sharing,
               sharing.shared || sharing.keepPrivate || sharing.attachments.contains(where: { $0.device != nil }) {
                SessionSharingBar(sharing: sharing, relays: model.relays) {
                    model.configure(session, remoteTyping: !sharing.remoteTyping, using: client)
                }
                Divider()
            }
            NativeTerminalView(
                attachment: attachment, mode: model.mode,
                fontSize: CGFloat(TerminalFontSize.clamped(terminalFontSize)),
                highContrast: terminalHighContrast || contrast == .increased,
                preferredColorScheme: systemColorScheme,
                palette: terminalPalette,
                announceOutput: terminalAnnounceOutput,
                activity: model.activity(for: session.id),
                onFailure: { model.attachmentFailed($0, id: attachmentID) },
                onEnded: { model.attachmentEnded(id: attachmentID, client: client) }
            )
            .id(attachmentID)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func disconnected(_ session: LocalSessionInfo, client: LocalAgentClient) -> some View {
        ContentUnavailableView {
            Label(model.ended ? String(localized: "Session Ended", bundle: .main) : String(localized: "Session Still Running", bundle: .main), systemImage: "terminal")
        } description: {
            Text(model.ended ? String(localized: "Refresh the list to choose another session.", bundle: .main)
                 : String(localized: "It keeps running while you're away. Connect to pick up where you left off.", bundle: .main))
        } actions: {
            if model.ended {
                Button(String(localized: "Refresh", bundle: .main)) { model.refresh(using: client) }
            } else { HStack(spacing: 12) {
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
                    ContentUnavailableView {
                        Label(model.sessions.isEmpty ? String(localized: "No Terminal Sessions Yet", bundle: .main) : String(localized: "Choose a Session", bundle: .main), systemImage: "terminal")
                    } description: {
                        Text(model.sessions.isEmpty ? String(localized: "Create a session to start working on this Mac.", bundle: .main) : String(localized: "Select a session on the left to connect.", bundle: .main))
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

/// Whether paired devices can reach this session right now, and who is on it.
private struct SessionSharingBar: View {
    let sharing: LocalSessionSharing
    let relays: [LocalRelayStatus]
    /// Pauses or resumes typing from paired devices.
    let toggleRemoteTyping: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            // Two lines at most: the split view measures minimum heights at
            // narrow widths, where unbounded wrapping overflows the window.
            Text(summary)
                .font(.callout)
                .foregroundStyle(WitermTheme.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("sessionSharingStatus")
            Spacer(minLength: 0)
            // A quick way to stop remote input without ending anyone's view.
            if !sharing.keepPrivate, !sharing.remoteTyping || remoteDevices.contains(where: { $0.mode == .control }) {
                Button(sharing.remoteTyping ? String(localized: "Pause Remote Typing", bundle: .main)
                       : String(localized: "Allow Remote Typing", bundle: .main),
                       systemImage: sharing.remoteTyping ? "hand.raised" : "keyboard",
                       action: toggleRemoteTyping)
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .accessibilityIdentifier("toggleRemoteTyping")
                    .help(String(localized: "Paired devices keep watching; this Mac keeps typing", bundle: .main))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(WitermTheme.statusFill)
    }

    private var remoteDevices: [LocalAttachmentInfo] { sharing.attachments.filter { $0.device != nil } }
    private var ready: Bool { relays.contains { $0.state == .ready } }

    private var summary: String {
        if !remoteDevices.isEmpty {
            let names = remoteDevices.map { attachment in
                let name = attachment.device?.name ?? ""
                return attachment.mode == .control
                    ? String(localized: "\(name) can type", bundle: .main)
                    : String(localized: "\(name) is viewing", bundle: .main)
            }
            return String(localized: "Remote · \(names.joined(separator: ", "))", bundle: .main)
        }
        if sharing.keepPrivate {
            return String(localized: "Private · No paired device can open it", bundle: .main)
        }
        if !sharing.remoteTyping {
            return String(localized: "Remote typing is paused. Paired devices can only watch.", bundle: .main)
        }
        if relays.isEmpty {
            return String(localized: "Shared, but remote access is off. Turn on Allow Remote Access in Settings > Devices.", bundle: .main)
        }
        return ready
            ? String(localized: "Shared · Paired devices can open it", bundle: .main)
            : String(localized: "Shared · Waiting for the server to accept this Mac", bundle: .main)
    }

    private var symbol: String {
        if sharing.keepPrivate, remoteDevices.isEmpty { return "lock.fill" }
        if relays.isEmpty { return "antenna.radiowaves.left.and.right.slash" }
        return ready || !remoteDevices.isEmpty ? "antenna.radiowaves.left.and.right" : "hourglass"
    }

    private var tint: Color {
        if sharing.keepPrivate, remoteDevices.isEmpty { return .secondary }
        if relays.isEmpty { return WitermTheme.warning }
        return ready || !remoteDevices.isEmpty ? WitermTheme.positive : .secondary
    }
}

/// A light pointer to the `witerm` command for starting sessions from Terminal.
private struct StartFromTerminalHint: View {
    private let tool = CommandLineToolModel.shared
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsTab.key) private var settingsTab = SettingsTab.general.rawValue

    var body: some View {
        VStack(spacing: 8) {
            Text(String(localized: "Or start one from Terminal in any folder:", bundle: .main))
                .font(.subheadline)
                .foregroundStyle(WitermTheme.secondary)
            if tool.state == .installed {
                CopyableCommand("witerm new")
                    .frame(maxWidth: 260)
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
                    Label(String(localized: "Enable Local Terminal", bundle: .main), systemImage: "terminal")
                } description: {
                    Text(String(localized: "Create and manage terminal sessions on this Mac.", bundle: .main))
                } actions: {
                    PrimaryButton(String(localized: "Enable Local Terminal", bundle: .main)) { Task { await service.start() } }
                        .accessibilityIdentifier("enableLocalTerminal")
                }
            case .requiresApproval:
                ContentUnavailableView {
                    Label(String(localized: "Allow Witerm to Run in the Background", bundle: .main), systemImage: "checkmark.shield")
                } description: {
                    Text(String(localized: "Allow Witerm in Login Items in System Settings.", bundle: .main))
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
        } description: {
            Text(String(localized: "Install tmux to create local terminal sessions.", bundle: .main))
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

/// Names a new session, or renames one when `renaming` is its current name.
struct NewLocalSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var invalid = false
    private let renaming: Bool
    let onCreate: (String) -> Void

    init(renaming current: String? = nil, onCreate: @escaping (String) -> Void) {
        _name = State(initialValue: current ?? String(localized: "New Terminal", bundle: .main))
        renaming = current != nil
        self.onCreate = onCreate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                IconTile(systemImage: "terminal")
                Text(renaming ? String(localized: "Rename Session", bundle: .main) : String(localized: "New Terminal Session", bundle: .main)).font(.headline)
            }
            TextField(String(localized: "Session Name", bundle: .main), text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
                .onChange(of: name) { invalid = false }
                .accessibilityIdentifier("localSessionName")
            if invalid {
                Text(String(localized: "Use 1–64 characters without control characters.", bundle: .main))
                    .font(.subheadline).foregroundStyle(WitermTheme.warning)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel", bundle: .main), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                PrimaryButton(renaming ? String(localized: "Rename", bundle: .main) : String(localized: "Create", bundle: .main), action: create)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(renaming ? "renameLocalSession" : "createLocalSession")
            }
            .witermControl()
        }
        .padding(WitermMetrics.pagePadding)
        .frame(width: 400)
        .witermTint()
    }

    private func create() {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(name.unicodeScalars.count),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            invalid = true
            return
        }
        onCreate(name)
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
