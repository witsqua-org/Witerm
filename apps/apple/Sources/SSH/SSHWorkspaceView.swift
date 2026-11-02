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
}

/// Sheet and alert state for the SSH workspace, shared by the Mac sidebar and
/// the iOS host list. Request tokens keep a stale credential lookup from
/// presenting an editor after the person moved on.
@MainActor @Observable
final class SSHWorkspaceUI {
    var editorRequest: SSHEditorRequest?
    var pendingConnection: (SSHProfile, [UUID: SSHCredential], Set<UUID>)?
    var removing: SSHProfile?
    var inspectingKeys: SSHProfile?
    /// The session whose files or forwards are shown; sheets follow it.
    var files: SSHSession?
    var forwarding: SSHSession?
    var appearance = false
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
    /// saved; otherwise opens the prefilled connection form.
    /// `reviewing` always shows the prefilled form with Connect, so a rejected
    /// credential is corrected instead of retried as is.
    func open(_ profile: SSHProfile, model: SSHWorkspaceModel, editing: Bool = false, reviewing: Bool = false) {
        let token = UUID()
        request = token
        Task {
            let stored = await model.savedCredentials(for: profile)
            guard visible, request == token, !model.connecting, model.session(for: profile.id) == nil,
                  model.profiles.contains(where: { $0.id == profile.id }) else { return }
            let hosts = (profile.jumpHosts + [profile.host]).map(\.id)
            if !editing, !reviewing, hosts.allSatisfy({ stored[$0] != nil }) {
                model.connect(profile, credentials: stored, remember: Set(hosts))
            } else {
                editorRequest = SSHEditorRequest(profile: profile, credentials: stored, purpose: editing ? .edit : .connect)
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
                    model.connect(pending.0, credentials: pending.1, remember: pending.2)
                }
            }) { request in
                SSHProfileForm(profile: request.profile, credentials: request.credentials, purpose: request.purpose,
                               address: request.address,
                               onSave: { profile, auth, remember in
                    guard ui.visible, ui.editorRequest?.id == request.id else { throw CancellationError() }
                    try await model.saveProfile(profile, credentials: auth, remember: remember)
                }) { profile, auth, remember in
                    guard ui.visible, ui.editorRequest?.id == request.id else { return }
                    ui.pendingConnection = (profile, auth, remember)
                }
            }
            .sheet(item: $model.trustPrompt, onDismiss: {
                if ui.visible { model.resumeTrustedAttempt() }
            }) { prompt in
                SSHTrustView(prompt: prompt, model: model)
            }
            .sheet(item: $ui.files) { session in SSHFilesView(connection: session.connection) }
            .sheet(item: $ui.forwarding) { session in SSHForwardingView(connection: session.connection) }
            .sheet(isPresented: $ui.appearance) { TerminalAppearanceSettings() }
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
                HStack(spacing: 12) {
                    Text(String(localized: "Deleted \(String(removed.profile.name)) and its saved credentials.", bundle: .main))
                        .font(.subheadline)
                        .foregroundStyle(WitermTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(String(localized: "Undo", bundle: .main)) { Task { await model.undoRemove() } }
                        .font(.subheadline.weight(.semibold))
                        .touchTarget()
                        .accessibilityIdentifier("sshUndoRemove")
                    Button(String(localized: "Dismiss", bundle: .main), systemImage: "xmark", action: model.dismissUndo)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .touchTarget(square: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(WitermTheme.surface, in: .capsule)
                .overlay { Capsule().strokeBorder(WitermTheme.secondary.opacity(0.25), lineWidth: 1).allowsHitTesting(false) }
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .frame(maxWidth: 520)
                .padding(16)
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
                HStack(spacing: 12) {
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
                    Button(String(localized: "Dismiss Message", bundle: .main)) { model.clearIssue() }
                        .touchTarget()
                }
                .font(.subheadline)
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
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        IconTile(systemImage: "checkmark.shield")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "First Connection to This Host", bundle: .main))
                                .font(.headline)
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
                    VStack(spacing: 8) {
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
            // Label wraps text around its icon at accessibility sizes; an
            // explicit stack keeps the lines aligned, and the decorative icon
            // gives way to the text at those sizes.
            HStack(alignment: .top, spacing: 14) {
                if !typeSize.isAccessibilitySize { icon.padding(.top, 2).accessibilityHidden(true) }
                details
            }
        } else {
            Label { details } icon: { icon }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(profile.name).lineLimit(expanded ? nil : 1)
                if favorite { Image(systemName: "star.fill").font(.caption).accessibilityHidden(true) }
            }
            Text(verbatim: activity?.summary(home: nil) ?? profile.endpointSummary)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(expanded && typeSize.isAccessibilitySize ? nil : 1)
                .truncationMode(.middle)
            if !profile.jumpHosts.isEmpty {
                Text(String(localized: "Jump hosts: \(String(profile.jumpHosts.count))", bundle: .main))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if expanded, active {
                IconText(String(localized: "Connected", bundle: .main), systemImage: "lock.shield")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(profile.identityHue)
            }
        }
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
    @ScaledMetric(relativeTo: .body) private var fontScale = 1.0
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
        SSHNativeTerminalView(host: session.terminal, fontSize: TerminalFontSize.clamped(fontSize) * fontScale,
            highContrast: highContrast || contrast == .increased, palette: palette,
            scheme: systemColorScheme, announceOutput: announceOutput,
            keyboardRequest: keyboardRequest)
            .id(session.token)
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
    /// The list of terminals and machines shown when no terminal is.
    @ViewBuilder let home: Home
    @State private var keyboardRequest = 0
    @State private var finding = false
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
                NavigationSplitView {
                    home
                        .navigationTitle(String(localized: "Terminals", bundle: .main))
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                Button(String(localized: "Add SSH Host…", bundle: .main), systemImage: "plus", action: ui.presentNew)
                                    .accessibilityIdentifier("newSSHProfile")
                                    .disabled(model.connecting)
                            }
                        }
                } detail: { detail }
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
            OfflineBanner(insets: EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))
            if model.issue != nil {
                SSHIssueBanner(model: model, ui: ui, profile: shownProfile)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            if let session = shown {
                // The host's hue edges the terminal and tints its controls, so
                // the screen always shows which machine receives input. On
                // iPhone the navigation bar names it instead of a second header.
                if sizeClass == .regular {
                    TerminalHeader(nil, destination: session.profile.endpointSummary,
                                   status: String(localized: "Connected", bundle: .main),
                                   statusImage: "lock.shield", live: true, hue: session.profile.identityHue) {
                        Button(String(localized: "Find in Terminal", bundle: .main), systemImage: "magnifyingglass") { finding = true }
                            .labelStyle(.iconOnly)
                            .keyboardShortcut("f", modifiers: .command)
                            .touchTarget(square: true)
                            .accessibilityIdentifier("terminalFind")
                    }
                } else {
                    Rectangle()
                        .fill(session.profile.identityHue.opacity(0.55))
                        .frame(height: 2)
                        .accessibilityHidden(true)
                }
                if finding {
                    TerminalFindBar(finder: finder(for: session)) { finding = false }
                    Divider()
                }
                if !backgroundTipSeen {
                    // Said once, the first time it applies: with a live SSH terminal on screen.
                    IssueBanner(String(localized: "SSH stops in the background. Use tmux to keep programs running.", bundle: .main),
                                systemImage: "info.circle") {
                        Button(String(localized: "OK", bundle: .main)) { backgroundTipSeen = true }
                            .font(.subheadline).touchTarget()
                            .accessibilityIdentifier("sshBackgroundTipDismiss")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
                SSHTerminalSurface(session: session, keyboardRequest: keyboardRequest)
            } else if let connecting = model.connectingProfile {
                VStack(spacing: 16) {
                    ProgressView(String(localized: "Connecting to \(String(connecting.name))…", bundle: .main))
                    Button(String(localized: "Cancel", bundle: .main), action: model.cancelConnecting).touchTarget()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let profile = shownProfile, let reason = model.disconnected[profile.id] {
                ContentUnavailableView {
                    Label(String(localized: "SSH Disconnected", bundle: .main), systemImage: "bolt.horizontal.circle")
                } description: {
                    Text(profile.endpointSummary + "\n" + reason)
                } actions: {
                    PrimaryButton(String(localized: "Reconnect", bundle: .main)) { ui.open(profile, model: model) }
                        .disabled(model.connecting)
                        .accessibilityIdentifier("sshReconnect")
                }
            } else if sizeClass == .regular {
                ContentUnavailableView(String(localized: "Choose a Terminal", bundle: .main), systemImage: "terminal")
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
        .navigationTitle(shownProfile?.name ?? String(localized: "Terminals", bundle: .main))
        .navigationBarTitleDisplayMode(shownID == nil ? .large : .inline)
        .toolbar(shownID == nil || sizeClass == .regular ? .automatic : .hidden, for: .tabBar)
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
            ToolbarItem(placement: .primaryAction) {
                if let session = shown {
                    Menu {
                        TerminalTextSizeControls()
                        if sizeClass != .regular {
                            Button(String(localized: "Find in Terminal", bundle: .main), systemImage: "magnifyingglass") { finding = true }
                                .keyboardShortcut("f", modifiers: .command)
                                .accessibilityIdentifier("terminalFind")
                        }
                        Button(String(localized: "SFTP Files", bundle: .main), systemImage: "folder") { ui.files = session }
                        Button(String(localized: "Port Forwarding", bundle: .main), systemImage: "arrow.left.arrow.right") { ui.forwarding = session }
                        Button(String(localized: "Terminal Display", bundle: .main), systemImage: "paintpalette") { ui.appearance = true }
                        Divider()
                        Button(String(localized: "Disconnect", bundle: .main), systemImage: "xmark.circle", role: .destructive) { model.disconnect(session) }
                    } label: { Label(String(localized: "Terminal Actions", bundle: .main), systemImage: "ellipsis.circle") }
                    .accessibilityIdentifier("sshSessionActions")
                } else if sizeClass != .regular {
                    Button(String(localized: "Add SSH Host…", bundle: .main), systemImage: "plus", action: ui.presentNew)
                        .disabled(model.connecting)
                        .accessibilityIdentifier("newSSHProfile")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if let session = shown {
                    TerminalKeyboardButton(terminal: { session.terminal.surface.terminal }) { keyboardRequest &+= 1 }
                        .id(session.token)
                        .accessibilityIdentifier("sshKeyboard")
                }
            }
        }
    }

    /// Other live SSH terminals, for switching from the title.
    private func otherOpen(than session: SSHSession) -> [SSHProfile] {
        model.orderedProfiles().filter { $0.id != session.id && model.session(for: $0.id) != nil }
    }

    /// The host's name over where typing goes. With other terminals open, a
    /// chevron beside it switches to one of them.
    private func compactTitle(_ session: SSHSession) -> some View {
        let others = otherOpen(than: session)
        return HStack(spacing: 2) {
            VStack(spacing: 1) {
                Text(session.profile.name).font(.headline).foregroundStyle(WitermTheme.ink)
                Text(verbatim: session.profile.endpointSummary)
                    .font(.caption.monospaced())
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

/// Host search, attached only when the list is long enough to need it.
struct HostSearch: ViewModifier {
    let enabled: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always),
                               prompt: String(localized: "Search Hosts", bundle: .main))
        } else {
            content
        }
    }
}
#endif
