#if os(iOS)
import Foundation
import Observation
import os
import UIKit
import WitermCore

struct RemoteTerminalIssue {
    let title: String
    let recovery: String
    let canViewReadOnly: Bool
    /// Someone else is typing; the view names who, when the Mac says.
    let typingElsewhere: Bool

    init(_ error: Error) {
        let relay = error as? RelayError
        let local = error as? LocalAgentClientError
        canViewReadOnly = relay == .sessionBusy || relay == .readOnly
            || local == .rejected(.sessionBusy) || local == .rejected(.readOnly)
        typingElsewhere = relay == .sessionBusy || local == .rejected(.sessionBusy)
        if let error = error as? RelayError {
            switch error {
            case .offline:
                title = String(localized: "Device Is Offline", bundle: .main)
                recovery = String(localized: "Check that the other device is online and allows remote access.", bundle: .main)
            case .untrusted, .revoked:
                title = String(localized: "No Longer Paired", bundle: .main)
                recovery = String(localized: "This device was unpaired, or can’t be verified. To pair again, choose Open On ▸ New Device on the other device.", bundle: .main)
            case .unauthorized:
                title = String(localized: "Unable to Verify Device Identity", bundle: .main)
                recovery = String(localized: "Unlock your device and check the network, then try again.", bundle: .main)
            case .invalidMessage:
                title = String(localized: "Unable to Verify Terminal Connection", bundle: .main)
                recovery = String(localized: "Disconnected. Check that this device is still paired, then reconnect.", bundle: .main)
            case .transport, .unavailable:
                title = String(localized: "Terminal Connection Interrupted", bundle: .main)
                recovery = String(localized: "Check your network and the device, then reconnect.", bundle: .main)
            case .backpressure:
                title = String(localized: "Terminal Cannot Receive Input", bundle: .main)
                recovery = String(localized: "Reconnect to continue.", bundle: .main)
            case .readOnly:
                title = String(localized: "Can Only Watch", bundle: .main)
                recovery = String(localized: "This device can only watch this terminal. Choose Watch.", bundle: .main)
            case .sessionBusy:
                title = String(localized: "Typing on Another Device", bundle: .main)
                recovery = String(localized: "Watch, or try again when it stops typing.", bundle: .main)
            case .sessionUnavailable:
                title = String(localized: "Terminal Unavailable", bundle: .main)
                recovery = String(localized: "It ended, or this device can no longer open it. Pull down to refresh the list.", bundle: .main)
            }
        } else if let error = error as? LocalAgentClientError {
            switch error {
            case .rejected(.sessionBusy):
                title = String(localized: "Typing on Another Device", bundle: .main)
                recovery = String(localized: "Watch, or try again when it stops typing.", bundle: .main)
            case .rejected(.notFound):
                title = String(localized: "Terminal Unavailable", bundle: .main)
                recovery = String(localized: "It ended, or this device can no longer open it. Pull down to refresh the list.", bundle: .main)
            case .rejected(.readOnly):
                title = String(localized: "Can Only Watch", bundle: .main)
                recovery = String(localized: "This device can only watch this terminal. Choose Watch.", bundle: .main)
            default:
                title = String(localized: "Terminal Connection Interrupted", bundle: .main)
                recovery = String(localized: "On the other device, check that Terminals is on in Settings, then try again.", bundle: .main)
            }
        } else {
            let issue = PairingIssue(error)
            title = issue.title
            recovery = issue.recovery
        }
    }
}

