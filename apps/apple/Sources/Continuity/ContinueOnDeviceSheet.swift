#if os(macOS)
import AppKit
import SwiftUI
import WitermCore

/// Continues one session on another device, or pairs a device without one.
/// One question per step, one primary action each; steps already done are
/// skipped. Server, remote access, pairing and per-device access all belong
/// to `ServerList.selected`, the server every pairing screen shows.
struct ContinueOnDeviceSheet: View {
    let service: LocalAgentService
    /// The session to continue; nil pairs a device without one.
    let sessionID: String?
    /// What a session was last seen doing, for the session checklist.
    var activity: (String) -> String? = { _ in nil }

    @Environment(ServerList.self) private var servers
    @Environment(\.localAgent) private var agent
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var remoteAccess = MacRemoteAccessModel()
    @State private var pairing: DevicePairingModel?
    @State private var invite: SessionInviteModel?
    @State private var step = Step.server
    @State private var choice: Choice?
    @State private var sessions: [LocalSessionInfo] = []
    @State private var accesses: [String: LocalDeviceAccess] = [:]
    @State private var guestPairings: Set<String> = []
    @State private var reach = Reach.only
    @State private var chosen: Set<String> = []
    @State private var canType = true
    @State private var guestPermission = PairingPermission.view
    @State private var guestDuration: TimeInterval = 3600
    @State private var copied = false
    @State private var editing: ServerEditRequest?
    @State private var problem: String?
    /// The device that may now open the session; the Open step watches for it.
    @State private var continuing: PairedDevice?
    /// Until the person acts, the sheet moves past steps that become done.
    @State private var autoAdvance = true

    enum Step: Hashable { case server, device, code, approve, open, invite, inviteCode, inviteReview }
    enum Choice: Hashable { case paired(String), new, guest }
    enum Reach: Hashable { case only, chosen, all }

    static let size = CGSize(width: 560, height: 540)

    private var server: ConnectionModel? { servers.selected }
    private var session: LocalSessionInfo? { sessionID.flatMap { id in sessions.first { $0.id == id } } }
    private var sessionName: String { session?.name ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                content
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(WitermTheme.surface)
        .witermTint()
        .serverEditor($editing)
        .animation(WitermMotion.transition(reduceMotion: reduceMotion), value: step)
        .task {
            remoteAccess.load()
            await service.refresh()
            await reload()
            if blocker == nil { advanceFromServer() }
        }
        .task(id: step == .open ? continuing?.id : nil) {
            // Watches for the other device to attach; real attachments only.
            guard step == .open, continuing != nil else { return }
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: blocker == nil) { _, ready in
            if ready, autoAdvance, step == .server { advanceFromServer() }
        }
        .onChange(of: server?.address) { _, _ in serverChanged() }
        .onChange(of: pairing?.device?.id) { _, _ in choosePairedDefault() }
        .onChange(of: pairing?.grants.map(\.id)) { _, _ in
            choosePairedDefault()
            Task { await reload() }
        }
        .onChange(of: pairing?.pairing?.status) { _, status in pairingChanged(status) }
        .onChange(of: invite?.phase) { _, phase in inviteChanged(phase) }
        .onChange(of: step) { _, step in
            AccessibilityNotification.Announcement(title(for: step)).post()
        }
        .onDisappear(perform: cleanUp)
    }

    // MARK: Header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(sessionID == nil ? String(localized: "Pair a Device", bundle: .main)
                 : String(localized: "Continue “\(sessionName)” on Another Device", bundle: .main))
                .font(.caption.weight(.medium))
                .foregroundStyle(WitermTheme.secondary)
            StepStrip(titles: path.map(\.title), current: currentIndex)
                .padding(.vertical, 4)
            Text(title(for: step))
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("continueStepTitle")
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(WitermTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 8) {
            switch step {
            case .approve, .inviteReview:
                Button(String(localized: "Reject", bundle: .main), role: .destructive) {
                    autoAdvance = false
                    if step == .approve { pairing?.reject(); step = .code } else { invite?.cancel(agent: agent); step = .invite }
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("continueReject")
                Spacer()
                // No Return shortcut: approving is a trust decision.
                Button(String(localized: "Approve", bundle: .main), action: approve)
                    .buttonStyle(.borderedProminent)
                    .disabled(!mayApprove)
                    .accessibilityIdentifier("continueApprove")
            case .open:
                Spacer()
                Button(String(localized: "Done", bundle: .main)) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("continueDone")
            default:
                if step != .server {
                    Button(String(localized: "Back", bundle: .main), action: back)
                        .accessibilityIdentifier("continueBack")
                }
                Spacer()
                Button(String(localized: "Cancel", bundle: .main)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("continueCancel")
                if let primary {
                    Button(primary.title, action: primary.action)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(primary.disabled)
                        .accessibilityIdentifier("continuePrimary")
                }
            }
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
    }

    private struct Primary {
        let title: String
        var disabled = false
        let action: () -> Void
    }

    private var primary: Primary? {
        switch step {
        case .server:
            switch blocker {
            case .noServer?:
                return Primary(title: String(localized: "Add Server…", bundle: .main)) { editing = .add }
            case .serviceOff?:
                if service.state == .requiresApproval {
                    return Primary(title: String(localized: "Open Login Items Settings", bundle: .main), action: service.openSettings)
                }
                return Primary(title: String(localized: "Enable Local Terminal", bundle: .main), disabled: service.state == .starting) {
                    Task { await service.start(); remoteAccess.load() }
                }
            case .checking?:
                return Primary(title: String(localized: "Checking…", bundle: .main), disabled: true) {}
            case .failed?, .unchecked?:
                return Primary(title: String(localized: "Check Again", bundle: .main)) { server?.check() }
            case .noContinuation?:
                return nil
            case .remoteAccessOff?:
                return Primary(title: String(localized: "Turn On Remote Access", bundle: .main)) {
                    guard let server else { return }
                    remoteAccess.setEnabled(true, address: server.address)
                    autoAdvance = true
                }
            case nil:
                return Primary(title: String(localized: "Continue", bundle: .main)) { autoAdvance = false; advanceFromServer() }
            }
        case .device:
            switch choice {
            case .paired(let id)?:
                guard let device = pairedDevices.first(where: { $0.id == id }) else { return nil }
                if reaches(device) {
                    return Primary(title: String(localized: "Continue", bundle: .main)) { continuing = device; step = .open }
                }
                return Primary(title: String(localized: "Allow “\(sessionName)”", bundle: .main)) { allow(device) }
            case .new?:
                return Primary(title: String(localized: "Show Code", bundle: .main)) { showCode() }
            case .guest?:
                return Primary(title: String(localized: "Continue", bundle: .main)) { step = .invite }
            case nil:
                return Primary(title: String(localized: "Continue", bundle: .main), disabled: true) {}
            }
        case .invite:
            let working: Bool = { if case .working = invite?.phase { return true }; return false }()
            return Primary(title: String(localized: "Create Invitation", bundle: .main), disabled: agent == nil || working, action: createInvitation)
        case .code, .inviteCode, .approve, .inviteReview, .open:
            return nil
        }
    }

    // MARK: Path

    private struct PathStep { let title: String; let steps: Set<Step> }

    private var path: [PathStep] {
        let server = PathStep(title: String(localized: "Server", bundle: .main), steps: [.server])
        let approve = PathStep(title: String(localized: "Approve", bundle: .main), steps: [.approve, .inviteReview])
        let open = PathStep(title: sessionID == nil ? String(localized: "Done", bundle: .main) : String(localized: "Open", bundle: .main), steps: [.open])
        if sessionID == nil {
            return [server, PathStep(title: String(localized: "Code", bundle: .main), steps: [.code]), approve, open]
        }
        if choice == .guest, step != .device, step != .server {
            var steps = [server, PathStep(title: String(localized: "Invite", bundle: .main), steps: [.invite]),
                         PathStep(title: String(localized: "Code", bundle: .main), steps: [.inviteCode])]
            if guestPermission == .control { steps.append(approve) }
            return steps + [open]
        }
        let device = PathStep(title: String(localized: "Device", bundle: .main), steps: [.device, .code])
        if case .paired? = choice, step != .code, step != .approve { return [server, device, open] }
        return [server, device, approve, open]
    }

    private var currentIndex: Int { path.firstIndex { $0.steps.contains(step) } ?? 0 }

    private func title(for step: Step) -> String {
        switch step {
        case .server: String(localized: "Connect This Mac", bundle: .main)
        case .device: String(localized: "Choose a Device", bundle: .main)
        case .code: String(localized: "Scan with the Other Device", bundle: .main)
        case .approve: String(localized: "Approve \(pairing?.pairing?.client?.name ?? String(localized: "the Other Device", bundle: .main))", bundle: .main)
        case .invite: String(localized: "Invite Someone", bundle: .main)
        case .inviteCode: String(localized: "Share the Invitation", bundle: .main)
        case .inviteReview: String(localized: "Someone Wants to Type", bundle: .main)
        case .open:
            if let continuing { String(localized: "Ready on \(continuing.name)", bundle: .main) }
            else if case .joined(let name) = invite?.phase { String(localized: "\(name) Joined", bundle: .main) }
            else { String(localized: "Paired", bundle: .main) }
        }
    }

    private var subtitle: String? {
        switch step {
        case .server: String(localized: "Your devices reach each other through a continuation server. It relays only end-to-end encrypted data.", bundle: .main)
        case .device: String(localized: "Which device will continue “\(sessionName)”?", bundle: .main)
        case .code: String(localized: "On the other device, open Witerm and choose Continue from Another Device.", bundle: .main)
        case .approve:
            String(localized: "Check that \(pairing?.pairing?.client?.name ?? String(localized: "the other device", bundle: .main)) shows this code.", bundle: .main)
        case .invite: String(localized: "They can open “\(sessionName)” once, on one device, without pairing.", bundle: .main)
        case .inviteCode: String(localized: "On their device, open Witerm and choose Continue from Another Device. Then scan this code or paste the link.", bundle: .main)
        case .inviteReview: String(localized: "Approve only if this is the device you invited.", bundle: .main)
        case .open:
            if let continuing, sessionID != nil {
                String(localized: "“\(sessionName)” opens on \(continuing.name) as soon as it finishes pairing.", bundle: .main)
            } else if sessionID == nil { String(localized: "Change what it can open at any time in Settings → Devices.", bundle: .main) }
            else { nil }
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let issue = pairing?.issue, step != .server, step != .invite, step != .inviteCode {
                IssueBanner(issue.title, message: issue.recovery, systemImage: "exclamationmark.shield.fill") {
                    if issue.integrityFailure {
                        Button(String(localized: "Leave This Pairing", bundle: .main)) { pairing?.resetPairing() }
                    } else {
                        Button(String(localized: "Try Again", bundle: .main)) { pairing?.refresh() }
                    }
                }
                .accessibilityIdentifier("pairingError")
            }
            if let problem { IssueBanner(problem) }
            switch step {
            case .server: serverStep
            case .device: deviceStep
            case .code: codeStep
            case .approve: approveStep
            case .open: openStep
            case .invite: inviteStep
            case .inviteCode: inviteCodeStep
            case .inviteReview: inviteReviewStep
            }
        }
    }

    // MARK: Server

    enum Blocker: Equatable { case noServer, serviceOff, checking, unchecked, failed(ConnectionIssue), noContinuation, remoteAccessOff }

    private var blocker: Blocker? {
        guard let server else { return .noServer }
        if service.state != .ready { return .serviceOff }
        switch server.phase {
        case .checking: return .checking
        case .idle: return .unchecked
        case .failed(let issue): return .failed(issue)
        case .available: break
        }
        guard server.supportsRelay, server.supportsPairing else { return .noContinuation }
        guard remoteAccess.loaded, remoteAccess.isEnabled(for: server.address) else { return .remoteAccessOff }
        return nil
    }

    @ViewBuilder private var serverStep: some View {
        if let server {
            Form {
                Section {
                    ContinuationServerPicker()
                    LabeledContent(String(localized: "Status", bundle: .main)) {
                        StatusBadge(server.statusTitle, systemImage: server.statusSymbol, tone: server.statusTone)
                    }
                    LabeledContent(String(localized: "Remote Access", bundle: .main),
                                   value: remoteAccess.isEnabled(for: server.address) ? String(localized: "On", bundle: .main) : String(localized: "Off", bundle: .main))
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 150)
            .padding(.horizontal, -20)
            switch blocker {
            case .failed(let issue)?:
                IssueBanner(issue.title, message: issue.recovery) {
                    Button(String(localized: "Edit Address…", bundle: .main)) { editing = .edit(server) }
                }
            case .noContinuation?:
                IssueBanner(String(localized: "\(server.displayName) doesn’t offer continuation", bundle: .main),
                            message: String(localized: "Choose another server, or update this one.", bundle: .main))
            case .serviceOff?:
                note(String(localized: "Continuing needs this Mac’s local terminal service.", bundle: .main))
                if let issue = service.issue { IssueBanner(issue) }
            case .remoteAccessOff?:
                note(String(localized: "Turning on remote access lets paired devices reach only the sessions you allow. You can turn it off in Settings → Devices.", bundle: .main))
                if let issue = remoteAccess.issue { IssueBanner(issue) }
            default:
                EmptyView()
            }
        } else {
            note(String(localized: "Add the continuation server your devices will use, such as witerm.example.com.", bundle: .main))
        }
    }

    // MARK: Device

    private var pairedDevices: [PairedDevice] {
        guard let pairing, let me = pairing.device else { return [] }
        return pairing.grants.filter { $0.host.id == me.id && !guestPairings.contains($0.pairingID) }.map(\.client)
    }

    private func grant(for device: PairedDevice) -> DeviceGrant? { pairing?.grants.first { $0.client.id == device.id } }

    private func policy(for device: PairedDevice) -> LocalDeviceAccess { accesses[device.id] ?? .default(for: device.id) }

    /// Whether the device can open the session now, before anything changes.
    private func reaches(_ device: PairedDevice) -> Bool {
        guard let session, session.sharing?.keepPrivate != true else { return false }
        return session.sharing?.shared == true || policy(for: device).lists(session.id)
    }

    private func typing(_ device: PairedDevice) -> Bool {
        grant(for: device)?.permission == .control && policy(for: device).permission == .control
    }

    @ViewBuilder private var deviceStep: some View {
        VStack(spacing: 8) {
            if pairing?.device == nil, pairing?.issue == nil { ActivityRow(String(localized: "Loading paired devices…", bundle: .main)) }
            ForEach(pairedDevices, id: \.id) { device in
                ChoiceRow(selected: choice == .paired(device.id), title: device.name,
                          detail: deviceDetail(device), symbol: device.platform == .macos ? "laptopcomputer" : "iphone",
                          hue: device.identityHue) { choice = .paired(device.id); autoAdvance = false }
                    .accessibilityIdentifier("continueDevice-\(device.id)")
            }
            ChoiceRow(selected: choice == .new, title: String(localized: "Pair a New Device", bundle: .main),
                      detail: String(localized: "A device with Witerm that isn’t paired with this Mac", bundle: .main),
                      symbol: "plus", hue: nil) { choice = .new; autoAdvance = false }
                .accessibilityIdentifier("continueNewDevice")
            ChoiceRow(selected: choice == .guest, title: String(localized: "Someone Else’s Device", bundle: .main),
                      detail: String(localized: "A one-time invitation to this session only", bundle: .main),
                      symbol: "person.badge.plus", hue: nil) { choice = .guest; autoAdvance = false }
                .accessibilityIdentifier("continueGuest")
            if session?.sharing?.keepPrivate == true, case .paired? = choice {
                note(String(localized: "“\(sessionName)” is private. Allowing a device makes it reachable again.", bundle: .main))
            }
        }
    }

    private func deviceDetail(_ device: PairedDevice) -> String {
        guard reaches(device) else { return String(localized: "Paired · can’t open “\(sessionName)” yet", bundle: .main) }
        return typing(device) ? String(localized: "Paired · can open “\(sessionName)”", bundle: .main)
            : String(localized: "Paired · can open “\(sessionName)” · view only", bundle: .main)
    }

    private func choosePairedDefault() {
        guard sessionID != nil, choice == nil || !(choiceStillValid), pairing?.device != nil else { return }
        let devices = pairedDevices
        if devices.count == 1 { choice = .paired(devices[0].id) }
        else if let reaching = devices.first(where: reaches) { choice = .paired(reaching.id) }
        else if let first = devices.first { choice = .paired(first.id) }
        else { choice = .new }
    }

    private var choiceStillValid: Bool {
        if case .paired(let id) = choice { return pairedDevices.contains { $0.id == id } }
        return true
    }

    // MARK: Code

    @ViewBuilder private var codeStep: some View {
        if let pairing, let invitation = pairing.invitation, pairing.pairing?.status == .waiting {
            HStack(alignment: .top, spacing: 18) {
                PairingQRCode(value: invitation.urlString)
                VStack(alignment: .leading, spacing: 10) {
                    if let me = pairing.device {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "This Mac’s code", bundle: .main)).font(.caption).foregroundStyle(WitermTheme.secondary)
                            Text(PairingFingerprint.display(publicKey: me.publicKey)).font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    serverLine
                    Button(copied ? String(localized: "Invitation Copied", bundle: .main) : String(localized: "Copy Invitation", bundle: .main),
                           systemImage: copied ? "checkmark" : "doc.on.doc") { copy(invitation.urlString) }
                        .accessibilityIdentifier("copyPairingInvitation")
                    if let expires = pairing.pairing?.expiresAt {
                        IconText(String(localized: "Expires at \(String(expires.formatted(date: .omitted, time: .shortened)))", bundle: .main), systemImage: "clock")
                            .font(.caption).foregroundStyle(WitermTheme.secondary)
                    }
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "Waiting for the other device…", bundle: .main)).font(.caption).foregroundStyle(WitermTheme.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        } else if let status = pairing?.pairing?.status, status == .expired || status == .rejected {
            note(status == .expired ? String(localized: "The code expired before a device used it.", bundle: .main)
                 : String(localized: "The request was rejected. Nothing was paired.", bundle: .main))
            Button(String(localized: "Show New Code", bundle: .main), action: showCode)
        } else if pairing?.issue == nil {
            ActivityRow(pairing?.busy ?? String(localized: "Creating invitation…", bundle: .main))
        }
    }

    /// The server the code belongs to, so it is never made for one you didn't see.
    private var serverLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "server.rack").foregroundStyle(WitermTheme.secondary).accessibilityHidden(true)
            Text(server?.displayName ?? "")
            Button(String(localized: "Change…", bundle: .main)) {
                autoAdvance = false
                pairing?.reject()
                invite?.cancel(agent: agent)
                step = .server
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("continueChangeServer")
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    // MARK: Approve

    @ViewBuilder private var approveStep: some View {
        if let client = pairing?.pairing?.client {
            Text(PairingFingerprint.display(publicKey: client.publicKey))
                .font(.system(.title3, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WitermTheme.statusFill, in: .rect(cornerRadius: 10, style: .continuous))
                .accessibilityLabel(String(localized: "Device code \(PairingFingerprint.display(publicKey: client.publicKey))", bundle: .main))
            if pairing?.existingGrantForRequest != nil {
                IconText(String(localized: "Already paired. Approving replaces its current access.", bundle: .main), systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline).foregroundStyle(WitermTheme.warning)
                    .accessibilityIdentifier("pairingReplacesGrant")
            }
            SessionReachPicker(reach: $reach, chosen: $chosen, sessions: reachableSessions, startingSession: session,
                               activity: activity)
            Form {
                Toggle(isOn: $canType) {
                    Text(String(localized: "Can Type", bundle: .main))
                    Text(String(localized: "Types alongside this Mac. Pause remote typing at any time.", bundle: .main))
                }
                .accessibilityIdentifier("continueCanType")
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 70)
            .padding(.horizontal, -20)
        }
    }

    /// Sessions a device could be allowed: live and not kept private.
    private var reachableSessions: [LocalSessionInfo] { sessions.filter { $0.sharing?.keepPrivate != true } }

    private var mayApprove: Bool {
        if step == .inviteReview { return invite.map { if case .review = $0.phase { true } else { false } } ?? false }
        guard pairing?.mayApprove == true, agent != nil else { return false }
        switch reach {
        case .all, .only: return true
        case .chosen: return !chosen.isEmpty || reachableSessions.isEmpty
        }
    }

    // MARK: Open

    @ViewBuilder private var openStep: some View {
        if let continuing {
            let live = session?.sharing?.attachments.first { $0.device?.deviceID == continuing.id }
            VStack(spacing: 0) {
                if let server { checkRow(String(localized: "Paired through \(server.displayName)", bundle: .main)) }
                Divider()
                if sessionID != nil {
                    checkRow(typing(continuing) ? String(localized: "Can open “\(sessionName)” and type", bundle: .main)
                             : String(localized: "Can open “\(sessionName)” · view only", bundle: .main))
                } else {
                    checkRow(openSummary(policy(for: continuing)))
                }
                if sessionID != nil {
                    Divider()
                    if let live {
                        checkRow(live.mode == .control ? String(localized: "\(continuing.name) is connected · can type", bundle: .main)
                                 : String(localized: "\(continuing.name) is connected · view only", bundle: .main))
                            .accessibilityIdentifier("continueConnected")
                    } else {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(String(localized: "Waiting for \(continuing.name) to connect…", bundle: .main))
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 9).padding(.horizontal, 12)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .background(WitermTheme.statusFill, in: .rect(cornerRadius: 10, style: .continuous))
            note(sessionID != nil && live == nil && pairing?.pairing?.status != .approved
                 ? String(localized: "On \(continuing.name), open Witerm. “\(sessionName)” is under Terminals → \(pairing?.device?.name ?? String(localized: "this Mac", bundle: .main)).", bundle: .main)
                 : String(localized: "Change what it can open in Settings → Devices.", bundle: .main))
        } else if case .joined = invite?.phase {
            checkRow(String(localized: "They can open “\(sessionName)” until the invitation ends.", bundle: .main))
                .background(WitermTheme.statusFill, in: .rect(cornerRadius: 10, style: .continuous))
            note(String(localized: "End their access at any time in Settings → Devices.", bundle: .main))
        }
    }

    private func checkRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(WitermTheme.positive).accessibilityHidden(true)
            Text(text)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
    }

    // MARK: Invite

    @ViewBuilder private var inviteStep: some View {
        if case .failed(let message) = invite?.phase {
            IssueBanner(message, message: String(localized: "Nothing was shared. Try again.", bundle: .main))
        }
        if case .working(let message) = invite?.phase { ActivityRow(message) }
        Form {
            Section(String(localized: "Access", bundle: .main)) {
                Picker(String(localized: "Access", bundle: .main), selection: $guestPermission) {
                    Text(String(localized: "View Only", bundle: .main)).tag(PairingPermission.view)
                    VStack(alignment: .leading) {
                        Text(String(localized: "Can Type", bundle: .main))
                        Text(String(localized: "You approve the device before it can type.", bundle: .main))
                            .font(.caption).foregroundStyle(WitermTheme.secondary)
                    }
                    .tag(PairingPermission.control)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .accessibilityIdentifier("inviteAccess")
            }
            Section {
                Picker(String(localized: "Access Ends After", bundle: .main), selection: $guestDuration) {
                    Text(String(localized: "1 hour", bundle: .main)).tag(TimeInterval(3600))
                    Text(String(localized: "8 hours", bundle: .main)).tag(TimeInterval(8 * 3600))
                    Text(String(localized: "24 hours", bundle: .main)).tag(SessionInvitation.longestAccess)
                }
                .accessibilityIdentifier("inviteDuration")
            } footer: {
                Text(String(localized: "Share the code or link only with the person you mean to invite. It stops working when it expires or when you end the session.", bundle: .main))
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 250)
        .padding(.horizontal, -20)
    }

    @ViewBuilder private var inviteCodeStep: some View {
        if case .waiting(let invitation) = invite?.phase {
            HStack(alignment: .top, spacing: 18) {
                PairingQRCode(value: invitation.urlString)
                VStack(alignment: .leading, spacing: 10) {
                    serverLine
                    Button(copied ? String(localized: "Link Copied", bundle: .main) : String(localized: "Copy Link", bundle: .main),
                           systemImage: copied ? "checkmark" : "doc.on.doc") { copy(invitation.urlString) }
                        .accessibilityIdentifier("copySessionInvitation")
                    IconText(String(localized: "Works once · join within 5 minutes · access until \(String(invitation.expiresAt.formatted(date: .omitted, time: .shortened)))", bundle: .main), systemImage: "clock")
                        .font(.caption).foregroundStyle(WitermTheme.secondary)
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "Waiting for them to join…", bundle: .main)).font(.caption).foregroundStyle(WitermTheme.secondary)
                    }
                }
            }
        } else if case .working(let message) = invite?.phase {
            ActivityRow(message)
        }
    }

    @ViewBuilder private var inviteReviewStep: some View {
        if case .review(_, let device) = invite?.phase {
            Text(device.name).font(.headline)
            Text(PairingFingerprint.display(publicKey: device.publicKey))
                .font(.system(.title3, design: .monospaced))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WitermTheme.statusFill, in: .rect(cornerRadius: 10, style: .continuous))
            note(String(localized: "They can type in this session until the invitation ends.", bundle: .main))
        }
    }

    // MARK: Actions

    private func note(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(WitermTheme.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = true
    }

    private func advanceFromServer() {
        guard step == .server, blocker == nil else { return }
        ensurePairing()
        if sessionID == nil { showCode() } else { step = .device; choosePairedDefault() }
    }

    private func back() {
        autoAdvance = false
        switch step {
        case .device: step = .server
        case .code:
            pairing?.reject()
            step = sessionID == nil ? .server : .device
        case .invite: step = .device
        case .inviteCode: invite?.cancel(agent: agent); step = .invite
        default: break
        }
    }

    private func ensurePairing() {
        guard let server else { return }
        if pairing?.serverAddress != server.address {
            pairing?.suspend()
            let made = DevicePairingModel(serverAddress: server.address)
            pairing = made
            made.connect()
        } else if pairing?.device == nil, pairing?.isWorking == false {
            pairing?.connect()
        }
    }

    private func showCode() {
        copied = false
        problem = nil
        ensurePairing()
        if let pairing, !pairing.hasLivePairing { pairing.resetPairing() }
        step = .code
        createWhenReady()
    }

    /// Creates the invitation once this Mac's identity is ready.
    private func createWhenReady() {
        guard step == .code, let pairing else { return }
        if pairing.device != nil, !pairing.isWorking, pairing.pairing == nil, pairing.issue == nil {
            pairing.create()
        } else if pairing.device == nil || pairing.isWorking {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                createWhenReady()
            }
        }
    }

    private func pairingChanged(_ status: PairingStatus?) {
        switch status {
        case .pending? where step == .code:
            reach = sessionID == nil ? .chosen : .only
            chosen = sessionID.map { [$0] } ?? []
            canType = true
            step = .approve
        case .approved? where step == .approve:
            continuing = pairing?.pairing?.client
            step = .open
            Task { await reload() }
        case .expired?, .rejected?:
            if step == .approve { step = .code }
        default: break
        }
    }

    /// Stores this Mac's policy before the grant exists, so the device never
    /// reaches more than chosen. A policy alone grants nothing.
    private func approve() {
        if step == .inviteReview {
            if case .review(let invitation, _) = invite?.phase { invite?.approve(invitation) }
            return
        }
        guard let pairing, let client = pairing.pairing?.client, let agent else { return }
        let permission: PairingPermission = canType ? .control : .view
        let listed: [String]
        switch reach {
        case .only: listed = sessionID.map { [$0] } ?? []
        case .chosen: listed = reachableSessions.map(\.id).filter(chosen.contains)
        case .all: listed = []
        }
        let access = LocalDeviceAccess(deviceID: client.id, scope: reach == .all ? .all : .shared,
                                       permission: permission == .view ? .view : .control, sessionIDs: listed)
        Task {
            do {
                _ = try await agent.deviceAccess(access)
                pairing.approve(permission: permission)
            } catch {
                problem = String(localized: "This Mac couldn’t save what the device may open. Nothing was approved.", bundle: .main)
            }
        }
    }

    /// Lets an already paired device open the session.
    private func allow(_ device: PairedDevice) {
        guard let agent, let session else { return }
        autoAdvance = false
        let current = policy(for: device)
        Task {
            do {
                if session.sharing?.keepPrivate == true { _ = try await agent.configure(sessionID: session.id, keepPrivate: false) }
                if !current.lists(session.id) {
                    _ = try await agent.deviceAccess(current.reaching(current.scope, sessions: current.sessionIDs + [session.id]))
                }
                await reload()
                continuing = device
                step = .open
            } catch {
                problem = String(localized: "This Mac couldn’t update what \(device.name) may open. Try again.", bundle: .main)
            }
        }
    }

    private func createInvitation() {
        guard let agent, let server, let sessionID else { return }
        if invite?.serverAddress != server.address { invite = SessionInviteModel(serverAddress: server.address, sessionID: sessionID) }
        guard let invite else { return }
        let permission = guestPermission
        let duration = guestDuration
        Task {
            // A private session can't be shared; inviting someone ends keeping it private.
            if session?.sharing?.keepPrivate == true { _ = try? await agent.configure(sessionID: sessionID, keepPrivate: false) }
            invite.create(permission: permission, lasting: duration, agent: agent)
        }
    }

    private func inviteChanged(_ phase: SessionInviteModel.Phase?) {
        switch phase {
        case .waiting? where step == .invite: step = .inviteCode
        case .review? where step == .inviteCode: step = .inviteReview
        case .joined?: step = .open
        case .failed?: if step != .invite { step = .invite }
        default: break
        }
    }

    private func serverChanged() {
        pairing?.reject()
        pairing?.suspend()
        pairing = nil
        invite?.cancel(agent: agent)
        invite = nil
        choice = nil
        remoteAccess.load()
        if step != .server { step = .server }
    }

    private func reload() async {
        guard let agent else { return }
        if let list = try? await agent.sessions() { sessions = list }
        if let stored = try? await agent.deviceAccess() {
            accesses = Dictionary(stored.map { ($0.deviceID, $0) }, uniquingKeysWith: { $1 })
        }
        if let invites = try? await agent.guests() { guestPairings = Set(invites.map(\.pairingID)) }
    }

    /// An unused code or invitation doesn't outlive the sheet.
    private func cleanUp() {
        if pairing?.pairing?.status == .waiting || pairing?.pairing?.status == .pending { pairing?.reject() }
        pairing?.suspend()
        switch invite?.phase {
        case .waiting?, .review?: invite?.cancel(agent: agent)
        default: invite?.stop()
        }
    }

    private func openSummary(_ access: LocalDeviceAccess) -> String {
        if access.scope == .all { return String(localized: "Can open every session on this Mac", bundle: .main) }
        switch access.sessionIDs.count {
        case 0: return String(localized: "Can’t open any session yet", bundle: .main)
        case 1: return String(localized: "Can open 1 session", bundle: .main)
        default: return String(localized: "Can open \(access.sessionIDs.count) sessions", bundle: .main)
        }
    }
}

/// Which sessions a device may open: the starting one, a chosen few, or all.
struct SessionReachPicker: View {
    @Binding var reach: ContinueOnDeviceSheet.Reach
    @Binding var chosen: Set<String>
    let sessions: [LocalSessionInfo]
    /// The session the flow started from; nil offers only a choice or all.
    let startingSession: LocalSessionInfo?
    var activity: (String) -> String? = { _ in nil }

    var body: some View {
        Form {
            Section(String(localized: "Can Open", bundle: .main)) {
                Picker(String(localized: "Can Open", bundle: .main), selection: $reach) {
                    if let startingSession {
                        Text(String(localized: "Only “\(startingSession.name)”", bundle: .main)).tag(ContinueOnDeviceSheet.Reach.only)
                    }
                    Text(String(localized: "Sessions I Choose…", bundle: .main)).tag(ContinueOnDeviceSheet.Reach.chosen)
                    VStack(alignment: .leading) {
                        Text(String(localized: "All Sessions on This Mac", bundle: .main))
                        Text(String(localized: "Including sessions you start later. Private sessions stay hidden.", bundle: .main))
                            .font(.caption).foregroundStyle(WitermTheme.secondary)
                    }
                    .tag(ContinueOnDeviceSheet.Reach.all)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .accessibilityIdentifier("pairingScope")
                if reach == .chosen {
                    if sessions.isEmpty {
                        Text(String(localized: "No sessions yet. Choose later in Settings → Devices.", bundle: .main))
                            .font(.caption).foregroundStyle(WitermTheme.secondary)
                    }
                    ForEach(sessions) { session in
                        let shared = session.sharing?.shared == true
                        Toggle(isOn: Binding(get: { shared || chosen.contains(session.id) },
                                             set: { if $0 { chosen.insert(session.id) } else { chosen.remove(session.id) } })) {
                            Text(session.name)
                            if shared {
                                Text(String(localized: "Shared with every paired device", bundle: .main))
                            } else if let doing = activity(session.id) {
                                Text(verbatim: doing).font(.caption.monospaced())
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(shared)
                        .padding(.leading, 20)
                        .accessibilityIdentifier("reachSession-\(session.id)")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: reach == .chosen ? CGFloat(120 + max(sessions.count, 1) * 26) : 130)
        .padding(.horizontal, -20)
    }
}

/// The continuation server every pairing screen uses, shared through
/// `ServerList.selected`; picking one here picks it everywhere.
struct ContinuationServerPicker: View {
    @Environment(ServerList.self) private var servers

    var body: some View {
        if servers.servers.count > 1 {
            Picker(String(localized: "Continuation Server", bundle: .main), selection: Binding(
                get: { servers.selected?.id },
                set: { id in if let server = servers.server(id: id) { servers.select(server) } })) {
                ForEach(servers.servers) { server in
                    Text(server.supportsRelay && server.supportsPairing || !server.phase.isAvailable
                         ? server.displayName
                         : String(localized: "\(server.displayName) (doesn’t offer continuation)", bundle: .main))
                        .tag(Optional(server.id))
                }
            }
            .accessibilityIdentifier("continuationServerPicker")
        } else if let server = servers.selected {
            LabeledContent(String(localized: "Continuation Server", bundle: .main), value: server.displayName)
        }
    }
}

/// The step names along the top, current one emphasized, done ones checked.
private struct StepStrip: View {
    let titles: [String]
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                if index > 0 {
                    Rectangle().fill(WitermTheme.divider).frame(width: 16, height: 1).accessibilityHidden(true)
                }
                HStack(spacing: 5) {
                    if index < current {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(WitermTheme.positive)
                    } else {
                        Text(verbatim: "\(index + 1)")
                            .font(.caption2.weight(.semibold))
                            .frame(width: 16, height: 16)
                            .foregroundStyle(index == current ? WitermTheme.actionLabel : WitermTheme.secondary)
                            .background(index == current ? WitermTheme.accent : Color.clear, in: Circle())
                            .overlay { Circle().strokeBorder(index == current ? Color.clear : WitermTheme.divider) }
                    }
                    Text(title)
                        .fontWeight(index == current ? .semibold : .regular)
                        .foregroundStyle(index <= current ? WitermTheme.ink : WitermTheme.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(index < current ? String(localized: "Done", bundle: .main)
                                    : index == current ? String(localized: "Current step", bundle: .main) : "")
            }
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
    }
}

/// One option in a list of mutually exclusive cards.
private struct ChoiceRow: View {
    let selected: Bool
    let title: String
    let detail: String
    let symbol: String
    let hue: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? WitermTheme.accent : WitermTheme.secondary)
                    .accessibilityHidden(true)
                IconTile(systemImage: symbol, tint: hue ?? WitermTheme.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(WitermTheme.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(selected ? WitermTheme.accent.opacity(0.06) : Color.clear, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? WitermTheme.accent.opacity(0.55) : WitermTheme.divider, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected ? String(localized: "Selected", bundle: .main) : String(localized: "Not Selected", bundle: .main))
    }
}
#endif
