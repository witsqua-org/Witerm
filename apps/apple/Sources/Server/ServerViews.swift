import Accessibility
import SwiftUI

/// The connection outcome in words and symbols, shared by setup and settings.
struct ConnectionFeedback: View {
    let model: ConnectionModel

    init(server: ConnectionModel) { model = server }

    var body: some View {
        switch model.phase {
        case .idle:
            Label {
                Text(model.hasAddress ? String(localized: "Check the server connection when you are ready.", bundle: .main) : String(localized: "Use the server’s HTTP or HTTPS address.", bundle: .main))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "network")
            }
            .foregroundStyle(WitermTheme.secondary)
        case .checking:
            HStack(alignment: .center, spacing: 12) {
                ConnectionActivity()
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Checking connection…", bundle: .main)).font(.subheadline.weight(.medium))
                    Text(String(localized: "Waiting for the server", bundle: .main)).font(.caption).foregroundStyle(WitermTheme.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        case .available(let date):
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(WitermTheme.positive)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "The server is reachable", bundle: .main)).font(.subheadline.weight(.medium))
                    Text(String(localized: "Checked at \(String(date.formatted(date: .omitted, time: .shortened)))", bundle: .main))
                        .font(.caption).foregroundStyle(WitermTheme.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        case .failed(let issue):
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(WitermTheme.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(issue.title).font(.subheadline.weight(.medium))
                    Text(issue.recovery)
                        .font(.subheadline)
                        .foregroundStyle(WitermTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// App-wide connection behavior: check every saved server on launch and on
/// return to the foreground, cancel in the background, and announce results.
struct ConnectionLifecycle: ViewModifier {
    @Environment(ServerList.self) private var servers
    @Environment(\.scenePhase) private var scenePhase
    @State private var network = NetworkStatus()

    func body(content: Content) -> some View {
        content
            .environment(network)
            .task { servers.checkAllIfNeeded() }
            // A returning network rechecks servers; terminals still wait for an explicit Reconnect.
            .onChange(of: network.online) { _, online in
                if online { servers.checkAllIfNeeded() }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background: servers.cancelAll()
                case .active: servers.checkAllIfNeeded()
                default: break
                }
            }
            .onChange(of: servers.servers.map(\.phase)) { old, new in
                // Additions and removals change the count; only announce
                // results for servers that were already listed.
                guard old.count == new.count else { return }
                for (index, (previous, current)) in zip(old, new).enumerated() where previous != current {
                    announce(current, after: previous, server: servers.servers[index])
                }
            }
            #if os(iOS)
            .sensoryFeedback(.success, trigger: servers.servers.reduce(0) { $0 + $1.successCount })
            .sensoryFeedback(.error, trigger: servers.servers.reduce(0) { $0 + $1.failureCount })
            #endif
    }

    private func announce(_ phase: ConnectionPhase, after previous: ConnectionPhase, server: ConnectionModel) {
        let message: String?
        switch phase {
        case .checking: message = String(localized: "Checking connection", bundle: .main)
        case .available: message = String(localized: "Connection checked. The server is reachable.", bundle: .main)
        case .failed(let issue): message = "\(issue.title)。\(issue.recovery)"
        case .idle: message = previous.isChecking ? String(localized: "Connection check cancelled", bundle: .main) : nil
        }
        guard let message else { return }
        // With several servers, say which one the result belongs to.
        let spoken = servers.servers.count > 1 ? "\(server.displayName), \(message)" : message
        AccessibilityNotification.Announcement(spoken).post()
    }
}

/// Adding a server, or editing a saved one.
enum ServerEditRequest: Identifiable {
    case add
    case edit(ConnectionModel)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let server): server.id.uuidString
        }
    }
}

/// The one place a server address is added or edited. Duplicates and the
/// list limit are reported in the sheet. On Mac, changing an address first
/// removes remote access through the old one.
private struct ServerEditor: ViewModifier {
    @Binding var request: ServerEditRequest?
    @Environment(ServerList.self) private var servers

    func body(content: Content) -> some View {
        content.sheet(item: $request) { request in
            switch request {
            case .add:
                ServerAddressSheet(title: String(localized: "Add Server", bundle: .main), address: "") { address in
                    do throws(ServerList.Failure) { try servers.add(address); return nil } catch { return error.message }
                }
            case .edit(let server):
                ServerAddressSheet(title: String(localized: "Edit Server", bundle: .main), address: server.address) { address in
                    do throws(ServerList.Failure) { try servers.validate(address, replacing: server) } catch { return error.message }
                    #if os(macOS)
                    if ServerAddressKey(address) != ServerAddressKey(server.address) {
                        do { try MacRemoteAccessModel.forget(serverAddress: server.address) } catch {
                            return String(localized: "Turn off remote access for this server before changing its address.", bundle: .main)
                        }
                    }
                    #endif
                    do throws(ServerList.Failure) { try servers.update(server, address: address); return nil } catch { return error.message }
                }
            }
        }
    }
}

extension View {
    func connectionLifecycle() -> some View { modifier(ConnectionLifecycle()) }

