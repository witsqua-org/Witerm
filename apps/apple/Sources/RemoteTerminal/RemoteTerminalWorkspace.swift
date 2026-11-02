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
                // Symbols alone; the spoken labels name where they go.
                if model.displayAttachment != nil {
                    Button(model.selectedGrant?.host.name ?? String(localized: "Terminals", bundle: .main),
                           systemImage: "chevron.backward") { model.showSessions() }
                        .labelStyle(.iconOnly)
                        .disabled(model.busy != nil)
                        .accessibilityIdentifier("remoteSessionList")
                } else if model.selectedGrant != nil {
                    Button(String(localized: "Terminals", bundle: .main), systemImage: "chevron.backward") { model.loadDevices() }
                        .labelStyle(.iconOnly)
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

    /// Other sessions this device may open, for switching from the title.
    /// Switching goes through `attach`, which waits for the detach ACK.
    private func otherSessions(than attachment: RemoteTerminalAttachment) -> [LocalSessionInfo] {
        model.sessions.filter { $0.id != attachment.session.id }
    }

    /// The terminal's name, and under it whether you're typing or watching
    /// (or what is happening instead) and the device it runs on. The state
    /// comes first, so a long device name never truncates it. With other
    /// terminals available, a chevron beside it switches to one.
    private func compactTitle(_ attachment: RemoteTerminalAttachment) -> some View {
        let others = otherSessions(than: attachment)
        return HStack(spacing: 2) {
            compactTitleText(attachment)
            if !others.isEmpty {
                TerminalSwitcher(names: others.map(\.name)) { model.attach(others[$0]) }
                    .disabled(model.busy != nil)
            }
        }
    }

    private func compactTitleText(_ attachment: RemoteTerminalAttachment) -> some View {
        VStack(spacing: 1) {
            Text(attachment.session.name)
                .font(.headline)
                .foregroundStyle(WitermTheme.ink)
            HStack(spacing: 4) {
                Image(systemName: terminalStatusImage)
                    .foregroundStyle(model.isInteractive ? WitermTheme.positive : WitermTheme.secondary)
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(verbatim: [terminalStatus, typingWhileWatching ?? model.selectedGrant?.host.name].compactMap { $0 }.joined(separator: " · "))
            }
            .font(.caption)
            .foregroundStyle(WitermTheme.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([terminalStatus, typingWhileWatching ?? model.selectedGrant?.host.name].compactMap { $0 }.joined(separator: ", "))
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
        TerminalBackdrop.color(dark: systemColorScheme == .dark, highContrast: terminalHighContrast || contrast == .increased,
                               palette: terminalPalette)
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
                    IssueBanner(title(of: issue), message: issue.recovery, systemImage: "exclamationmark.shield.fill") {
                        if issue.canViewReadOnly, let session = model.selectedSession {
                            Button(String(localized: "Watch", bundle: .main)) { model.attach(session, mode: .view) }
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
            // A terminal that didn't open (the banner above says why), or
            // whose opening was cancelled: it never connected, so try again.
            if let session = model.selectedSession, model.busy == nil {
                VStack(alignment: .leading, spacing: 12) {
                    Label(session.name, systemImage: "terminal").font(.headline)
                    PrimaryButton(String(localized: "Try Again", bundle: .main), systemImage: "arrow.clockwise") {
                        model.reconnect()
                    }
                    .accessibilityIdentifier("reconnectRemoteTerminal")
                }
                .witermCard()
            }
            // Typing is the norm, so only its absence is stated.
            if grant.permission == .view {
                StatusBadge(String(localized: "Can only watch", bundle: .main), systemImage: "eye")
                    .padding(.top, 4)
            }
            ForEach(model.sessions) { session in
                let access = model.access(for: session)
                Button { model.attach(session) } label: {
                    HStack(spacing: 14) {
                        IconTile(systemImage: "terminal", tint: grant.host.identityHue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.name).font(.headline).foregroundStyle(WitermTheme.ink)
                            // Who else types there, as of this list; the badge
                            // above already covers a device that can only watch.
                            let detail = [TypingElsewhere.summary(session.writers, hostName: grant.host.name),
                                          access == .view && grant.permission != .view
                                            ? String(localized: "Can only watch", bundle: .main) : nil].compactMap { $0 }
                            if !detail.isEmpty {
                                Text(detail.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(WitermTheme.secondary)
                            }
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
                .accessibilityValue(access == .control ? String(localized: "Can watch and type", bundle: .main) : String(localized: "Can only watch", bundle: .main))
                // Watching a session you could type in is rare: one long press
                // away, and a VoiceOver action, instead of a button on every row.
                .contextMenu {
                    if access == .control {
                        Button(String(localized: "Watch", bundle: .main), systemImage: "eye") { model.attach(session, mode: .view) }
                    }
                }
                .accessibilityActions {
                    if access == .control {
                        Button(String(localized: "Watch", bundle: .main)) { model.attach(session, mode: .view) }
                    }
                }
                .witermCard(padding: 14)
                .disabled(model.busy != nil)
            }
            if model.loaded, model.sessions.isEmpty, model.busy == nil {
                ContentUnavailableView(String(localized: "No Terminals", bundle: .main), systemImage: "terminal", description: Text(String(localized: "On the other device, choose Open On ▸ \(PairingDeviceName.current).", bundle: .main)))
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
                TerminalHeader(attachment.session.name,
                               status: [terminalStatus, typingWhileWatching].compactMap { $0 }.joined(separator: " · "),
                               statusImage: terminalStatusImage,
                               live: model.isInteractive, hue: model.selectedGrant?.host.identityHue) {
                    terminalActions
                }
            }
            OfflineBanner(insets: EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            if model.notice {
                let notice = TypingElsewhere.watchingNotice(model.openWriters, hostName: model.selectedGrant?.host.name ?? "")
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
            // While watching a terminal this device could type in, list it
            // again every few seconds so the title keeps saying who types.
            // Stops when typing, leaving, or in the background; slows down
            // while the list can't be had.
            .task(id: pollsWriters) {
                guard pollsWriters else { return }
                var delay = 3.0
                while !Task.isCancelled {
                    delay = await model.refreshWriters() ? 3 : min(delay * 2, 30)
                    try? await Task.sleep(for: .seconds(delay))
                }
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

    private var pollsWriters: Bool {
        scenePhase == .active && model.isInteractive && model.mode == .view && model.canRequestControl
    }

    /// While watching: where typing is (Typing on *device*), when the Mac says.
    private var typingWhileWatching: String? {
        guard model.isInteractive, model.mode == .view, let grant = model.selectedGrant else { return nil }
        return TypingElsewhere.summary(model.openWriters, hostName: grant.host.name)
    }

    /// An issue's title, naming who types when that's why typing was refused.
    private func title(of issue: RemoteTerminalIssue) -> String {
        guard issue.typingElsewhere, let grant = model.selectedGrant else { return issue.title }
        return TypingElsewhere.busyTitle(model.openWriters, hostName: grant.host.name)
    }

    /// Your own view of the terminal: Typing or Watching, or what is
    /// happening instead (switching, leaving, disconnected, ended).
    private var terminalStatus: String {
        if model.isInteractive {
            return model.mode == .view ? String(localized: "Watching", bundle: .main) : String(localized: "Typing", bundle: .main)
        }
        if let busy = model.busy { return busy }
        if model.connectionState == .ended { return String(localized: "Terminal Ended", bundle: .main) }
        return String(localized: "Disconnected", bundle: .main)
    }

    private var terminalStatusImage: String {
        guard model.isInteractive else { return model.busy != nil ? "arrow.triangle.2.circlepath" : "bolt.horizontal.circle" }
        return model.mode == .view ? "eye" : "keyboard"
    }

    /// iPad's header: the actions menu and the keyboard. Typing or watching
    /// lives in the menu, as on iPhone, since devices now type together.
    private var terminalActions: some View {
        HStack(spacing: typeSize.isAccessibilitySize ? 12 : 8) {
            Menu(String(localized: "Terminal Actions", bundle: .main), systemImage: "ellipsis.circle") { terminalSecondaryActions }
                .labelStyle(.iconOnly)
                .touchTarget(square: true)
                .accessibilityIdentifier("terminalActionsMenu")
            terminalKeyboardButton
        }
        .font(.subheadline)
    }

    /// Text size first (the most frequent), then find and display, typing or
    /// watching, and Leave last. The back button already lists the sessions.
    @ViewBuilder private var terminalSecondaryActions: some View {
        TerminalTextSizeControls()
        Button(String(localized: "Find in Terminal", bundle: .main), systemImage: "magnifyingglass") { finding = true }
            .keyboardShortcut("f", modifiers: .command)
            .accessibilityIdentifier("terminalFind")
        Button(String(localized: "Terminal Display", bundle: .main), systemImage: "paintpalette") { showingAppearance = true }
            .accessibilityIdentifier("terminalAppearance")
        terminalControlButton
        if model.isInteractive {
            Divider()
            // Back to the device's terminals, where this one is still listed:
            // leaving never looks like a dropped connection.
            Button(String(localized: "Leave", bundle: .main), systemImage: "rectangle.portrait.and.arrow.right") { model.showSessions() }
                .accessibilityHint(String(localized: "The terminal keeps running.", bundle: .main))
                .accessibilityIdentifier("detachRemoteTerminal")
        }
    }

    /// The title says what tapping does from the current state, and the
    /// title bar shows the switch at once. A terminal this device can only
    /// watch says so here, where someone looking for typing would look.
    @ViewBuilder private var terminalControlButton: some View {
        if model.isInteractive, model.canRequestControl {
            Button(model.mode == .control ? String(localized: "Stop Typing", bundle: .main) : String(localized: "Start Typing", bundle: .main), systemImage: model.mode == .control ? "eye" : "keyboard") {
                model.switchMode()
            }
            .accessibilityIdentifier("switchRemoteControl")
        } else if model.isInteractive {
            Button {} label: {
                Label(String(localized: "Start Typing", bundle: .main), systemImage: "keyboard")
                Text(String(localized: "Can only watch", bundle: .main))
            }
            .disabled(true)
            .accessibilityIdentifier("switchRemoteControl")
        }
    }

    @ViewBuilder private var terminalKeyboardButton: some View {
        if model.isInteractive, model.mode == .control {
            TerminalKeyboardButton(terminal: { [finder] in finder.terminal }) { keyboardRequest += 1 }
                .id(model.attachmentID)
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

    /// What happened and one clear next step: Reconnect when it can work,
    /// otherwise back to the sessions (the back button also goes there).
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
                Text(model.connectionState == .ended ? String(localized: "Terminal Ended", bundle: .main) : (model.issue.map(title(of:)) ?? String(localized: "Terminal Disconnected", bundle: .main)))
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
                            Button(String(localized: "Watch", bundle: .main)) { model.reconnect(as: .view) }.touchTarget()
                                .accessibilityIdentifier("reconnectRemoteReadOnly")
                        }
                    }
                } else {
                    PrimaryButton(String(localized: "Back to Terminals", bundle: .main), systemImage: "list.bullet") { model.showSessions() }
                        .accessibilityIdentifier("remoteDisconnectedSessionList")
                }
            }
        }
    }

}

#endif