/// Where typing is, in the words a paired device can use. The Mac lists the
/// others who can type in a terminal (`writers`): another paired device by
/// name, or nil for the Mac itself. Older Macs don't list them, so the
/// wording falls back to "another device".
enum TypingElsewhere {
    /// The names of everyone else typing, the Mac by its paired name, each
    /// once; nil when the Mac didn't say.
    static func names(_ writers: [LocalWriterInfo]?, hostName: String) -> [String]? {
        guard let writers else { return nil }
        var names: [String] = []
        for writer in writers {
            let name = writer.name ?? hostName
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// "Typing on iPad", or nil when nobody else types or the Mac didn't say.
    static func summary(_ writers: [LocalWriterInfo]?, hostName: String) -> String? {
        guard let names = names(writers, hostName: hostName), !names.isEmpty else { return nil }
        let joined = names.formatted(.list(type: .and))
        return String(localized: "Typing on \(joined)", bundle: .main)
    }

    /// A terminal that refused typing because someone else types.
    static func busyTitle(_ writers: [LocalWriterInfo]?, hostName: String) -> String {
        summary(writers, hostName: hostName) ?? String(localized: "Typing on Another Device", bundle: .main)
    }

    /// A reconnect that found someone else typing and watched instead.
    static func watchingNotice(_ writers: [LocalWriterInfo]?, hostName: String) -> String {
        guard let summary = summary(writers, hostName: hostName) else {
            return String(localized: "Another device is typing, so you’re watching.", bundle: .main)
        }
        return String(localized: "\(summary), so you’re watching.", bundle: .main)
    }
}

enum RemoteTerminalConnectionState: Equatable {
    case browsing, connecting, connected, switching, disconnected, ended
}

/// Whether a device answered when its terminals were last listed.
enum TerminalListing: Equatable {
    case listing, online, offline
    case failed(title: String, recovery: String)
}

@MainActor @Observable
final class RemoteTerminalModel {
    let serverAddress: String
    private(set) var grants: [DeviceGrant] = []
    /// One grant per device, however many pairings it has on this server:
    /// the one that can type if any can, then the newest. Lists show these;
    /// Unpair ends every pairing with the device.
    var devices: [DeviceGrant] { Self.devices(in: grants) }
    /// Devices this one is paired with: `devices` without the grants that
    /// came from a one-terminal invitation (see `SharedTerminals`).
    var pairedDevices: [DeviceGrant] {
        let shared = SharedTerminals.ids()
        return Self.devices(in: grants.filter { !shared.contains($0.id) })
    }
    /// Grants from a one-terminal invitation, for Terminals ▸ Shared with
    /// You. A device that is also paired is listed once, as paired.
    var sharedGrants: [DeviceGrant] {
        let shared = SharedTerminals.ids()
        let paired = Set(pairedDevices.map(\.host.id))
        return grants.filter { shared.contains($0.id) && !paired.contains($0.host.id) }
    }
    /// Each listed grant's terminals, as last listed, so Terminals can show
    /// every device's terminals without opening one. In memory only.
    private(set) var terminals: [String: [LocalSessionInfo]] = [:]
    /// Whether each grant's device answered the last listing.
    private(set) var listing: [String: TerminalListing] = [:]
    @ObservationIgnored private var listings: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var listingGeneration = 0
    private(set) var selectedGrant: DeviceGrant?
    private(set) var sessions: [LocalSessionInfo] = []
    private(set) var selectedSession: LocalSessionInfo?
    private(set) var attachment: (any PairedTerminalLink)?
    // The renderer retains only its in-memory last frame after a disconnect.
    private(set) var displayAttachment: (any PairedTerminalLink)?
    private(set) var attachmentID = UUID()
    private(set) var mode: LocalAttachmentMode = .view
    private(set) var reconnectMode: LocalAttachmentMode = .view
    private(set) var connectionState: RemoteTerminalConnectionState = .browsing
    private(set) var busy: String?
    private(set) var issue: RemoteTerminalIssue?
    private(set) var loaded = false
    @ObservationIgnored private var opensSoleSession = false
    /// An automatic reconnect found someone else typing, so it watches
    /// instead; the view says who, from the latest list.
    private(set) var notice = false
    /// The grant being unpaired from this device, while that's under way.
    private(set) var unpairingID: String?
    /// The device whose pairing just ended while it was open here. Its
    /// terminal and list close at once, so Terminals says why until dismissed.
    private(set) var unpairedName: String?
    /// Whether the app is in the foreground. Reconnects wait for it.
    @ObservationIgnored private var appActive = true
    /// The terminal was interrupted by something the person didn't choose
    /// (the app went to the background or the network dropped), so it
    /// reconnects on its own once the app is active. Leaving, revocation,
    /// and a session ending never set it.
    @ObservationIgnored private var resumeWhenActive = false
    @ObservationIgnored private var automaticAttempts = 0
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var grace: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored private var returnedAt: Date?
    /// The link was let go (or lost) in the background, and the terminal
    /// stays on screen as it was until `resumeSilently` hands its renderer a
    /// new one. It counts as connected meanwhile: nothing about it changes
    /// on screen.
    private(set) var parked = false
    /// Resumes in place so far, for the layout probe and tests.
    private(set) var resumes = 0
    @ObservationIgnored private var liveGrid: (columns: Int, rows: Int)?
    /// A parked link's detach is still waiting for the Mac's ACK; resuming
    /// waits for it, so the Mac has let go before the new link asks to type.
    @ObservationIgnored private var releasing = false
    @ObservationIgnored private var activeID: UUID?
    @ObservationIgnored private var pairing: PairingClient?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var authorizationCheck: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// The renderer of `displayAttachment` (identity `attachmentID`), owned
    /// here rather than by a view, so it can stay connected off screen.
    private(set) var host: PairedTerminalHost?
    /// Terminals left with Back that stay connected, watching (Round 18).
    private(set) var kept: [KeptPairedTerminal] = []
    /// Set when opening a terminal disconnected others to stay within
    /// `PairedKeepAlive.limit`; the terminal says so for a moment.
    private(set) var keptNote: String?
    /// The text size the terminal view last used, for renderers made off screen.
    static var rendererFontSize: CGFloat = 14
    @ObservationIgnored private lazy var tunnels = TunnelGate { [weak self] in self?.liveLinks ?? 0 }

    init(serverAddress: String) {
        self.serverAddress = serverAddress
        PairedKeepAlive.register(self)
    }

    /// Attachments this model holds now: the one on screen (or being
    /// opened) and the kept ones.
    var liveLinks: Int {
        let shown = attachment != nil || parked || (work != nil && selectedSession != nil
            && [.connecting, .switching].contains(connectionState)) ? 1 : 0
        return shown + kept.filter(\.connected).count
    }

    var isInteractive: Bool { (attachment != nil || parked) && connectionState == .connected && busy == nil }
    var canReconnect: Bool {
        selectedGrant != nil && selectedSession != nil && busy == nil && connectionState != .ended
    }
    var canRequestControl: Bool { selectedSession.map { access(for: $0) == .control } ?? false }

    /// What this device may do in a session: the Mac's policy for it, within
    /// the signed grant.
    func access(for session: LocalSessionInfo) -> LocalAttachmentMode {
        guard selectedGrant?.permission == .control else { return .view }
        return sessions.first { $0.id == session.id }?.access ?? session.access ?? .control
    }

    func loadDevices() {
        suspend()
        clearDisplay()
        selectedGrant = nil
        selectedSession = nil
        sessions = []
        grants = []
        loaded = false
        connectionState = .browsing
        cancelListings()
        #if DEBUG
        if RemoteFixture.isActive {
            grants = RemoteFixture.grants
            loaded = true
            listTerminals()
            return
        }
        #endif
        do {
            let pairing = try pairingClient()
            let token = generation
            busy = String(localized: "Loading paired devices…", bundle: .main)
            issue = nil
            work = Task { [weak self] in
                do {
                    _ = try await pairing.register()
                    let candidates = try await pairing.grants()
                    var verified: [DeviceGrant] = []
                    for candidate in candidates {
                        try Task.checkCancellation()
                        do {
                            let grant = try await pairing.trustedRelayGrant(id: candidate.id)
                            guard grant.host.platform == .macos else { continue }
                            verified.append(grant)
                        } catch RelayError.untrusted { continue }
                        catch RelayError.revoked { continue }
                    }
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.grants = verified
                    self.loaded = true
                    self.busy = nil
                    self.work = nil
                    SharedTerminals.prune(keeping: Set(verified.map(\.id)))
                    // A kept terminal whose grant is gone is let go.
                    for entry in self.kept where !verified.contains(where: { $0.id == entry.grant.id }) {
                        _ = self.disconnectKept(entry, acknowledged: false)
                    }
                    self.listTerminals()
                } catch { self?.failed(error, token: token) }
            }
        } catch { issue = RemoteTerminalIssue(error) }
    }

    /// `openingSole` attaches at once when the device can open exactly one
    /// session, as after continuing a session from that device.
    func select(_ grant: DeviceGrant, openingSole: Bool = false) {
        guard busy == nil else { return }
        // A terminal on screen stays connected, off screen (Round 18).
        if !keepDisplayed() { suspend() }
        clearDisplay()
        unpairedName = nil
        selectedGrant = grant
        selectedSession = nil
        sessions = []
        opensSoleSession = openingSole
        // A grant approved just now is listed before the next device listing;
        // listing its sessions verifies it first, as for any grant.
        if !grants.contains(where: { $0.id == grant.id }) { grants.append(grant) }
        refreshSessions()
    }

    func refreshSessions() {
        guard busy == nil, let grant = selectedGrant, attachment == nil else { return }
        cancelWork()
        loaded = false
        #if DEBUG
        if RemoteFixture.isActive {
            sessions = FixtureMac.shared.sessions(for: grant.id)
            terminals[grant.id] = sessions
            loaded = true
            if opensSoleSession, sessions.count == 1 { attach(sessions[0]) }
            opensSoleSession = false
            return
        }
        #endif
        do {
            let pairing = try pairingClient()
            let token = generation
            busy = String(localized: "Loading terminals…", bundle: .main)
            issue = nil
            work = Task { [weak self] in
                do {
                    let grants = try await pairing.grants()
                    guard grants.contains(where: { $0.id == grant.id }) else { throw RelayError.revoked }
                    _ = try await pairing.trustedRelayGrant(id: grant.id)
                    let sessions = try await RemoteTerminalClient(pairing: pairing, grantID: grant.id).sessions()
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.sessions = sessions
                    self.terminals[grant.id] = sessions
                    self.listing[grant.id] = .online
                    self.loaded = true
                    self.busy = nil
                    self.work = nil
                    if let selected = self.selectedSession, !sessions.contains(where: { $0.id == selected.id }) {
                        self.selectedSession = nil
                    }
                    if self.opensSoleSession, sessions.count == 1 {
                        self.opensSoleSession = false
                        self.attach(sessions[0])
                    }
                    self.opensSoleSession = false
                } catch { self?.failed(error, token: token) }
            }
        } catch { issue = RemoteTerminalIssue(error) }
    }

    func attach(_ session: LocalSessionInfo, mode requestedMode: LocalAttachmentMode? = nil) {
        attach(session, mode: requestedMode, automatic: false)
    }

    /// Opens a terminal listed in Terminals, from any of this server's
    /// devices. Another terminal open here is detached first, and the new
    /// one attaches only after that ACK (`attach` does both).
    func open(_ session: LocalSessionInfo, on grant: DeviceGrant, mode requestedMode: LocalAttachmentMode? = nil) {
        guard busy == nil else { return }
        let showingIt = selectedGrant?.id == grant.id && displayAttachment?.session.id == session.id
        // Round 18: a terminal on screen stays connected when another opens.
        if !showingIt, displayAttachment != nil {
            if !keepDisplayed() { clearDisplay(); selectedSession = nil }
        }
        // One kept since Back reopens as it was: no reconnect, no redraw.
        if let entry = kept.first(where: { $0.key == PairedTerminalKey(grantID: grant.id, sessionID: session.id) && $0.connected }) {
            reopen(entry)
            return
        }
        if selectedGrant?.id != grant.id {
            unpairedName = nil
            selectedGrant = grant
            selectedSession = nil
            if !grants.contains(where: { $0.id == grant.id }) { grants.append(grant) }
            sessions = terminals[grant.id] ?? []
        }
        if !sessions.contains(where: { $0.id == session.id }) { sessions.append(session) }
        automaticAttempts = 0
        notice = false
        keptNote = nil
        // At the limit, the terminal left longest ago is disconnected first.
        var releases: [Task<Void, Never>] = []
        if !showingIt || attachment == nil {
            let room = PairedKeepAlive.makeRoom()
            releases = room.releases
            if !room.names.isEmpty { noteDisconnected(room.names) }
        }
        // Opening types when allowed; when someone else is typing it opens
        // with the keyboard down instead, and says who (never by force).
        attach(session, mode: requestedMode, automatic: requestedMode == nil, waitingFor: releases)
    }

    /// What `grant`'s device lets this one do in `session`, as listed.
    static func access(for session: LocalSessionInfo, on grant: DeviceGrant) -> LocalAttachmentMode {
        grant.permission == .control ? session.access ?? .control : .view
    }

    // MARK: Listing every device's terminals

    /// Lists the terminals of every device on this server, each on its own,
    /// so one offline device never hides another's terminals. Read-only: it
    /// never touches an open terminal or the selection.
    func listTerminals() {
        for grant in pairedDevices + sharedGrants { listTerminals(on: grant) }
    }

    private func listTerminals(on grant: DeviceGrant) {
        guard listings[grant.id] == nil else { return }
        if listing[grant.id] == nil { listing[grant.id] = .listing }
        #if DEBUG
        if RemoteFixture.isActive {
            terminals[grant.id] = FixtureMac.shared.sessions(for: grant.id)
            listing[grant.id] = RemoteFixture.offline.contains(grant.id) ? .offline : .online
            return
        }
        #endif
        let pairing: PairingClient
        do { pairing = try pairingClient() } catch { return }
        let token = listingGeneration
        let tunnels = tunnels
        listings[grant.id] = Task { [weak self] in
            var result: Result<[LocalSessionInfo], Error>
            // Kept terminals hold tunnels; a listing waits for a free one.
            await tunnels.acquire()
            defer { tunnels.release() }
            do {
                let current = try await pairing.grants()
                guard current.contains(where: { $0.id == grant.id }) else { throw RelayError.revoked }
                _ = try await pairing.trustedRelayGrant(id: grant.id)
                result = .success(try await RemoteTerminalClient(pairing: pairing, grantID: grant.id).sessions())
            } catch {
                result = .failure(error)
            }
            guard let self, self.listingGeneration == token, !Task.isCancelled else { return }
            self.listings[grant.id] = nil
            switch result {
            case .success(let sessions):
                self.terminals[grant.id] = sessions
                self.listing[grant.id] = .online
            case .failure(let error):
                if Self.isTrustFailure(error), self.selectedGrant?.id != grant.id {
                    // Ended on the other side: it leaves the lists, as a
                    // device listing would drop it.
                    for entry in self.kept where entry.grant.id == grant.id { self.disconnectKept(entry, acknowledged: false) }
                    self.grants.removeAll { $0.id == grant.id }
                    self.terminals[grant.id] = nil
                    self.listing[grant.id] = nil
                    SharedTerminals.forget(grant.id)
                } else if (error as? RelayError) == .offline {
                    self.listing[grant.id] = .offline
                } else {
                    let issue = RemoteTerminalIssue(error)
                    self.listing[grant.id] = .failed(title: issue.title, recovery: issue.recovery)
                }
            }
        }
    }

    private func cancelListings() {
        listingGeneration += 1
        listings.values.forEach { $0.cancel() }
        listings = [:]
        terminals = [:]
        listing = [:]
    }

    /// `releaseGrid`: when typing stops, the size this device watches at,
    /// sent before the detach so the Mac's grid (which this device set while
    /// typing, with the keyboard up) fits the screen it's watched on.
    private func attach(_ session: LocalSessionInfo, mode requestedMode: LocalAttachmentMode?, automatic: Bool,
                        releaseGrid: (columns: Int, rows: Int)? = nil, waitingFor releases: [Task<Void, Never>] = []) {
        guard busy == nil, let grant = selectedGrant else { return }
        let allowed = access(for: session)
        if !automatic {
            automaticAttempts = 0
            notice = false
        }
        resumeWhenActive = false
        parked = false
        retry?.cancel(); retry = nil
        let targetMode = requestedMode ?? allowed
        guard allowed == .control || targetMode == .view else {
            issue = RemoteTerminalIssue(RelayError.readOnly)
            return
        }
        cancelWork()
        let previous = deactivate()
        // Typing or watching the same session, rather than opening another one.
        let changingMode = previous != nil && selectedSession?.id == session.id
        selectedSession = session
        reconnectMode = targetMode
        let switching = previous != nil
        connectionState = switching ? .switching : .connecting
        // The keyboard is the switch: shown types, hidden watches.
        busy = changingMode ? (targetMode == .view ? String(localized: "Hiding Keyboard…", bundle: .main) : String(localized: "Showing Keyboard…", bundle: .main)) : String(localized: "Opening terminal…", bundle: .main)
        issue = nil
        do {
            let open = try linkOpener(for: grant)
            let token = generation
            work = Task { [weak self] in
                do {
                    // A detach ACK confirms the host released the old controller.
                    // A failed release never silently proceeds to a new controller.
                    if let previous {
                        if let grid = releaseGrid, changingMode, targetMode == .view {
                            #if DEBUG
                            Self.layoutLog.notice("stopTyping releaseGrid=\(grid.columns, privacy: .public)x\(grid.rows, privacy: .public)")
                            #endif
                            // Best effort: another writer may own the grid, and the detach decides.
                            try? await previous.resize(columns: grid.columns, rows: grid.rows)
                        }
                        try await previous.detach()
                    }
                    // Kept terminals disconnected to make room have let go.
                    for release in releases { await release.value }
                    try Task.checkCancellation()
                    // Earlier output fills the renderer's scrollback, so a drag scrolls back through it.
                    let next = try await open(session.id, session.columns, session.rows, targetMode)
                    guard let self, self.generation == token, !Task.isCancelled else {
                        await next.abort()
                        return
                    }
                    // The attach reply carries the live grid; the listed access still applies.
                    // Who else types comes from the list, until the next one.
                    let writers = self.sessions.first { $0.id == next.session.id }?.writers ?? session.writers
                    let live = LocalSessionInfo(id: next.session.id, name: next.session.name, createdAt: next.session.createdAt,
                                                columns: next.session.columns, rows: next.session.rows, access: allowed,
                                                writers: writers)
                    self.selectedSession = live
                    self.sessions = self.sessions.map { $0.id == live.id ? live : $0 }
                    self.mode = targetMode
                    self.attachmentID = UUID()
                    self.activeID = self.attachmentID
                    self.liveGrid = (live.columns, live.rows)
                    // A new renderer for the new attachment; the old one's
                    // link has already been let go.
                    let old = self.host
                    self.host = self.makeHost(id: self.attachmentID, link: next, mode: targetMode)
                    old?.stop()
                    self.displayAttachment = next
                    self.attachment = next
                    self.connectionState = .connected
                    self.busy = nil
                    self.work = nil
                    self.automaticAttempts = 0
                } catch {
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    // Coming back never takes control by force: when another
                    // device has it, watch instead and say so.
                    if automatic, targetMode == .control, Self.isBusy(error) {
                        self.busy = nil
                        self.work = nil
                        self.notice = true
                        self.attach(session, mode: .view, automatic: true)
                        return
                    }
                    self.failed(error, token: token, automatic: automatic)
                }
            }
        } catch {
            if let previous { Task { await previous.abort() } }
            failed(error, token: generation)
        }
    }

    /// The keyboard went down: watch, with the Mac's grid set to `grid`
    /// first (the watching view's size) when this device was the one typing.
    func stopTyping(fitting grid: (columns: Int, rows: Int)?) {
        guard isInteractive, mode == .control, let session = selectedSession else { return }
        attach(session, mode: .view, automatic: true, releaseGrid: grid)
    }

    #if DEBUG
    static let layoutLog = Logger(subsystem: "com.witerm", category: "terminal-layout")
    #endif

    func switchMode() {
        guard isInteractive, canRequestControl, let session = selectedSession else { return }
        // Asking to type while someone else does falls back to watching and
        // says who (the automatic path); it never takes typing by force.
        attach(session, mode: mode == .control ? .view : .control, automatic: true)
    }

    func reconnect(as requestedMode: LocalAttachmentMode? = nil) {
        guard canReconnect, let session = selectedSession else { return }
        attach(session, mode: requestedMode ?? reconnectMode)
    }

    func attachmentFailed(_ error: Error, id: UUID) {
        guard id == activeID else { return }
        let previous = deactivate()
        if let previous { Task { await previous.abort() } }
        // Renderer shutdown cancels its callback task. The active attachment
        // identity, rather than that task's cancellation bit, owns this event.
        failed(error, token: generation, allowCancelledCaller: true, automatic: true)
    }

    func attachmentEnded(id: UUID) {
        guard id == activeID else { return }
        let previous = deactivate()
        if let previous { Task { await previous.abort() } }
        resumeWhenActive = false
        connectionState = .ended
        issue = nil
        if let id = selectedSession?.id { sessions.removeAll { $0.id == id } }
    }

    // MARK: Background and return

    /// How long a terminal left in the background is kept: returning within
    /// it continues the same terminal on screen without a reconnect; after
    /// it, the terminal is let go (detach ACK) and returning reconnects as
    /// before. Replaces Round 16's 15-second grace (protocol/relay-v1.md).
    static let backgroundWindow: Duration = .seconds(180)
    /// iOS gives a background task about 30 seconds, not guaranteed. The
    /// connection is let go this long before that runs out, while there's
    /// still time for the Mac's ACK; a suspended app answers no pings and
    /// the relay server would close the tunnel 15 to 20 seconds later anyway.
    static let releaseMargin: TimeInterval = 5
    /// After returning, a link found dead this soon is resumed without a
    /// word (the relay server closed it while the app was suspended).
    static let returnMargin: TimeInterval = 10

    /// The app moved to the background. A live terminal keeps its
    /// connection while iOS lets the app run (`beginBackgroundTask`, no
    /// background modes). Just before that time runs out the link is let go
    /// with an ACK but the screen, its scrollback and the keyboard stay as
    /// they were (`parked`), so returning within `backgroundWindow` resumes
    /// the same terminal in place. Past the window it detaches as before.
    func enterBackground() {
        appActive = false
        backgroundedAt = Date()
        returnedAt = nil
        retry?.cancel(); retry = nil
        // Kept terminals follow the same 3-minute rule (Round 18).
        let keepsAny = kept.contains { $0.state == .live || $0.state == .releasing }
        let shownLive = attachment != nil && busy == nil
        if !shownLive, !parked {
            // Interrupted mid-connect, or already disconnected by accident:
            // pick it up again on return. A parked terminal stays parked.
            if displayAttachment != nil, connectionState != .ended, busy != nil || resumeWhenActive { resumeWhenActive = true }
            suspend()
        }
        guard shownLive || keepsAny else { return }
        if shownLive { resumeWhenActive = true }
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Witerm terminal") { [weak self] in
            // iOS is about to suspend the app: no time left for an
            // acknowledged detach, so close at once (the Mac releases
            // control when the connection closes); the screen stays.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.grace?.cancel(); self.grace = nil
                if self.attachment != nil, !self.appActive { self.park(acknowledged: false) }
                if !self.appActive { self.parkKept(acknowledged: false) }
                self.endBackgroundTask()
            }
        }
        // `backgroundTimeRemaining` is very large until iOS has decided.
        let remaining = UIApplication.shared.backgroundTimeRemaining
        let allowed = remaining.isFinite && remaining < 600 ? remaining : 30
        let window = Double(Self.backgroundWindow.components.seconds)
        let release = min(window, max(1, allowed - Self.releaseMargin))
        #if DEBUG
        Self.layoutLog.notice("background remaining=\(allowed, privacy: .public)s release=\(release, privacy: .public)s")
        #endif
        grace = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(release)) } catch { return }
            guard let self, !self.appActive else { return }
            self.grace = nil
            self.parkKept(acknowledged: true)
            if self.attachment == nil {
                // Only kept terminals: done once their ACKs are in.
                let steps = self.kept.compactMap(\.work)
                Task { [weak self] in
                    for step in steps { await step.value }
                    self?.endBackgroundTask()
                }
            } else if self.backgroundedFor >= window { self.detachForBackground() } else { self.park(acknowledged: true) }
        }
    }

    /// The app is active again. A terminal still connected simply carries
    /// on; one parked within the window resumes in place; one past it
    /// reconnects as before.
    func enterForeground() {
        appActive = true
        returnedAt = Date()
        let away = backgroundedFor
        backgroundedAt = nil
        grace?.cancel(); grace = nil
        #if DEBUG
        Self.layoutLog.notice("foreground away=\(away, privacy: .public)s parked=\(self.parked, privacy: .public) releasing=\(self.releasing, privacy: .public) busy=\(self.busy != nil, privacy: .public) linked=\(self.attachment != nil, privacy: .public)")
        #endif
        if parked {
            if away <= Double(Self.backgroundWindow.components.seconds), busy == nil {
                // In place, not through the visible reconnect; after the
                // release's ACK when it's still under way.
                resumeWhenActive = false
                if !releasing { resumeSilently() }
            } else {
                // Past the window: let go for good, and reconnect as before.
                parked = false
                connectionState = .disconnected
                resumeWhenActive = true
            }
        }
        endBackgroundTask()
        returnKept(withinWindow: away <= Double(Self.backgroundWindow.components.seconds))
        resumeIfNeeded()
        // A list may have changed while away.
        if displayAttachment == nil, selectedGrant != nil, busy == nil { refreshSessions() }
        listTerminals()
    }

    /// Seconds since the app went to the background (0 while active).
    private var backgroundedFor: TimeInterval { backgroundedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    /// Lets the link go but keeps the terminal on screen as it is, renderer,
    /// scrollback and keyboard included, for `resumeSilently`. Nothing typed
    /// meanwhile is kept or resent.
    private func park(acknowledged: Bool) {
        guard let previous = deactivate() else { return }
        parked = true
        cancelWork()
        #if DEBUG
        Self.layoutLog.notice("park acknowledged=\(acknowledged, privacy: .public) after=\(self.backgroundedFor, privacy: .public)s")
        #endif
        guard acknowledged else {
            Task { await previous.abort() }
            return
        }
        let token = generation
        releasing = true
        work = Task { [weak self] in
            // A failed release leaves nothing to resend; the Mac also
            // releases control when this connection closes.
            do { try await previous.detach() } catch { await previous.abort() }
            guard let self else { return }
            self.releasing = false
            guard self.generation == token else { return }
            self.work = nil
            self.endBackgroundTask()
            if self.appActive, self.parked { self.resumeSilently() }
        }
    }

    /// The renderer's link ended or failed. Within the background window, or
    /// just after returning (the relay server closed the tunnel while the
    /// app was suspended), a network failure parks the terminal and resumes
    /// it in place; true means the renderer keeps its screen and waits for
    /// the new link. Anything else goes the usual way.
    func linkLost(_ error: Error, id: UUID) -> Bool {
        guard id == activeID, Self.isTransient(error), busy == nil, displayAttachment != nil else { return false }
        let returnedRecently = returnedAt.map { Date().timeIntervalSince($0) <= Self.returnMargin } ?? false
        guard !appActive || returnedRecently else { return false }
        _ = deactivate()
        parked = true
        cancelWork()
        #if DEBUG
        Self.layoutLog.notice("linkLost resuming in place active=\(self.appActive, privacy: .public)")
        #endif
        if appActive { resumeSilently() }
        return true
    }

    /// Opens a new link to the parked terminal, in the same mode, and hands
    /// it to the same renderer, which keeps the old screen up until the
    /// Mac's redraw has arrived (no blank frame, no Reconnecting). If
    /// someone else types there now, it watches instead and says so; if it
    /// can't connect, the usual Disconnected and Reconnect show.
    private func resumeSilently() {
        guard parked, let grant = selectedGrant, let session = selectedSession else { parked = false; return }
        let resumeMode = mode
        let grid = liveGrid ?? (session.columns, session.rows)
        let started = Date()
        do {
            let open = try linkOpener(for: grant)
            let token = generation
            work = Task { [weak self] in
                do {
                    let next = try await open(session.id, grid.columns, grid.rows, resumeMode)
                    guard let self, self.generation == token, !Task.isCancelled, self.parked else {
                        await next.abort()
                        return
                    }
                    self.parked = false
                    self.resumeWhenActive = false
                    self.work = nil
                    // The same renderer (same identity) takes the new link.
                    self.activeID = self.attachmentID
                    self.host?.replace(next)
                    self.displayAttachment = next
                    self.attachment = next
                    self.resumes += 1
                    #if DEBUG
                    Self.layoutLog.notice("resumed in place in \(Date().timeIntervalSince(started), privacy: .public)s")
                    #endif
                } catch {
                    #if DEBUG
                    Self.layoutLog.notice("resume failed: \(String(describing: error), privacy: .public)")
                    #endif
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.parked = false
                    self.work = nil
                    if resumeMode == .control, Self.isBusy(error) {
                        // Someone else types there now: watch, and say who.
                        self.notice = true
                        self.connectionState = .disconnected
                        self.attach(session, mode: .view, automatic: true)
                        return
                    }
                    self.connectionState = .disconnected
                    self.failed(error, token: token, automatic: true)
                }
            }
        } catch {
            parked = false
            connectionState = .disconnected
            failed(error, token: generation)
        }
    }

    /// The grid the Mac last told the open terminal, for resuming at it.
    func noteGrid(columns: Int, rows: Int, id: UUID) {
        guard id == attachmentID else { return }
        liveGrid = (columns, rows)
    }

    private func detachForBackground() {
        grace = nil
        parked = false
        guard !appActive, busy == nil, let previous = deactivate() else { endBackgroundTask(); return }
        cancelWork()
        connectionState = .disconnected
        // Busy until the detach ACK, so returning mid-release reconnects only
        // after the Mac has let go of the old connection.
        busy = String(localized: "Leaving…", bundle: .main)
        let token = generation
        work = Task { [weak self] in
            // A failed release leaves nothing to resend; the Mac also
            // releases control when this connection closes.
            do { try await previous.detach() } catch { await previous.abort() }
            guard let self, self.generation == token else { return }
            self.busy = nil
            self.work = nil
            self.endBackgroundTask()
            self.resumeIfNeeded()
        }
    }

    private func resumeIfNeeded() {
        guard appActive, resumeWhenActive, !parked, attachment == nil, busy == nil, displayAttachment != nil,
              canReconnect, let session = selectedSession else { return }
        resumeWhenActive = false
        attach(session, mode: reconnectMode, automatic: true)
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Network and relay interruptions are retried a few times with growing
    /// pauses while the app is active. Anything about trust, permission or
    /// the session itself waits for the person.
    private func scheduleAutomaticReconnect(after error: Error) {
        guard Self.isTransient(error), displayAttachment != nil, connectionState != .ended,
              selectedSession != nil else { return }
        guard appActive else { resumeWhenActive = true; return }
        guard automaticAttempts < 4 else { return }
        automaticAttempts += 1
        let delay = Duration.seconds(1 << (automaticAttempts - 1))
        let token = generation
        retry = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.generation == token, self.appActive else { return }
            self.retry = nil
            self.resumeWhenActive = true
            self.resumeIfNeeded()
        }
    }

    private static func isTransient(_ error: Error) -> Bool {
        if let relay = error as? RelayError {
            return [.offline, .transport, .unavailable, .backpressure].contains(relay)
        }
        if error is URLError { return true }
        if let local = error as? LocalAgentClientError, case .rejected = local { return false }
        return error is LocalAgentClientError
    }

    private static func isBusy(_ error: Error) -> Bool {
        (error as? RelayError) == .sessionBusy || (error as? LocalAgentClientError) == .rejected(.sessionBusy)
    }

    func dismissNotice() { notice = false }

    /// Who else can type in the open terminal, as of the latest list.
    var openWriters: [LocalWriterInfo]? {
        guard let id = selectedSession?.id else { return nil }
        return sessions.first { $0.id == id }?.writers
    }

    /// Lists the device's terminals again only to learn who else types in
    /// the one being watched, so its title can say where typing is. Changes
    /// nothing else; false when the list couldn't be had.
    @discardableResult
    func refreshWriters() async -> Bool {
        guard isInteractive, mode == .view, canRequestControl, let grant = selectedGrant,
              let id = selectedSession?.id else { return false }
        let token = generation
        let listed: [LocalSessionInfo]
        #if DEBUG
        if RemoteFixture.isActive { listed = FixtureMac.shared.sessions(for: grant.id) } else {
            await tunnels.acquire()
            defer { tunnels.release() }
            guard let pairing, let fresh = try? await RemoteTerminalClient(pairing: pairing, grantID: grant.id).sessions() else { return false }
            listed = fresh
        }
        #else
        await tunnels.acquire()
        defer { tunnels.release() }
        guard let pairing, let fresh = try? await RemoteTerminalClient(pairing: pairing, grantID: grant.id).sessions() else { return false }
        listed = fresh
        #endif
        guard generation == token, selectedGrant?.id == grant.id, selectedSession?.id == id else { return false }
        sessions = sessions.map { session in
            guard let fresh = listed.first(where: { $0.id == session.id }) else { return session }
            return LocalSessionInfo(id: session.id, name: session.name, createdAt: session.createdAt, columns: session.columns,
                                    rows: session.rows, access: session.access, writers: fresh.writers)
        }
        return true
    }

    /// Ends this device's pairing with `grant`'s device, through the server
    /// (either side may). A terminal open from it is left first, after the
    /// detach ACK; then it leaves the lists. Throws when the server wasn't
    /// told, leaving the device listed so Unpair can be tried again.
    func unpair(_ grant: DeviceGrant) async throws {
        guard unpairingID == nil else { return }
        unpairingID = grant.id
        defer { unpairingID = nil }
        #if DEBUG
        let pairing: PairingClient? = RemoteFixture.isActive ? nil : try pairingClient()
        #else
        let pairing: PairingClient? = try pairingClient()
        #endif
        // Every pairing with that device ends, so it leaves the lists: an
        // earlier one that was never cleaned up would otherwise keep it there.
        let ending = Self.pairings(endedBy: grant, in: grants)
        // Kept terminals from it are let go first, each with the Mac's ACK.
        await disconnectKept(grantIDs: Set(ending.map(\.id)), acknowledged: true)
        if let selected = selectedGrant, ending.contains(where: { $0.id == selected.id }) {
            cancelWork()
            resumeWhenActive = false
            notice = false
            if let previous = deactivate() {
                connectionState = .disconnected
                busy = String(localized: "Leaving…", bundle: .main)
                do { try await previous.detach() } catch { await previous.abort() }
                busy = nil
            }
            clearDisplay()
            selectedSession = nil
            sessions = []
            selectedGrant = nil
            connectionState = .browsing
        }
        for pairingToEnd in ending {
            try await pairing?.revoke(grantID: pairingToEnd.id, pairingID: pairingToEnd.pairingID)
            grants.removeAll { $0.id == pairingToEnd.id }
            terminals[pairingToEnd.id] = nil
            listing[pairingToEnd.id] = nil
            SharedTerminals.forget(pairingToEnd.id)
        }
        if unpairedName == grant.host.name { unpairedName = nil }
        UIAccessibility.post(notification: .announcement,
                             argument: String(localized: "Unpaired from \(grant.host.name)", bundle: .main))
    }

    /// Ends a one-terminal invitation's grant early, from this device (a
    /// participant may delete its own grant on the relay server). Only that
    /// grant ends: it can't be undone, and the other device must invite
    /// this one again. A terminal open from it is left first, after the
    /// detach ACK. Throws when the server wasn't told, leaving it listed.
    func endInvitation(_ grant: DeviceGrant) async throws {
        guard unpairingID == nil else { return }
        unpairingID = grant.id
        defer { unpairingID = nil }
        #if DEBUG
        let pairing: PairingClient? = RemoteFixture.isActive ? nil : try pairingClient()
        #else
        let pairing: PairingClient? = try pairingClient()
        #endif
        await disconnectKept(grantIDs: [grant.id], acknowledged: true)
        if selectedGrant?.id == grant.id {
            cancelWork()
            resumeWhenActive = false
            notice = false
            if let previous = deactivate() {
                connectionState = .disconnected
                busy = String(localized: "Leaving…", bundle: .main)
                do { try await previous.detach() } catch { await previous.abort() }
                busy = nil
            }
            clearDisplay()
            selectedSession = nil
            sessions = []
            selectedGrant = nil
            connectionState = .browsing
        }
        try await pairing?.revoke(grantID: grant.id, pairingID: grant.pairingID)
        grants.removeAll { $0.id == grant.id }
        terminals[grant.id] = nil
        listing[grant.id] = nil
        SharedTerminals.forget(grant.id)
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Invitation ended", bundle: .main))
    }

    /// The pairings Unpair ends: `grant` and any other this device holds with
    /// the same device, the one asked for first.
    /// Groups pairings by device, in the order devices first appear.
    static func devices(in grants: [DeviceGrant]) -> [DeviceGrant] {
        var order: [String] = []
        var best: [String: DeviceGrant] = [:]
        func rank(_ grant: DeviceGrant) -> (Int, Date) { (grant.permission == .control ? 1 : 0, grant.createdAt) }
        for grant in grants {
            if let current = best[grant.host.id] {
                if rank(grant) > rank(current) { best[grant.host.id] = grant }
            } else {
                order.append(grant.host.id)
                best[grant.host.id] = grant
            }
        }
        return order.compactMap { best[$0] }
    }

    static func pairings(endedBy grant: DeviceGrant, in grants: [DeviceGrant]) -> [DeviceGrant] {
        [grant] + grants.filter { $0.id != grant.id && $0.host.id == grant.host.id }
    }

    /// Back to the device's terminals. An open terminal is left first (it
    /// keeps running there), and the list shows after the detach ACK.
    func showSessions() {
        guard busy == nil else { return }
        resumeWhenActive = false
        parked = false
        notice = false
        let previous = deactivate()
        cancelWork()
        issue = nil
        guard let previous else {
            clearDisplay()
            selectedSession = nil
            connectionState = .browsing
            refreshSessions()
            return
        }
        // Keep the noninteractive renderer until the detach ACK; dismantling
        // its output consumer first can race the release handshake.
        connectionState = .disconnected
        let token = generation
        busy = String(localized: "Disconnecting…", bundle: .main)
        work = Task { [weak self] in
            do {
                try await previous.detach()
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.clearDisplay()
                self.selectedSession = nil
                self.connectionState = .browsing
                self.busy = nil
                self.work = nil
                self.refreshSessions()
            } catch { self?.failed(error, token: token) }
        }
    }

    /// The model is going away (its relay server was removed or changed):
    /// every terminal, shown or kept, is let go.
    func shutDown() {
        suspend()
        for entry in kept { disconnectKept(entry, acknowledged: false) }
    }

    func suspend() {
        parked = false
        cancelWork()
        let previous = deactivate()
        if let previous { Task { await previous.abort() } }
        if displayAttachment != nil, connectionState != .ended { connectionState = .disconnected }
    }

    func cancelWork() {
        generation += 1
        work?.cancel()
        retry?.cancel()
        retry = nil
        authorizationCheck?.cancel()
        work = nil
        authorizationCheck = nil
        busy = nil
        // A parked terminal stays connected on screen until it resumes.
        if attachment == nil, !parked, displayAttachment != nil, connectionState != .ended {
            connectionState = .disconnected
        }
    }

    private func deactivate() -> (any PairedTerminalLink)? {
        let previous = attachment
        attachment = nil
        activeID = nil
        return previous
    }

    private func clearDisplay() {
        resumeWhenActive = false
        parked = false
        displayAttachment = nil
        host?.stop()
        host = nil
        attachmentID = UUID()
    }

    private func failed(_ error: Error, token: Int, allowCancelledCaller: Bool = false, automatic: Bool = false) {
        guard generation == token, allowCancelledCaller || !Task.isCancelled else { return }
        busy = nil
        work = nil
        if Self.isTrustFailure(error) {
            authorizationUnavailable()
            return
        }
        if displayAttachment != nil { connectionState = .disconnected }
        issue = RemoteTerminalIssue(error)
        if automatic { scheduleAutomaticReconnect(after: error) }
        // A peer-side revoke closes the transport. Refresh signed grants so the
        // UI removes stale reconnect actions rather than misreporting an outage.
        guard let grant = selectedGrant, let pairing else { return }
        authorizationCheck = Task { [weak self] in
            do {
                let latest = try await pairing.grants()
                guard let self, self.generation == token, self.selectedGrant?.id == grant.id,
                      !Task.isCancelled else { return }
                if !latest.contains(where: { $0.id == grant.id }) { self.authorizationUnavailable() }
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                if Self.isTrustFailure(error) { self.authorizationUnavailable() }
            }
        }
    }

    private static func isTrustFailure(_ error: Error) -> Bool {
        if let relay = error as? RelayError { return relay == .revoked || relay == .untrusted }
        return (error as? PairingClientError) == .invalidProof
    }

    func dismissUnpaired() { unpairedName = nil }

    private func authorizationUnavailable() {
        resumeWhenActive = false
        notice = false
        if let name = selectedGrant?.host.name {
            unpairedName = name
            UIAccessibility.post(notification: .announcement,
                                 argument: String(localized: "No Longer Paired with \(name)", bundle: .main))
        }
        let previous = deactivate()
        if let previous { Task { await previous.abort() } }
        if let id = selectedGrant?.id {
            for entry in kept where entry.grant.id == id { disconnectKept(entry, acknowledged: false) }
            grants.removeAll { $0.id == id }
            terminals[id] = nil
            listing[id] = nil
            SharedTerminals.forget(id)
        }
        selectedGrant = nil
        selectedSession = nil
        sessions = []
        clearDisplay()
        connectionState = .browsing
        loaded = true
        busy = nil
        issue = RemoteTerminalIssue(RelayError.revoked)
    }

    /// Opens a link to one of `grant`'s terminals: through the relay
    /// server, after checking the grant again, or (DEBUG) to the fixture's Mac.
    private func linkOpener(for grant: DeviceGrant) throws
        -> @Sendable (String, Int, Int, LocalAttachmentMode) async throws -> any PairedTerminalLink {
        #if DEBUG
        if RemoteFixture.isActive {
            return { id, columns, rows, mode in
                try await FixtureMac.shared.attach(grant: grant, sessionID: id, columns: columns, rows: rows, mode: mode, history: true)
            }
        }
        #endif
        let pairing = try pairingClient()
        return { id, columns, rows, mode in
            _ = try await pairing.trustedRelayGrant(id: grant.id)
            return try await RemoteTerminalClient(pairing: pairing, grantID: grant.id).attach(
                sessionID: id, columns: columns, rows: rows, mode: mode, history: true)
        }
    }

    private func pairingClient() throws -> PairingClient {
        if let pairing { return pairing }
        let client = try PairingClient(serverAddress: serverAddress, deviceName: PairingDeviceName.current, platform: .ios)
        pairing = client
        return client
    }
}

// MARK: Staying connected after Back (Round 18)

extension RemoteTerminalModel {
    /// A renderer for `link`, owned here; what it reports goes to whoever
    /// holds the terminal when it happens (on screen or kept).
    fileprivate func makeHost(id: UUID, link: any PairedTerminalLink, mode: LocalAttachmentMode) -> PairedTerminalHost {
        PairedTerminalHost(id: id, link: link, mode: mode, fontSize: Self.rendererFontSize, routes: PairedTerminalRoutes(
            isParked: { [weak self] in self?.isParked(id) ?? false },
            onLinkLost: { [weak self] in self?.linkLost($0, host: id) ?? false },
            onGrid: { [weak self] in self?.noteGrid(columns: $0, rows: $1, host: id) },
            onFailure: { [weak self] in self?.renderFailed($0, host: id) },
            onEnded: { [weak self] in self?.renderEnded(host: id) }))
    }

    private func keptEntry(host id: UUID) -> KeptPairedTerminal? { kept.first { $0.host.id == id } }

    private func isParked(_ id: UUID) -> Bool {
        if id == attachmentID { return parked }
        // Between links (releasing typing, parked, resuming) the renderer waits.
        return keptEntry(host: id).map { $0.state != .live } ?? false
    }

    private func linkLost(_ error: Error, host id: UUID) -> Bool {
        if id == attachmentID { return linkLost(error, id: id) }
        guard let entry = keptEntry(host: id), entry.state == .live, Self.isTransient(error) else { return false }
        // Lost while kept: resumed in place once (now, or on return).
        entry.set(.parked)
        if appActive { resume(entry) }
        return true
    }

    private func noteGrid(columns: Int, rows: Int, host id: UUID) {
        if id == attachmentID { noteGrid(columns: columns, rows: rows, id: id) } else { keptEntry(host: id)?.grid = (columns, rows) }
    }

    private func renderFailed(_ error: Error, host id: UUID) {
        if id == attachmentID { return attachmentFailed(error, id: id) }
        guard let entry = keptEntry(host: id) else { return }
        _ = disconnectKept(entry, acknowledged: false)
        if Self.isTrustFailure(error) { keptGrantEnded(entry.grant) }
    }

    /// The Mac ended a kept terminal: it leaves the list at once.
    private func renderEnded(host id: UUID) {
        if id == attachmentID { return attachmentEnded(id: id) }
        guard let entry = keptEntry(host: id) else { return }
        _ = disconnectKept(entry, acknowledged: false)
        terminals[entry.grant.id]?.removeAll { $0.id == entry.session.id }
        sessions.removeAll { $0.id == entry.session.id && selectedGrant?.id == entry.grant.id }
    }

    /// Whether `session` on `grant`'s device is connected here: on screen
    /// or kept. Terminals lists it as Connected.
    func isConnected(_ session: LocalSessionInfo, on grant: DeviceGrant) -> Bool {
        if selectedGrant?.id == grant.id, displayAttachment?.session.id == session.id,
           attachment != nil || parked, connectionState == .connected { return true }
        return kept.contains { $0.key == PairedTerminalKey(grantID: grant.id, sessionID: session.id) && $0.connected }
    }

    /// Back (the button, the edge swipe): the terminal stays connected,
    /// watching, off screen, and Terminals shows the list at once. Typing
    /// stops first, as when the keyboard hides: the Mac's grid is set to the
    /// watching size, typing is let go with the Mac's ACK, and a watching
    /// link takes over, all after the list is back. A terminal that isn't
    /// connected (its last frame) is simply put away.
    func leaveKeepingConnection() {
        guard busy == nil else { return }
        guard keepDisplayed() else {
            // Nothing live to keep: as Disconnect, which also handles a
            // terminal not shown (a list).
            return showSessions()
        }
        issue = nil
        refreshSessions()
    }

    /// Disconnect, from the terminal's menu or its row: it's let go (the
    /// Mac's ACK first) and is no longer Connected; it keeps running on the Mac.
    func disconnect() { showSessions() }

    /// Disconnect from a row: the terminal on screen, or a kept one.
    func disconnect(_ session: LocalSessionInfo, on grant: DeviceGrant) {
        if selectedGrant?.id == grant.id, displayAttachment?.session.id == session.id { return showSessions() }
        guard let entry = kept.first(where: { $0.key == PairedTerminalKey(grantID: grant.id, sessionID: session.id) }) else { return }
        _ = disconnectKept(entry)
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Disconnected from \(session.name)", bundle: .main))
    }