    func serverEditor(_ request: Binding<ServerEditRequest?>) -> some View {
        modifier(ServerEditor(request: request))
    }
}

#if os(iOS)
/// Shown in the Devices tab while no server is saved, or while the only saved
/// server has not yet been verified to offer remote terminals. `model` is an
/// unsaved, empty placeholder when there is no server.
struct ServerSetupView: View {
    let model: ConnectionModel
    let openSSH: () -> Void
    @State private var editing: ServerEditRequest?
    @State private var showingPairing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(spacing: typeSize.isAccessibilitySize ? 20 : 24) {
                if !typeSize.isAccessibilitySize {
                    introduction
                }
                VStack(spacing: 16) {
                    serverCard
                    if model.phase.isAvailable, !model.supportsRelay {
                        relayUnavailable
                    }
                }
                if typeSize.isAccessibilitySize {
                    actionBar
                }
                sshAlternative
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, WitermMetrics.pagePadding)
            .padding(.top, typeSize.isAccessibilitySize ? 12 : 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .background(WorkspaceBackground())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !typeSize.isAccessibilitySize {
                actionBar
                    .frame(maxWidth: 480)
                    .padding(.horizontal, WitermMetrics.pagePadding)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(String(localized: "Mac Access", bundle: .main))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Server Settings", bundle: .main), systemImage: "slider.horizontal.3") {
                    editing = model.hasAddress ? .edit(model) : .add
                }
                .accessibilityIdentifier("serverSettings")
            }
        }
        .serverEditor($editing)
        .sheet(isPresented: $showingPairing) {
            DevicePairingView(serverAddress: model.address).id(model.address)
        }
        .onChange(of: model.address) { showingPairing = false }
        .animation(WitermMotion.transition(reduceMotion: reduceMotion), value: model.phase)
    }

    private var introduction: some View {
        VStack(spacing: 14) {
            BrandEmblem()
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(String(localized: "Connect to your workspace.", bundle: .main))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(WitermTheme.ink)
                Text(String(localized: "Add your Witerm server to open terminal sessions on paired devices.", bundle: .main))
                    .font(.subheadline)
                    .foregroundStyle(WitermTheme.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(String(localized: "Server", bundle: .main)).font(.headline)
                    Spacer(minLength: 12)
                    statusBadge
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "Server", bundle: .main)).font(.headline)
                    statusBadge
                }
            }
            HStack(alignment: .top, spacing: 12) {
                if !typeSize.isAccessibilitySize {
                    IconTile(systemImage: "server.rack")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.hostName ?? String(localized: "Your First Server", bundle: .main))
                        .font(.headline)
                        .foregroundStyle(WitermTheme.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.hasAddress ? model.address : String(localized: "Add an address to check the connection.", bundle: .main))
                        .font(model.hasAddress ? .system(.subheadline, design: .monospaced) : .subheadline)
                        .foregroundStyle(WitermTheme.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            ConnectionFeedback(server: model)
                .accessibilityIdentifier("connectionFeedback")
                .id(model.phase.accessibilityKey)
                .transition(.opacity.combined(with: reduceMotion ? .identity : .offset(y: 5)))
        }
        .witermCard()
    }

    private var statusBadge: some View {
        StatusBadge(model.statusTitle, systemImage: model.statusSymbol, tone: model.statusTone)
            .accessibilityIdentifier("connectionStatus")
    }

    private var relayUnavailable: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "This server does not offer remote terminals.", bundle: .main))
                .font(.subheadline)
                .foregroundStyle(WitermTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.supportsPairing {
                Button(String(localized: "Device Pairing", bundle: .main), systemImage: "link") { showingPairing = true }
                    .touchTarget()
                    .accessibilityIdentifier("devicePairing")
            }
        }
        .witermCard()
    }

    private var sshAlternative: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Text(String(localized: "Direct SSH works without a server.", bundle: .main))
                    .foregroundStyle(WitermTheme.secondary)
                Button(String(localized: "Open SSH", bundle: .main), action: openSSH)
                    .accessibilityIdentifier("openSSHFromSetup")
            }
            VStack(spacing: 4) {
                Text(String(localized: "Direct SSH works without a server.", bundle: .main))
                    .foregroundStyle(WitermTheme.secondary)
                Button(String(localized: "Open SSH", bundle: .main), action: openSSH)
                    .touchTarget()
                    .accessibilityIdentifier("openSSHFromSetup")
            }
        }
        .font(.subheadline)
        .multilineTextAlignment(.center)
    }

    private var actionBar: some View {
        ConnectionActions(isChecking: model.phase.isChecking, hasAddress: model.hasAddress) {
            if model.hasAddress { model.check() } else { editing = .add }
        } cancel: {
            model.cancel()
        }
    }
}
#endif
