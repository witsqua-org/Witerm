#if os(macOS)
import AppKit
import Observation
import SwiftUI
import WitermCore

/// Where remote access through one server really stands: the setting, and
/// what the background service reports, not only whether the server answers.
enum MacRemoteAccessState: Equatable {
    /// Allow Remote Access is off for this server.
    case off
    /// On, but the local service isn't running, so nothing can reach this Mac.
    case serviceOff
    /// On, and the server hasn't accepted this Mac yet.
    case connecting
    /// The server accepted this Mac; paired devices can reach it now.
    case ready

    init(enabled: Bool, serviceReady: Bool, relays: [LocalRelayStatus], address: String) {
        guard enabled else { self = .off; return }
        guard serviceReady else { self = .serviceOff; return }
        let key = ServerAddressKey(address)
        self = relays.contains { $0.state == .ready && ServerAddressKey($0.server) == key } ? .ready : .connecting
    }

    var title: String {
        switch self {
        case .off: String(localized: "Off", bundle: .main)
        case .serviceOff: String(localized: "Local Terminal Off", bundle: .main)
        case .connecting: String(localized: "Connecting…", bundle: .main)
        case .ready: String(localized: "Online", bundle: .main)
        }
    }

    var systemImage: String {
        switch self {
        case .off: "antenna.radiowaves.left.and.right.slash"
        case .serviceOff: "exclamationmark.triangle.fill"
        case .connecting: "hourglass"
        case .ready: "antenna.radiowaves.left.and.right"
        }
    }

    var tone: StatusBadge.Tone {
        switch self {
        case .off, .connecting: .neutral
        case .serviceOff: .warning
        case .ready: .positive
        }
    }
}

/// Which servers this Mac accepts remote access through. The background
/// service keeps one relay connection per enabled server.
@MainActor @Observable
final class MacRemoteAccessModel {
    private(set) var hosts: [RelayHostConfiguration] = []
    private(set) var loaded = false
    private(set) var issue: String?

    func load() {
        do {
            hosts = try Self.store()?.readAll() ?? []
            loaded = true
            issue = nil
        } catch {
            loaded = false
            issue = String(localized: "Unable to read remote access settings. Try again.", bundle: .main)
        }
    }

    func isEnabled(for address: String) -> Bool {
        let key = ServerAddressKey(address)
        return hosts.contains { $0.enabled && ServerAddressKey($0.serverAddress) == key }
    }

    func setEnabled(_ enabled: Bool, address: String) {
        do {
            guard let store = try Self.store() else { throw LocalAgentClientError.unavailable }
            try store.upsert(RelayHostConfiguration(serverAddress: address, deviceName: Self.deviceName, enabled: enabled))
            load()
        } catch {
            issue = enabled ? String(localized: "Unable to enable remote access. Check the server address and local terminal service.", bundle: .main) : String(localized: "Unable to turn off remote access. Try again.", bundle: .main)
        }
    }

    /// Removes remote access through a server that is being removed or whose
    /// address is changing.
    static func forget(serverAddress: String) throws {
        // An address the store cannot normalize was never saved there.
        guard (try? PairingServerAddress.normalized(serverAddress)) != nil else { return }
        try store()?.remove(serverAddress: serverAddress)
    }

    private static var deviceName: String {
        let clean = (Host.current().localizedName ?? String(localized: "My Mac", bundle: .main))
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(String.UnicodeScalarView((clean.isEmpty ? String(localized: "My Mac", bundle: .main) : clean).unicodeScalars.prefix(64)))
    }

    /// Nil before the local service has created its state directory.
    private static func store() throws -> RelayHostConfigurationStore? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "WitermAppGroup") as? String,
              !group.isEmpty, !group.contains("$(") else { throw LocalAgentClientError.unavailable }
        let directory = try LocalAgentPaths.stateDirectory(appGroupID: group)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        return RelayHostConfigurationStore(stateDirectory: directory)
    }
}
#endif
