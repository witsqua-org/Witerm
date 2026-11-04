import Observation
import SwiftUI
import WitermSSH

struct SSHEditorRequest: Identifiable {
    let id = UUID()
    let profile: SSHProfile?
    let credentials: [UUID: SSHCredential]
    let purpose: SSHFormPurpose
    /// `user@host:port` to start a new host from.
    var address: String? = nil
    /// Hosts whose saved credential wasn't read (Face ID was cancelled, or the
    /// person chose Enter Password): it stays unless they save a new one.
    var preserving: Set<UUID> = []
}

/// Sheet and alert state for the SSH workspace, shared by the Mac sidebar and
/// the iOS host list. Request tokens keep a stale credential lookup from
/// presenting an editor after the person moved on.
@MainActor @Observable
final class SSHWorkspaceUI {
    var editorRequest: SSHEditorRequest?
    var pendingConnection: (SSHProfile, [UUID: SSHCredential], Set<UUID>, Set<UUID>)?
    var removing: SSHProfile?
    var inspectingKeys: SSHProfile?
    /// The session whose files or forwards are shown; sheets follow it.
    var files: SSHSession?
    var forwarding: SSHSession?
    var importing = false
    /// A connected host a keyboard command asked to show; the workspace shows it and clears this.
    var requestedSession: UUID?
    #if os(iOS)
    /// The host whose terminal (or disconnected state) fills the screen on iOS.
    private(set) var shownID: UUID?

    /// Switches between the list and a terminal without animating the tab
    /// bar. Its animated hide and show can leave Liquid Glass "match"
    /// animations attached indefinitely, so the app never reports idle.
    func show(_ id: UUID?) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { shownID = id }
    }
    #endif
    private(set) var visible = false
    @ObservationIgnored private var request = UUID()
    @ObservationIgnored private var newRequested: String?? = nil

    /// For commands issued from another tab: presents once the workspace appears.
    func presentNewWhenVisible(address: String? = nil) {
        if visible { presentNew(address: address) } else { newRequested = .some(address) }
    }

    func presentNew() { presentNew(address: nil) }

    func presentNew(address: String?) {
        guard visible else { return }
        request = UUID()
        editorRequest = SSHEditorRequest(profile: nil, credentials: [:], purpose: .new, address: address)
    }

    /// Connects at once when every hop has credentials the person explicitly
    /// saved, after one Face ID (or Touch ID, or passcode) check for all of
    /// them; otherwise opens the prefilled connection form. `reviewing`
    /// always shows the prefilled form with Connect, so a rejected credential
    /// is corrected instead of retried as is. Cancelling the check ends the
    /// attempt without an error and offers the form to type the password.
    func open(_ profile: SSHProfile, model: SSHWorkspaceModel, editing: Bool = false, reviewing: Bool = false) {
        let token = UUID()
        request = token
        Task {
            @MainActor func current() -> Bool {
                visible && request == token && !model.connecting && model.session(for: profile.id) == nil
                    && model.profiles.contains(where: { $0.id == profile.id })
            }
            let saved = await model.savedCredentialHosts(for: profile)
            guard current() else { return }
            let hosts = (profile.jumpHosts + [profile.host]).map(\.id)
            let purpose: SSHFormPurpose = editing ? .edit : .connect
            guard !saved.isEmpty else {
                editorRequest = SSHEditorRequest(profile: profile, credentials: [:], purpose: purpose)
                return
            }
            let read = await model.savedCredentials(for: profile)
            guard current() else { return }
            switch read {
            case .read(let stored):
                if !editing, !reviewing, hosts.allSatisfy({ stored[$0] != nil }) {
                    model.connect(profile, credentials: stored, remember: Set(hosts))
                } else {
                    editorRequest = SSHEditorRequest(profile: profile, credentials: stored, purpose: purpose)
                }
            case .cancelled where editing, .failed:
                return
            case .cancelled, .enterPassword:
                editorRequest = SSHEditorRequest(profile: profile, credentials: [:], purpose: purpose, preserving: saved)
            }
        }
    }

    func presentImport() {
        guard visible else { return }
        request = UUID()
        importing = true
    }

    func inspectKeys(_ profile: SSHProfile) { request = UUID(); inspectingKeys = profile }
    func remove(_ profile: SSHProfile) { request = UUID(); removing = profile }

    func appeared() {
        visible = true
        if let address = newRequested { newRequested = nil; presentNew(address: address) }
    }

    func disappeared() {
        visible = false
        request = UUID()
        pendingConnection = nil
        editorRequest = nil
    }
}

