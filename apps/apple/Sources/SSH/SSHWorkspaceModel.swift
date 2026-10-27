import Foundation
import Observation
import WitermSSH

struct SSHTrustPrompt: Identifiable {
    let id = UUID()
    let key: SSHHostKey
}

enum SSHUIError {
    static func message(_ error: Error) -> String {
        switch error as? SSHFailure {
        case .hostKeyChanged: String(localized: "The host key has changed and the connection was blocked. Check with your server administrator first.", bundle: .main)
        case .hostKeyRejected: String(localized: "This host was not trusted. Connection cancelled.", bundle: .main)
        case .missingCredential: String(localized: "Enter credentials for the target host and every jump host.", bundle: .main)
        case .unsupportedPrivateKey: String(localized: "Unable to use this private key. Check its format and passphrase.", bundle: .main)
        case .invalidConfiguration: String(localized: "Check the host address, port and username.", bundle: .main)
        case .invalidForward: String(localized: "Check the listening port and target address.", bundle: .main)
        case .backpressure: String(localized: "The connection could not keep up and was closed. Reconnect to continue.", bundle: .main)
        case .storageUnavailable: String(localized: "Unable to access secure storage on this device. Try again later.", bundle: .main)
        case .transferTooLarge: String(localized: "The file exceeds the transfer limit.", bundle: .main)
        case .invalidPath: String(localized: "Unable to use this file path.", bundle: .main)
        case .cancelled: String(localized: "Operation cancelled.", bundle: .main)
        case .hostNotFound: String(localized: "Unable to find this host. Check the address spelling, DNS, or VPN.", bundle: .main)
        case .connectionRefused: String(localized: "The host refused the connection. Check the port and that its SSH server is running.", bundle: .main)
        case .timedOut: String(localized: "The host did not respond in time. Check the network, firewall, or VPN, then try again.", bundle: .main)
        case .networkUnreachable: String(localized: "This network can't reach the host. Check Wi-Fi, VPN, or the address.", bundle: .main)
        case .jumpTargetUnreachable: String(localized: "The jump host could not reach the target. Check the target address and port as the jump host sees them.", bundle: .main)
        case .authenticationFailed: String(localized: "The username, password, or key was not accepted. Check the credentials, then try again.", bundle: .main)
        case .authenticationMethodUnavailable: String(localized: "The host does not accept this sign-in method. Use a password or an Ed25519 key it allows.", bundle: .main)
        case .noCommonAlgorithms: String(localized: "The host offers no algorithms Witerm considers secure, so the connection was stopped. Ask its administrator to enable modern algorithms.", bundle: .main)
        default: String(localized: "The operation did not finish. Check the connection and permissions, then try again.", bundle: .main)
        }
    }

    /// The next step an issue offers, beyond dismissing it.
    static func recovery(_ error: Error) -> SSHRecovery? {
        switch error as? SSHFailure {
        case .hostNotFound, .connectionRefused, .jumpTargetUnreachable, .authenticationFailed,
             .authenticationMethodUnavailable, .missingCredential, .unsupportedPrivateKey, .invalidConfiguration:
            .editConnection
        case .timedOut, .networkUnreachable, .backpressure, .disconnected: .tryAgain
        default: nil
        }
    }
}

enum SSHRecovery { case editConnection, tryAgain }

/// A deleted host kept briefly so the deletion can be undone. Credentials
/// stay in memory only for the undo window, then are dropped.
struct RemovedSSHProfile {
    let profile: SSHProfile
    fileprivate let credentials: [UUID: SSHCredential]
    fileprivate let favorite: Bool
    fileprivate let lastUsed: Double?
    fileprivate let hue: Int?
    let token = UUID()
}

/// One connected SSH host. The session owns its terminal renderer, so output
/// keeps being consumed while another host or screen is shown.
@MainActor @Observable
final class SSHSession: Identifiable {
    let profile: SSHProfile
    let connection: SSHConnection
    let shell: SSHShell
    @ObservationIgnored let terminal: SSHTerminalHost
    /// Identifies this connection instance even if its host reconnects later.
    let token: UUID
    private var closed = false

    nonisolated var id: UUID { profile.id }

    init(profile: SSHProfile, connection: SSHConnection, shell: SSHShell, token: UUID,
         onEnded: @escaping @MainActor (Error?) -> Void) {
        self.token = token
        self.profile = profile
        self.connection = connection
        self.shell = shell
        terminal = SSHTerminalHost(shell: shell, onEnded: onEnded)
        #if os(iOS)
        terminal.surface.terminal.inputDestination = profile.endpointSummary
        #endif
    }

    func close() {
        guard !closed else { return }
        closed = true
        terminal.stop()
        Task { [shell, connection] in await shell.close(); await connection.disconnect() }
    }
}

@MainActor @Observable
final class SSHWorkspaceModel {
    /// Bounds sockets, renderers, and memory held by background sessions.
    static let sessionLimit = 8

    var profiles: [SSHProfile] = []
    private(set) var sessions: [SSHSession] = []
    /// Connection context only. Terminal frames, input and credentials are not retained here.
    private(set) var disconnected: [UUID: String] = [:]
    private(set) var favorites = Set(UserDefaults.standard.stringArray(forKey: "witerm.sshFavorites") ?? [])
    private(set) var lastUsed = UserDefaults.standard.dictionary(forKey: "witerm.sshLastUsed") as? [String: Double] ?? [:]
    /// The single connection attempt in flight, including host-key review.
    private(set) var connectingProfile: SSHProfile?
    var issue: String?
    /// The host an issue belongs to, when it belongs to one.
    private(set) var issueProfileID: UUID?
    private(set) var issueRecovery: SSHRecovery?
    /// Completed connection attempts, for haptic feedback.
    private(set) var recentlyRemoved: RemovedSSHProfile?
    @ObservationIgnored private var removalExpiry: Task<Void, Never>?
    static let undoWindow: Duration = .seconds(10)
    private(set) var connectSuccesses = 0
    private(set) var connectFailures = 0
    var trustPrompt: SSHTrustPrompt?
    private var untrustedKey: SSHHostKey?
    private var pendingAttempt: (profile: SSHProfile, credentials: [UUID: SSHCredential], remember: Set<UUID>)?
    private var approvedAttempt = false
    private var connectTask: Task<Void, Never>?
    private var generation = UUID()

    var connecting: Bool { connectTask != nil }

    func session(for profileID: UUID) -> SSHSession? { sessions.first { $0.id == profileID } }

    func isFavorite(_ profile: SSHProfile) -> Bool { favorites.contains(profile.id.uuidString) }

    func toggleFavorite(_ profile: SSHProfile) {
        if !favorites.insert(profile.id.uuidString).inserted { favorites.remove(profile.id.uuidString) }
        UserDefaults.standard.set(Array(favorites), forKey: "witerm.sshFavorites")
    }

