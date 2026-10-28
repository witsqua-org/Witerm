#if os(macOS)
import AppKit
import Observation
import SwiftUI
import WitermCore

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
