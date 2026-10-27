#if os(iOS)
import SwiftUI
import WitermCore

/// One paired device's sessions and live terminal, for one server.
/// `RemoteDevicesView` shows it once a device is selected. Navigation follows
/// the model's state rather than a pushed stack, so the renderer stays alive
/// until a detach ACK confirms control was released.
struct RemoteTerminalWorkspace: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    let model: RemoteTerminalModel
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(TerminalFontSize.key) private var terminalFontSize = TerminalFontSize.standard
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage("witerm.terminalHighContrast") private var terminalHighContrast = false
    @AppStorage("witerm.terminalAnnounceOutput") private var terminalAnnounceOutput = false
    @ScaledMetric(relativeTo: .body) private var scaledTerminalFont = 14.0
    @State private var showingAppearance = false
    @State private var keyboardRequest = 0
    /// Mirrors whether a terminal is shown, changed without animation; see
    /// `SSHWorkspaceView.show(_:)` for why the tab bar must not animate.
    @State private var terminalShown = false


    var body: some View {
        Group {
            if let attachment = model.displayAttachment {
                terminal(attachment)
            } else {
                browser
            }
        }
        .background(WitermTheme.canvas)
        .navigationTitle(model.selectedGrant?.host.name ?? String(localized: "Devices", bundle: .main))
        .navigationBarTitleDisplayMode(model.selectedGrant == nil ? .large : .inline)
        .toolbar(terminalShown ? .hidden : .automatic, for: .tabBar)
        .onChange(of: model.displayAttachment != nil, initial: true) { _, shown in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { terminalShown = shown }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if model.displayAttachment != nil {
                    Button(String(localized: "Sessions", bundle: .main), systemImage: "chevron.backward") { model.showSessions() }
                        .labelStyle(.titleAndIcon)
                        .disabled(model.busy != nil)
                        .accessibilityIdentifier("remoteSessionList")
                } else if model.selectedGrant != nil {
                    Button(String(localized: "Devices", bundle: .main), systemImage: "chevron.backward") { model.loadDevices() }
                        .labelStyle(.titleAndIcon)
                        .disabled(model.busy != nil)
                        .accessibilityIdentifier("remoteChooseMac")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if model.displayAttachment == nil {
                    Button(String(localized: "Refresh", bundle: .main), systemImage: "arrow.clockwise", action: model.refreshSessions)
                    .disabled(model.busy != nil)
                    .accessibilityIdentifier("refreshRemoteSessions")
                }
            }
        }
        .task {
            // Returning to the tab resumes where the person left off; a kept
            // last frame waits for an explicit reconnect.
            if model.displayAttachment == nil { model.refreshSessions() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.suspend() }
        }
        // Going back to the device list has already cleared the selection and
        // started reloading devices; suspending then would cancel that load.
        .onDisappear { if model.selectedGrant != nil { model.suspend() } }
        .sheet(isPresented: $showingAppearance) { TerminalAppearanceSettings() }
    }

    private var browser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let busy = model.busy {
                    ActivityRow(busy) { model.cancelWork() }
                        .accessibilityIdentifier("remoteTerminalActivity")
                }
                if let issue = model.issue {
                    IssueBanner(issue.title, message: issue.recovery, systemImage: "exclamationmark.shield.fill") {
                        if issue.canViewReadOnly, let session = model.selectedSession {
                            Button(String(localized: "View Only", bundle: .main)) { model.attach(session, mode: .view) }
                                .touchTarget().disabled(model.busy != nil)
                        }
                    }
                    .accessibilityIdentifier("remoteTerminalError")
                }
                if let grant = model.selectedGrant {
                    sessions(for: grant)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
    }

    private func sessions(for grant: DeviceGrant) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let session = model.selectedSession, model.busy == nil {
                VStack(alignment: .leading, spacing: 12) {
                    Label(String(localized: "Terminal Disconnected", bundle: .main), systemImage: "terminal").font(.headline)
                    Text(session.name).foregroundStyle(WitermTheme.secondary)
                    PrimaryButton(String(localized: "Reconnect", bundle: .main), systemImage: "arrow.clockwise") {
                        model.reconnect()
                    }
                    .accessibilityIdentifier("reconnectRemoteTerminal")
                }
                .witermCard()
            }
            HStack {
                Text(String(localized: "Terminal Sessions", bundle: .main)).font(.headline)
                Spacer()
                StatusBadge(grant.permission == .view ? String(localized: "Read-Only Permission", bundle: .main) : String(localized: "Control Permission", bundle: .main),
                            systemImage: grant.permission == .view ? "eye" : "keyboard")
            }
            .padding(.top, 4)
            ForEach(model.sessions) { session in
                HStack(spacing: 12) {
                    Button { model.attach(session) } label: {
                        HStack(spacing: 14) {
                            IconTile(systemImage: "terminal", tint: grant.host.identityHue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.name).font(.headline).foregroundStyle(WitermTheme.ink)
                                Text(String(localized: "\(String(session.columns)) columns · \(String(session.rows)) rows", bundle: .main))
                                    .font(.caption).foregroundStyle(WitermTheme.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(WitermTheme.secondary)
                                .accessibilityHidden(true)
                        }
                        .touchTarget()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("remoteSession-\(session.id)")
                    if grant.permission == .control {
                        Button(String(localized: "View Only", bundle: .main), systemImage: "eye") { model.attach(session, mode: .view) }
                            .labelStyle(.iconOnly)
                            .touchTarget(square: true)
                            .accessibilityLabel(String(localized: "View Only", bundle: .main))
                    }
                }
                .witermCard(padding: 14)
                .disabled(model.busy != nil)
            }
            if model.loaded, model.sessions.isEmpty, model.busy == nil {
                ContentUnavailableView(String(localized: "No Available Sessions", bundle: .main), systemImage: "terminal", description: Text(String(localized: "Share a terminal session on the device, then refresh the list.", bundle: .main)))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("remoteSessionsEmpty")
            }
        }
    }

    private func terminal(_ attachment: RemoteTerminalAttachment) -> some View {
        let id = model.attachmentID
        return VStack(spacing: 0) {
            TerminalHeader(attachment.session.name, status: terminalStatus, statusImage: terminalStatusImage, live: model.isInteractive,
                           hue: model.selectedGrant?.host.identityHue) {
                terminalActions
            }
            ZStack(alignment: .top) {
                RemoteNativeTerminalView(
                    attachment: attachment, mode: model.mode, keyboardRequest: keyboardRequest,
                    isInteractive: model.isInteractive,
                    fontSize: CGFloat(scaledTerminalFont * TerminalFontSize.clamped(terminalFontSize) / TerminalFontSize.standard),
                    highContrast: terminalHighContrast || contrast == .increased,
                    preferredColorScheme: systemColorScheme,
                    announceOutput: terminalAnnounceOutput,
                    onFailure: { model.attachmentFailed($0, id: id) },
                    onEnded: { model.attachmentEnded(id: id) }
                )
                .id(id)
                if !model.isInteractive { connectionOverlay }
            }
        }
    }

    private var terminalStatus: String {
        if model.isInteractive {
            return model.mode == .view ? String(localized: "View Only", bundle: .main) : String(localized: "Control Terminal", bundle: .main)
        }
        return model.busy != nil ? String(localized: "Connecting", bundle: .main) : String(localized: "Disconnected", bundle: .main)
    }

    private var terminalStatusImage: String {
        guard model.isInteractive else { return model.busy != nil ? "arrow.triangle.2.circlepath" : "bolt.horizontal.circle" }
        return model.mode == .view ? "eye" : "keyboard"
    }

    private var terminalActions: some View {
        Group {
            if typeSize.isAccessibilitySize {
                HStack(spacing: 12) {
                    Menu(String(localized: "Terminal Actions", bundle: .main), systemImage: "ellipsis") {
                        terminalSecondaryActions
                        terminalControlButton
                    }
                        .touchTarget(square: true)
                        .accessibilityIdentifier("terminalActionsMenu")
                    terminalKeyboardButton
                }
            } else {
                HStack(spacing: 8) {
                    Menu(String(localized: "Terminal Actions", bundle: .main), systemImage: "ellipsis.circle") { terminalSecondaryActions }
                        .labelStyle(.iconOnly)
                        .touchTarget(square: true)
                        .accessibilityIdentifier("terminalActionsMenu")
                    terminalControlButton
                    terminalKeyboardButton
                }
            }
        }
        .font(.subheadline)
    }

    @ViewBuilder private var terminalSecondaryActions: some View {
        Group {
            Button(String(localized: "Display", bundle: .main), systemImage: "textformat.size") { showingAppearance = true }
                .touchTarget(square: true)
                .accessibilityIdentifier("terminalAppearance")
            Button(String(localized: "Sessions", bundle: .main), systemImage: "list.bullet") { model.showSessions() }
                .touchTarget(square: true)
                .disabled(model.busy != nil)
                .accessibilityIdentifier("remoteSessionListInline")
            if model.isInteractive {
                Button(String(localized: "Disconnect", bundle: .main), systemImage: "eject") { model.disconnect() }
                    .touchTarget(square: true)
                    .accessibilityIdentifier("detachRemoteTerminal")
            }
        }
    }

    @ViewBuilder private var terminalControlButton: some View {
        if model.isInteractive, model.canRequestControl {
            Button(model.mode == .control ? String(localized: "Release Control", bundle: .main) : String(localized: "Request Control", bundle: .main), systemImage: model.mode == .control ? "eye" : "keyboard") {
                model.switchMode()
            }
            .touchTarget()
            .accessibilityIdentifier("switchRemoteControl")
        }
    }

    @ViewBuilder private var terminalKeyboardButton: some View {
        if model.isInteractive, model.mode == .control {
            Button(String(localized: "Keyboard", bundle: .main), systemImage: "keyboard") { keyboardRequest += 1 }
                .touchTarget(square: true)
                .accessibilityIdentifier("remoteKeyboard")
        }
    }

    private var connectionOverlay: some View {
        ScrollView {
            connectionStatusContent
                .padding(WitermMetrics.cardPadding)
                .frame(maxWidth: 600, alignment: .leading)
                .background {
                    if reduceTransparency || contrast == .increased {
                        RoundedRectangle(cornerRadius: WitermMetrics.cardRadius, style: .continuous).fill(WitermTheme.surface)
                    } else {
                        RoundedRectangle(cornerRadius: WitermMetrics.cardRadius, style: .continuous).fill(.regularMaterial)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var connectionStatusContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let busy = model.busy {
                HStack(spacing: 12) {
                    ProgressView().accessibilityHidden(true)
                    Text(busy).font(.headline)
                    Spacer(minLength: 8)
                    Button(String(localized: "Cancel", bundle: .main)) { model.cancelWork() }.touchTarget()
                }
                .accessibilityIdentifier("remoteTerminalActivity")
            } else {
                Text(model.connectionState == .ended ? String(localized: "Session Ended", bundle: .main) : (model.issue?.title ?? String(localized: "Terminal Disconnected", bundle: .main)))
                    .font(.headline)
                    .accessibilityIdentifier("remoteDisconnectedStatus")
                if let issue = model.issue {
                    Text(issue.recovery).font(.subheadline).foregroundStyle(WitermTheme.secondary)
                }
                if model.canReconnect {
                    VStack(alignment: .leading, spacing: 12) {
                        PrimaryButton(String(localized: "Reconnect", bundle: .main), systemImage: "arrow.clockwise") { model.reconnect() }
                            .accessibilityIdentifier("reconnectRemoteTerminal")
                        if model.reconnectMode == .control {
                            Button(String(localized: "Connect Read Only", bundle: .main)) { model.reconnect(as: .view) }.touchTarget()
                                .accessibilityIdentifier("reconnectRemoteReadOnly")
                        }
                    }
                }
                Button(String(localized: "Back to Sessions", bundle: .main), systemImage: "list.bullet") { model.showSessions() }
                    .touchTarget()
                    .accessibilityIdentifier("remoteDisconnectedSessionList")
            }
        }
    }

}

#endif