    func orderedProfiles(search: String = "", favoritesOnly: Bool = false) -> [SSHProfile] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return profiles.filter {
            (!favoritesOnly || isFavorite($0)) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || $0.endpointSummary.localizedCaseInsensitiveContains(query))
        }.sorted {
            if isFavorite($0) != isFavorite($1) { return isFavorite($0) }
            let first = lastUsed[$0.id.uuidString] ?? 0, second = lastUsed[$1.id.uuidString] ?? 0
            if first != second { return first > second }
            let names = $0.name.localizedStandardCompare($1.name)
            return names == .orderedSame ? $0.id.uuidString < $1.id.uuidString : names == .orderedAscending
        }
    }

    func saveProfile(_ profile: SSHProfile, credentials: [UUID: SSHCredential], remember: Set<UUID>) async throws {
        let store = try SSHProfileStore()
        try await store.save(profile)
        for host in profile.jumpHosts + [profile.host] {
            try await store.setCredential(remember.contains(host.id) ? credentials[host.id] : nil, hostID: host.id)
        }
        profiles = try await store.profiles()
    }

    func load() async {
        do { profiles = try await SSHProfileStore().profiles() }
        catch { report(SSHUIError.message(error), profileID: nil) }
    }

    func savedCredentials(for profile: SSHProfile) async -> [UUID: SSHCredential] {
        do {
            let store = try SSHProfileStore()
            var result: [UUID: SSHCredential] = [:]
            for host in profile.jumpHosts + [profile.host] {
                if let value = try await store.credential(hostID: host.id) { result[host.id] = value }
            }
            return result
        } catch { report(SSHUIError.message(error), profileID: profile.id); return [:] }
    }

    func removeProfile(_ profile: SSHProfile) async {
        if let session = session(for: profile.id) { disconnect(session) }
        if connectingProfile?.id == profile.id { cancelConnecting() }
        let credentials = await savedCredentials(for: profile)
        let removed = RemovedSSHProfile(
            profile: profile, credentials: credentials, favorite: isFavorite(profile),
            lastUsed: lastUsed[profile.id.uuidString], hue: IdentityHue.assignment(for: profile.id.uuidString))
        do {
            let store = try SSHProfileStore()
            try await store.delete(id: profile.id)
            recentlyRemoved = removed
            removalExpiry?.cancel()
            removalExpiry = Task { [weak self] in
                try? await Task.sleep(for: Self.undoWindow)
                guard !Task.isCancelled, self?.recentlyRemoved?.token == removed.token else { return }
                self?.recentlyRemoved = nil
            }
            IdentityHue.forget(profile.id.uuidString)
            disconnected[profile.id] = nil
            favorites.remove(profile.id.uuidString)
            lastUsed[profile.id.uuidString] = nil
            UserDefaults.standard.set(Array(favorites), forKey: "witerm.sshFavorites")
            UserDefaults.standard.set(lastUsed, forKey: "witerm.sshLastUsed")
            await load()
        } catch { report(SSHUIError.message(error), profileID: nil) }
    }

    /// Restores the last deleted host with its credentials, hue, and order.
    func undoRemove() async {
        guard let removed = recentlyRemoved else { return }
        recentlyRemoved = nil
        removalExpiry?.cancel()
        let id = removed.profile.id.uuidString
        IdentityHue.restore(id, index: removed.hue)
        if removed.favorite { favorites.insert(id) }
        lastUsed[id] = removed.lastUsed
        UserDefaults.standard.set(Array(favorites), forKey: "witerm.sshFavorites")
        UserDefaults.standard.set(lastUsed, forKey: "witerm.sshLastUsed")
        do {
            try await saveProfile(removed.profile, credentials: removed.credentials,
                                  remember: Set(removed.credentials.keys))
        } catch { report(SSHUIError.message(error), profileID: nil) }
    }

    func dismissUndo() {
        recentlyRemoved = nil
        removalExpiry?.cancel()
    }

    /// Starts a new attempt. Live sessions for other hosts are unaffected;
    /// an earlier attempt that has not finished is cancelled.
    func connect(_ profile: SSHProfile, credentials: [UUID: SSHCredential], remember: Set<UUID>) {
        cancelConnecting()
        guard session(for: profile.id) == nil else { return }
        guard sessions.count < Self.sessionLimit else {
            report(String(localized: "Disconnect another SSH session before opening a new one.", bundle: .main), profileID: profile.id)
            return
        }
        let current = UUID()
        generation = current
        connectingProfile = profile
        clearIssue()
        pendingAttempt = (profile, credentials, remember)
        connectTask = Task { [weak self] in
            var connected: SSHConnection?
            do {
                try profile.validate()
                let store = try SSHProfileStore()
                try await store.save(profile)
                let savedProfiles = try await store.profiles()
                if self?.generation == current { self?.profiles = savedProfiles }
                let client = try await SSHConnection.connect(
                    profile: profile, credentials: credentials,
                    verifyHostKey: { [weak self] key in
                        guard let self else { throw CancellationError() }
                        try await self.verify(key, generation: current)
                    })
                connected = client
                try Task.checkCancellation()
                let terminal = try await client.openShell(columns: 80, rows: 24)
                guard let self, self.generation == current, !Task.isCancelled else {
                    await terminal.close(); await client.disconnect(); return
                }
                for host in profile.jumpHosts + [profile.host] {
                    try await store.setCredential(
                        remember.contains(host.id) ? credentials[host.id] : nil, hostID: host.id)
                }
                // Keychain writes suspend. A cancel or a newer attempt may own
                // the workspace by now; this one must not commit over it.
                guard self.generation == current, !Task.isCancelled else {
                    await terminal.close(); await client.disconnect(); return
                }
                let token = UUID()
                let session = SSHSession(profile: profile, connection: client, shell: terminal, token: token) { [weak self] error in
                    self?.ended(error, token: token)
                }
                self.sessions.append(session)
                self.connectSuccesses += 1
                self.disconnected[profile.id] = nil
                self.lastUsed[profile.id.uuidString] = Date().timeIntervalSince1970
                UserDefaults.standard.set(self.lastUsed, forKey: "witerm.sshLastUsed")
                self.connectingProfile = nil
                self.connectTask = nil
                self.pendingAttempt = nil
                await self.load()
            } catch {
                await connected?.disconnect()
                guard let self, self.generation == current else { return }
                self.connectingProfile = nil
                self.connectTask = nil
                if !Task.isCancelled, let key = self.untrustedKey {
                    self.untrustedKey = nil
                    self.trustPrompt = SSHTrustPrompt(key: key)
                } else if !Task.isCancelled {
                    self.pendingAttempt = nil
                    self.connectFailures += 1
                    self.report(SSHUIError.message(error), profileID: profile.id, recovery: SSHUIError.recovery(error))
                }
            }
        }
    }

    private func verify(_ key: SSHHostKey, generation current: UUID) async throws {
        try Task.checkCancellation()
        guard generation == current else { throw CancellationError() }
        let known = try SSHKnownHosts()
        let status = try await known.status(for: key)
        // A cancelled attempt must not leave its key as the next prompt.
        guard generation == current else { throw CancellationError() }
        switch status {
        case .trusted: return
        case .changed: throw SSHFailure.hostKeyChanged
        case .unknown:
            // End this handshake before asking for trust. An explicit approval
            // starts a fresh attempt instead of holding a live authentication
            // exchange open while the user compares fingerprints.
            untrustedKey = key
            throw SSHFailure.hostKeyRejected
        }
    }

    func approveHostKey(_ prompt: SSHTrustPrompt) async {
        guard trustPrompt?.id == prompt.id else { return }
        do {
            try await SSHKnownHosts().trust(prompt.key)
            guard trustPrompt?.id == prompt.id else { return }
            approvedAttempt = true
            trustPrompt = nil
        } catch {
            trustPrompt = nil; pendingAttempt = nil
            report(SSHUIError.message(error), profileID: nil)
        }
    }

    func rejectHostKey() {
        trustPrompt = nil; untrustedKey = nil; pendingAttempt = nil; approvedAttempt = false
    }

    func resumeTrustedAttempt() {
        guard approvedAttempt, let attempt = pendingAttempt else { return }
        approvedAttempt = false; pendingAttempt = nil
        connect(attempt.profile, credentials: attempt.credentials, remember: attempt.remember)
    }

    /// Cancels only the attempt in flight; live sessions keep running.
    func cancelConnecting() {
        generation = UUID()
        connectTask?.cancel(); connectTask = nil
        connectingProfile = nil
        rejectHostKey()
    }

    func disconnect(_ session: SSHSession) {
        disconnected[session.id] = String(localized: "Reconnect to open a new SSH shell. Whether previous programs keep running depends on the remote host.", bundle: .main)
        sessions.removeAll { $0 === session }
        session.close()
    }

    func disconnectAll(forBackground: Bool = false) {
        cancelConnecting()
        let open = sessions
        sessions = []
        for session in open {
            disconnected[session.id] = forBackground
                ? String(localized: "SSH disconnected when the app went to the background. Reconnect to open a new shell; previous programs depend on the remote host.", bundle: .main)
                : String(localized: "Reconnect to open a new SSH shell. Whether previous programs keep running depends on the remote host.", bundle: .main)
        }
        open.forEach { $0.close() }
    }

    private func ended(_ error: Error?, token: UUID) {
        guard let session = sessions.first(where: { $0.token == token }) else { return }
        disconnect(session)
        disconnected[session.id] = error.map(SSHUIError.message)
            ?? String(localized: "The SSH session has ended.", bundle: .main)
        report(error.map(SSHUIError.message) ?? String(localized: "The SSH session has ended.", bundle: .main),
               profileID: session.id)
    }

    func clearIssue() { issue = nil; issueProfileID = nil; issueRecovery = nil }

    private func report(_ message: String, profileID: UUID?, recovery: SSHRecovery? = nil) {
        issue = message
        issueProfileID = profileID
        issueRecovery = profileID == nil ? nil : recovery
    }
}
