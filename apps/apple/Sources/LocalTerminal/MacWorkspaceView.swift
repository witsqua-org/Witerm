#if os(macOS)
import AppKit
import SwiftUI
import WitermCore

enum MacDestination: Hashable {
    case local(String)
    case ssh(UUID)
    /// Paired devices through one saved server; nil when none is saved.
    case devices(ConnectionModel.ID?)
}

/// One sidebar for everything a person can open: sessions on this Mac, saved
/// SSH hosts, and paired devices. The detail column is always the work itself.
struct MacWorkspaceView: View {
    let service: LocalAgentService
    @Environment(ServerList.self) private var servers
    @State private var selection: MacDestination?
    @State private var terminal = LocalTerminalModel()
    @State private var ssh = SSHWorkspaceModel()
    @State private var sshUI = SSHWorkspaceUI()
    @State private var creatingSession = false
    @State private var endingSession: LocalSessionInfo?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            detail
        }
        .witermTint()
        .frame(minWidth: 860, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(String(localized: "New Terminal Session", bundle: .main), systemImage: "terminal") { creatingSession = true }
                        .disabled(!canCreateSession)
                        .accessibilityIdentifier("newLocalSession")
                    Button(String(localized: "New SSH Connection", bundle: .main), systemImage: "network", action: sshUI.presentNew)
                        .disabled(ssh.connecting)
                        .accessibilityIdentifier("newSSHProfile")
                } label: {
                    Label(String(localized: "New", bundle: .main), systemImage: "plus")
                }
                .accessibilityIdentifier("newMenu")
                .help(String(localized: "New terminal session or SSH connection", bundle: .main))
            }
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Refresh", bundle: .main), systemImage: "arrow.clockwise") { Task { await refresh() } }
                    .disabled(service.state == .starting || terminal.isWorking)
                    .accessibilityIdentifier("refreshLocalSessions")
                    .help(String(localized: "Refresh sessions and hosts", bundle: .main))
            }
        }
        .focusedSceneValue(\.workspaceActions, WorkspaceActions(
            newSession: canCreateSession ? { creatingSession = true } : nil,
            newSSHConnection: sshUI.presentNew,
            refresh: { Task { await refresh() } }
        ))
        .modifier(SSHPresentations(model: ssh, ui: sshUI))
        .sheet(isPresented: $creatingSession) {
            NewLocalSessionSheet { name in
                guard let client = service.client else { return }
                terminal.create(name: name, using: client)
            }
        }
        .alert(String(localized: "End Terminal Session?", bundle: .main), isPresented: Binding(get: { endingSession != nil }, set: { if !$0 { endingSession = nil } })) {
            Button(String(localized: "Cancel", bundle: .main), role: .cancel) { endingSession = nil }
            Button(String(localized: "End Session", bundle: .main), role: .destructive) {
                if let session = endingSession, let client = service.client { terminal.close(session, using: client) }
                endingSession = nil
            }
        } message: {
            Text(String(localized: "Programs in this session will be terminated. Unsaved changes may be lost.", bundle: .main))
        }
        .task { await refresh() }
        .onChange(of: service.state) { _, state in
            if state == .ready, let client = service.client {
                terminal.refresh(using: client)
            } else {
                terminal.serviceUnavailable()
            }
        }
        .onChange(of: service.stopRequests) { terminal.serviceUnavailable() }
        .onChange(of: selection) { old, new in selectionChanged(from: old, to: new) }
        .onChange(of: terminal.selectedID) { _, id in
            if let id {
                selection = .local(id)
            } else if case .local = selection {
                selection = nil
            }
        }
        .onChange(of: ssh.connectingProfile?.id) { _, id in
            if let id { selection = .ssh(id) }
        }
        .onChange(of: ssh.profiles.map(\.id)) { _, ids in
            if case .ssh(let id) = selection, !ids.contains(id), ssh.connectingProfile?.id != id { selection = nil }
        }
        .onChange(of: servers.servers.map(\.id)) { _, ids in
            // A removed server's page falls back to the first remaining one.
            if case .devices(let id)? = selection, id.map(ids.contains) != true {
                selection = .devices(ids.first)
            }
        }
        .onDisappear { ssh.disconnectAll() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            terminal.detach()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            Task { await refresh() }
        }
    }

    private var canCreateSession: Bool {
        service.state == .ready && terminal.tmuxAvailable && !terminal.isWorking && terminal.sessions.count < 16
    }

    private func refresh() async {
        await service.refresh()
        if service.state == .ready, let client = service.client { terminal.refresh(using: client) }
        await ssh.load()
    }

    private func selectionChanged(from old: MacDestination?, to new: MacDestination?) {
        // SSH sessions own their renderers and stay connected across selection.
        guard case .local(let id) = new, let client = service.client else { return }
        terminal.select(id, using: client)
        if terminal.selectedID != id {
            selection = terminal.selectedID.map(MacDestination.local)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section(String(localized: "This Mac", bundle: .main)) {
                localRows
            }
            Section(String(localized: "SSH Hosts", bundle: .main)) {
                ForEach(ssh.profiles) { profile in
                    let session = ssh.session(for: profile.id)
                    SSHHostRowContent(profile: profile, active: session != nil)
                        .tag(MacDestination.ssh(profile.id))
                        .accessibilityIdentifier("sshProfileRow-\(profile.id.uuidString)")
                        .accessibilityLabel(profile.name)
                        .accessibilityValue(profile.accessibilitySummary
                            + (session == nil ? "" : String(localized: ", connected", bundle: .main)))
                        .contextMenu {
                            if let session {
                                Button(String(localized: "Disconnect", bundle: .main)) { ssh.disconnect(session) }
                            } else {
                                Button(String(localized: "Connect", bundle: .main)) { selection = .ssh(profile.id); sshUI.open(profile, model: ssh) }
                                    .disabled(ssh.connecting)
                                Button(String(localized: "Edit Connection", bundle: .main)) { sshUI.open(profile, model: ssh, editing: true) }
                                    .disabled(ssh.connecting)
                            }
                            Button(String(localized: "Host Keys", bundle: .main)) { sshUI.inspectKeys(profile) }
                            Divider()
                            Button(String(localized: "Delete Connection", bundle: .main), role: .destructive) { sshUI.remove(profile) }
                        }
                }
                if ssh.profiles.isEmpty {
                    Button(String(localized: "Add SSH Host…", bundle: .main), systemImage: "plus", action: sshUI.presentNew)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("addSSHHostSidebar")
                }
            }
            Section(String(localized: "Devices", bundle: .main)) {
                if servers.servers.count > 1 {
                    // One row per server: pairing and remote access are per server.
                    ForEach(Array(servers.servers.enumerated()), id: \.element.id) { index, server in
                        Label(server.displayName, systemImage: "iphone.and.arrow.forward")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .tag(MacDestination.devices(server.id))
                            .accessibilityLabel(String(localized: "Paired Devices, \(server.displayName)", bundle: .main))
                            .accessibilityIdentifier(index == 0 ? "devicesNavigation" : "devicesNavigation-\(index)")
                    }
                } else {
                    Label(String(localized: "Paired Devices", bundle: .main), systemImage: "iphone.and.arrow.forward")
                        .tag(MacDestination.devices(servers.servers.first?.id))
                        .accessibilityIdentifier("devicesNavigation")
                }
            }
        }
        .listStyle(.sidebar)
        // Native selection: the row fills with the tint behind white text, so
        // the sidebar keeps the system accent rather than the app's ink.
        .tint(Color.accentColor)
        .navigationTitle("Witerm")
        .safeAreaInset(edge: .bottom, spacing: 0) { serverFooter }
    }

    @ViewBuilder
    private var localRows: some View {
        if service.state == .ready, terminal.tmuxAvailable {
            ForEach(terminal.sessions) { session in
                let attached = terminal.selectedID == session.id && terminal.attachment != nil
                Label {
                    Text(session.name).lineLimit(1)
                } icon: {
                    Image(systemName: attached ? "terminal.fill" : "terminal")
                        .foregroundStyle(attached ? WitermTheme.positive : .secondary)
                }
                .tag(MacDestination.local(session.id))
                .accessibilityLabel(session.name)
                .accessibilityValue(attached ? String(localized: "Connected", bundle: .main) : "")
                .accessibilityIdentifier("localSession-\(session.id)")
                .contextMenu {
                    if let client = service.client {
                        Button(String(localized: "Connect", bundle: .main)) { terminal.attach(session, using: client, mode: .control) }
                        Button(String(localized: "View Only", bundle: .main)) { terminal.attach(session, using: client, mode: .view) }
                        Divider()
                        Button(String(localized: "End Session", bundle: .main), role: .destructive) { endingSession = session }
                    }
                }
                .disabled(terminal.isWorking)
            }
            if terminal.sessions.isEmpty {
                Button(String(localized: "New Terminal Session…", bundle: .main), systemImage: "plus") { creatingSession = true }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(!canCreateSession)
                    .accessibilityIdentifier("newLocalSessionSidebar")
            }
        } else {
            Text(localStatusSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .selectionDisabled()
        }
    }

    private var localStatusSummary: String {
        if service.state == .ready { return String(localized: "tmux Required", bundle: .main) }
        switch service.state {
        case .starting: return String(localized: "Enabling local terminal…", bundle: .main)
        case .requiresApproval: return String(localized: "Waiting for background approval", bundle: .main)
        case .notRegistered: return String(localized: "Local terminal is off", bundle: .main)
        case .unavailable, .ready: return String(localized: "Local Terminal Unavailable", bundle: .main)
        }
    }

    private var serverFooter: some View {
        SettingsLink {
            HStack(spacing: 10) {
                Image(systemName: footerSymbol)
                    .foregroundStyle(footerTint)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(footerTitle)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(footerStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityLabel(String(localized: "Server: \(footerTitle), \(footerStatus)", bundle: .main))
        .accessibilityHint(String(localized: "Opens Settings", bundle: .main))
        .accessibilityIdentifier("serverStatusFooter")
    }

    /// One server is named; several are summarized by their worst state.
    private var footerTitle: String {
        switch servers.servers.count {
        case 0: String(localized: "No Server", bundle: .main)
        case 1: servers.servers[0].displayName
        default: String(localized: "\(servers.servers.count) Servers", bundle: .main)
        }
    }

    private var footerTone: StatusBadge.Tone {
        let tones = servers.servers.map(\.statusTone)
        if tones.contains(.warning) { return .warning }
        if !tones.isEmpty, tones.allSatisfy({ $0 == .positive }) { return .positive }
        return .neutral
    }

    private var footerStatus: String {
        let list = servers.servers
        if list.count == 1 { return list[0].statusTitle }
        if list.isEmpty { return String(localized: "Not Set Up", bundle: .main) }
        if list.contains(where: { $0.phase.isChecking }) { return String(localized: "Checking", bundle: .main) }
        let failed = list.filter { $0.statusTone == .warning }.count
        if failed > 0 { return String(localized: "\(failed) Unreachable", bundle: .main) }
        return footerTone == .positive ? String(localized: "All Reachable", bundle: .main) : String(localized: "Not Checked", bundle: .main)
    }

    private var footerSymbol: String {
        if servers.servers.count == 1 { return servers.servers[0].statusSymbol }
        switch footerTone {
        case .positive: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle"
        case .neutral: return "server.rack"
        }
    }

    private var footerTint: Color {
        switch footerTone {
        case .positive: WitermTheme.positive
        case .warning: WitermTheme.warning
        case .neutral: .secondary
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .local?:
            LocalTerminalDetail(service: service, model: terminal) { endingSession = $0 }
        case .ssh(let id)?:
            // A new host is selected as soon as it starts connecting, before
            // it is saved; show it so its progress and errors stay visible.
            if let profile = ssh.profiles.first(where: { $0.id == id })
                ?? ssh.connectingProfile.flatMap({ $0.id == id ? $0 : nil }) {
                SSHHostDetail(profile: profile, model: ssh, ui: sshUI)
            } else {
                overview
            }
        case .devices(let id)?:
            MacDevicesView(service: service, server: servers.server(id: id))
                .id(id)
        case nil:
            overview
        }
    }

    private var overview: some View {
        LocalOverview(service: service, model: terminal, canCreate: canCreateSession,
                      newSession: { creatingSession = true }, newSSHConnection: sshUI.presentNew)
    }
}
#endif