    /// Moves the live terminal on screen into `kept`. False when there's
    /// none (nothing on screen, or it isn't connected).
    @discardableResult
    fileprivate func keepDisplayed() -> Bool {
        guard busy == nil, !parked, let grant = selectedGrant, let session = selectedSession, let host,
              let link = attachment, displayAttachment != nil, connectionState == .connected else { return false }
        let typing = mode == .control
        cancelWork()
        _ = deactivate()
        let entry = KeptPairedTerminal(grant: grant, session: session, host: host, link: link,
                                       grid: liveGrid ?? (session.columns, session.rows), state: typing ? .releasing : .live)
        kept.append(entry)
        // Off screen now: the renderer stays with the entry.
        self.host = nil
        displayAttachment = nil
        attachmentID = UUID()
        selectedSession = nil
        connectionState = .browsing
        notice = false
        keptNote = nil
        resumeWhenActive = false
        if typing { releaseTyping(entry) }
        #if DEBUG
        Self.layoutLog.notice("kept session=\(session.id, privacy: .public) typing=\(typing, privacy: .public) kept=\(self.kept.count, privacy: .public) live=\(PairedKeepAlive.liveCount, privacy: .public) keptKB=\(PairedKeepAlive.keptBytes / 1024, privacy: .public)")
        #endif
        return true
    }

