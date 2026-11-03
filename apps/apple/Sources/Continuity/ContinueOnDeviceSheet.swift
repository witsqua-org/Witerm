#if os(macOS)
import AppKit
import SwiftUI
import WitermCore

/// Opens one terminal on another device (Open On ▸), or pairs a device
/// without one. One question per step, one primary action each; steps
/// already done are skipped. Server, remote access, pairing and per-device
/// access all belong to `ServerList.selected`, the server every pairing
/// screen shows.
///
/// The first step is decided before anything is shown, and only the step's
/// own content cross-fades when it changes. (The whole sheet used to animate
/// on `step`, and the first automatic step change landed while the sheet
/// was being laid out for the first time, so its parts grew out of the
/// top-left corner.)
struct ContinueOnDeviceSheet: View {
    let service: LocalAgentService
    /// The session to continue; nil pairs a device without one.
    let sessionID: String?
    /// Where Open On ▸ asked to go: the device step, a paired device, a new
    /// device, or someone else's.
    var target = OpenOnTarget.choose
    /// What a session was last seen doing, for the session checklist.
    var activity: (String) -> String? = { _ in nil }

    @Environment(ServerList.self) private var servers
    @Environment(MacPairedDevices.self) private var known
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
    /// What the background service reports for each server with remote access on.
    @State private var relays: [LocalRelayStatus] = []
    @State private var reach = Reach.only
    @State private var chosen: Set<String> = []
    @State private var canType = true
    @State private var guestPermission = PairingPermission.view
    @State private var guestDuration: TimeInterval = 3600
    @State private var copied = false
    /// Approving also ends older pairings with a device of the same name and kind.
    @State private var unpairOlder = true
    @State private var editing: ServerEditRequest?
    @State private var problem: String?
    /// The device that may now open the session; the Open step watches for it.
    @State private var continuing: PairedDevice?
    /// Until the person acts, the sheet moves past steps that become done.
    @State private var autoAdvance = true
    /// Whether the first step is decided; until then only the frame shows.
    @State private var ready = false
    /// Whether Open On's device was applied (it is, once).
    @State private var targetApplied = false

    enum Step: Hashable { case server, device, code, approve, open, invite, inviteCode, inviteReview }
    enum Choice: Hashable { case paired(String), new, guest }
    enum Reach: Hashable { case only, chosen, all }

    static let height: CGFloat = 540

    private var server: ConnectionModel? { servers.selected }
    private var session: LocalSessionInfo? { sessionID.flatMap { id in sessions.first { $0.id == id } } }
    private var sessionName: String { session?.name ?? "" }

    var body: some View {
        // A fixed height, so moving between steps never resizes the sheet.
        SheetScaffold(nil, width: .flow, height: Self.height, onEscape: { if step == .open { dismiss() } }) {
            // A new identity per step: the old content fades out and the new
            // one fades in at its final size, never growing.
            VStack(alignment: .leading, spacing: 0) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(step)
                    .transition(.opacity)
            }
            .animation(ready ? WitermMotion.transition(reduceMotion: reduceMotion) : nil, value: step)
            .opacity(ready ? 1 : 0)
        } header: {
            header.opacity(ready ? 1 : 0)
        } leading: {
            footerLeading.opacity(ready ? 1 : 0)
        } trailing: {
            footerTrailing.opacity(ready ? 1 : 0)
        }
        .serverEditor($editing)
        .task {
            remoteAccess.load()
            await service.refresh()
            await reload()
            // The first step appears as it is, without animating into place.
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                if blocker == nil { advanceFromServer() }
                ready = true
            }
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
        // A device that unpaired itself leaves the list here too.
        .onChange(of: known.devices.map(\.id)) { _, _ in
            guard let pairing, !pairing.isWorking, !pairing.hasLivePairing, step == .device || step == .open else { return }
            pairing.refresh()
        }
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

