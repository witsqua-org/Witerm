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

/// Whether paired devices may reach this Mac's sessions through the server.
struct MacRemoteAccessCard: View {
    let serverAddress: String
    let service: LocalAgentService
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = MacRemoteAccessModel()

    init(serverAddress: String, service: LocalAgentService, model: MacRemoteAccessModel = MacRemoteAccessModel()) {
        self.serverAddress = serverAddress
        self.service = service
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(systemImage: "antenna.radiowaves.left.and.right")
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Allow Remote Access", bundle: .main))
                        .font(.headline)
                    Text(String(localized: "Paired iPhone and iPad devices can connect to the sessions you share on this Mac.", bundle: .main))
                        .font(.subheadline)
                        .foregroundStyle(WitermTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle(String(localized: "Allow Remote Access", bundle: .main), isOn: Binding(
                    get: { model.isEnabled(for: serverAddress) },
                    set: { model.setEnabled($0, address: serverAddress) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(WitermTheme.positive)
                .disabled(!model.loaded || (service.state != .ready && !model.isEnabled(for: serverAddress)))
                .accessibilityIdentifier("allowRemoteConnections")
            }
            if model.isEnabled(for: serverAddress) {
                IconText(String(localized: "Devices must be paired and authorized to view or control the terminal.", bundle: .main), systemImage: "checkmark.shield")
                    .font(.subheadline)
                    .foregroundStyle(WitermTheme.secondary)
            }
            if service.state != .ready {
                Divider()
                Text(String(localized: "Enable this Mac’s local terminal service first.", bundle: .main))
                    .font(.subheadline)
                    .foregroundStyle(WitermTheme.secondary)
                if service.state == .requiresApproval {
                    Button(String(localized: "Open Login Items Settings", bundle: .main), action: service.openSettings)
                } else {
                    Button(String(localized: "Enable Local Terminal", bundle: .main)) {
                        Task { await service.start(); if service.state == .ready { model.load() } }
                    }
                    .disabled(service.state == .starting)
                }
                if let issue = service.issue { Text(issue).font(.subheadline).foregroundStyle(WitermTheme.warning) }
            }
            if let issue = model.issue {
                IssueBanner(issue) {
                    Button(String(localized: "Try Again", bundle: .main), action: model.load)
                }
                .accessibilityIdentifier("remoteAccessSettingsError")
            }
        }
        .witermCard()
        .task {
            await service.refresh()
            model.load()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await service.refresh(); model.load() }
            }
        }
    }
}
#endif