/// Attaches every SSH sheet and alert. Apply once per workspace. Sessions are
/// not closed when this view disappears; the workspace owner decides that.
struct SSHPresentations: ViewModifier {
    @Bindable var model: SSHWorkspaceModel
    @Bindable var ui: SSHWorkspaceUI
    /// iOS places the undo bar inside each tab, clear of the tab bar.
    var showsUndo = true

    func body(content: Content) -> some View {
        content
            .task { await model.load() }
            .sheet(item: $ui.editorRequest, onDismiss: {
                guard ui.visible else { ui.pendingConnection = nil; return }
                if let pending = ui.pendingConnection {
                    ui.pendingConnection = nil
                    model.connect(pending.0, credentials: pending.1, remember: pending.2, preserving: pending.3)
                }
            }) { request in
                SSHProfileForm(profile: request.profile, credentials: request.credentials, purpose: request.purpose,
                               address: request.address,
                               onSave: { profile, auth, remember in
                    guard ui.visible, ui.editorRequest?.id == request.id else { throw CancellationError() }
                    try await model.saveProfile(profile, credentials: auth, remember: remember, preserving: request.preserving)
                }) { profile, auth, remember in
                    guard ui.visible, ui.editorRequest?.id == request.id else { return }
                    ui.pendingConnection = (profile, auth, remember, request.preserving)
                }
            }
            .sheet(item: $model.trustPrompt, onDismiss: {
                if ui.visible { model.resumeTrustedAttempt() }
            }) { prompt in
                #if os(macOS)
                MacSSHTrustSheet(prompt: prompt, model: model)
                #else
                SSHTrustView(prompt: prompt, model: model)
                #endif
            }
            #if os(macOS)
            .sheet(item: $ui.files) { session in MacSFTPBrowser(connection: session.connection) }
            #else
            .sheet(item: $ui.files) { session in SSHFilesView(connection: session.connection) }
            #endif
            .sheet(item: $ui.forwarding) { session in SSHForwardingView(connection: session.connection) }
            .sheet(isPresented: $ui.importing) { SSHConfigImportView(model: model) }
            .sheet(item: $ui.inspectingKeys) { profile in SSHHostKeysView(profile: profile) }
            // Deleting is immediate and undoable, rather than confirmed up front.
            .onChange(of: ui.removing?.id) {
                guard let removing = ui.removing else { return }
                ui.removing = nil
                Task { await model.removeProfile(removing) }
            }
            .overlay(alignment: .bottom) { if showsUndo { SSHUndoRemovalBar(model: model) } }
            .onChange(of: model.sessions.map(\.token)) { _, open in
                if let files = ui.files, !open.contains(files.token) { ui.files = nil }
                if let forwarding = ui.forwarding, !open.contains(forwarding.token) { ui.forwarding = nil }
            }
            .onAppear { ui.appeared() }
            .onDisappear { ui.disappeared() }
    }
}

