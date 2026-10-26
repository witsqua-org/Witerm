#if os(macOS)
import AppKit
import SwiftUI
import WitermCore

/// A selected local tmux session: the live terminal, or a way back into it.
struct LocalTerminalDetail: View {
    @Bindable var service: LocalAgentService
    @Bindable var model: LocalTerminalModel
    let endSession: (LocalSessionInfo) -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage(TerminalFontSize.key) private var terminalFontSize = TerminalFontSize.standard
    @AppStorage("witerm.terminalHighContrast") private var terminalHighContrast = false
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
        .onDisappear { model.detach() }
    }

    private func terminal(_ attachment: LocalTerminalAttachment, session: LocalSessionInfo, client: LocalAgentClient) -> some View {
        let attachmentID = model.attachmentID
        return VStack(spacing: 0) {
            TerminalHeader(
                nil,
                status: model.mode == .view ? String(localized: "View Only", bundle: .main) : String(localized: "Input Enabled", bundle: .main),
                statusImage: model.mode == .view ? "eye" : "keyboard",
                live: true
            ) {
                Button(String(localized: "Disconnect", bundle: .main), systemImage: "eject", action: model.detach)
                    .touchTarget()
                    .accessibilityIdentifier("detachLocalTerminal")
                    .help(String(localized: "Disconnect; the session keeps running", bundle: .main))
                Button(String(localized: "End Session", bundle: .main), systemImage: "xmark.circle", role: .destructive) { endSession(session) }
                    .labelStyle(.iconOnly)
                    .touchTarget(square: true)
                    .help(String(localized: "End Session", bundle: .main))
            }
            .buttonStyle(.borderless)
            NativeTerminalView(
                attachment: attachment, mode: model.mode,
                fontSize: CGFloat(TerminalFontSize.clamped(terminalFontSize)),
                highContrast: terminalHighContrast || contrast == .increased,
                preferredColorScheme: systemColorScheme,
                announceOutput: terminalAnnounceOutput,
                onFailure: { model.attachmentFailed($0, id: attachmentID) },
                onEnded: { model.attachmentEnded(id: attachmentID, client: client) }
            )
            .id(attachmentID)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func disconnected(_ session: LocalSessionInfo, client: LocalAgentClient) -> some View {
        ContentUnavailableView {
            Label(model.ended ? String(localized: "Session Ended", bundle: .main) : String(localized: "Terminal Disconnected", bundle: .main), systemImage: "terminal")
        } description: {
            Text(String(localized: "Connect to this session, or refresh the session list.", bundle: .main))
        } actions: {
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
                        HStack(spacing: 12) {
                            PrimaryButton(String(localized: "New Session", bundle: .main), action: newSession)
                                .disabled(!canCreate)
                            Button(String(localized: "New SSH Connection", bundle: .main), action: newSSHConnection)
                                .buttonStyle(.bordered)
                                .witermControl()
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

struct NewLocalSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = String(localized: "New Terminal", bundle: .main)
    @State private var invalid = false
    let onCreate: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                IconTile(systemImage: "terminal")
                Text(String(localized: "New Terminal Session", bundle: .main)).font(.headline)
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
                PrimaryButton(String(localized: "Create", bundle: .main), action: create)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("createLocalSession")
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
#endif
