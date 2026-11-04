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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    /// Round 20: the Connected Devices sheet.
    @State private var showingDevices = false


    var body: some View {
        Group {
            // Shown only while a terminal (or its kept last frame) is
            // displayed: each device's terminals are listed in Terminals.
            if let attachment = model.displayAttachment, let host = model.host {
                terminal(attachment, host: host)
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
            if !shown { showingDevices = false }
        }
        // Round 20: everyone connected to this terminal, live while open. A
        // keyboard that didn't come back when it closes stops typing, as
        // after Find.
        .sheet(isPresented: $showingDevices, onDismiss: stopTypingIfKeyboardStaysHidden) {
            ConnectedDevicesSheet(model: model)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // Symbols alone; the spoken labels name where they go.
                if model.displayAttachment != nil {
                    // Back keeps the terminal connected (Round 18), as for SSH.
                    Button(String(localized: "Terminals", bundle: .main),
                           systemImage: "chevron.backward") { model.leaveKeepingConnection() }
                        .labelStyle(.iconOnly)
                        .disabled(model.busy != nil)
                        .accessibilityHint(model.isInteractive ? String(localized: "The terminal stays connected.", bundle: .main)
                                           : String(localized: "Returns to your terminals.", bundle: .main))
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
        // Renderers made off screen (a terminal left typing) start at the
        // text size shown here.
        .onChange(of: rendererFontSize, initial: true) { _, size in RemoteTerminalModel.rendererFontSize = size }
        // No suspend when this disappears: the terminal stays connected
        // until Disconnect (Round 18); the model owns its renderer.
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
        if model.displayAttachment != nil { model.leaveKeepingConnection() } else if model.selectedGrant != nil { model.loadDevices() }
    }

    private var rendererFontSize: CGFloat {
        CGFloat(TerminalFontSize.clamped(terminalFontSize)) * TerminalTextScale.factor(typeSize)
    }

    /// Other sessions this device may open, for switching from the title.
    /// Switching goes through `attach`, which waits for the detach ACK.
    private func otherSessions(than attachment: any PairedTerminalLink) -> [LocalSessionInfo] {
        model.sessions.filter { $0.id != attachment.session.id }
    }

    /// The terminal's name, and under it whether you're typing or watching
    /// (or what is happening instead) and the device it runs on. The state
    /// comes first, so a long device name never truncates it. With other
    /// terminals available, a chevron beside it switches to one.
    private func compactTitle(_ attachment: any PairedTerminalLink) -> some View {
        let others = otherSessions(than: attachment)
        return HStack(spacing: WitermMetrics.Space.xxs) {
            compactTitleText(attachment)
            if !others.isEmpty {
                // The one shown now stays connected, as after Back.
                TerminalSwitcher(names: others.map(\.name)) { index in
                    if let grant = model.selectedGrant { model.open(others[index], on: grant) }
                }
                    .disabled(model.busy != nil)
            }
        }
    }

    private func compactTitleText(_ attachment: any PairedTerminalLink) -> some View {
        VStack(spacing: 0) {
            Text(attachment.session.name)
                .font(WitermType.cardTitle)
                .foregroundStyle(WitermTheme.ink)
            HStack(spacing: WitermMetrics.Space.xs) {
                Image(systemName: terminalStatusImage)
                    .foregroundStyle(model.isInteractive ? WitermTheme.positive : WitermTheme.secondary)
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(verbatim: statusFacts.joined(separator: " · "))
            }
            .font(WitermType.meta)
            .foregroundStyle(WitermTheme.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(statusFacts.joined(separator: ", "))
            .accessibilityIdentifier("terminalInputStatus")
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// The title's status line, in order of importance (a long name is cut
    /// from the end): what limits this device, how many devices are
    /// connected when others are (Round 20; never who types), then the Mac.
    private var statusFacts: [String] {
        [terminalStatus, deviceCount, model.selectedGrant?.host.name].compactMap { $0 }
    }

    /// "3 devices connected", this device included, while connected and
    /// others are too; nil when it's alone or the Mac doesn't say.
    private var deviceCount: String? {
        guard model.isInteractive else { return nil }
        return ConnectedDevices.count(model.connectedDevices)
    }

    /// The terminal's own background, so the area under the home indicator
    /// continues the terminal instead of showing a band.
    private var terminalBackground: Color {
        TerminalBackdrop.color(dark: systemColorScheme == .dark, highContrast: terminalHighContrast || contrast == .increased,
                               palette: terminalPalette)
    }

    private func terminal(_ attachment: any PairedTerminalLink, host: PairedTerminalHost) -> some View {
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
                               status: [terminalStatus, deviceCount].compactMap { $0 }.joined(separator: " · ")
                                   .nilIfEmpty ?? String(localized: "Connected", bundle: .main),
                               statusImage: terminalStatusImage,
                               live: model.isInteractive, hue: model.selectedGrant?.host.identityHue) {
                    terminalActions
                }
            }
            OfflineBanner(insets: EdgeInsets(top: WitermMetrics.Space.s, leading: WitermMetrics.Space.l,
                                             bottom: WitermMetrics.Space.s, trailing: WitermMetrics.Space.l))
            // Typing was refused, or a reconnect found it so: what happened
            // here, never who types (Round 20); Connected Devices says that.
            if model.notice {
                HStack(alignment: .firstTextBaseline, spacing: WitermMetrics.Space.s) {
                    Image(systemName: WitermSymbols.watching).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
                        Text(ConnectedDevices.watchingNotice)
                        if model.connectedDevices != nil {
                            Button(String(localized: "Connected Devices", bundle: .main)) { showingDevices = true }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityIdentifier("remoteNoticeConnectedDevices")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button(String(localized: "Dismiss", bundle: .main), systemImage: "xmark", action: model.dismissNotice)
                        .labelStyle(.iconOnly)
                        .touchTarget(square: true)
                }
                .font(WitermType.rowDetail)
                .padding(.horizontal, WitermMetrics.Space.l)
                .background(.bar)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("remoteTerminalNotice")
            }
            // Opening this one disconnected the terminal left longest ago.
            if let note = model.keptNote {
                HStack(alignment: .firstTextBaseline, spacing: WitermMetrics.Space.s) {
                    Image(systemName: WitermSymbols.disconnect).accessibilityHidden(true)
                    Text(note).frame(maxWidth: .infinity, alignment: .leading)
                    Button(String(localized: "Dismiss", bundle: .main), systemImage: "xmark", action: model.dismissKeptNote)
                        .labelStyle(.iconOnly)
                        .touchTarget(square: true)
                }
                .font(WitermType.rowDetail)
                .foregroundStyle(.secondary)
                .padding(.horizontal, WitermMetrics.Space.l)
                .background(.bar)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("remoteKeptNote")
                .task(id: note) {
                    try? await Task.sleep(for: .seconds(8))
                    if model.keptNote == note { model.dismissKeptNote() }
                }
            }
            if finding {
                TerminalFindBar(finder: finder) { finding = false }
                Divider()
            }
            ZStack(alignment: .top) {
                RemoteNativeTerminalView(
                    host: host, keyboardRequest: keyboardRequest,
                    isInteractive: model.isInteractive,
                    fontSize: rendererFontSize,
                    highContrast: terminalHighContrast || contrast == .increased,
                    preferredColorScheme: systemColorScheme,
                    palette: terminalPalette,
                    announceOutput: terminalAnnounceOutput,
                    finder: finder,
                    inputDestination: model.selectedGrant.map { $0.host.name + " · " + attachment.session.name },
                    barActions: typingBarHidden ? keyRowActions : nil,
                    keyboardButton: startTyping,
                    tapToType: startTyping.map { _ in { typeOnTap() } }
                )
                .id(id)
                // The renderer leaves the keyboard's space itself (see
                // `TerminalKeyboardOverlap`).
                .ignoresSafeArea(.keyboard, edges: .bottom)
                // Showing or hiding the keyboard switches without covering
                // the terminal; the title says it's under way.
                if !model.isInteractive, model.connectionState != .switching { connectionOverlay }
                // Round 19: over the old screen, never taking the terminal's
                // space (that would resize the Mac's grid).
                Group {
                    if model.isInteractive, host.catchingUp { catchingUpNote }
                }
                .animation(reduceMotion ? .linear(duration: 0.15) : .easeOut(duration: 0.2), value: host.catchingUp)
            }
            // Round 20: while connected, list the terminal again every 10
            // seconds so the title's count stays current, and every 5 while
            // Connected Devices is open. Each list opens a relay tunnel and
            // the server allows a device 30 a minute, so this stays at 6 (12
            // with the sheet), and never closer than that however often the
            // keyboard switches. Stops when leaving or in the background;
            // slows down while the list can't be had.
            .task(id: devicePoll) {
                guard let poll = devicePoll else { return }
                var delay = poll.interval
                // Opening the sheet lists at once unless a list just came.
                var gap = poll.sheet ? 2 : delay
                while !Task.isCancelled {
                    let since = model.devicesListedAt.map { Date().timeIntervalSince($0) } ?? .infinity
                    if since < gap {
                        try? await Task.sleep(for: .seconds(gap - since))
                        continue
                    }
                    delay = await model.refreshDevices() ? poll.interval : min(delay * 2, 60)
                    gap = delay
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

    /// How the open terminal's devices are listed again: nil when they
    /// aren't (not connected, in the background, or the Mac doesn't say).
    private struct DevicePoll: Equatable {
        let sheet: Bool
        /// While the sheet is open, a new link (typing or watching again)
        /// lists at once, so whose grid it is shows again soon.
        let link: UUID?
        var interval: TimeInterval { sheet ? 5 : 10 }
    }

    private var devicePoll: DevicePoll? {
        guard scenePhase == .active, model.isInteractive, model.followsDevices else { return nil }
        return DevicePoll(sheet: showingDevices, link: showingDevices ? model.attachmentID : nil)
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

    /// Text and Colors first (the most frequent), then Find, Connected
    /// Devices (Round 20; a sheet, never another menu), and Disconnect last.
    /// Typing follows the keyboard, so there's no switch here.
    @ViewBuilder private var terminalSecondaryActions: some View {
        TerminalTextAndColorsItems()
        Button(String(localized: "Find in Terminal", bundle: .main), systemImage: "magnifyingglass") { finding = true }
            .accessibilityIdentifier("terminalFind")
        if model.isInteractive, model.connectedDevices != nil {
            Button(String(localized: "Connected Devices", bundle: .main), systemImage: ConnectedDevicesSheet.symbol) {
                showingDevices = true
            }
            .accessibilityIdentifier("terminalConnectedDevices")
        }
        if model.isInteractive {
            Divider()
            // Round 18: Back keeps a paired terminal connected, so ending
            // the connection is its own item, with the same word as SSH. It
            // never ends the terminal: a phone can't (protocol/relay-v1.md).
            Button(String(localized: "Disconnect", bundle: .main), systemImage: WitermSymbols.disconnect) { model.disconnect() }
                .accessibilityHint(String(localized: "Keeps running on \(model.selectedGrant?.host.name ?? String(localized: "the other device", bundle: .main)).", bundle: .main))
                .accessibilityIdentifier("detachRemoteTerminal")
        }
    }

    /// The keyboard button's action while watching a terminal this device
    /// may type in: the Mac is asked for typing (after the detach ACK of the
    /// watching connection), and the keyboard rises once it accepts. Taking
    /// typing is always this explicit tap; a refusal leaves the keyboard
    /// down and says so. Nil hides the button: while typing (the
    /// key row's Hide Keyboard takes its place), and when this device can
    /// only watch.
    private var startTyping: (() -> Void)? {
        guard model.isInteractive, model.mode == .view, model.canRequestControl else { return nil }
        return { model.switchMode() }
    }

    /// A tap on a watched terminal starts typing, as on an SSH terminal,
    /// when nobody else types there; then it asks the Mac (after the detach
    /// ACK of the watching connection), which still refuses if someone
    /// started meanwhile, and this keeps watching and says so. When the
    /// latest list says someone else types, the tap keeps watching and says
    /// so, without asking: it never takes typing from anyone. Who types is
    /// in Connected Devices (Round 20).
    private func typeOnTap() {
        if model.isInteractive, model.mode == .view, model.othersType {
            model.noteTypingUnavailable()
            UIAccessibility.post(notification: .announcement, argument: ConnectedDevices.watchingNotice)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        model.switchMode()
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
            // The Mac gets the keyboard-hidden size first, so the watched
            // grid fills the screen (it kept the rows above the keyboard).
            let fit = (finder.terminal as? RemoteNativeTerminalView.TerminalInputView)?.watchingFit?()
            model.stopTyping(fitting: fit)
        }
    }

    /// Round 19: a new link (typing or watching again, or back from the
    /// background) is waiting for the Mac's redraw for longer than a moment
    /// (`LinkCoordinator.catchUpThreshold`); the old screen stays under it
    /// and it goes as soon as the redraw arrives. Spoken once, if it stays.
    private var catchingUpNote: some View {
        let label = String(localized: "Catching up…", bundle: .main)
        return HStack(spacing: WitermMetrics.Space.s) {
            ProgressView().controlSize(.small)
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(WitermType.rowDetail)
        .foregroundStyle(.secondary)
        .padding(.horizontal, WitermMetrics.Space.l)
        .padding(.vertical, WitermMetrics.Space.s)
        .background(.bar)
        .transition(.opacity)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityIdentifier("remoteCatchingUp")
        .task {
            // Not on a note that only flashes.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            UIAccessibility.post(notification: .announcement, argument: label)
        }
    }

    /// Round 18: the system's own empty-state view (and its progress view
    /// while connecting) over a system material, instead of a custom card:
    /// the kept last frame shows dimmed behind it, and the material follows
    /// Reduce Transparency and Increase Contrast by itself.
    private var connectionOverlay: some View {
        Group {
            if let busy = model.busy {
                VStack(spacing: WitermMetrics.Space.l) {
                    ProgressView(busy)
                    Button(String(localized: "Cancel", bundle: .main)) { model.cancelWork() }
                        .buttonStyle(.bordered)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("remoteTerminalActivity")
            } else {
                connectionStatusContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    /// What happened and one clear next step: Reconnect when it can work,
    /// otherwise back to Terminals (the back button also goes there).
    private var connectionStatusContent: some View {
        let ended = model.connectionState == .ended
        let title = ended ? String(localized: "Terminal Ended", bundle: .main)
            : (model.issue?.title ?? String(localized: "Disconnected", bundle: .main))
        return ContentUnavailableView {
            Label {
                Text(title).accessibilityIdentifier("remoteDisconnectedStatus")
            } icon: {
                Image(systemName: ended ? "checkmark.circle" : (model.issue?.title == RemoteTerminalIssue(RelayError.offline).title
                                                                 ? "wifi.slash" : WitermSymbols.disconnected))
            }
        } description: {
            if let issue = model.issue { Text(issue.recovery) }
        } actions: {
            if model.canReconnect {
                // The app's prominent button: system glass (bordered with
                // Reduce Transparency), with the label color that keeps contrast.
                PrimaryButton(String(localized: "Reconnect", bundle: .main), systemImage: "arrow.clockwise") { model.reconnect() }
                    .accessibilityIdentifier("reconnectRemoteTerminal")
            } else {
                PrimaryButton(String(localized: "Back to Terminals", bundle: .main), systemImage: "list.bullet") { model.showSessions() }
                    .accessibilityIdentifier("remoteDisconnectedSessionList")
            }
        }
    }

}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif
