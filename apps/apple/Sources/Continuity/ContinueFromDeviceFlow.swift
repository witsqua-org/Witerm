#if os(iOS)
import SwiftUI
import UIKit
import WitermCore

/// A request to continue from another device, optionally with a pasted link.
struct ContinueFlowRequest: Identifiable {
    let id = UUID()
    var invitation: String?
}

/// Continue from another device: scan or paste the invitation it shows,
/// check it, and wait for approval; then the session opens. The invitation
/// names its server, and a new server is added only on the person's tap.
/// Pairing codes (`witerm://pair`) and one-session invitations
/// (`witerm://share`) both work here.
struct ContinueFromDeviceFlow: View {
    var invitation: String?
    /// Opens the other device's terminal, attaching at once to a sole session.
    let opened: (ConnectionModel, DeviceGrant) -> Void
    @Environment(ServerList.self) private var servers
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var path: [Route] = []
    @State private var problem: String?
    @State private var typing = false
    @State private var text = ""
    @State private var scanID = UUID()
    @FocusState private var fieldFocused: Bool

    /// Each step carries its invitation, so a pushed screen never reads
    /// state that changed after it was pushed.
    enum Route: Hashable {
        case check(Parsed, scanned: Bool)
        case wait(Parsed, scanned: Bool)
    }

    enum Parsed: Hashable {
        case pairing(PairingInvitation)
        case share(SessionInvitation)

        var link: String {
            switch self {
            case .pairing(let invitation): invitation.urlString
            case .share(let invitation): invitation.urlString
            }
        }

        func hash(into hasher: inout Hasher) { hasher.combine(link) }

        var server: String {
            switch self {
            case .pairing(let invitation): invitation.server
            case .share(let invitation): invitation.server
            }
        }

        var hostPublicKey: String {
            switch self {
            case .pairing(let invitation): invitation.hostPublicKey
            case .share(let invitation): invitation.hostPublicKey
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            scanStep
                .navigationTitle(String(localized: "Continue from Another Device", bundle: .main))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel", bundle: .main)) { dismiss() }
                    }
                }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .check(let parsed, let scanned):
                        ContinueCheckStep(parsed: parsed, scanned: scanned, startOver: startOver) {
                            path.append(.wait(parsed, scanned: scanned))
                        }
                    case .wait(let parsed, let scanned):
                        ContinueWaitStep(parsed: parsed, scanned: scanned, startOver: startOver) { server, grant in
                            dismiss()
                            opened(server, grant)
                        }
                    }
                }
        }
        .witermTint()
        .task {
            if let invitation { read(invitation, scanned: false) }
        }
    }

    // MARK: Scan

    /// The camera first, then paste. Typing an invitation puts the camera
    /// away, so the field and Continue stay above the keyboard. At
    /// accessibility text sizes the actions come first, ahead of the
    /// explanations they would otherwise follow by several screens.
    private var scanStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .font(.subheadline).foregroundStyle(WitermTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("invitationProblem")
                }
                if typeSize.isAccessibilitySize {
                    entryActions
                    scanner
                    instructions
                } else {
                    scanner
                    instructions
                    entryActions
                }
            }
            .readableContent()
            .padding(.vertical, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(WitermTheme.canvas)
    }

    @ViewBuilder private var scanner: some View {
        if !typing {
            InvitationScanner { value in read(value, scanned: true) }
                .id(scanID)
        }
    }

    private var instructions: some View {
        Text(String(localized: "On the other device, choose Continue on Another Device.", bundle: .main))
            .font(.subheadline).foregroundStyle(WitermTheme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Typing (when chosen), paste, and the switch between typing and scanning.
    @ViewBuilder private var entryActions: some View {
        if typing {
            invitationField
            PrimaryButton(String(localized: "Continue", bundle: .main), fullWidth: true) { read(text, scanned: false) }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("preparePairing")
        }
        PasteButton(payloadType: String.self) { values in
            if let value = values.first { read(value, scanned: false) }
        }
        .buttonBorderShape(.capsule)
        .labelStyle(.titleAndIcon)
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("pasteInvitation")
        if !typing {
            Button(String(localized: "Type Invitation…", bundle: .main)) { typing = true; fieldFocused = true }
                .frame(maxWidth: .infinity)
                .touchTarget()
                .accessibilityIdentifier("typeInvitation")
        } else if InvitationScanner.isSupported {
            Button(String(localized: "Scan a Code Instead", bundle: .main), systemImage: "qrcode.viewfinder") {
                fieldFocused = false
                typing = false
            }
            .frame(maxWidth: .infinity)
            .touchTarget()
            .accessibilityIdentifier("scanInvitationInstead")
        }
    }

    /// An invitation is one line of text, so Return continues instead of
    /// starting a new line; a pasted trailing line break does the same.
    private var invitationField: some View {
        TextField(String(localized: "Invitation", bundle: .main), text: $text, axis: .vertical)
            .lineLimit(2...5)
            .font(.system(.subheadline, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .privacySensitive()
            .submitLabel(.continue)
            .focused($fieldFocused)
            .padding(12)
            .background(WitermTheme.surface, in: .rect(cornerRadius: 12, style: .continuous))
            .accessibilityIdentifier("sessionInvitationField")
            .onChange(of: text) { _, value in
                guard value.contains(where: \.isNewline) else { return }
                text = value.filter { !$0.isNewline }
                if !text.trimmingCharacters(in: .whitespaces).isEmpty { read(text, scanned: false) }
            }
    }

    /// Reads either kind of invitation. A scanned code for a saved server goes
    /// straight to the request: the other device still has to approve.
    private func read(_ value: String, scanned: Bool) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed: Parsed
        if let share = try? SessionInvitation(urlString: trimmed) {
            parsed = .share(share)
        } else if let pairing = try? PairingInvitation(urlString: trimmed) {
            parsed = .pairing(pairing)
        } else {
            scanID = UUID()
            problem = trimmed.lowercased().hasPrefix("witerm://share")
                ? String(localized: "This invitation has expired or isn’t valid. Ask for a new one.", bundle: .main)
                : String(localized: "That isn’t a Witerm invitation. On the other device, choose Continue on Another Device to get one.", bundle: .main)
            return
        }
        problem = nil
        let known = servers.servers.contains { ServerAddressKey($0.address) == ServerAddressKey(parsed.server) }
        fieldFocused = false
        path = scanned && known ? [.wait(parsed, scanned: true)] : [.check(parsed, scanned: scanned)]
    }

    /// Back to the first step for another invitation. A typed one is cleared,
    /// since it was already used; the camera restarts.
    private func startOver() {
        path = []
        text = ""
        problem = nil
        scanID = UUID()
    }

    /// Going back for another invitation: by camera when this one was
    /// scanned, otherwise by paste or typing, which a device without a
    /// camera also has.
    static func startOverTitle(scanned: Bool) -> String {
        scanned ? String(localized: "Scan Again", bundle: .main) : String(localized: "Use Another Invitation", bundle: .main)
    }
}

/// One screen: the other device's code and the server the invitation uses.
private struct ContinueCheckStep: View {
    let parsed: ContinueFromDeviceFlow.Parsed
    let scanned: Bool
    let startOver: () -> Void
    let next: () -> Void
    @Environment(ServerList.self) private var servers
    @State private var problem: String?

    private var saved: ConnectionModel? {
        servers.servers.first { ServerAddressKey($0.address) == ServerAddressKey(parsed.server) }
    }

    var body: some View {
        Form {
            Section {
                Text(PairingFingerprint.display(publicKey: parsed.hostPublicKey))
                    .font(.system(.title3, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityLabel(String(localized: "Device code \(PairingFingerprint.display(publicKey: parsed.hostPublicKey))", bundle: .main))
            } header: {
                Text(String(localized: "Other Device’s Code", bundle: .main))
            } footer: {
                Text(scanned ? String(localized: "Scanned from its screen.", bundle: .main)
                     : String(localized: "Check that this matches the code on the other device.", bundle: .main))
            }
            if case .share(let invitation) = parsed {
                Section {
                    LabeledContent(String(localized: "Access", bundle: .main), value: invitation.permission == .control
                                   ? String(localized: "Can watch and type", bundle: .main) : String(localized: "Can only watch", bundle: .main))
                    LabeledContent(String(localized: "Until", bundle: .main), value: invitation.expiresAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section {
                LabeledContent {
                    if saved == nil { StatusBadge(String(localized: "New", bundle: .main), systemImage: "plus") }
                } label: {
                    Label(URL(string: parsed.server)?.host ?? parsed.server, systemImage: "server.rack")
                }
            } header: {
                Text(String(localized: "Relay Server", bundle: .main))
            } footer: {
                if saved == nil {
                    Text(servers.isFull ? ServerList.Failure.full.message
                         : String(localized: "Continuing adds this server. Continue only if you trust the device that showed the code.", bundle: .main))
                }
            }
            if let problem {
                Section { Text(problem).foregroundStyle(WitermTheme.warning) }
            }
            Section {
                PrimaryButton(primaryTitle, fullWidth: true, action: proceed)
                    .disabled(saved == nil && servers.isFull)
                    .accessibilityIdentifier("joinPairing")
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                Button(ContinueFromDeviceFlow.startOverTitle(scanned: scanned), action: startOver)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("continueStartOver")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Check the Other Device", bundle: .main))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var primaryTitle: String {
        switch parsed {
        // Typing waits for the other device to approve; watching opens at once.
        case .pairing: String(localized: "Request Access", bundle: .main)
        case .share(let invitation): invitation.permission == .control
            ? String(localized: "Request Access", bundle: .main) : String(localized: "Watch", bundle: .main)
        }
    }

    private func proceed() {
        if saved == nil {
            do throws(ServerList.Failure) {
                // Never switch servers because a link says so: this tap is the consent.
                try servers.add(parsed.server)
            } catch {
                problem = error.message
                return
            }
        }
        next()
    }
}

/// Waiting for the other device to approve, then opening its session.
private struct ContinueWaitStep: View {
    let parsed: ContinueFromDeviceFlow.Parsed
    let scanned: Bool
    let startOver: () -> Void
    let opened: (ConnectionModel, DeviceGrant) -> Void
    @Environment(ServerList.self) private var servers
    @Environment(\.dismiss) private var dismiss
    @State private var pairing: DevicePairingModel?
    @State private var join = JoinSessionModel()
    @State private var requested = false
    @State private var approvedGrant: DeviceGrant?

    private var server: ConnectionModel? {
        servers.servers.first { ServerAddressKey($0.address) == ServerAddressKey(parsed.server) }
    }

    private var hostName: String? { pairing?.pairing?.host.name }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                IconTile(systemImage: "laptopcomputer.and.iphone", tint: IdentityHue.sky)
                    .scaleEffect(1.6)
                    .padding(.top, 24)
                    .padding(.bottom, 8)
                    .accessibilityHidden(true)
                status
                if case .pairing = parsed, let device = pairing?.device, failureMessage == nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "This Device’s Code", bundle: .main))
                            .font(.footnote).foregroundStyle(WitermTheme.secondary).textCase(.uppercase)
                        Text(PairingFingerprint.display(publicKey: device.publicKey))
                            .font(.system(.title3, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(WitermTheme.surface, in: .rect(cornerRadius: 20, style: .continuous))
                            .accessibilityLabel(String(localized: "This device’s code \(PairingFingerprint.display(publicKey: device.publicKey))", bundle: .main))
                        Text(String(localized: "On \(hostName ?? String(localized: "the other device", bundle: .main)), check that the same code appears, then choose Approve.", bundle: .main))
                            .font(.footnote).foregroundStyle(WitermTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .readableContent()
        }
        .background(WitermTheme.canvas)
        .navigationTitle(failureMessage != nil ? String(localized: "Continue from Another Device", bundle: .main)
                         : hostName.map { String(localized: "Approve on \($0)", bundle: .main) }
                         ?? String(localized: "Approve on the Other Device", bundle: .main))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                // A failed request has nothing left to cancel; this only closes.
                Button(failureMessage != nil ? String(localized: "Cancel", bundle: .main)
                       : String(localized: "Cancel Request", bundle: .main)) { cancel() }
                    .accessibilityIdentifier("cancelContinueRequest")
            }
        }
        .task { start() }
        .onChange(of: pairing?.device?.id) { _, _ in requestPairing() }
        .onChange(of: join.phase) { _, phase in
            if case .alreadyPaired(let grant) = phase { approvedGrant = grant }
        }
        .onChange(of: pairing?.pairing?.status) { _, status in
            if status == .approved, let grant = pairing?.pairing?.grant { approvedGrant = grant }
        }
        // Opening needs the server checked, so its devices can be listed.
        .onChange(of: openable) { _, ready in if ready { open() } }
        .onDisappear { if pairing?.hasLivePairing == true { pairing?.reject() }; pairing?.suspend(); join.cancel() }
        .sensoryFeedback(.success, trigger: approvedGrant?.id)
    }

    private var openable: Bool { approvedGrant != nil && server?.supportsRelay == true }

    /// Why the request can't go on, if it can't. Nothing is waiting then, so
    /// the screen stops asking for approval.
    private var failureMessage: (title: String, detail: String)? {
        if let issue = pairing?.issue { return (issue.title, issue.recovery) }
        if let status = pairing?.pairing?.status, status == .expired || status == .rejected {
            return (status == .expired ? String(localized: "The other device didn’t approve in time.", bundle: .main)
                    : String(localized: "The other device rejected the request.", bundle: .main),
                    scanned ? String(localized: "Scan a new code to try again.", bundle: .main)
                        : String(localized: "Get a new invitation from the other device to try again.", bundle: .main))
        }
        if case .failed(let message) = join.phase {
            return (message, String(localized: "Ask for a new invitation if this one has expired.", bundle: .main))
        }
        if let server, case .failed(let issue) = server.phase, approvedGrant != nil { return (issue.title, issue.recovery) }
        if let server, server.phase.isAvailable, !server.supportsRelay {
            return (String(localized: "This server doesn’t offer remote terminals.", bundle: .main),
                    String(localized: "Ask the other device to use another relay server.", bundle: .main))
        }
        return nil
    }

    @ViewBuilder private var status: some View {
        if let failureMessage {
            failure(failureMessage.title, failureMessage.detail)
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text(waitingText).font(.headline)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("pairingActivity")
        }
    }

    private var waitingText: String {
        if approvedGrant != nil { return String(localized: "Opening the terminal…", bundle: .main) }
        switch join.phase {
        case .working(let message): return message
        case .waitingForApproval: return String(localized: "Waiting for approval…", bundle: .main)
        default: break
        }
        if case .share = parsed { return String(localized: "Opening the terminal…", bundle: .main) }
        return pairing?.pairing == nil ? String(localized: "Sending the request…", bundle: .main)
            : String(localized: "Waiting for approval…", bundle: .main)
    }

    private func failure(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 12) {
            Label(title, systemImage: "exclamationmark.circle").font(.headline).foregroundStyle(WitermTheme.warning)
            Text(detail).font(.subheadline).foregroundStyle(WitermTheme.secondary).multilineTextAlignment(.center)
            Button(ContinueFromDeviceFlow.startOverTitle(scanned: scanned), action: startOver)
                .buttonStyle(.bordered).witermControl()
                .accessibilityIdentifier("continueStartOver")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pairingError")
    }

    private func start() {
        guard let server, !requested else { return }
        if server.phase == .idle { server.check() }
        switch parsed {
        case .pairing:
            let model = DevicePairingModel(serverAddress: server.address)
            pairing = model
            model.connect()
        case .share(let invitation):
            requested = true
            join.join(invitation, server: server) { grant in approvedGrant = grant }
        }
    }

    /// Joins once this device's identity is registered with the server.
    private func requestPairing() {
        guard case .pairing(let invitation) = parsed, let pairing, pairing.device != nil, !requested else { return }
        requested = true
        // Always ask, even when already paired with that device: the Mac shows
        // a pairing code only when it expects a request (a new device, or
        // re-pairing, where approving replaces the current access), and a
        // grant kept here may already be revoked there.
        pairing.prepare(invitation.urlString)
        pairing.join()
    }

    private func open() {
        guard let server, let approvedGrant else { return }
        opened(server, approvedGrant)
    }

    private func cancel() {
        pairing?.reject()
        join.cancel()
        dismiss()
    }
}
#endif
