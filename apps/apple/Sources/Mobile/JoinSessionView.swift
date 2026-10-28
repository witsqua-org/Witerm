#if os(iOS)
import SwiftUI
import UIKit
import WitermCore

/// Joins one Mac session from an invitation, without pairing.
@MainActor @Observable
final class JoinSessionModel {
    enum Phase: Equatable {
        case idle
        case working(String)
        /// A control invitation waits for the person at the Mac to approve.
        case waitingForApproval
        /// This device is already paired with that Mac; its pairing applies.
        case alreadyPaired(DeviceGrant)
        case failed(String)
    }

    private(set) var phase = Phase.idle
    @ObservationIgnored private var work: Task<Void, Never>?
    /// A grant whose proof couldn't be delivered yet, so trying again
    /// doesn't need a new invitation.
    @ObservationIgnored private var joined: (PairingClient, DeviceGrant)?

    /// Joins through the pairing endpoints, checks that the grant the Mac
    /// signed matches what the link says, then proves this device holds the
    /// link. Nothing opens until all three succeed.
    func join(_ invitation: SessionInvitation, server: ConnectionModel, opened: @escaping (DeviceGrant) -> Void) {
        work?.cancel()
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let client: PairingClient
                let grant: DeviceGrant
                if let joined = self.joined, joined.1.pairingID == invitation.pairingID {
                    (client, grant) = joined
                } else {
                    self.phase = .working(String(localized: "Joining…", bundle: .main))
                    let joining = try PairingClient(serverAddress: server.address, deviceName: Self.deviceName, platform: .ios)
                    _ = try await joining.register()
                    // One grant per Mac and device: an existing pairing is used as is.
                    if let paired = try await joining.grants().first(where: { $0.host.publicKey == invitation.hostPublicKey }) {
                        self.phase = .alreadyPaired(paired)
                        return
                    }
                    var pairing = try await joining.join(invitation.pairingInvitation())
                    while pairing.status != .approved {
                        guard pairing.status == .pending || pairing.status == .waiting else { throw PairingClientError.api(code: "pairing_unavailable") }
                        if invitation.permission == .control { self.phase = .waitingForApproval }
                        try await Task.sleep(for: .seconds(2))
                        pairing = try await joining.pairing(id: invitation.pairingID)
                    }
                    // Verifies the Mac's signature against the key pinned from the link.
                    guard let signed = try await joining.grants().first(where: { $0.pairingID == invitation.pairingID }) else {
                        throw PairingClientError.invalidProof
                    }
                    guard signed.permission == invitation.permission else {
                        try? await joining.revoke(grantID: signed.id, pairingID: signed.pairingID)
                        throw PairingClientError.invalidProof
                    }
                    (client, grant) = (joining, signed)
                    self.joined = (client, grant)
                }
                self.phase = .working(String(localized: "Opening the session…", bundle: .main))
                try await RemoteTerminalClient(pairing: client, grantID: grant.id).redeem(invitation)
                self.joined = nil
                self.phase = .idle
                opened(grant)
            } catch is CancellationError {
                self.phase = .idle
            } catch {
                guard !Task.isCancelled else { return }
                let issue = (error as? RelayError).map { RemoteTerminalIssue($0) }
                self.phase = .failed(issue?.title ?? PairingIssue(error).title)
            }
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        phase = .idle
    }

    private static var deviceName: String {
        let clean = UIDevice.current.name.components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(String.UnicodeScalarView((clean.isEmpty ? String(localized: "My iPhone", bundle: .main) : clean).unicodeScalars.prefix(64)))
    }
}

/// Paste or scan a session invitation, review it, then join.
struct JoinSessionView: View {
    let opened: (ConnectionModel, DeviceGrant) -> Void
    @Environment(ServerList.self) private var servers
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var scanning = false
    @State private var invitation: SessionInvitation?
    @State private var problem: String?
    @State private var model = JoinSessionModel()
    @State private var addedServer: ConnectionModel.ID?

