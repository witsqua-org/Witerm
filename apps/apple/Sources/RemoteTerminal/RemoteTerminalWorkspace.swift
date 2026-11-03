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
    @State private var keyboardRequest = 0
    @State private var finder = TerminalFinder()
    @State private var finding = false
    /// Mirrors whether a terminal is shown, changed without animation; see
    /// `SSHWorkspaceView.show(_:)` for why the tab bar must not animate.
    @State private var terminalShown = false
    /// See `TerminalTypingBar`.
    @State private var typingBarHidden = false


    var body: some View {
        Group {
            // Shown only while a terminal (or its kept last frame) is
            // displayed: each device's terminals are listed in Terminals.
            if let attachment = model.displayAttachment {
                terminal(attachment)
            }
        }
        .background(model.displayAttachment != nil && compactTerminal ? terminalBackground : WitermTheme.canvas)
        .edgeSwipeBack(enabled: model.busy == nil && (model.displayAttachment != nil || model.selectedGrant != nil), action: goBack)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(model.selectedGrant == nil ? .large : .inline)
        // iPhone gives the terminal the whole screen; iPad keeps the tabs.
        .toolbar(terminalShown && compactTerminal ? .hidden : .automatic, for: .tabBar)
        .modifier(TerminalTypingBar(terminal: { [finder] in finder.terminal }, identity: model.attachmentID,
                                    enabled: compactTerminal && model.displayAttachment != nil, barHidden: $typingBarHidden))
        .onReceive(NotificationCenter.default.publisher(for: .witermFindInTerminal)) { _ in
            if model.displayAttachment != nil { finding = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .witermFindStep)) { _ in
            if model.displayAttachment != nil { finding = true }
        }
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
                // One button leaves the title room; the keyboard button is at
                // the terminal's bottom right, under the thumb.
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu(String(localized: "Terminal Actions", bundle: .main), systemImage: WitermSymbols.more) {
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
        // Hiding the keyboard stops typing: the Mac's grid is authoritative
        // again and this device no longer resizes it.
        .onReceive(NotificationCenter.default.publisher(for: .witermTerminalFocusChanged)) { note in
            guard (note.object as AnyObject?) === finder.terminal, note.userInfo?["focused"] as? Bool == false else { return }
            stopTypingIfKeyboardStaysHidden()
        }
        .onChange(of: finding) { _, open in if !open { stopTypingIfKeyboardStaysHidden() } }
        // Typing and watching switch with a tick, as well as the title change.
        .sensoryFeedback(.selection, trigger: model.isInteractive ? model.mode : nil)
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
        return HStack(spacing: WitermMetrics.Space.xxs) {
            compactTitleText(attachment)
            if !others.isEmpty {
                TerminalSwitcher(names: others.map(\.name)) { model.attach(others[$0]) }
                    .disabled(model.busy != nil)
            }
        }
    }

    private func compactTitleText(_ attachment: RemoteTerminalAttachment) -> some View {
        VStack(spacing: 0) {
            Text(attachment.session.name)
                .font(WitermType.cardTitle)
                .foregroundStyle(WitermTheme.ink)
            HStack(spacing: WitermMetrics.Space.xs) {
                Image(systemName: terminalStatusImage)
                    .foregroundStyle(model.isInteractive ? WitermTheme.positive : WitermTheme.secondary)
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(verbatim: [terminalStatus, typingWhileWatching ?? model.selectedGrant?.host.name].compactMap { $0 }.joined(separator: " · "))
            }
            .font(WitermType.meta)
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

    private func terminal(_ attachment: RemoteTerminalAttachment) -> some View {
        let id = model.attachmentID
        return VStack(spacing: 0) {
            if compactTerminal {
                // The Mac's hue edges the terminal, so it always shows where input goes.
                Rectangle()
                    .fill(WitermTheme.edge(model.selectedGrant?.host.identityHue ?? WitermTheme.secondary))
                    .frame(height: 2)
                    .accessibilityHidden(true)
            } else {
                // The navigation bar already names the Mac.
                TerminalHeader(attachment.session.name,
                               status: [terminalStatus, typingWhileWatching].compactMap { $0 }.joined(separator: " · ")
                                   .nilIfEmpty ?? String(localized: "Connected", bundle: .main),
                               statusImage: terminalStatusImage,
                               live: model.isInteractive, hue: model.selectedGrant?.host.identityHue) {
                    terminalActions
                }
            }
            OfflineBanner(insets: EdgeInsets(top: WitermMetrics.Space.s, leading: WitermMetrics.Space.l,
                                             bottom: WitermMetrics.Space.s, trailing: WitermMetrics.Space.l))
            if model.notice {
                let notice = TypingElsewhere.watchingNotice(model.openWriters, hostName: model.selectedGrant?.host.name ?? "")
                HStack(alignment: .firstTextBaseline, spacing: WitermMetrics.Space.s) {
                    Image(systemName: WitermSymbols.watching).accessibilityHidden(true)
                    Text(notice).frame(maxWidth: .infinity, alignment: .leading)
                    Button(String(localized: "Dismiss", bundle: .main), systemImage: "xmark", action: model.dismissNotice)
                        .labelStyle(.iconOnly)
                        .touchTarget(square: true)
                }
                .font(WitermType.rowDetail)
                .padding(.horizontal, WitermMetrics.Space.l)
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
                    fontSize: CGFloat(TerminalFontSize.clamped(terminalFontSize)) * TerminalTextScale.factor(typeSize),
                    highContrast: terminalHighContrast || contrast == .increased,
                    preferredColorScheme: systemColorScheme,
                    palette: terminalPalette,
                    announceOutput: terminalAnnounceOutput,
                    finder: finder,
                    inputDestination: model.selectedGrant.map { $0.host.name + " · " + attachment.session.name },
                    barActions: typingBarHidden ? keyRowActions : nil,
                    keyboardButton: startTyping,
                    onFailure: { model.attachmentFailed($0, id: id) },
                    onEnded: { model.attachmentEnded(id: id) }
                )
                .id(id)
                // The renderer leaves the keyboard's space itself (see
                // `TerminalKeyboardOverlap`).
                .ignoresSafeArea(.keyboard, edges: .bottom)
                // Showing or hiding the keyboard switches without covering
                // the terminal; the title says it's under way.
                if !model.isInteractive, model.connectionState != .switching { connectionOverlay }
            }
            // While watching a terminal this device could type in, list it
            // again every 10 seconds so the title keeps saying who types.
            // Each list opens a relay tunnel and the server allows a device
            // 30 a minute, so this stays at 6. Stops when typing, leaving, or
            // in the background; slows down while the list can't be had.
            .task(id: pollsWriters) {
                guard pollsWriters else { return }
                var delay = 10.0
                while !Task.isCancelled {
                    delay = await model.refreshWriters() ? 10 : min(delay * 2, 60)
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
            // Keeps terminal contents out of the app switcher's snapshot.
            .overlay {
                if scenePhase != .active {
                    Rectangle().fill(WitermTheme.canvas)
                        .overlay { Image(systemName: WitermSymbols.keptPrivate).font(.largeTitle).foregroundStyle(WitermTheme.secondary) }
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

    /// Plain facts only, never a mode: Can only watch when that's the
    /// grant, or what is happening instead (the keyboard switching, leaving,
    /// disconnected, ended). Nil while connected otherwise; the keyboard
    /// itself shows whether you're typing.
    private var terminalStatus: String? {
        if model.isInteractive {
            return model.canRequestControl ? nil : String(localized: "Can only watch", bundle: .main)
        }
        if let busy = model.busy { return busy }
        if model.connectionState == .ended { return String(localized: "Terminal Ended", bundle: .main) }
        return String(localized: "Disconnected", bundle: .main)
    }

    private var terminalStatusImage: String {
        guard model.isInteractive else { return model.busy != nil ? "arrow.triangle.2.circlepath" : WitermSymbols.disconnected }
        return model.canRequestControl ? WitermSymbols.connected : WitermSymbols.watching
    }

    /// iPad's header: the actions menu. The keyboard button is at the
    /// terminal's bottom right, as on iPhone.
    private var terminalActions: some View {
        HStack(spacing: typeSize.isAccessibilitySize ? WitermMetrics.Space.m : WitermMetrics.Space.s) {
            Menu(String(localized: "Terminal Actions", bundle: .main), systemImage: WitermSymbols.more) { terminalSecondaryActions }
                .labelStyle(.iconOnly)
                .touchTarget(square: true)
                .accessibilityIdentifier("terminalActionsMenu")
        }
        .font(WitermType.rowDetail)
    }

    /// The bar's actions menu as the key row's last key, tinted like the bar.
    private var keyRowActions: AnyView {
        AnyView(TerminalKeyRowActions { terminalSecondaryActions }.tint(model.selectedGrant?.host.identityHue))
    }

    /// Text and Colors first (the most frequent), then Find, and Leave last.
    /// Typing follows the keyboard, so there's no switch here.
    @ViewBuilder private var terminalSecondaryActions: some View {
        TerminalTextAndColorsMenu()
        Button(String(localized: "Find in Terminal", bundle: .main), systemImage: "magnifyingglass") { finding = true }
            .accessibilityIdentifier("terminalFind")
        if model.isInteractive {
            Divider()
            // Back to Terminals, where this one is still listed in its
            // device's section: leaving never looks like a dropped connection.
            Button(String(localized: "Leave", bundle: .main), systemImage: WitermSymbols.leave) { model.showSessions() }
                .accessibilityHint(String(localized: "The terminal keeps running.", bundle: .main))
                .accessibilityIdentifier("detachRemoteTerminal")
        }
    }

    /// The keyboard button's action while watching a terminal this device
    /// may type in: the Mac is asked for typing (after the detach ACK of the
    /// watching connection), and the keyboard rises once it accepts. Taking
    /// typing is always this explicit tap; a refusal leaves the keyboard
    /// down and says who is typing. Nil hides the button: while typing (the
    /// key row's Hide Keyboard takes its place), and when this device can
    /// only watch.
    private var startTyping: (() -> Void)? {
        guard model.isInteractive, model.mode == .view, model.canRequestControl else { return nil }
        return { model.switchMode() }
    }

    /// The keyboard went down (Hide Keyboard, a swipe on the keyboard, or
    /// the find bar closing without it): stop typing, after a moment in
    /// which focus may come straight back. Not while finding, while a sheet
    /// such as the paste review is up, or in the background, where the
    /// keyboard is down for another reason.
    private func stopTypingIfKeyboardStaysHidden() {
        let id = model.attachmentID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard model.attachmentID == id, model.isInteractive, model.mode == .control, !finding,
                  scenePhase == .active, finder.terminal?.isFirstResponder == false,
                  finder.terminal?.window?.rootViewController?.presentedViewController == nil else { return }
            model.switchMode()
        }
    }

    private var connectionOverlay: some View {
        ScrollView {
            connectionStatusContent
                .padding(WitermMetrics.cardPadding)
                .frame(maxWidth: WitermMetrics.readableWidth, alignment: .leading)
                .background {
                    if reduceTransparency || contrast == .increased {
                        RoundedRectangle(cornerRadius: WitermMetrics.cardRadius, style: .continuous).fill(WitermTheme.surface)
                    } else {
                        RoundedRectangle(cornerRadius: WitermMetrics.cardRadius, style: .continuous).fill(.regularMaterial)
                    }
                }
                .padding(WitermMetrics.Space.l)
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    /// What happened and one clear next step: Reconnect when it can work,
    /// otherwise back to the sessions (the back button also goes there).
    private var connectionStatusContent: some View {
        VStack(alignment: .leading, spacing: WitermMetrics.Space.m) {
            if let busy = model.busy {
                HStack(spacing: WitermMetrics.Space.m) {
                    ProgressView().accessibilityHidden(true)
                    Text(busy).font(WitermType.cardTitle)
                    Spacer(minLength: WitermMetrics.Space.s)
                    Button(String(localized: "Cancel", bundle: .main)) { model.cancelWork() }.touchTarget()
                }
                .accessibilityIdentifier("remoteTerminalActivity")
            } else {
                Text(model.connectionState == .ended ? String(localized: "Terminal Ended", bundle: .main) : (model.issue.map(title(of:)) ?? String(localized: "Disconnected", bundle: .main)))
                    .font(WitermType.cardTitle)
                    .accessibilityIdentifier("remoteDisconnectedStatus")
                if let issue = model.issue {
                    Text(issue.recovery).font(WitermType.rowDetail).foregroundStyle(WitermTheme.secondary)
                }
                if model.canReconnect {
                    VStack(alignment: .leading, spacing: WitermMetrics.Space.m) {
                        PrimaryButton(String(localized: "Reconnect", bundle: .main), systemImage: "arrow.clockwise") { model.reconnect() }
                            .accessibilityIdentifier("reconnectRemoteTerminal")
                    }
                } else {
                    PrimaryButton(String(localized: "Back to Terminals", bundle: .main), systemImage: "list.bullet") { model.showSessions() }
                        .accessibilityIdentifier("remoteDisconnectedSessionList")
                }
            }
        }
    }

}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif
