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
            HStack(alignment: .center, spacing: WitermMetrics.Space.m) {
                ConnectionActivity()
                VStack(alignment: .leading, spacing: WitermMetrics.Space.xs) {
                    Text(String(localized: "Checking connection…", bundle: .main)).font(.subheadline.weight(.medium))
                    Text(String(localized: "Waiting for the server", bundle: .main)).font(WitermType.meta).foregroundStyle(WitermTheme.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        case .available(let date):
            HStack(alignment: .top, spacing: WitermMetrics.Space.m) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(WitermTheme.positive)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: WitermMetrics.Space.xs) {
                    Text(String(localized: "The server is reachable", bundle: .main)).font(.subheadline.weight(.medium))
                    Text(String(localized: "Checked at \(String(date.formatted(date: .omitted, time: .shortened)))", bundle: .main))
                        .font(WitermType.meta).foregroundStyle(WitermTheme.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        case .failed(let issue):
            HStack(alignment: .top, spacing: WitermMetrics.Space.m) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(WitermTheme.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: WitermMetrics.Space.xs) {
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

    // The check always follows. On iPhone the longer titles pushed the
    // sheet's own title off ("Add Relay…"), so they say only what's done.
    #if os(iOS)
    static let addTitle = String(localized: "Add", bundle: .main)
    static let saveTitle = String(localized: "Save", bundle: .main)
    #else
    static let addTitle = String(localized: "Add and Check", bundle: .main)
    static let saveTitle = String(localized: "Save and Check", bundle: .main)
    #endif

    func body(content: Content) -> some View {
        content.sheet(item: $request) { request in
            switch request {
            case .add:
                ServerAddressSheet(title: String(localized: "Add Relay Server", bundle: .main),
                                   actionTitle: Self.addTitle, address: "") { address in
                    do throws(ServerList.Failure) { try servers.add(address); return nil } catch { return error.message }
                }
            case .edit(let server):
                ServerAddressSheet(title: String(localized: "Edit Relay Server", bundle: .main),
                                   actionTitle: Self.saveTitle, address: server.address) { address in
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