    private var server: ConnectionModel? {
        guard let invitation else { return nil }
        return servers.servers.first { ServerAddressKey($0.address) == ServerAddressKey(invitation.server) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let invitation { review(invitation) } else { entry }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Open Shared Session", bundle: .main))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .main)) { model.cancel(); dismiss() }
                }
            }
            .sheet(isPresented: $scanning) {
                PairingScannerView { value in text = value; read() }
            }
        }
        .onDisappear { model.cancel() }
    }

    private var entry: some View {
        Section {
            Button(String(localized: "Scan Invitation Code", bundle: .main), systemImage: "qrcode.viewfinder") { scanning = true }
                .accessibilityIdentifier("scanSessionInvitation")
            TextField(String(localized: "Or paste the invitation link", bundle: .main), text: $text, axis: .vertical)
                .lineLimit(2...5)
                .font(.system(.subheadline, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .accessibilityIdentifier("sessionInvitationField")
            Button(String(localized: "Review Invitation", bundle: .main), action: read)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } footer: {
            Text(problem ?? String(localized: "Someone sharing a session from their Mac can send you a link or show a code. You don't need to pair with that Mac.", bundle: .main))
        }
    }

    @ViewBuilder
    private func review(_ invitation: SessionInvitation) -> some View {
        Section {
            LabeledContent(String(localized: "Access", bundle: .main), value: invitation.permission == .control
                           ? String(localized: "Can type", bundle: .main) : String(localized: "View only", bundle: .main))
            LabeledContent(String(localized: "Until", bundle: .main), value: invitation.expiresAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent(String(localized: "Mac Fingerprint", bundle: .main)) {
                Text(PairingFingerprint.display(publicKey: invitation.hostPublicKey))
                    .font(.footnote.monospaced()).multilineTextAlignment(.trailing)
            }
        } footer: {
            Text(String(localized: "If you can, compare the fingerprint with the one shown on the Mac.", bundle: .main))
        }
        Section {
            if let server {
                switch model.phase {
                case .idle:
                    Button(String(localized: "Join Session", bundle: .main), systemImage: "terminal") {
                        model.join(invitation, server: server) { grant in
                            dismiss()
                            opened(server, grant)
                        }
                    }
                    .disabled(!server.supportsRelay || !server.supportsPairing)
                    .accessibilityIdentifier("joinSharedSession")
                    if !server.supportsRelay || !server.supportsPairing { ConnectionFeedback(server: server) }
                case .working(let message):
                    ActivityRow(message) { model.cancel() }
                case .waitingForApproval:
                    ActivityRow(String(localized: "Waiting for the Mac to approve…", bundle: .main)) { model.cancel() }
                case .alreadyPaired(let grant):
                    Text(String(localized: "This iPhone is already paired with that Mac, so it uses its pairing instead of the invitation.", bundle: .main))
                    Button(String(localized: "Open the Mac in Terminals", bundle: .main), systemImage: "terminal") {
                        dismiss()
                        opened(server, grant)
                    }
                    .accessibilityIdentifier("openPairedMac")
                case .failed(let message):
                    Text(message).foregroundStyle(WitermTheme.warning)
                    Button(String(localized: "Try Again", bundle: .main)) {
                        model.join(invitation, server: server) { grant in
                            dismiss()
                            opened(server, grant)
                        }
                    }
                }
            } else {
                // Never switch servers because a link says so: ask first.
                LabeledContent(String(localized: "Server", bundle: .main), value: invitation.server)
                Button(String(localized: "Add This Server", bundle: .main), systemImage: "plus") {
                    do {
                        let added = try servers.add(invitation.server)
                        added.check()
                        addedServer = added.id
                    } catch let failure as ServerList.Failure {
                        problem = failure.message
                    } catch {
                        problem = nil
                    }
                }
                .disabled(servers.isFull)
                .accessibilityIdentifier("addInvitationServer")
            }
        } footer: {
            if server == nil {
                Text(String(localized: "This invitation uses a Witerm server you haven't added. Add it only if you trust the person who sent it.", bundle: .main))
            }
        }
        Section {
            Button(String(localized: "Use Another Invitation", bundle: .main)) {
                model.cancel(); self.invitation = nil; text = ""
            }
        }
    }

    private func read() {
        do {
            invitation = try SessionInvitation(urlString: text.trimmingCharacters(in: .whitespacesAndNewlines))
            problem = nil
        } catch {
            invitation = nil
            problem = String(localized: "That isn't a valid or current session invitation. Ask for a new one.", bundle: .main)
        }
    }
}
#endif
