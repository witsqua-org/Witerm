import Observation
import SwiftUI
import WitermSSH

struct SSHEditorRequest: Identifiable {
    let id = UUID()
    let profile: SSHProfile?
    let credentials: [UUID: SSHCredential]
    let purpose: SSHFormPurpose
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
    private(set) var visible = false
    @ObservationIgnored private var request = UUID()

    func presentNew() {
        guard visible else { return }
        request = UUID()
        editorRequest = SSHEditorRequest(profile: nil, credentials: [:], purpose: .new)
    }

    /// Connects at once when every hop has credentials the person explicitly
    /// saved; otherwise opens the prefilled connection form.
    func open(_ profile: SSHProfile, model: SSHWorkspaceModel, editing: Bool = false) {
        let token = UUID()
        request = token
        Task {
            let stored = await model.savedCredentials(for: profile)
            guard visible, request == token, !model.connecting, model.session(for: profile.id) == nil,
                  model.profiles.contains(where: { $0.id == profile.id }) else { return }
            let hosts = (profile.jumpHosts + [profile.host]).map(\.id)
            if !editing, hosts.allSatisfy({ stored[$0] != nil }) {
                model.connect(profile, credentials: stored, remember: Set(hosts))
            } else {
                editorRequest = SSHEditorRequest(profile: profile, credentials: stored, purpose: editing ? .edit : .connect)
            }
        }
    }

    func inspectKeys(_ profile: SSHProfile) { request = UUID(); inspectingKeys = profile }
    func remove(_ profile: SSHProfile) { request = UUID(); removing = profile }

    func appeared() { visible = true }

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
            .sheet(item: $ui.inspectingKeys) { profile in SSHHostKeysView(profile: profile) }
            .alert(String(localized: "Delete SSH Connection?", bundle: .main), isPresented: Binding(get: { ui.removing != nil }, set: { if !$0 { ui.removing = nil } })) {
                Button(String(localized: "Cancel", bundle: .main), role: .cancel) { ui.removing = nil }
                Button(String(localized: "Delete", bundle: .main), role: .destructive) {
                    if let removing = ui.removing { Task { await model.removeProfile(removing) } }
                    ui.removing = nil
                }
            } message: { Text(String(localized: "The saved connection and its credentials will be deleted.", bundle: .main)) }
            .onChange(of: model.sessions.map(\.token)) { _, open in
                if let files = ui.files, !open.contains(files.token) { ui.files = nil }
                if let forwarding = ui.forwarding, !open.contains(forwarding.token) { ui.forwarding = nil }
            }
            .onAppear { ui.appeared() }
            .onDisappear { ui.disappeared() }
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
                            Text(String(localized: "Compare the host fingerprint through a trusted channel before continuing.", bundle: .main))
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
            Text(verbatim: profile.endpointSummary)
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

    var body: some View {
        #if os(macOS)
        SSHNativeTerminalView(host: session.terminal, fontSize: TerminalFontSize.clamped(fontSize),
            highContrast: highContrast || contrast == .increased,
            scheme: systemColorScheme, announceOutput: announceOutput)
            .id(session.token)
        #else
        SSHNativeTerminalView(host: session.terminal, fontSize: TerminalFontSize.clamped(fontSize) * fontScale,
            highContrast: highContrast || contrast == .increased,
            scheme: systemColorScheme, announceOutput: announceOutput,
            keyboardRequest: keyboardRequest)
            .id(session.token)
        #endif
    }
}

#if os(iOS)
/// Saved hosts and their live sessions. Several hosts can stay connected; the
/// Hosts button returns to the list without disconnecting.
struct SSHWorkspaceView: View {
    /// Owned by the app root so sessions outlive tab switches.
    @Bindable var model: SSHWorkspaceModel
    @State private var ui = SSHWorkspaceUI()
    @State private var shownID: UUID?
    @State private var keyboardRequest = 0
    @State private var search = ""
    @State private var favoritesOnly = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var shownProfile: SSHProfile? { model.profiles.first { $0.id == shownID } }
    private var shown: SSHSession? { shownID.flatMap(model.session(for:)) }

