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

/// One paired device's page in Devices: what this device may do there,
/// through which relay server, its code, a way to its terminals, and Unpair.
struct MacDeviceDetails: View {
    let server: ConnectionModel
    let grant: DeviceGrant
    let model: RemoteTerminalModel
    /// Shows the device's terminals in Terminals.
    let openTerminals: () -> Void
    /// Called once every pairing with the device has ended, before the page closes.
    let unpaired: () -> Void
    @Environment(NetworkStatus.self) private var network: NetworkStatus?
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    @State private var failure: PairingIssue?

    private var unpairing: Bool { model.unpairingID == grant.id }
    private var offline: Bool { network?.online == false }

    /// Names the device the app runs on, as the vocabulary allows.
    private var thisDevice: String {
        UIDevice.current.userInterfaceIdiom == .pad ? String(localized: "This iPad", bundle: .main)
            : String(localized: "This iPhone", bundle: .main)
    }

    var body: some View {
        Form {
            Section {
                Button(action: openTerminals) {
                    ContentActionLabel(String(localized: "Show Terminals", bundle: .main), systemImage: WitermSymbols.sshHost)
                }
                .disabled(unpairing || model.busy != nil)
                .accessibilityIdentifier("deviceShowTerminals")
            }
            Section {
                // What this device may do on that one.
                LabeledContent(String(localized: "Access", bundle: .main), value: grant.permission == .view
                               ? String(localized: "Can only watch", bundle: .main) : String(localized: "Can watch and type", bundle: .main))
                LabeledContent(String(localized: "Relay Server", bundle: .main), value: server.displayName)
                LabeledContent(String(localized: "Device Code", bundle: .main)) {
                    Text(PairingFingerprint.display(publicKey: grant.host.publicKey))
                        .font(WitermType.code).textSelection(.enabled)
                }
            }
            Section {
                Button(role: .destructive) { confirming = true } label: {
                    if unpairing {
                        HStack(spacing: WitermMetrics.Space.s) {
                            ProgressView()
                            Text(String(localized: "Unpairing…", bundle: .main))
                        }
                    } else {
                        Label(String(localized: "Unpair…", bundle: .main), systemImage: WitermSymbols.pair).fontWeight(.semibold)
                    }
                }
                .disabled(unpairing || offline)
                .accessibilityIdentifier("unpairDevice")
            } footer: {
                // Unpairing goes through the relay server; say why it can't, and what to do.
                if offline {
                    Text(String(localized: "Unpairing needs a network connection.", bundle: .main))
                } else if let failure {
                    Text(String(localized: "\(failure.title). \(thisDevice) no longer opens its terminals, but the relay server wasn’t told. Try again, or unpair on the other device.", bundle: .main))
                        .foregroundStyle(WitermTheme.warning)
                        .accessibilityIdentifier("unpairFailure")
                }
            }
        }
        .navigationTitle(grant.host.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(unpairing)
        .alert(String(localized: "Unpair from “\(grant.host.name)”?", bundle: .main), isPresented: $confirming) {
            Button(String(localized: "Unpair", bundle: .main), role: .destructive, action: unpair)
            Button(String(localized: "Cancel", bundle: .main), role: .cancel) {}
        } message: {
            Text(String(localized: "\(thisDevice) can no longer open its terminals. To use them again, pair again.", bundle: .main))
        }
        .sensoryFeedback(.error, trigger: failure?.title)
        .sensoryFeedback(.success, trigger: done)
    }

    @State private var done = false

    private func unpair() {
        failure = nil
        Task {
            do {
                try await model.unpair(grant)
                done = true
                unpaired()
                dismiss()
            } catch {
                failure = PairingIssue(error)
            }
        }
    }
}
#endif