    /// The steps, then the step's title and one line. The terminal's name is
    /// in the first step's title, so there's no separate caption.
    private var header: some View {
        VStack(alignment: .leading, spacing: WitermMetrics.Space.xs) {
            StepStrip(titles: path.map(\.title), current: currentIndex)
                .padding(.bottom, WitermMetrics.Space.xs)
            Text(title(for: step))
                .font(WitermType.pageTitle)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("continueStepTitle")
            if let subtitle {
                Text(subtitle)
                    .font(WitermType.rowDetail)
                    .foregroundStyle(WitermTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Back, or Reject on a review step. Reject has no shortcut: Esc
    /// always means Cancel.
    @ViewBuilder private var footerLeading: some View {
        switch step {
        case .approve, .inviteReview:
            Button(String(localized: "Reject", bundle: .main), role: .destructive) {
                autoAdvance = false
                if step == .approve { pairing?.reject(); step = .code } else { invite?.cancel(agent: agent); step = .invite }
            }
            .accessibilityIdentifier("continueReject")
        case .server, .open:
            EmptyView()
        default:
            Button(String(localized: "Back", bundle: .main), action: back)
                .accessibilityIdentifier("continueBack")
        }
    }

    /// Cancel (Esc), then the step's primary. Approve has no Return: it's a
    /// trust decision.
    @ViewBuilder private var footerTrailing: some View {
        switch step {
        case .open:
            Button(String(localized: "Done", bundle: .main)) { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("continueDone")
        default:
            Button(String(localized: "Cancel", bundle: .main)) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("continueCancel")
            if step == .approve || step == .inviteReview {
                Button(String(localized: "Approve", bundle: .main), action: approve)
                    .buttonStyle(.borderedProminent)
                    .disabled(!mayApprove)
                    .accessibilityIdentifier("continueApprove")
            } else if let primary {
                Button(primary.title, action: primary.action)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(primary.disabled)
                    .accessibilityIdentifier("continuePrimary")
            }
        }
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
                return Primary(title: String(localized: "Add Relay Server…", bundle: .main)) { editing = .add }
            case .serviceOff?:
                if service.state == .requiresApproval {
                    return Primary(title: String(localized: "Open Login Items Settings", bundle: .main), action: service.openSettings)
                }
                return Primary(title: String(localized: "Turn On Terminals", bundle: .main), disabled: service.state == .starting) {
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
                return Primary(title: String(localized: "Show QR Code", bundle: .main)) { showCode() }
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
        let server = PathStep(title: String(localized: "Relay Server", bundle: .main), steps: [.server])
        let approve = PathStep(title: String(localized: "Approve", bundle: .main), steps: [.approve, .inviteReview])
        let open = PathStep(title: sessionID == nil ? String(localized: "Done", bundle: .main) : Self.openStepTitle, steps: [.open])
        if sessionID == nil {
            return [server, PathStep(title: Self.qrStepTitle, steps: [.code]), approve, open]
        }
        if choice == .guest, step != .device, step != .server {
            var steps = [server, PathStep(title: String(localized: "Invite", bundle: .main), steps: [.invite]),
                         PathStep(title: Self.qrStepTitle, steps: [.inviteCode])]
            if guestPermission == .control { steps.append(approve) }
            return steps + [open]
        }
        let device = PathStep(title: String(localized: "Device", bundle: .main), steps: [.device, .code])
        if case .paired? = choice, step != .code, step != .approve { return [server, device, open] }
        return [server, device, approve, open]
    }

    private var currentIndex: Int { path.firstIndex { $0.steps.contains(step) } ?? 0 }

    /// The step where the other device scans: what it scans is the QR code.
    static var qrStepTitle: String { String(localized: "QR Code", bundle: .main) }
    /// The last step's name, "where it opens": its own key, so it can't be
    /// translated as a state ("Opened").
    static var openStepTitle: String {
        // "terminal.open" (Open, 打开): the catalog's English for "step.open" was its key.
        String(localized: "terminal.open", defaultValue: "Open", bundle: .main)
    }

    private func title(for step: Step) -> String {
        switch step {
        case .server: String(localized: "Connect This Mac", bundle: .main)
        case .device: sessionID == nil ? String(localized: "Choose a Device", bundle: .main)
            : String(localized: "Open “\(sessionName)” on Another Device", bundle: .main)
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
        case .server, .device: nil
        case .code: String(localized: "On the other device, choose Add Device.", bundle: .main)
        case .approve:
            String(localized: "Check that \(pairing?.pairing?.client?.name ?? String(localized: "the other device", bundle: .main)) shows this code.", bundle: .main)
        case .invite: String(localized: "They can open “\(sessionName)” once, on one device, without pairing.", bundle: .main)
        case .inviteCode: String(localized: "On their device, choose Add Device.", bundle: .main)
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
        VStack(alignment: .leading, spacing: WitermMetrics.Space.m) {
            // Nothing here reaches another device without a network.
            OfflineBanner()
            if let issue = pairing?.issue, step != .server, step != .invite, step != .inviteCode {
                IssueBanner(issue.title, message: issue.recovery, systemImage: WitermSymbols.unpaired) {
                    if issue.integrityFailure {
                        Button(String(localized: "Start Over", bundle: .main)) { pairing?.resetPairing() }
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
        // UI tests: the fixture needs no relay server.
        if PairingFixture.isActive { return nil }
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
            // A group box rather than a fixed-height Form: it takes the height
            // its rows need at any text size or language.
            GroupBox {
                VStack(alignment: .leading, spacing: WitermMetrics.Space.s) {
                    ContinuationServerPicker()
                    LabeledContent(String(localized: "Status", bundle: .main)) {
                        StatusBadge(server.statusTitle, systemImage: server.statusSymbol, tone: server.statusTone)
                    }
                }
                .padding(WitermMetrics.Space.xs)
            }
            switch blocker {
            case .failed(let issue)?:
                IssueBanner(issue.title, message: issue.recovery) {
                    Button(String(localized: "Edit Address…", bundle: .main)) { editing = .edit(server) }
                }
            case .noContinuation?:
                IssueBanner(String(localized: "\(server.displayName) can’t pair devices", bundle: .main),
                            message: String(localized: "Choose another relay server, or update this one.", bundle: .main))
            case .serviceOff?:
                if let issue = service.issue { IssueBanner(issue) }
            case .remoteAccessOff?:
                note(String(localized: "Paired devices can open only the terminals you allow.", bundle: .main))
                if let issue = remoteAccess.issue { IssueBanner(issue) }
            default:
                EmptyView()
            }
        } else {
            note(String(localized: "Add the relay server your devices will use, such as witerm.example.com.", bundle: .main))
        }
    }

    // MARK: Device

    /// The app's list until this sheet's own pairing has loaded, so the
    /// device step is complete from its first frame.
    private var pairedDevices: [PairedDevice] {
        guard let pairing, let me = pairing.device else {
            return known.pairing?.serverAddress == server?.address ? known.devices : []
        }
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
        VStack(spacing: WitermMetrics.Space.s) {
            ForEach(pairedDevices, id: \.id) { device in
                ChoiceRow(selected: choice == .paired(device.id), title: device.name,
                          detail: deviceDetail(device), symbol: device.platform == .macos ? "laptopcomputer" : "iphone",
                          hue: device.identityHue) { choice = .paired(device.id); autoAdvance = false }
                    .accessibilityIdentifier("continueDevice-\(device.id)")
            }
            ChoiceRow(selected: choice == .new, title: String(localized: "Pair a New Device", bundle: .main),
                      detail: nil, symbol: WitermSymbols.pair, hue: nil) { choice = .new; autoAdvance = false }
                .accessibilityIdentifier("continueNewDevice")
            ChoiceRow(selected: choice == .guest, title: String(localized: "Someone Else’s Device", bundle: .main),
                      detail: String(localized: "A one-time invitation to this terminal only", bundle: .main),
                      symbol: "person.badge.plus", hue: nil) { choice = .guest; autoAdvance = false }
                .accessibilityIdentifier("continueGuest")
            if session?.sharing?.keepPrivate == true, case .paired? = choice {
                note(String(localized: "“\(sessionName)” is private. Allowing a device turns that off.", bundle: .main))
            }
        }
    }

    private func deviceDetail(_ device: PairedDevice) -> String {
        let detail = !reaches(device) ? String(localized: "Can’t open “\(sessionName)” yet", bundle: .main)
            : typing(device) ? String(localized: "Can watch and type in “\(sessionName)”", bundle: .main)
            : String(localized: "Can only watch “\(sessionName)”", bundle: .main)
        // Two pairings with one name (a device set up again) tell themselves apart by date.
        guard pairedDevices.contains(where: { $0.id != device.id && $0.name == device.name }),
              let grant = grant(for: device) else { return detail }
        return detail + " · " + MacDevicesView.pairedDate(grant)
    }

    private func choosePairedDefault() {
        // Open On ▸ named a device: choose it, and go on to Open when it can
        // already open this terminal; otherwise its Allow is the next step.
        if case .device(let id) = target, !targetApplied, let device = pairedDevices.first(where: { $0.id == id }) {
            targetApplied = true
            choice = .paired(id)
            if reaches(device), step == .device { continuing = device; step = .open }
            return
        }
        guard sessionID != nil, choice == nil || !(choiceStillValid), pairing?.device != nil else { return }
        let devices = pairedDevices
        if devices.count == 1 { choice = .paired(devices[0].id) }
        else if let reaching = devices.first(where: reaches) { choice = .paired(reaching.id) }
        else if let first = devices.first { choice = .paired(first.id) }
        else {
            choice = .new
            if autoAdvance, step == .device { showCode() }
        }
    }

    private var choiceStillValid: Bool {
        if case .paired(let id) = choice { return pairedDevices.contains { $0.id == id } }
        return true
    }

    // MARK: QR code

    /// One layout from the first frame: while the QR code is being made, the
    /// tile is blank, Copy is disabled, and the status line says so. Nothing
    /// grows or moves when the QR code arrives. Beside it, this Mac's code,
    /// which the other device compares.
    @ViewBuilder private var codeStep: some View {
        if let status = pairing?.pairing?.status, status == .expired || status == .rejected {
            note(status == .expired ? String(localized: "The QR code expired before a device used it.", bundle: .main)
                 : String(localized: "The request was rejected. Nothing was paired.", bundle: .main))
            Button(String(localized: "Show New QR Code", bundle: .main), action: showCode)
        } else if pairing?.issue == nil {
            let invitation = pairing?.pairing?.status == .waiting ? pairing?.invitation : nil
            HStack(alignment: .top, spacing: WitermMetrics.Space.l) {
                if let invitation {
                    PairingQRCode(value: invitation.urlString)
                } else {
                    // The tile's own size (168 + 2 × 12), blank.
                    RoundedRectangle(cornerRadius: WitermMetrics.Radius.xl, style: .continuous)
                        .fill(WitermTheme.statusFill)
                        .witermOutline(cornerRadius: WitermMetrics.Radius.xl)
                        .frame(width: 192, height: 192)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: WitermMetrics.Space.m) {
                    VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
                        Text(String(localized: "This Mac’s code", bundle: .main))
                            .font(WitermType.meta).foregroundStyle(WitermTheme.secondary)
                        Text(pairing?.device.map { PairingFingerprint.display(publicKey: $0.publicKey) } ?? " ")
                            .font(WitermType.code)
                            .textSelection(.enabled)
                    }
                    serverLine
                    copyInvitationButton(invitation?.urlString)
                        .accessibilityIdentifier("copyPairingInvitation")
                    IconText((pairing?.pairing?.expiresAt).map { String(localized: "Expires at \(String($0.formatted(date: .omitted, time: .shortened)))", bundle: .main) } ?? " ",
                             systemImage: "clock")
                        .font(WitermType.rowDetail).foregroundStyle(WitermTheme.secondary)
                        .opacity(invitation == nil ? 0 : 1)
                    Text(invitation == nil ? String(localized: "Making a QR code…", bundle: .main)
                         : String(localized: "Waiting for the other device…", bundle: .main))
                        .font(WitermType.rowDetail).foregroundStyle(WitermTheme.secondary)
                }
            }
        }
    }

    /// The relay server the QR code belongs to, so it is never made for one you didn't see.
    private var serverLine: some View {
        HStack(spacing: WitermMetrics.Space.s) {
            Image(systemName: WitermSymbols.relayServer).foregroundStyle(WitermTheme.secondary).accessibilityHidden(true)
            Text(server?.displayName ?? "")
            Button(String(localized: "Change…", bundle: .main)) {
                autoAdvance = false
                pairing?.reject()
                invite?.cancel(agent: agent)
                step = .server
            }
            .buttonStyle(.link)
            .witermLinkPointer()
            .help(String(localized: "Use another relay server", bundle: .main))
            .accessibilityIdentifier("continueChangeServer")
        }
        .font(WitermType.rowDetail)
        .accessibilityElement(children: .combine)
    }

    /// Copy Invitation: ✓ Copied for 2 seconds, announced, as in Settings.
    private func copyInvitationButton(_ value: String?) -> some View {
        Button(copied ? String(localized: "Copied", bundle: .main) : String(localized: "Copy Invitation", bundle: .main),
               systemImage: copied ? "checkmark" : "doc.on.doc") { if let value { copy(value) } }
            .disabled(value == nil)
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
    }

    // MARK: Approve

    /// Other pairings this Mac has with a device of the same name and kind:
    /// most likely the same device before it got a new identity.
    private var olderPairings: [DeviceGrant] {
        guard let pairing, let me = pairing.device, let requester = pairing.pairing?.client else { return [] }
        return pairing.grants.filter {
            $0.host.id == me.id && $0.client.id != requester.id
                && $0.client.name == requester.name && $0.client.platform == requester.platform
        }
    }

    @ViewBuilder private var approveStep: some View {
        if let client = pairing?.pairing?.client {
            // Not selectable: on macOS 27.2 a selectable Text with padding and
            // a background under a custom accessibility label sent the label
            // lookup into endless recursion and crashed the app whenever
            // VoiceOver or a UI test read this step. The code is compared by
            // eye, and VoiceOver reads it from the label.
            Text(PairingFingerprint.display(publicKey: client.publicKey))
                .font(WitermType.codeHero)
                .padding(.horizontal, WitermMetrics.Space.m).padding(.vertical, WitermMetrics.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WitermTheme.statusFill, in: .rect(cornerRadius: WitermMetrics.Radius.m, style: .continuous))
                .witermOutline(cornerRadius: WitermMetrics.Radius.m)
                .accessibilityLabel(String(localized: "Device code \(PairingFingerprint.display(publicKey: client.publicKey))", bundle: .main))
            if pairing?.existingGrantForRequest != nil {
                IconText(String(localized: "Already paired. Approving replaces its current access.", bundle: .main), systemImage: "arrow.triangle.2.circlepath")
                    .font(WitermType.rowDetail).foregroundStyle(WitermTheme.warning)
                    .accessibilityIdentifier("pairingReplacesGrant")
            }
            if let older = olderPairings.first {
                Toggle(String(localized: "Also unpair the older “\(older.client.name)”", bundle: .main), isOn: $unpairOlder)
                    .toggleStyle(.checkbox)
                    .help(String(localized: "A device with this name is already paired, probably this one before it was set up again", bundle: .main))
                    .accessibilityIdentifier("pairingUnpairOlder")
            }
            SessionReachPicker(reach: $reach, chosen: $chosen, sessions: reachableSessions, startingSession: session,
                               activity: activity)
            GroupBox {
                PermissionPicker(canType: $canType)
                    .accessibilityIdentifier("continueCanType")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(WitermMetrics.Space.xs)
            }
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
                if let server {
                    checkRow(String(localized: "Paired through \(server.displayName)", bundle: .main))
                    Divider()
                    // The other device reaches this Mac only once the server
                    // has accepted it; say so rather than wait silently.
                    if remoteState(server) == .ready {
                        checkRow(String(localized: "This Mac is online through \(server.displayName)", bundle: .main))
                            .accessibilityIdentifier("continueMacOnline")
                    } else {
                        waitRow(String(localized: "Connecting this Mac to \(server.displayName)…", bundle: .main))
                            .accessibilityIdentifier("continueMacConnecting")
                    }
                }
                Divider()
                if sessionID != nil {
                    checkRow(typing(continuing) ? String(localized: "Can watch and type in “\(sessionName)”", bundle: .main)
                             : String(localized: "Can only watch “\(sessionName)”", bundle: .main))
                } else {
                    checkRow((typing(continuing) ? PermissionPicker.canType : PermissionPicker.watchOnly)
                             + " · " + MacDevicesView.reachSummary(policy(for: continuing), sessions: sessions))
                }
                if sessionID != nil {
                    Divider()
                    if let live {
                        checkRow(live.mode == .control ? String(localized: "Typing on \(continuing.name)", bundle: .main)
                                 : String(localized: "Watching on \(continuing.name)", bundle: .main))
                            .accessibilityIdentifier("continueConnected")
                    } else {
                        waitRow(String(localized: "Waiting for \(continuing.name) to open “\(sessionName)”…", bundle: .main))
                    }
                }
            }
            .background(WitermTheme.statusFill, in: .rect(cornerRadius: WitermMetrics.Radius.m, style: .continuous))
            .witermOutline(cornerRadius: WitermMetrics.Radius.m)
            // Without a terminal the subtitle already says where to change it.
            if sessionID != nil {
                note(live == nil && pairing?.pairing?.status != .approved
                     ? String(localized: "On \(continuing.name), open Witerm. “\(sessionName)” is under Terminals → \(pairing?.device?.name ?? String(localized: "this Mac", bundle: .main)).", bundle: .main)
                     : String(localized: "Change what it can open in Settings → Devices.", bundle: .main))
            }
        } else if case .joined = invite?.phase {
            checkRow(String(localized: "They can open “\(sessionName)” until the invitation ends.", bundle: .main))
                .background(WitermTheme.statusFill, in: .rect(cornerRadius: WitermMetrics.Radius.m, style: .continuous))
                .witermOutline(cornerRadius: WitermMetrics.Radius.m)
            note(String(localized: "End their access at any time in Settings → Devices.", bundle: .main))
        }
    }

    private func remoteState(_ server: ConnectionModel) -> MacRemoteAccessState {
        MacRemoteAccessState(enabled: remoteAccess.isEnabled(for: server.address),
                             serviceReady: service.state == .ready, relays: relays, address: server.address)
    }

    private func waitRow(_ text: String) -> some View {
        HStack(spacing: WitermMetrics.Space.s) {
            ProgressView().controlSize(.small)
            Text(text)
            Spacer(minLength: 0)
        }
        .padding(.vertical, WitermMetrics.Space.s).padding(.horizontal, WitermMetrics.Space.m)
        .accessibilityElement(children: .combine)
    }

    private func checkRow(_ text: String) -> some View {
        HStack(spacing: WitermMetrics.Space.s) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(WitermTheme.positive).accessibilityHidden(true)
            Text(text)
            Spacer(minLength: 0)
        }
        .padding(.vertical, WitermMetrics.Space.s).padding(.horizontal, WitermMetrics.Space.m)
    }

    // MARK: Invite

    @ViewBuilder private var inviteStep: some View {
        if case .failed(let message) = invite?.phase {
            IssueBanner(message, message: String(localized: "Nothing was shared. Try again.", bundle: .main))
        }
        if case .working(let message) = invite?.phase { ActivityRow(message) }
        GroupBox {
            Picker(String(localized: "What they can do", bundle: .main), selection: $guestPermission) {
                Text(PermissionPicker.watchOnly).tag(PairingPermission.view)
                VStack(alignment: .leading) {
                    Text(PermissionPicker.canType)
                    Text(String(localized: "You approve their device first.", bundle: .main))
                        .font(WitermType.meta).foregroundStyle(WitermTheme.secondary)
                }
                .tag(PairingPermission.control)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(WitermMetrics.Space.xs)
            .accessibilityIdentifier("inviteAccess")
        }
        GroupBox {
            Picker(String(localized: "Access Ends After", bundle: .main), selection: $guestDuration) {
                Text(String(localized: "1 hour", bundle: .main)).tag(TimeInterval(3600))
                Text(String(localized: "8 hours", bundle: .main)).tag(TimeInterval(8 * 3600))
                Text(String(localized: "24 hours", bundle: .main)).tag(SessionInvitation.longestAccess)
            }
            .padding(WitermMetrics.Space.xs)
            .accessibilityIdentifier("inviteDuration")
        }
    }

    @ViewBuilder private var inviteCodeStep: some View {
        if case .waiting(let invitation) = invite?.phase {
            HStack(alignment: .top, spacing: WitermMetrics.Space.l) {
                PairingQRCode(value: invitation.urlString)
                VStack(alignment: .leading, spacing: WitermMetrics.Space.m) {
                    serverLine
                    copyInvitationButton(invitation.urlString)
                        .accessibilityIdentifier("copySessionInvitation")
                    IconText(String(localized: "Works once · join within 5 minutes · access until \(String(invitation.expiresAt.formatted(date: .omitted, time: .shortened)))", bundle: .main), systemImage: "clock")
                        .font(WitermType.rowDetail).foregroundStyle(WitermTheme.secondary)
                    HStack(spacing: WitermMetrics.Space.s) {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "Waiting for them to join…", bundle: .main))
                            .font(WitermType.rowDetail).foregroundStyle(WitermTheme.secondary)
                    }
                }
            }
        } else if case .working(let message) = invite?.phase {
            ActivityRow(message)
        }
    }

    @ViewBuilder private var inviteReviewStep: some View {
        if case .review(_, let device) = invite?.phase {
            Text(device.name).font(WitermType.cardTitle)
            Text(PairingFingerprint.display(publicKey: device.publicKey))
                .font(WitermType.codeHero)
                .padding(.horizontal, WitermMetrics.Space.m).padding(.vertical, WitermMetrics.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WitermTheme.statusFill, in: .rect(cornerRadius: WitermMetrics.Radius.m, style: .continuous))
                .witermOutline(cornerRadius: WitermMetrics.Radius.m)
            note(String(localized: "They can watch and type in this terminal until the invitation ends.", bundle: .main))
        }
    }

    // MARK: Actions

    private func note(_ text: String) -> some View {
        Text(text).font(WitermType.rowDetail).foregroundStyle(WitermTheme.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = true
        AccessibilityNotification.Announcement(String(localized: "Copied", bundle: .main)).post()
    }

    private func advanceFromServer() {
        guard step == .server, blocker == nil else { return }
        ensurePairing()
        guard sessionID != nil else { showCode(); return }
        switch target {
        case .newDevice: choice = .new; showCode()
        case .someoneElse: choice = .guest; step = .invite
        case .choose where known.pairing?.serverAddress == server?.address && known.pairing?.device != nil && known.devices.isEmpty:
            // Nothing paired yet: straight to the code, as the device step would.
            choice = .new; showCode()
        case .device, .choose: step = .device; choosePairedDefault()
        }
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
        // Clear an earlier code or problem, but never while the model is at
        // work: resetting suspends it, which cancelled the connection
        // ensurePairing had just started when the sheet opened straight to
        // the code, so it waited forever on "Making a code…".
        if let pairing, !pairing.isWorking, !pairing.hasLivePairing { pairing.resetPairing() }
        ensurePairing()
        step = .code
        createWhenReady()
    }

    /// Creates the invitation once this Mac's identity is ready.
    private func createWhenReady() {
        guard step == .code, let pairing else { return }
        if pairing.device != nil, !pairing.isWorking, pairing.pairing == nil, pairing.issue == nil {
            pairing.create()
        } else if pairing.device == nil || pairing.isWorking {
            // Nothing is making this Mac's identity ready: start it again.
            if pairing.device == nil, !pairing.isWorking, pairing.issue == nil { pairing.connect() }
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
        let older = unpairOlder ? olderPairings : []
        #if DEBUG
        if PairingFixture.isActive {
            PairingFixture.accesses[client.id] = access
            pairing.approve(permission: permission, alsoUnpair: older)
            return
        }
        #endif
        Task {
            do {
                _ = try await agent.deviceAccess(access)
                pairing.approve(permission: permission, alsoUnpair: older)
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
        #if DEBUG
        if PairingFixture.isActive {
            PairingFixture.accesses[device.id] = current.reaching(current.scope, sessions: current.sessionIDs + [session.id])
            accesses[device.id] = PairingFixture.accesses[device.id]
            continuing = device
            step = .open
            return
        }
        #endif
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
        if let status = try? await agent.status() { relays = status.relays ?? [] }
        if let list = try? await agent.sessions() { sessions = list }
        if let stored = try? await agent.deviceAccess() {
            accesses = Dictionary(stored.map { ($0.deviceID, $0) }, uniquingKeysWith: { $1 })
        }
        #if DEBUG
        accesses.merge(PairingFixture.accesses) { $1 }
        #endif
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

}

/// What another device may do, in the shared words: "Can watch and type" or
/// "Can only watch". Never "View Only" or "Can Type" on its own.
struct PermissionPicker: View {
    @Binding var canType: Bool

    static var canType: String { String(localized: "Can watch and type", bundle: .main) }
    static var watchOnly: String { String(localized: "Can only watch", bundle: .main) }

    var body: some View {
        Picker(String(localized: "What it can do", bundle: .main), selection: $canType) {
            Text(Self.canType).tag(true)
            Text(Self.watchOnly).tag(false)
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
    }
}

/// Which terminals a device may open: the starting one, a chosen few, or all.
/// A group box with its own height, never a fixed-height Form, so rows with
/// a second line, longer languages and larger text are never cut off.
struct SessionReachPicker: View {
    @Binding var reach: ContinueOnDeviceSheet.Reach
    @Binding var chosen: Set<String>
    let sessions: [LocalSessionInfo]
    /// The session the flow started from; nil offers only a choice or all.
    let startingSession: LocalSessionInfo?
    var activity: (String) -> String? = { _ in nil }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: WitermMetrics.Space.s) {
                Picker(String(localized: "Terminals", bundle: .main), selection: $reach) {
                    if let startingSession {
                        Text(String(localized: "Only “\(startingSession.name)”", bundle: .main)).tag(ContinueOnDeviceSheet.Reach.only)
                    }
                    Text(String(localized: "Terminals you choose", bundle: .main)).tag(ContinueOnDeviceSheet.Reach.chosen)
                    VStack(alignment: .leading) {
                        Text(String(localized: "All terminals", bundle: .main))
                        Text(String(localized: "Including ones you start later. Private ones stay hidden.", bundle: .main))
                            .font(WitermType.meta).foregroundStyle(WitermTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .tag(ContinueOnDeviceSheet.Reach.all)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .accessibilityIdentifier("pairingScope")
                if reach == .chosen {
                    if sessions.isEmpty {
                        Text(String(localized: "No terminals yet. Choose later in Settings → Devices.", bundle: .main))
                            .font(WitermType.meta).foregroundStyle(WitermTheme.secondary)
                    }
                    ForEach(sessions) { session in
                        let shared = session.sharing?.shared == true
                        Toggle(isOn: Binding(get: { shared || chosen.contains(session.id) },
                                             set: { if $0 { chosen.insert(session.id) } else { chosen.remove(session.id) } })) {
                            VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
                                Text(session.name)
                                if shared {
                                    Text(String(localized: "Shared: every paired device can open it", bundle: .main))
                                        .font(WitermType.meta).foregroundStyle(WitermTheme.secondary)
                                } else if let doing = activity(session.id) {
                                    Text(verbatim: doing).font(WitermType.codeInline).foregroundStyle(WitermTheme.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(shared)
                        .padding(.leading, WitermMetrics.Space.xl)
                        .accessibilityIdentifier("reachSession-\(session.id)")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(WitermMetrics.Space.xs)
        } label: {
            Text(String(localized: "Terminals", bundle: .main)).font(WitermType.cardTitle)
        }
    }
}

/// The relay server every pairing screen uses, shared through
/// `ServerList.selected`; picking one here picks it everywhere.
struct ContinuationServerPicker: View {
    @Environment(ServerList.self) private var servers

    var body: some View {
        if servers.servers.count > 1 {
            Picker(String(localized: "Relay Server", bundle: .main), selection: Binding(
                get: { servers.selected?.id },
                set: { id in if let server = servers.server(id: id) { servers.select(server) } })) {
                ForEach(servers.servers) { server in
                    Text(server.supportsRelay && server.supportsPairing || !server.phase.isAvailable
                         ? server.displayName
                         : String(localized: "\(server.displayName) (can’t pair devices)", bundle: .main))
                        .tag(Optional(server.id))
                }
            }
            .accessibilityIdentifier("continuationServerPicker")
        } else if let server = servers.selected {
            LabeledContent(String(localized: "Relay Server", bundle: .main), value: server.displayName)
        }
    }
}

/// The step names along the top, current one emphasized, done ones checked.
private struct StepStrip: View {
    let titles: [String]
    let current: Int

    var body: some View {
        HStack(spacing: WitermMetrics.Space.s) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                if index > 0 {
                    Rectangle().fill(WitermTheme.hairline).frame(width: WitermMetrics.Space.l, height: 1).accessibilityHidden(true)
                }
                HStack(spacing: WitermMetrics.Space.xs) {
                    if index < current {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(WitermTheme.positive)
                    } else {
                        Text(verbatim: "\(index + 1)")
                            .font(WitermType.meta.weight(.semibold))
                            .frame(width: 16, height: 16)
                            .foregroundStyle(index == current ? WitermTheme.actionLabel : WitermTheme.secondary)
                            .background(index == current ? WitermTheme.accent : Color.clear, in: Circle())
                            .overlay { Circle().strokeBorder(index == current ? Color.clear : WitermTheme.secondary.opacity(0.6)) }
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
        .font(WitermType.meta)
        .accessibilityElement(children: .contain)
    }
}

/// One option in the device step, as a `SelectableCard`.
private struct ChoiceRow: View {
    let selected: Bool
    let title: String
    let detail: String?
    let symbol: String
    let hue: Color?
    let action: () -> Void

    var body: some View {
        SelectableCard(selected: selected, action: action) {
            HStack(spacing: WitermMetrics.Space.m) {
                IconTile(systemImage: symbol, tint: hue ?? WitermTheme.secondary)
                VStack(alignment: .leading, spacing: WitermMetrics.Space.xxs) {
                    Text(title).font(WitermType.rowTitle.weight(.semibold))
                    if let detail {
                        Text(detail).font(WitermType.rowDetail).foregroundStyle(WitermTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark")
                    .font(WitermType.rowTitle.weight(.semibold))
                    .foregroundStyle(WitermTheme.accent)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
        }
    }
}
#endif