/// Offers to undo a host deletion for a few seconds.
struct SSHUndoRemovalBar: View {
    let model: SSHWorkspaceModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let removed = model.recentlyRemoved {
                HStack(spacing: WitermMetrics.Space.m) {
                    Text(removed.hadCredentials
                         ? String(localized: "Deleted \(String(removed.profile.name)) and its saved credentials.", bundle: .main)
                         : String(localized: "Deleted \(String(removed.profile.name)).", bundle: .main))
                        .font(WitermType.rowDetail)
                        .foregroundStyle(WitermTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: WitermMetrics.Space.s)
                    Button(String(localized: "Undo", bundle: .main)) { Task { await model.undoRemove() } }
                        .font(WitermType.rowDetail.weight(.semibold))
                        .touchTarget()
                        .accessibilityIdentifier("sshUndoRemove")
                    Button(String(localized: "Dismiss", bundle: .main), systemImage: "xmark", action: model.dismissUndo)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .touchTarget(square: true)
                        .accessibilityIdentifier("sshUndoDismiss")
                }
                .padding(.horizontal, WitermMetrics.Space.l)
                .padding(.vertical, WitermMetrics.Space.s)
                .background(WitermTheme.surface, in: .capsule)
                .overlay { Capsule().strokeBorder(WitermTheme.hairline, lineWidth: 1).allowsHitTesting(false) }
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .frame(maxWidth: WitermMetrics.readableWidth)
                .padding(WitermMetrics.Space.l)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .onAppear {
                    AccessibilityNotification.Announcement(String(localized: "Deleted \(String(removed.profile.name)). Undo is available.", bundle: .main)).post()
                }
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.88),
                   value: model.recentlyRemoved?.token)
    }
}

/// The current SSH issue with its next step: correct the connection, or try
/// the same one again after a network problem.
struct SSHIssueBanner: View {
    let model: SSHWorkspaceModel
    let ui: SSHWorkspaceUI
    let profile: SSHProfile?

    var body: some View {
        if let issue = model.issue {
            IssueBanner(issue) {
                HStack(spacing: WitermMetrics.Space.m) {
                    if let profile, model.issueProfileID == profile.id {
                        switch model.issueRecovery {
                        case .editConnection:
                            Button(String(localized: "Check Connection…", bundle: .main)) {
                                model.clearIssue(); ui.open(profile, model: model, reviewing: true)
                            }
                            .touchTarget()
                            .disabled(model.connecting)
                            .accessibilityIdentifier("sshIssueEdit")
                        case .tryAgain:
                            Button(String(localized: "Try Again", bundle: .main)) {
                                model.clearIssue(); ui.open(profile, model: model)
                            }
                            .touchTarget()
                            .disabled(model.connecting)
                            .accessibilityIdentifier("sshIssueRetry")
                        case nil: EmptyView()
                        }
                    }
                    Button(String(localized: "Dismiss", bundle: .main)) { model.clearIssue() }
                        .touchTarget()
                }
                .font(WitermType.rowDetail)
            }
            .accessibilityIdentifier("sshIssue")
        }
    }
}

struct SSHTrustView: View {
    let prompt: SSHTrustPrompt
    let model: SSHWorkspaceModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: WitermMetrics.Space.l) {
                    HStack(alignment: .top, spacing: WitermMetrics.Space.m) {
                        IconTile(systemImage: "checkmark.shield")
                        VStack(alignment: .leading, spacing: WitermMetrics.Space.xs) {
                            Text(String(localized: "First Connection to This Host", bundle: .main))
                                .font(WitermType.cardTitle)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(String(localized: "Check that this matches the fingerprint the host's owner gives you.", bundle: .main))
                                .font(.subheadline)
                                .foregroundStyle(WitermTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent(String(localized: "Host", bundle: .main), value: prompt.key.authority)
                        LabeledContent(String(localized: "Key Type", bundle: .main), value: prompt.key.algorithm)
                        Divider()
                        Text(prompt.key.fingerprint)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(WitermTheme.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(String(localized: "Host fingerprint, \(String(prompt.key.fingerprint))", bundle: .main))
                            .accessibilityIdentifier("sshHostFingerprint")
                    }
                    .witermCard()
                    VStack(spacing: WitermMetrics.Space.s) {
                        PrimaryButton(String(localized: "Trust and Connect", bundle: .main), systemImage: "checkmark.shield", fullWidth: true) {
                            Task { await model.approveHostKey(prompt) }
                        }
                        .accessibilityIdentifier("sshTrustHost")
                        Button(String(localized: "Cancel", bundle: .main), role: .cancel) { model.rejectHostKey() }
                            .touchTarget()
                    }
                }
                .padding(WitermMetrics.pagePadding)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(WitermTheme.canvas)
            .navigationTitle(String(localized: "Verify Host Identity", bundle: .main))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .witermTint()
        .interactiveDismissDisabled()
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 520, minHeight: 440)
        #endif
    }
}

