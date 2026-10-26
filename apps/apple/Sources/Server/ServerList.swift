import Foundation
import Observation

/// Every saved Witerm server. All are checked and used at once: devices
/// paired through any of them appear together, and the Mac can accept remote
/// access through several at the same time.
@MainActor @Observable
final class ServerList {
    static let limit = 8
    private static let storageKey = "witerm.serverAddresses"
    /// The single address saved by earlier versions; read once, then replaced.
    private static let legacyKey = "witerm.serverAddress"

    private(set) var servers: [ConnectionModel]

    enum Failure: Error, Equatable {
        case duplicate, full

        var message: String {
            switch self {
            case .duplicate: String(localized: "This server is already in your list.", bundle: .main)
            case .full: String(localized: "You can save up to 8 servers. Remove one to add another.", bundle: .main)
            }
        }
    }

    init() {
        let defaults = UserDefaults.standard
        let stored = defaults.stringArray(forKey: Self.storageKey)
            ?? defaults.string(forKey: Self.legacyKey).map { [$0] }
        #if os(macOS)
        let addresses = stored ?? ["http://localhost:8080"]
        #else
        let addresses = stored ?? []
        #endif
        servers = addresses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(Self.limit)
            .map(ConnectionModel.init(address:))
    }

    var isFull: Bool { servers.count >= Self.limit }
    var relayServers: [ConnectionModel] { servers.filter(\.supportsRelay) }

    func server(id: ConnectionModel.ID?) -> ConnectionModel? {
        servers.first { $0.id == id }
    }

    /// Adds and checks a server. The address must already be validated.
    @discardableResult
    func add(_ address: String) throws(Failure) -> ConnectionModel {
        try validate(address, replacing: nil)
        let server = ConnectionModel(address: address)
        servers.append(server)
        save()
        server.check()
        return server
    }

    /// Throws when the address could not be added, or saved over `server`.
    func validate(_ address: String, replacing server: ConnectionModel?) throws(Failure) {
        guard !contains(address, except: server) else { throw .duplicate }
        guard server != nil || !isFull else { throw .full }
    }

    func update(_ server: ConnectionModel, address: String) throws(Failure) {
        try validate(address, replacing: server)
        // Saving the same address again re-checks it.
        guard address != server.address else { server.check(); return }
        server.update(address: address)
        save()
    }

    /// On Mac, remove the server's remote access first.
    func remove(_ server: ConnectionModel) {
        server.cancel()
        servers.removeAll { $0.id == server.id }
        save()
    }

    func checkAllIfNeeded() { servers.forEach { $0.checkIfNeeded() } }
    func cancelAll() { servers.forEach { $0.cancel() } }

    private func contains(_ address: String, except excluded: ConnectionModel? = nil) -> Bool {
        let key = ServerAddressKey(address)
        return servers.contains { $0.id != excluded?.id && ServerAddressKey($0.address) == key }
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(servers.map(\.address), forKey: Self.storageKey)
        defaults.removeObject(forKey: Self.legacyKey)
    }
}

/// Two spellings of one server compare equal: scheme and host case, default
/// ports and trailing paths are ignored.
struct ServerAddressKey: Hashable {
    private let value: String

    init(_ address: String) {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            value = address; return
        }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        value = parts.string ?? address
    }
}
