#if os(iOS)
import SwiftUI
import WitermCore

/// One paired device's sessions and live terminal, for one server.
/// The Terminals tab shows it once a Mac is chosen. Navigation follows
/// the model's state rather than a pushed stack, so the renderer stays alive
/// until a detach ACK confirms control was released.
struct RemoteTerminalWorkspace: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    let model: RemoteTerminalModel
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(TerminalFontSize.key) private var terminalFontSize = TerminalFontSize.standard
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage("witerm.terminalHighContrast") private var terminalHighContrast = false
    @AppStorage(TerminalColorScheme.key) private var terminalPalette = TerminalColorScheme.system
    @AppStorage("witerm.terminalAnnounceOutput") private var terminalAnnounceOutput = false
    @ScaledMetric(relativeTo: .body) private var scaledTerminalFont = 14.0
    @State private var showingAppearance = false
    @State private var keyboardRequest = 0
    @State private var finder = TerminalFinder()
    @State private var finding = false
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
        .background(model.displayAttachment != nil && compactTerminal ? terminalBackground : WitermTheme.canvas)
        .edgeSwipeBack(enabled: model.busy == nil && (model.displayAttachment != nil || model.selectedGrant != nil), action: goBack)
        .navigationTitle(navigationTitle)
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
                    Button(String(localized: "Terminals", bundle: .main), systemImage: "chevron.backward") { model.loadDevices() }
                        .labelStyle(.titleAndIcon)
                        .disabled(model.busy != nil)
                        .accessibilityIdentifier("remoteChooseMac")
                }
            }
            // On iPhone the bar names the session and holds its actions, so
            // the terminal gets the screen instead of a second header.
            if compactTerminal, let attachment = model.displayAttachment {
                ToolbarItem(placement: .principal) { compactTitle(attachment) }
                // Two buttons leave the title room; switching between typing
                // and watching is rarer now that devices type together.
                ToolbarItemGroup(placement: .primaryAction) {
                    terminalKeyboardButton
                    Menu(String(localized: "Terminal Actions", bundle: .main), systemImage: "ellipsis.circle") {
                        terminalControlButton
                        terminalSecondaryActions
                    }
                    .accessibilityIdentifier("terminalActionsMenu")
                }
            }
        }
        .task {
            // Returning to the tab resumes where the person left off; a kept
            // last frame waits for a reconnect.
            if model.displayAttachment == nil { model.refreshSessions() }
        }
        // Going back to the device list has already cleared the selection and
        // started reloading devices; suspending then would cancel that load.
        .onDisappear { if model.selectedGrant != nil { model.suspend() } }
        .sheet(isPresented: $showingAppearance) { TerminalAppearanceSettings() }
    }

    private var navigationTitle: String {
        if compactTerminal, let attachment = model.displayAttachment { return attachment.session.name }
        return model.selectedGrant?.host.name ?? String(localized: "Terminals", bundle: .main)
    }

    private var compactTerminal: Bool { sizeClass == .compact }

    /// The edge swipe and the back button: from a terminal to its sessions,
    /// from sessions to the list of terminals.
    private func goBack() {
        if model.displayAttachment != nil { model.showSessions() } else if model.selectedGrant != nil { model.loadDevices() }
    }

    /// The session's name, and under it the Mac with an icon for typing or
    /// watching; the status words are spoken rather than shown.
    private func compactTitle(_ attachment: RemoteTerminalAttachment) -> some View {
        VStack(spacing: 1) {
            Text(attachment.session.name)
                .font(.headline)
                .foregroundStyle(WitermTheme.ink)
            HStack(spacing: 4) {
                Image(systemName: terminalStatusImage)
                    .foregroundStyle(model.isInteractive ? WitermTheme.positive : WitermTheme.secondary)
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(verbatim: model.selectedGrant?.host.name ?? "")
            }
            .font(.caption)
            .foregroundStyle(WitermTheme.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([model.selectedGrant?.host.name, terminalStatus].compactMap { $0 }.joined(separator: ", "))
            .accessibilityIdentifier("terminalInputStatus")
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// The terminal's own background, so the area under the home indicator
    /// continues the terminal instead of showing a band.
    private var terminalBackground: Color {
        let dark = systemColorScheme == .dark
        if terminalHighContrast || contrast == .increased { return dark ? .black : .white }
        guard let values = terminalPalette.values(dark: dark) else { return Color(uiColor: .systemBackground) }
        return Color(uiColor: UIColor(terminalRGB: values.background))
    }

    private var browser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OfflineBanner()
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
        // Pull down to list the Mac's sessions again; the list also reloads
        // when it appears and when the app returns.
        .refreshable {
            model.refreshSessions()
            while model.busy != nil, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .accessibilityIdentifier("remoteSessionsList")
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
                StatusBadge(grant.permission == .view ? String(localized: "View Only", bundle: .main) : String(localized: "Can Type", bundle: .main),
                            systemImage: grant.permission == .view ? "eye" : "keyboard")
            }
            .padding(.top, 4)
            ForEach(model.sessions) { session in
                let access = model.access(for: session)
                HStack(spacing: 12) {
                    Button { model.attach(session) } label: {
                        HStack(spacing: 14) {
                            IconTile(systemImage: "terminal", tint: grant.host.identityHue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.name).font(.headline).foregroundStyle(WitermTheme.ink)
                                Text(access == .control ? String(localized: "Open to Type", bundle: .main) : String(localized: "View Only", bundle: .main))
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
                    if access == .control {
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
                ContentUnavailableView(String(localized: "No Available Sessions", bundle: .main), systemImage: "terminal", description: Text(String(localized: "Share a terminal session on the device, then pull down to refresh.", bundle: .main)))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("remoteSessionsEmpty")
            }
        }
    }

    private func terminal(_ attachment: RemoteTerminalAttachment) -> some View {
        let id = model.attachmentID
        return VStack(spacing: 0) {
            if compactTerminal {
                // The Mac's hue edges the terminal, so it always shows where input goes.
                Rectangle()
                    .fill((model.selectedGrant?.host.identityHue ?? WitermTheme.secondary).opacity(0.55))
                    .frame(height: 2)
                    .accessibilityHidden(true)
            } else {
                // The navigation bar already names the Mac.
                TerminalHeader(attachment.session.name, status: terminalStatus, statusImage: terminalStatusImage,
                               live: model.isInteractive, hue: model.selectedGrant?.host.identityHue) {
                    terminalActions
                }
            }
            OfflineBanner(insets: EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            if let notice = model.notice {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "eye").accessibilityHidden(true)
                    Text(notice).frame(maxWidth: .infinity, alignment: .leading)
                    Button(String(localized: "Dismiss", bundle: .main), systemImage: "xmark", action: model.dismissNotice)
                        .labelStyle(.iconOnly)
                        .touchTarget(square: true)
                }
                .font(.subheadline)
                .padding(.horizontal, 16)
                .background(WitermTheme.surface)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("remoteTerminalNotice")
            }
            if finding {
                TerminalFindBar(finder: finder) { finding = false }
                Divider()
            }
            ZStack(alignment: .top) {
                RemoteNativeTerminalView(
                    attachment: attachment, mode: model.mode, keyboardRequest: keyboardRequest,
                    isInteractive: model.isInteractive,
                    fontSize: CGFloat(scaledTerminalFont * TerminalFontSize.clamped(terminalFontSize) / TerminalFontSize.standard),
                    highContrast: terminalHighContrast || contrast == .increased,
                    preferredColorScheme: systemColorScheme,
                    palette: terminalPalette,
                    announceOutput: terminalAnnounceOutput,
                    finder: finder,
                    inputDestination: model.selectedGrant.map { $0.host.name + " · " + attachment.session.name },
                    onFailure: { model.attachmentFailed($0, id: id) },
                    onEnded: { model.attachmentEnded(id: id) }
                )
                .id(id)
                if !model.isInteractive { connectionOverlay }
            }
            // Keeps terminal contents out of the app switcher's snapshot.
            .overlay {
                if scenePhase != .active {
                    Rectangle().fill(WitermTheme.canvas)
                        .overlay { Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(WitermTheme.secondary) }
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var terminalStatus: String {
        if model.isInteractive {
            return model.mode == .view ? String(localized: "View Only", bundle: .main) : String(localized: "Input Enabled", bundle: .main)
        }
        if let busy = model.busy { return busy }
        if model.connectionState == .ended { return String(localized: "Session Ended", bundle: .main) }
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
            Button(String(localized: "Find in Terminal", bundle: .main), systemImage: "magnifyingglass") { finding = true }
                .keyboardShortcut("f", modifiers: .command)
                .touchTarget(square: true)
                .accessibilityIdentifier("terminalFind")
            Button(String(localized: "Display", bundle: .main), systemImage: "textformat.size") { showingAppearance = true }
                .touchTarget(square: true)
                .accessibilityIdentifier("terminalAppearance")
            Button(String(localized: "Sessions", bundle: .main), systemImage: "list.bullet") { model.showSessions() }
                .touchTarget(square: true)
                .disabled(model.busy != nil)
                .accessibilityIdentifier("remoteSessionListInline")
            if model.isInteractive {
                Button(String(localized: "Leave", bundle: .main), systemImage: "rectangle.portrait.and.arrow.right") { model.disconnect() }
                    .touchTarget(square: true)
                    .accessibilityIdentifier("detachRemoteTerminal")
            }
        }
    }

    @ViewBuilder private var terminalControlButton: some View {
        if model.isInteractive, model.canRequestControl {
            Button(model.mode == .control ? String(localized: "Watch Only", bundle: .main) : String(localized: "Start Typing", bundle: .main), systemImage: model.mode == .control ? "eye" : "keyboard") {
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