extension SSHProfile {
    var endpointSummary: String { "\(host.username)@\(host.hostname):\(host.port)" }

    var accessibilitySummary: String {
        endpointSummary + (jumpHosts.isEmpty ? "" : String(localized: ", jump hosts: \(String(jumpHosts.count))", bundle: .main))
    }
}

/// Saved host summary used by the Mac sidebar and the iOS host list.
/// The Mac sidebar keeps rows to one line each; the iOS list lets the name
/// wrap and shows the connected state on its own line, so neither competes
/// with the name for width.
struct SSHHostRowContent: View {
    let profile: SSHProfile
    let active: Bool
    var expanded = false
    var favorite = false
    /// A connected host shows what runs there instead of its address.
    var activity: TerminalActivity? = nil
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if expanded {
            // The iOS row: a tile in the host's hue, then the text, which
            // keeps its own lines at every text size.
            HStack(alignment: .center, spacing: WitermMetrics.Space.m) {
                if !typeSize.isAccessibilitySize {
                    IconTile(systemImage: active ? "terminal.fill" : WitermSymbols.sshHost, tint: profile.identityHue)
                }
                details
            }
        } else {
            Label { details } icon: { icon }
        }
    }

    /// The address under the name. A host named after its address shows only
    /// what the name leaves out (a port other than 22), not the address twice.
    private var addressLine: String? {
        if let doing = activity?.summary(home: nil) { return doing }
        guard expanded, profile.name == "\(profile.host.username)@\(profile.host.hostname)" else { return profile.endpointSummary }
        return profile.host.port == 22 ? nil : ":\(profile.host.port)"
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
            HStack(spacing: WitermMetrics.Space.s) {
                Text(profile.name).lineLimit(expanded ? nil : 1)
                if favorite { Image(systemName: "star.fill").font(WitermType.meta).accessibilityHidden(true) }
            }
            if let addressLine {
                #if os(iOS)
                if expanded {
                    // Wraps between characters at large sizes, never with a hyphen.
                    AddressText(addressLine, lines: typeSize.isAccessibilitySize ? 0 : 1)
                } else {
                    plainAddress(addressLine)
                }
                #else
                plainAddress(addressLine)
                #endif
            }
            if !profile.jumpHosts.isEmpty {
                Text(String(localized: "Jump hosts: \(String(profile.jumpHosts.count))", bundle: .main))
                    .font(WitermType.meta)
                    .foregroundStyle(expanded ? WitermTheme.secondary : .secondary)
            }
            if expanded, active {
                IconText(String(localized: "Connected", bundle: .main), systemImage: WitermSymbols.connected)
                    .font(WitermType.meta.weight(.semibold))
                    .foregroundStyle(profile.identityHue)
            }
        }
    }

    private func plainAddress(_ text: String) -> some View {
        Text(verbatim: text)
            .font(WitermType.codeInline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var icon: some View {
        // The host's identity hue marks it everywhere; a filled symbol marks
        // a live session.
        Image(systemName: active ? "terminal.fill" : "terminal")
            .foregroundStyle(profile.identityHue)
    }
}

/// A session's live renderer with the person's display preferences applied.
struct SSHTerminalSurface: View {
    let session: SSHSession
    var keyboardRequest = 0
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var systemColorScheme
    #if os(iOS)
    /// The bar's actions for the key row while the bar is hidden for typing.
    var barActions: AnyView? = nil
    @Environment(\.dynamicTypeSize) private var typeSize
    #endif
    @AppStorage(TerminalFontSize.key) private var fontSize = TerminalFontSize.standard
    @AppStorage("witerm.terminalHighContrast") private var highContrast = false
    @AppStorage("witerm.terminalAnnounceOutput") private var announceOutput = false
    @AppStorage(TerminalColorScheme.key) private var palette = TerminalColorScheme.system

    var body: some View {
        #if os(macOS)
        SSHNativeTerminalView(host: session.terminal, fontSize: TerminalFontSize.clamped(fontSize),
            highContrast: highContrast || contrast == .increased, palette: palette,
            scheme: systemColorScheme, announceOutput: announceOutput)
            .id(session.token)
        #else
        SSHNativeTerminalView(host: session.terminal, fontSize: TerminalFontSize.clamped(fontSize) * TerminalTextScale.factor(typeSize),
            highContrast: highContrast || contrast == .increased, palette: palette,
            scheme: systemColorScheme, announceOutput: announceOutput,
            keyboardRequest: keyboardRequest, barActions: barActions)
            .id(session.token)
            // The renderer leaves the keyboard's space itself (see
            // `TerminalKeyboardOverlap`).
            .ignoresSafeArea(.keyboard, edges: .bottom)
        #endif
    }
}

#if os(iOS)
/// Live SSH terminals on top of a home list. Several hosts can stay
/// connected; the back button returns to the list without disconnecting.
/// The owner applies `SSHPresentations` once for the whole app.
struct SSHWorkspaceView<Home: View>: View {
    /// Owned by the app root so sessions outlive tab switches.
    @Bindable var model: SSHWorkspaceModel
    /// Owned by the app root so keyboard commands can reach it from any tab.
    let ui: SSHWorkspaceUI
    /// A paired device's terminals, shown in the detail column on a regular
    /// width (iPad) so the list stays beside them.
    var remote: AnyView? = nil
    /// The list of terminals and machines shown when no terminal is.
    @ViewBuilder let home: Home
    @State private var keyboardRequest = 0
    @State private var finding = false
    /// See `TerminalTypingBar`.
    @State private var typingBarHidden = false
    @AppStorage("witerm.sshBackgroundTipSeen") private var backgroundTipSeen = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("witerm.terminalHighContrast") private var highContrast = false
    @AppStorage(TerminalColorScheme.key) private var palette = TerminalColorScheme.system

    private var shownID: UUID? { ui.shownID }
    private var shownProfile: SSHProfile? { model.profiles.first { $0.id == shownID } }
    private var shown: SSHSession? { shownID.flatMap(model.session(for:)) }

    var body: some View {
        Group {
            if sizeClass == .regular {
                // The split view is the tab's root: the list in the sidebar,
                // the SSH or paired terminal beside it in its own stack.
                NavigationSplitView {
                    // Add SSH Host… lives in the list's SSH Hosts section.
                    home
                        .navigationTitle(String(localized: "Terminals", bundle: .main))
                } detail: {
                    NavigationStack {
                        if let remote { remote } else { detail }
                    }
                }
            } else { detail }
        }
        .onChange(of: model.sessions.map(\.token)) { old, _ in
            if let opened = model.sessions.first(where: { !old.contains($0.token) }) { ui.show(opened.id) }
        }
        .onChange(of: model.profiles.map(\.id)) { _, ids in
            if let shownID, !ids.contains(shownID) { ui.show(nil) }
        }
        .sensoryFeedback(.success, trigger: model.connectSuccesses)
        .sensoryFeedback(.error, trigger: model.connectFailures)
        .onChange(of: shownID) { finding = false }
        .onReceive(NotificationCenter.default.publisher(for: .witermFindInTerminal)) { _ in
            if shown != nil, remote == nil { finding = true }
        }
        // Find Next or Previous before there's a search opens the bar for one.
        .onReceive(NotificationCenter.default.publisher(for: .witermFindStep)) { _ in
            if shown != nil, remote == nil { finding = true }
        }
        .onChange(of: ui.requestedSession, initial: true) { _, id in
            guard let id else { return }
            ui.requestedSession = nil
            if model.session(for: id) != nil { ui.show(id) }
        }
    }

    private func finder(for session: SSHSession) -> TerminalFinder {
        let finder = TerminalFinder()
        finder.terminal = session.terminal.surface.terminal
        return finder
    }

    private var detail: some View {
        VStack(spacing: 0) {
            OfflineBanner(insets: EdgeInsets(top: WitermMetrics.Space.s, leading: WitermMetrics.Space.l, bottom: 0, trailing: WitermMetrics.Space.l))
            if model.issue != nil {
                SSHIssueBanner(model: model, ui: ui, profile: shownProfile)
                    .padding(.horizontal, WitermMetrics.Space.l)
                    .padding(.vertical, WitermMetrics.Space.s)
            }
            if let session = shown {
                // The host's hue edges the terminal and tints its controls, so
                // the screen always shows which machine receives input. On
                // iPhone the navigation bar names it instead of a second header.
                if sizeClass == .regular {
                    TerminalHeader(nil, destination: session.profile.endpointSummary,
                                   status: String(localized: "Connected", bundle: .main),
                                   statusImage: WitermSymbols.connected, live: true, hue: session.profile.identityHue) {
                        Button(String(localized: "Find in Terminal", bundle: .main), systemImage: "magnifyingglass") { finding = true }
                            .labelStyle(.iconOnly)
                            .touchTarget(square: true)
                            .accessibilityIdentifier("terminalFind")
                    }
                } else {
                    Rectangle()
                        .fill(WitermTheme.edge(session.profile.identityHue))
                        .frame(height: 2)
                        .accessibilityHidden(true)
                }
                if finding {
                    TerminalFindBar(finder: finder(for: session)) { finding = false }
                    Divider()
                }
                if !backgroundTipSeen {
                    // Said once, the first time it applies: with a live SSH terminal on screen.
                    IssueBanner(String(localized: "SSH stays connected for 3 minutes in the background. Use tmux to keep programs running longer.", bundle: .main),
                                systemImage: "info.circle") {
                        Button(String(localized: "OK", bundle: .main)) { backgroundTipSeen = true }
                            .font(.subheadline).touchTarget()
                            .accessibilityIdentifier("sshBackgroundTipDismiss")
                    }
                    .padding(.horizontal, WitermMetrics.Space.l).padding(.vertical, WitermMetrics.Space.s)
                }
                SSHTerminalSurface(session: session, keyboardRequest: keyboardRequest,
                                   barActions: typingBarHidden ? keyRowActions(session) : nil)
            } else if let connecting = model.connectingProfile {
                VStack(spacing: WitermMetrics.Space.l) {
                    ProgressView(String(localized: "Connecting to \(String(connecting.name))…", bundle: .main))
                    Button(String(localized: "Cancel", bundle: .main), action: model.cancelConnecting).touchTarget()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let profile = shownProfile, let reason = model.disconnected[profile.id] {
                ContentUnavailableView {
                    Label(String(localized: "Disconnected", bundle: .main), systemImage: WitermSymbols.disconnected)
                } description: {
                    Text(profile.endpointSummary + "\n" + reason)
                } actions: {
                    PrimaryButton(String(localized: "Reconnect", bundle: .main)) { ui.open(profile, model: model) }
                        .disabled(model.connecting)
                        .accessibilityIdentifier("sshReconnect")
                }
            } else if sizeClass == .regular {
                // Honest before anything is saved: nothing to choose yet.
                ContentUnavailableView(model.profiles.isEmpty ? String(localized: "No Terminal Open", bundle: .main)
                                       : String(localized: "Choose a Terminal", bundle: .main), systemImage: "terminal")
            } else {
                home
            }
        }
        // Under a terminal on iPhone, its own color continues past the home indicator.
        .background(shown != nil && sizeClass != .regular
                    ? TerminalBackdrop.color(dark: systemColorScheme == .dark, highContrast: highContrast || contrast == .increased,
                                             palette: palette)
                    : WitermTheme.canvas)
        // Like the back button, an edge swipe returns to the list and keeps the session connected.
        .edgeSwipeBack(enabled: shownID != nil && sizeClass != .regular) { ui.show(nil) }
        .tint(shownProfile?.identityHue)
        // On a regular width the sidebar already says Terminals.
        .navigationTitle(shownProfile?.name ?? (sizeClass == .regular ? "" : String(localized: "Terminals", bundle: .main)))
        .navigationBarTitleDisplayMode(shownID == nil ? .large : .inline)
        .toolbar(shownID == nil || sizeClass == .regular ? .automatic : .hidden, for: .tabBar)
        .modifier(TerminalTypingBar(terminal: { [session = shown] in session?.terminal.surface.terminal }, identity: shown?.token,
                                    enabled: shown != nil && sizeClass != .regular, barHidden: $typingBarHidden))
        .toolbar {
            if shownID != nil, sizeClass != .regular {
                ToolbarItem(placement: .topBarLeading) {
                    // The symbol alone; the spoken label still names where it goes.
                    Button(String(localized: "Terminals", bundle: .main), systemImage: "chevron.backward") { ui.show(nil) }
                        .labelStyle(.iconOnly)
                        .accessibilityHint(shown != nil ? String(localized: "The terminal stays connected.", bundle: .main)
                                            : String(localized: "Returns to your terminals.", bundle: .main))
                        .accessibilityIdentifier("sshShowHosts")
                }
                if let session = shown {
                    ToolbarItem(placement: .principal) { compactTitle(session) }
                }
            }
            // Only the actions menu: the keyboard button is at the
            // terminal's bottom right, as on a paired terminal.
            ToolbarItem(placement: .primaryAction) {
                if let session = shown {
                    Menu { sessionActions(session, find: sizeClass != .regular) } label: { Label(String(localized: "Terminal Actions", bundle: .main), systemImage: WitermSymbols.more) }
                    .accessibilityIdentifier("sshSessionActions")
                }
            }
        }
    }

    /// The bar's actions menu as the key row's last key, tinted like the bar.
    private func keyRowActions(_ session: SSHSession) -> AnyView {
        AnyView(TerminalKeyRowActions { sessionActions(session, find: true) }.tint(session.profile.identityHue))
    }

    /// The terminal's actions, in the bar's menu or, while the bar is hidden
    /// for typing, on the key row. iPad's header has its own Find button.
    @ViewBuilder private func sessionActions(_ session: SSHSession, find: Bool) -> some View {
        TerminalTextAndColorsItems()
        if find {
            Button(String(localized: "Find in Terminal", bundle: .main), systemImage: "magnifyingglass") { finding = true }
                .accessibilityIdentifier("terminalFind")
        }
        Button(String(localized: "SFTP Files", bundle: .main), systemImage: "folder") { ui.files = session }
        Button(String(localized: "Port Forwarding", bundle: .main), systemImage: "arrow.left.arrow.right") { ui.forwarding = session }
        Divider()
        // The same item as a paired terminal's (Round 18): it ends the
        // connection; the host stays saved.
        Button(String(localized: "Disconnect", bundle: .main), systemImage: WitermSymbols.disconnect) { model.disconnect(session) }
    }

    /// Other live SSH terminals, for switching from the title.
    private func otherOpen(than session: SSHSession) -> [SSHProfile] {
        model.orderedProfiles().filter { $0.id != session.id && model.session(for: $0.id) != nil }
    }

    /// The host's name over where typing goes. With other terminals open, a
    /// chevron beside it switches to one of them.
    private func compactTitle(_ session: SSHSession) -> some View {
        let others = otherOpen(than: session)
        return HStack(spacing: WitermMetrics.Space.xxs) {
            VStack(spacing: 0) {
                Text(session.profile.name).font(WitermType.cardTitle).foregroundStyle(WitermTheme.ink)
                Text(verbatim: session.profile.endpointSummary)
                    .font(WitermType.codeInline)
                    .foregroundStyle(WitermTheme.secondary)
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([session.profile.name, session.profile.endpointSummary,
                                 String(localized: "Connected", bundle: .main)].joined(separator: ", "))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("terminalInputStatus")
            if !others.isEmpty {
                TerminalSwitcher(names: others.map(\.name)) { ui.show(others[$0].id) }
            }
        }
    }
}

/// Search, attached only when the list is long enough to need it.
struct HostSearch: ViewModifier {
    let enabled: Bool
    @Binding var text: String
    let prompt: String

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always),
                               prompt: prompt)
        } else {
            content
        }
    }
}
#endif
