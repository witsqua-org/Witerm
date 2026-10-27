import CoreImage.CIFilterBuiltins
import SwiftUI
import WitermCore
#if os(macOS)
import AppKit
#endif

enum PairingPresentation {
    /// A sheet with its own navigation and Done button.
    case sheet
    /// Inline content inside another scrolling page.
    case embedded
}

struct DevicePairingView: View {
    let presentation: PairingPresentation
    let onGrantsChanged: (([DeviceGrant]) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: DevicePairingModel
    @State private var invitationText = ""
    @State private var permission = PairingPermission.view
    @State private var copied = false
    @State private var revoking: DeviceGrant?
    #if os(iOS)
    @State private var scanning = false
    @State private var scannedInvitation: String?
    #endif

    init(serverAddress: String, presentation: PairingPresentation = .sheet,
         onGrantsChanged: (([DeviceGrant]) -> Void)? = nil) {
        self.presentation = presentation
        self.onGrantsChanged = onGrantsChanged
        _model = State(initialValue: DevicePairingModel(serverAddress: serverAddress))
    }

    var body: some View {
        Group {
            switch presentation {
            case .sheet:
                NavigationStack {
                    ScrollView { content.readableContent() }
                        .background(WitermTheme.canvas)
                        .navigationTitle(String(localized: "Device Pairing", bundle: .main))
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(String(localized: "Done", bundle: .main)) { dismiss() }
                                    .keyboardShortcut(.cancelAction)
                                    .accessibilityIdentifier("closePairing")
                            }
                            ToolbarItem(placement: .primaryAction) { refreshButton }
                        }
                }
                #if os(macOS)
                .frame(minWidth: 600, minHeight: 620)
                #endif
            case .embedded:
                // The host window already has a Refresh toolbar item.
                content
            }
        }
        .witermTint()
        .task { model.connect() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.resume() } else { model.suspend() }
        }
        .onDisappear { model.suspend() }
        .onChange(of: model.invitation?.urlString) { copied = false }
        .onChange(of: model.grants, initial: true) { _, grants in onGrantsChanged?(grants) }
        .onChange(of: model.pairing?.id) { _, id in
            permission = .view
            if id == nil { invitationText = "" }
        }
        .animation(WitermMotion.transition(reduceMotion: reduceMotion), value: model.pairing?.status)
        .alert(String(localized: "Revoke Device Access?", bundle: .main), isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })) {
            Button(String(localized: "Cancel", bundle: .main), role: .cancel) { revoking = nil }
            Button(String(localized: "Revoke Access", bundle: .main), role: .destructive) {
                if let grant = revoking { model.revoke(grant) }
                revoking = nil
            }
        } message: {
            Text(String(localized: "This device will need to pair again to regain access.", bundle: .main))
        }
        #if os(iOS)
        .sensoryFeedback(.success, trigger: model.successCount)
        .sheet(isPresented: $scanning, onDismiss: reviewScannedInvitation) {
            PairingScannerView { invitation in
                invitationText = invitation
                scannedInvitation = invitation
            }
        }
        .onChange(of: model.isWorking) { _, working in
            if !working && !scanning { reviewScannedInvitation() }
        }
        #endif
    }

    #if os(iOS)
    private func reviewScannedInvitation() {
        guard let invitation = scannedInvitation, !model.isWorking,
              model.issue?.integrityFailure != true else { return }
        scannedInvitation = nil
        model.prepare(invitation)
    }
    #endif

    private var refreshButton: some View {
        Button(String(localized: "Refresh", bundle: .main), systemImage: "arrow.clockwise", action: model.refresh)
            .disabled(model.isWorking || model.issue?.integrityFailure == true)
            .accessibilityIdentifier("refreshPairing")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let busy = model.busy {
                ActivityRow(busy)
                    .accessibilityIdentifier("pairingActivity")
            }
            if let issue = model.issue { issueCard(issue) }
            identity
            if model.device != nil {
                #if os(macOS)
                hostPairing
                #else
                clientPairing
                #endif
                grants
            } else if !model.isWorking {
                PrimaryButton(String(localized: "Try Again", bundle: .main), systemImage: "arrow.clockwise", fullWidth: true, action: model.connect)
            }
        }
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: 14) {
            #if os(macOS)
            IconTile(systemImage: "laptopcomputer")
            #else
            IconTile(systemImage: "iphone")
            #endif
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "This Device", bundle: .main))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(WitermTheme.secondary)
                if let device = model.device {
                    Text(device.name).font(.headline)
                    fingerprint(device.publicKey)
                } else {
                    Text(String(localized: "Verifying device identity", bundle: .main))
                        .font(.subheadline)
                        .foregroundStyle(WitermTheme.secondary)
                }
                IconText(URL(string: model.serverAddress)?.host ?? model.serverAddress, systemImage: "server.rack")
                    .font(.caption)
                    .foregroundStyle(WitermTheme.secondary)
                    .textSelection(.enabled)
            }
        }
        .witermCard()
    }

    private func issueCard(_ issue: PairingIssue) -> some View {
        IssueBanner(issue.title, message: issue.recovery, systemImage: "exclamationmark.shield.fill") {
            if issue.integrityFailure {
                Button(String(localized: "Leave This Pairing", bundle: .main), action: model.resetPairing)
                    .touchTarget()
            }
        }
        .accessibilityIdentifier("pairingError")
    }

    #if os(macOS)
    private var hostPairing: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(String(localized: "Pair iPhone or iPad", bundle: .main)).font(.headline)
            if let pairing = model.pairing {
                switch pairing.status {
                case .waiting:
                    if let invitation = model.invitation {
                        HStack(alignment: .center, spacing: 16) {
                            PairingQRCode(value: invitation.urlString)
                            VStack(alignment: .leading, spacing: 12) {
                                Text(String(localized: "Paste the invitation on the other device, then compare this device’s fingerprint.", bundle: .main))
                                    .font(.subheadline).foregroundStyle(WitermTheme.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button(copied ? String(localized: "Invitation Copied", bundle: .main) : String(localized: "Copy Pairing Invitation", bundle: .main), systemImage: copied ? "checkmark" : "doc.on.doc") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(invitation.urlString, forType: .string)
                                    copied = true
                                }
                                .buttonStyle(.bordered)
                                .witermControl()
                                .accessibilityIdentifier("copyPairingInvitation")
                                expiry(pairing.expiresAt)
                            }
                        }
                    }
                    Button(String(localized: "Cancel Invitation", bundle: .main), role: .cancel, action: model.reject)
                        .disabled(model.isWorking)
                case .pending:
                    if let client = pairing.client {
                        VStack(alignment: .leading, spacing: 6) {
                            IconText(String(localized: "Pairing Request Received", bundle: .main), systemImage: "iphone.radiowaves.left.and.right")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(WitermTheme.accent)
                            Text(client.name).font(.headline)
                            fingerprint(client.publicKey)
                            Text(String(localized: "Confirm that this is the device you want to pair.", bundle: .main))
                                .font(.subheadline).foregroundStyle(WitermTheme.secondary)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(localized: "Access Level", bundle: .main)).font(.subheadline.weight(.medium))
                            permissionChoice(String(localized: "Read Only", bundle: .main),
                                             detail: String(localized: "Can watch terminal output.", bundle: .main),
                                             systemImage: "eye", value: .view)
                            permissionChoice(String(localized: "Allow Control", bundle: .main),
                                             detail: String(localized: "Can also type into sessions when no one else is in control.", bundle: .main),
                                             systemImage: "keyboard", value: .control)
                        }
                        .disabled(model.isWorking || model.issue?.integrityFailure == true)
                        // Contain, so the options keep their own identifiers.
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("pairingPermission")
                        HStack(spacing: 12) {
                            PrimaryButton(String(localized: "Approve Pairing", bundle: .main), systemImage: "checkmark.shield") { model.approve(permission: permission) }
                                .disabled(!model.mayApprove)
                                .accessibilityIdentifier("approvePairing")
                            Button(String(localized: "Reject", bundle: .main), role: .destructive, action: model.reject)
                                .witermControl()
                                .disabled(model.isWorking)
                        }
                    }
                    expiry(pairing.expiresAt)
                case .approved, .rejected, .expired:
                    pairingOutcome(pairing)
                    PrimaryButton(String(localized: "Create New Invitation", bundle: .main), systemImage: "plus", action: model.create)
                        .disabled(model.isWorking)
                }
            } else {
                Text(String(localized: "Create an invitation, then approve the pairing request on this Mac.", bundle: .main))
                    .font(.subheadline).foregroundStyle(WitermTheme.secondary)
                PrimaryButton(String(localized: "Create Pairing Invitation", bundle: .main), systemImage: "plus", action: model.create)
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("createPairingInvitation")
            }
        }
        .witermCard()
    }

    private func permissionChoice(_ title: String, detail: String, systemImage: String, value: PairingPermission) -> some View {
        let selected = permission == value
        return Button { permission = value } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? WitermTheme.accent : WitermTheme.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    IconText(title, systemImage: systemImage).font(.subheadline.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(WitermTheme.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .touchTarget()
            .background(selected ? WitermTheme.accent.opacity(0.08) : Color.clear, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? WitermTheme.accent.opacity(0.6) : WitermTheme.divider, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The value states the selection. An .isSelected trait on this custom
        // button made AppKit resolve its label recursively and crash.
        .accessibilityValue(selected ? String(localized: "Selected", bundle: .main) : String(localized: "Not Selected", bundle: .main))
        .accessibilityIdentifier(value == .view ? "pairingPermissionView" : "pairingPermissionControl")
    }
    #else
    private var clientPairing: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Pair a Device", bundle: .main)).font(.headline)
            if let pairing = model.pairing {
                HStack(alignment: .top, spacing: 14) {
                    IconTile(systemImage: "desktopcomputer")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pairing.host.name).font(.headline)
                        fingerprint(pairing.host.publicKey)
                    }
                }
                switch pairing.status {
                case .waiting, .pending:
                    Label(String(localized: "Waiting for Approval", bundle: .main), systemImage: "hand.raised")
                        .font(.subheadline.weight(.medium))
                    Text(String(localized: "Compare this device’s name and fingerprint on the other device, then choose its access level.", bundle: .main))
                        .font(.subheadline).foregroundStyle(WitermTheme.secondary)
                    expiry(pairing.expiresAt)
                    Button(String(localized: "Cancel Request", bundle: .main), role: .cancel, action: model.reject)
                        .touchTarget()
                        .disabled(model.isWorking)
                case .approved, .rejected, .expired:
                    pairingOutcome(pairing)
                    Button(String(localized: "Use New Invitation", bundle: .main)) {
                        invitationText = ""
                        model.resetPairing()
                    }
                    .touchTarget()
                }
            } else if let invitation = model.preparedInvitation {
                Text(String(localized: "Device Fingerprint", bundle: .main)).font(.subheadline.weight(.medium))
                fingerprint(invitation.hostPublicKey)
                Text(String(localized: "Compare this fingerprint with the one on the other device before requesting access.", bundle: .main))
                    .font(.subheadline).foregroundStyle(WitermTheme.secondary)
                PrimaryButton(String(localized: "Confirm and Request Pairing", bundle: .main), systemImage: "link", fullWidth: true, action: model.join)
                    .disabled(model.isWorking || model.issue?.integrityFailure == true)
                    .accessibilityIdentifier("joinPairing")
                Button(String(localized: "Enter Invitation Again", bundle: .main)) { model.discardPreparedInvitation() }
                    .frame(maxWidth: .infinity).touchTarget()
                    .disabled(model.isWorking)
            } else {
                Text(String(localized: "On the other device, open Paired Devices and create an invitation.", bundle: .main))
                    .font(.subheadline).foregroundStyle(WitermTheme.secondary)
                Button(String(localized: "Scan Mac’s QR Code", bundle: .main), systemImage: "qrcode.viewfinder") { scanning = true }
                    .buttonStyle(.bordered)
                    .witermControl()
                    .disabled(model.isWorking || model.issue?.integrityFailure == true)
                    .accessibilityIdentifier("scanPairingInvitation")
                TextField(String(localized: "Paste the pairing invitation from the other device", bundle: .main), text: $invitationText, axis: .vertical)
                    .lineLimit(3...6)
                    .font(.system(.subheadline, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(WitermTheme.canvas, in: .rect(cornerRadius: 12, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WitermTheme.divider) }
                    .privacySensitive()
                    .accessibilityIdentifier("pairingInvitationField")
                HStack(spacing: 12) {
                    PasteButton(payloadType: String.self) { values in
                        invitationText = values.first ?? ""
                    }
                    .buttonBorderShape(.capsule)
                    .labelStyle(.titleAndIcon)
                    Spacer(minLength: 0)
                }
                PrimaryButton(String(localized: "Review Invitation", bundle: .main), systemImage: "checkmark.shield", fullWidth: true) { model.prepare(invitationText) }
                    .disabled(model.isWorking || invitationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("preparePairing")
            }
        }
        .witermCard()
    }
    #endif

    private var grants: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(String(localized: "Authorized Devices", bundle: .main)).font(.headline)
                Spacer()
                if presentation == .embedded {
                    refreshButton
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help(String(localized: "Refresh", bundle: .main))
                }
            }
            if model.grants.isEmpty {
                Text(String(localized: "No authorized devices yet.", bundle: .main))
                    .font(.subheadline).foregroundStyle(WitermTheme.secondary)
            } else {
                ForEach(model.grants) { grant in
                    let peer = grant.host.id == model.device?.id ? grant.client : grant.host
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 14) {
                            grantSummary(grant, peer: peer)
                            Spacer(minLength: 8)
                            revokeButton(grant, peer: peer)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            grantSummary(grant, peer: peer)
                            revokeButton(grant, peer: peer)
                        }
                    }
                    if grant.id != model.grants.last?.id { Divider() }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pairedDevices")
        .witermCard()
    }

    private func grantSummary(_ grant: DeviceGrant, peer: PairedDevice) -> some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(systemImage: peer.platform == .macos ? "desktopcomputer" : "iphone", tint: peer.identityHue)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(peer.name).font(.subheadline.weight(.semibold))
                    StatusBadge(grant.permission == .view ? String(localized: "Read-Only Access", bundle: .main) : String(localized: "Allow Control", bundle: .main),
                                systemImage: grant.permission == .view ? "eye" : "keyboard")
                }
                fingerprint(peer.publicKey)
            }
        }
    }

    private func revokeButton(_ grant: DeviceGrant, peer: PairedDevice) -> some View {
        #if os(macOS)
        Button(String(localized: "Revoke access for \(String(peer.name))", bundle: .main), role: .destructive) { revoking = grant }
            .touchTarget()
            .disabled(model.isWorking)
            .accessibilityIdentifier("revokeGrant-\(grant.id)")
        #else
        Button(String(localized: "Revoke Access", bundle: .main), role: .destructive) { revoking = grant }
            .touchTarget()
            .disabled(model.isWorking)
            .accessibilityLabel(String(localized: "Revoke access for \(String(peer.name))", bundle: .main))
            .accessibilityIdentifier("revokeGrant-\(grant.id)")
        #endif
    }

    private func pairingOutcome(_ pairing: DevicePairing) -> some View {
        let text: String
        let symbol: String
        switch pairing.status {
        case .approved where pairing.grant != nil:
            #if os(iOS)
            text = String(localized: "Paired. On your Mac, allow remote access and share a session. Then open Devices on this iPhone or iPad.", bundle: .main)
            #else
            text = String(localized: "Pairing Confirmed", bundle: .main)
            #endif
            symbol = "checkmark.shield.fill"
        case .approved:
            text = String(localized: "Access Revoked", bundle: .main)
            symbol = "link.badge.plus"
        case .expired:
            text = String(localized: "The invitation has expired. Use a new invitation.", bundle: .main)
            symbol = "clock.badge.exclamationmark"
        default:
            text = String(localized: "Pairing Cancelled", bundle: .main)
            symbol = "xmark.circle"
        }
        return IconText(text, systemImage: symbol)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(WitermTheme.accent)
            .accessibilityIdentifier("pairingOutcome")
    }

    @ViewBuilder
    private func fingerprint(_ key: String) -> some View {
        let display = PairingFingerprint.display(publicKey: key)
        #if os(macOS)
        // No selection or label override on macOS; see IconText.
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "Device Fingerprint", bundle: .main)).font(.caption2)
            Text(display)
                .font(.system(.caption, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(WitermTheme.secondary)
        #else
        Text(display)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(WitermTheme.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(String(localized: "Device fingerprint \(String(display))", bundle: .main))
        #endif
    }

    private func expiry(_ date: Date) -> some View {
        IconText(String(localized: "Invitation expires at \(String(date.formatted(date: .omitted, time: .shortened)))", bundle: .main), systemImage: "clock")
            .font(.caption).foregroundStyle(WitermTheme.secondary)
    }
}

private struct PairingQRCode: View {
    let value: String
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 168, height: 168)
                    .padding(12)
                    .background(.white, in: .rect(cornerRadius: 14, style: .continuous))
                    .privacySensitive()
                    .accessibilityHidden(true)
            }
        }
        .task(id: value) {
            image = makeImage()
        }
    }

    private func makeImage() -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