    /// Typing stops as when the keyboard hides (Round 16 and 17): the Mac
    /// gets the watching size, the typing link is let go with its ACK (its
    /// renderer stays until then), and a watching link with its own renderer
    /// takes over. A release that fails disconnects the terminal: nothing is
    /// ever resent, and typing is never kept off screen.
    private func releaseTyping(_ entry: KeptPairedTerminal) {
        let previous = entry.link, old = entry.host
        old.freeze()
        let fit = old.surface.watchingFit
        let open: (@Sendable (String, Int, Int, LocalAttachmentMode) async throws -> any PairedTerminalLink)?
        open = try? linkOpener(for: entry.grant)
        entry.work = Task { [weak self, weak entry] in
            // Best effort: another writer may own the grid, and the detach decides.
            try? await previous.resize(columns: fit.columns, rows: fit.rows)
            do { try await previous.detach() } catch {
                await previous.abort()
                guard let self, let entry else { return }
                _ = self.disconnectKept(entry, acknowledged: false)
                return
            }
            guard let self, let entry, entry.state == .releasing, let open else {
                if let entry, entry.state == .releasing { _ = self?.disconnectKept(entry, acknowledged: false) }
                return
            }
            do {
                let next = try await open(entry.session.id, fit.columns, fit.rows, .view)
                guard entry.state == .releasing, self.kept.contains(where: { $0 === entry }) else {
                    await next.abort()
                    return
                }
                let watching = self.makeHost(id: UUID(), link: next, mode: .view)
                entry.adopt(host: watching, link: next)
                entry.grid = (next.session.columns, next.session.rows)
                entry.set(.live)
                old.stop()
            } catch {
                _ = self.disconnectKept(entry, acknowledged: false)
                if Self.isTrustFailure(error) { self.keptGrantEnded(entry.grant) }
            }
        }
    }