    /// Switches between the list and a terminal without animating the tab
    /// bar. Its animated hide and show can leave Liquid Glass "match"
    /// animations attached indefinitely, so the app never reports idle.
    private func show(_ id: UUID?) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { shownID = id }
    }

    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    hostList
                        .navigationTitle("SSH")
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                Button(String(localized: "New SSH Connection", bundle: .main), systemImage: "plus", action: ui.presentNew)
                                    .accessibilityIdentifier("newSSHProfile")
                                    .disabled(model.connecting)
                            }
                        }
                } detail: { detail }
            } else { detail }
        }
        .modifier(SSHPresentations(model: model, ui: ui))
        .onChange(of: model.sessions.map(\.token)) { old, _ in
            if let opened = model.sessions.first(where: { !old.contains($0.token) }) { show(opened.id) }
        }
        .onChange(of: model.profiles.map(\.id)) { _, ids in
            if let shownID, !ids.contains(shownID) { show(nil) }
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            if let issue = model.issue {
                IssueBanner(issue) {
                    Button(String(localized: "Dismiss Message", bundle: .main)) { model.clearIssue() }
                        .font(.subheadline)
                        .touchTarget()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .accessibilityIdentifier("sshIssue")
            }
            if let session = shown {
                // The host's hue edges the terminal and tints its controls, so
                // the screen always shows which machine receives input.
                TerminalHeader(nil, destination: session.profile.endpointSummary,
                               status: String(localized: "Input Enabled", bundle: .main),
                               statusImage: "keyboard", live: true, hue: session.profile.identityHue) { EmptyView() }
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
                ContentUnavailableView(String(localized: "Choose an SSH Host", bundle: .main), systemImage: "terminal")
            } else {
                hostList
            }
        }
        .background(WitermTheme.canvas)
        .tint(shownProfile?.identityHue)
        .navigationTitle(shownProfile?.name ?? "SSH")
        .navigationBarTitleDisplayMode(shownID == nil ? .large : .inline)
        .toolbar(shownID == nil || sizeClass == .regular ? .automatic : .hidden, for: .tabBar)
        .toolbar {
            if shownID != nil, sizeClass != .regular {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "Hosts", bundle: .main), systemImage: "chevron.backward") { show(nil) }
                        .labelStyle(.titleAndIcon)
                        .accessibilityHint(shown != nil ? String(localized: "The session stays connected.", bundle: .main)
                                            : String(localized: "Returns to saved hosts.", bundle: .main))
                        .accessibilityIdentifier("sshShowHosts")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if let session = shown {
                    Menu {
                        Button(String(localized: "SFTP Files", bundle: .main), systemImage: "folder") { ui.files = session }
                        Button(String(localized: "Port Forwarding", bundle: .main), systemImage: "arrow.left.arrow.right") { ui.forwarding = session }
                        Button(String(localized: "Terminal Display", bundle: .main), systemImage: "textformat.size") { ui.appearance = true }
                        Button(String(localized: "Disconnect", bundle: .main), systemImage: "xmark.circle", role: .destructive) { model.disconnect(session) }
                    } label: { Label(String(localized: "SSH Actions", bundle: .main), systemImage: "ellipsis.circle") }
                    .accessibilityIdentifier("sshSessionActions")
                } else if sizeClass != .regular {
                    Button(String(localized: "New SSH Connection", bundle: .main), systemImage: "plus", action: ui.presentNew)
                        .disabled(model.connecting)
                        .accessibilityIdentifier("newSSHProfile")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if shown != nil {
                    Button(String(localized: "Keyboard", bundle: .main), systemImage: "keyboard") { keyboardRequest &+= 1 }
                        .accessibilityIdentifier("sshKeyboard")
                }
            }
        }
    }

    private var hostList: some View {
        List {
            Section {
                Toggle(String(localized: "Favorites Only", bundle: .main), isOn: $favoritesOnly)
                    .accessibilityIdentifier("sshFavoritesOnly")
            } footer: {
                Text(String(localized: "SSH connections close when this app goes to the background. Remote programs follow the host’s session rules.", bundle: .main))
            }
            ForEach(model.orderedProfiles(search: search, favoritesOnly: favoritesOnly)) { profile in
                let session = model.session(for: profile.id)
                HStack(spacing: 4) {
                    Button {
                        if session != nil { show(profile.id) } else { ui.open(profile, model: model) }
                    } label: {
                        SSHHostRowContent(profile: profile, active: session != nil, expanded: true, favorite: model.isFavorite(profile))
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sshProfileRow-\(profile.id.uuidString)")
                    .accessibilityLabel(profile.name)
                    .accessibilityValue(profile.accessibilitySummary
                        + (session == nil ? "" : String(localized: ", connected", bundle: .main))
                        + (model.isFavorite(profile) ? String(localized: ", favorite", bundle: .main) : ""))
                    .accessibilityHint(session == nil
                        ? String(localized: "Connects, or asks for credentials that are not saved.", bundle: .main)
                        : String(localized: "Shows the connected terminal.", bundle: .main))
                    .accessibilityAddTraits(shownID == profile.id ? .isSelected : [])
                    Menu {
                        Button(model.isFavorite(profile) ? String(localized: "Remove from Favorites", bundle: .main) : String(localized: "Add to Favorites", bundle: .main), systemImage: "star") { model.toggleFavorite(profile) }
                        if let session {
                            Button(String(localized: "Disconnect", bundle: .main), systemImage: "xmark.circle", role: .destructive) { model.disconnect(session) }
                        } else {
                            Button(String(localized: "Edit Connection", bundle: .main), systemImage: "pencil") { ui.open(profile, model: model, editing: true) }
                        }
                        Button(String(localized: "Host Keys", bundle: .main), systemImage: "key") { ui.inspectKeys(profile) }
                        Button(String(localized: "Delete Connection", bundle: .main), systemImage: "trash", role: .destructive) { ui.remove(profile) }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(String(localized: "Actions for \(String(profile.name))", bundle: .main))
                    .accessibilityIdentifier("sshProfileActions-\(profile.id.uuidString)")
                }
                .listRowBackground(sizeClass == .regular && shownID == profile.id ? profile.identityHue.opacity(0.12) : nil)
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: String(localized: "Search Hosts", bundle: .main))
        .scrollContentBackground(.hidden)
        .overlay {
            if !model.profiles.isEmpty, model.orderedProfiles(search: search, favoritesOnly: favoritesOnly).isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No Matching Hosts", bundle: .main), systemImage: "magnifyingglass")
                } actions: {
                    Button(String(localized: "Show All Hosts", bundle: .main)) { search = ""; favoritesOnly = false }
                }
            } else if model.profiles.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Connect Directly With SSH", bundle: .main), systemImage: "terminal")
                } description: {
                    Text(String(localized: "Add a host to use the terminal, file transfers and port forwarding.", bundle: .main))
                } actions: {
                    PrimaryButton(String(localized: "Add Host", bundle: .main), systemImage: "plus", action: ui.presentNew)
                }
            }
        }
    }
}
#endif
