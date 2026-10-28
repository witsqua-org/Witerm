#if os(iOS)
import SwiftUI
import WitermCore

/// One remote-terminal model per saved server, kept across view updates and
/// shared by the Terminals and Machines tabs. A
/// server whose address changes gets a fresh model, because grants and
/// identities belong to an address.
@MainActor
final class RemoteModels {
    private var models: [ConnectionModel.ID: RemoteTerminalModel] = [:]

    func model(for server: ConnectionModel) -> RemoteTerminalModel {
        if let model = models[server.id], model.serverAddress == server.address { return model }
        models[server.id]?.suspend()
        let model = RemoteTerminalModel(serverAddress: server.address)
        models[server.id] = model
        return model
    }

    func existing(for server: ConnectionModel) -> RemoteTerminalModel? {
        models[server.id].flatMap { $0.serverAddress == server.address ? $0 : nil }
    }

    /// Lists devices for relay servers not listed yet, or whose listing was cancelled.
    func loadNew(_ servers: [ConnectionModel]) {
        for server in servers {
            let model = model(for: server)
            if !model.loaded, model.busy == nil { model.loadDevices() }
        }
    }

    func suspend(_ servers: [ConnectionModel]) {
        servers.forEach { existing(for: $0)?.suspend() }
    }

    /// Live terminals keep a short grace period, then release and reconnect on return.
    func enterBackground() {
        models.values.forEach { $0.enterBackground() }
    }

    func enterForeground() {
        models.values.forEach { $0.enterForeground() }
    }

    /// Stops and forgets models whose server was removed.
    func prune(keeping servers: [ConnectionModel]) {
        let kept = Set(servers.map(\.id))
        for (id, model) in models where !kept.contains(id) {
            model.suspend()
            models[id] = nil
        }
    }
}

/// One paired device: who it is, through which server, and its fingerprint.
struct MacDeviceDetails: View {
    let server: ConnectionModel
    let grant: DeviceGrant
    let done: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent(String(localized: "Device", bundle: .main), value: grant.host.name)
                LabeledContent(String(localized: "Server", bundle: .main), value: server.address)
                LabeledContent(String(localized: "Access Level", bundle: .main), value: grant.permission == .view
                               ? String(localized: "View Only", bundle: .main) : String(localized: "Can Type", bundle: .main))
                LabeledContent(String(localized: "Device Fingerprint", bundle: .main)) {
                    Text(PairingFingerprint.display(publicKey: grant.host.publicKey))
                        .font(.body.monospaced()).textSelection(.enabled)
                }
            }
            .navigationTitle(String(localized: "Device Details", bundle: .main))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: .main), action: done)
                }
            }
        }
    }
}
#endif