    /// Shows a kept terminal again: the same renderer and attachment, so
    /// nothing reconnects or redraws. It shows with the keyboard down
    /// (watching); the keyboard button or a tap types, as usual. One still
    /// changing (releasing, resuming) is shown once that's done.
    private func reopen(_ entry: KeptPairedTerminal) {
        guard entry.state != .live else { return adopt(entry) }
        busy = String(localized: "Opening terminal…", bundle: .main)
        selectedGrant = entry.grant
        let token = generation
        let step = entry.work
        work = Task { [weak self, weak entry] in
            await step?.value
            guard let self, self.generation == token, !Task.isCancelled else { return }
            self.busy = nil
            self.work = nil
            if let entry, entry.state == .live, self.kept.contains(where: { $0 === entry }) {
                self.adopt(entry)
            } else if let entry {
                // It couldn't stay connected: open it the usual way.
                self.open(entry.session, on: entry.grant)
            }
        }
    }

    private func adopt(_ entry: KeptPairedTerminal) {
        kept.removeAll { $0 === entry }
        cancelWork()
        if selectedGrant?.id != entry.grant.id {
            selectedGrant = entry.grant
            if !grants.contains(where: { $0.id == entry.grant.id }) { grants.append(entry.grant) }
        }
        if let listed = terminals[entry.grant.id] { sessions = listed }
        if !sessions.contains(where: { $0.id == entry.session.id }) { sessions.append(entry.session) }
        let live = LocalSessionInfo(id: entry.session.id, name: entry.session.name, createdAt: entry.session.createdAt,
                                    columns: entry.grid.columns, rows: entry.grid.rows, access: entry.session.access,
                                    writers: entry.session.writers)
        selectedSession = live
        unpairedName = nil
        issue = nil
        notice = false
        keptNote = nil
        mode = entry.host.mode
        reconnectMode = .view
        attachmentID = entry.host.id
        activeID = entry.host.id
        liveGrid = entry.grid
        host = entry.host
        displayAttachment = entry.link
        attachment = entry.link
        connectionState = .connected
        #if DEBUG
        Self.layoutLog.notice("reopened kept session=\(entry.session.id, privacy: .public) kept=\(self.kept.count, privacy: .public)")
        #endif
    }

    /// Lets a kept terminal go: with the Mac's ACK unless `acknowledged` is
    /// false (its link already failed or ended). Returns the release, for
    /// opening another only after it.
    @discardableResult
    func disconnectKept(_ entry: KeptPairedTerminal, acknowledged: Bool = true) -> Task<Void, Never> {
        let wasLive = entry.state == .live
        entry.set(.closing)
        kept.removeAll { $0 === entry }
        let link = entry.link, host = entry.host, step = entry.work
        step?.cancel()
        return Task {
            if acknowledged, wasLive {
                do { try await link.detach() } catch { await link.abort() }
            } else {
                await link.abort()
            }
            host.stop()
        }
    }

    /// Every kept terminal of `grant` is let go (unpaired, invitation
    /// ended, revoked). Returns once each has let go.
    func disconnectKept(grantIDs: Set<String>, acknowledged: Bool) async {
        let releases = kept.filter { grantIDs.contains($0.grant.id) }.map { disconnectKept($0, acknowledged: acknowledged) }
        for release in releases { await release.value }
    }

    /// A kept terminal found its grant gone: the device leaves the lists,
    /// and Terminals says why, as when it happens on screen.
    private func keptGrantEnded(_ grant: DeviceGrant) {
        if selectedGrant?.id == grant.id { return authorizationUnavailable() }
        for entry in kept where entry.grant.id == grant.id { _ = disconnectKept(entry, acknowledged: false) }
        grants.removeAll { $0.id == grant.id }
        terminals[grant.id] = nil
        listing[grant.id] = nil
        SharedTerminals.forget(grant.id)
        unpairedName = grant.host.name
        UIAccessibility.post(notification: .announcement,
                             argument: String(localized: "No Longer Paired with \(grant.host.name)", bundle: .main))
    }

    private func noteDisconnected(_ names: [String]) {
        let list = names.map { "“\($0)”" }.formatted(.list(type: .and))
        let note = String(localized: "Disconnected \(list) to keep \(PairedKeepAlive.limit) terminals connected. It keeps running.", bundle: .main)
        keptNote = note
        UIAccessibility.post(notification: .announcement, argument: note)
    }

    func dismissKeptNote() { keptNote = nil }

    // MARK: Kept terminals in the background

    /// Lets each kept terminal's link go with the Mac's ACK (or at once when
    /// iOS is out of time), keeping its renderer and screen.
    func parkKept(acknowledged: Bool) {
        for entry in kept where entry.state == .live {
            entry.set(.parked)
            let link = entry.link
            entry.work = Task {
                if acknowledged { do { try await link.detach() } catch { await link.abort() } } else { await link.abort() }
            }
        }
    }

    /// Back within the window: each parked kept terminal gets a new watching
    /// link for the same renderer. Past it, every kept terminal is let go.
    func returnKept(withinWindow: Bool) {
        for entry in kept {
            if withinWindow {
                if entry.state == .parked { resume(entry) }
            } else {
                _ = disconnectKept(entry)
            }
        }
    }

    /// A new watching link for a parked kept terminal, to its same renderer,
    /// after any release still under way. If it can't connect, it's let go.
    private func resume(_ entry: KeptPairedTerminal) {
        guard entry.state == .parked, let open = try? linkOpener(for: entry.grant) else {
            _ = disconnectKept(entry, acknowledged: false)
            return
        }
        entry.set(.resuming)
        let step = entry.work, grid = entry.grid
        entry.work = Task { [weak self, weak entry] in
            await step?.value
            guard let entry, entry.state == .resuming else { return }
            do {
                let next = try await open(entry.session.id, grid.columns, grid.rows, .view)
                guard let self, entry.state == .resuming, self.kept.contains(where: { $0 === entry }) else {
                    await next.abort()
                    return
                }
                entry.resumed(with: next)
                entry.set(.live)
                #if DEBUG
                Self.layoutLog.notice("kept resumed session=\(entry.session.id, privacy: .public)")
                #endif
            } catch {
                guard let self else { return }
                _ = self.disconnectKept(entry, acknowledged: false)
                if Self.isTrustFailure(error) { self.keptGrantEnded(entry.grant) }
            }
        }
    }
}

/// The name this device pairs under, which the other device shows (in its
/// Open On menu, for one).
enum PairingDeviceName {
    /// Read on the main actor, where `UIDevice` lives; every caller is UI.
    @MainActor static var current: String {
        let clean = UIDevice.current.name.components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(String.UnicodeScalarView((clean.isEmpty ? String(localized: "My iPhone", bundle: .main) : clean).unicodeScalars.prefix(64)))
    }
}
#endif
