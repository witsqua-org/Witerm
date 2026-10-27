import Foundation
@preconcurrency import Citadel
import Crypto
@preconcurrency import NIO
@preconcurrency import NIOSSH

/// An authenticated connection and the jump connections that carry it.
/// Reconnection is always explicit; previously submitted input is never replayed.
public actor SSHConnection {
    internal let client: SSHClient
    internal let forwarding = SSHForwardRegistry()
    private let clients: [SSHClientReference]
    private var shells: [UUID: SSHShell] = [:]
    private var closed = false

    private init(clients: [SSHClientReference]) {
        self.clients = clients
        self.client = clients[clients.count - 1].client
    }

    public static func connect(
        profile: SSHProfile,
        credentials: [UUID: SSHCredential],
        verifyHostKey: @escaping @Sendable (SSHHostKey) async throws -> Void
    ) async throws -> SSHConnection {
        try profile.validate()
        var connected: [SSHClientReference] = []
        let cancellation = SSHConnectCancellation()
        return try await withTaskCancellationHandler {
            do {
                for host in profile.jumpHosts + [profile.host] {
                    try Task.checkCancellation()
                    guard let credential = credentials[host.id] else { throw SSHFailure.missingCredential }
                    let authentication = try SSHAuthenticationFactory(username: host.username, credential: credential)
                    let validator = SSHIdentityValidator(host: host, verify: verifyHostKey)
                    let settings = SSHClientSettings(
                        host: host.hostname, port: host.port,
                        authenticationMethod: { authentication.make() },
                        hostKeyValidator: .custom(validator)
                    )
                    let next: SSHClient
                    if let previous = connected.last {
                        next = try await previous.client.jump(to: settings)
                    } else {
                        next = try await SSHClient.connect(to: settings)
                    }
                    connected.append(SSHClientReference(client: next))
                    cancellation.register(next)
                    try Task.checkCancellation()
                }
                let result = SSHConnection(clients: connected)
                connected.last?.client.onDisconnect { [weak result] in
                    Task { await result?.disconnect() }
                }
                cancellation.finish()
                try Task.checkCancellation()
                return result
            } catch {
                cancellation.finish()
                for connection in connected.reversed() { try? await connection.client.close() }
                throw SSHFailure.classify(error)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    internal func requireConnected() throws {
        guard !closed, client.isConnected else { throw SSHFailure.disconnected }
    }

    public func openShell(columns: Int = 80, rows: Int = 24) async throws -> SSHShell {
        try requireConnected()
        let shell = try await SSHShell.open(client: client, columns: columns, rows: rows)
        guard !closed, !Task.isCancelled else {
            await shell.close()
            throw SSHFailure.cancelled
        }
        shells[shell.id] = shell
        return shell
    }

    public func disconnect() async {
        guard !closed else { return }
        closed = true
        await forwarding.closeAll()
        let previous = Array(shells.values)
        shells.removeAll()
        for shell in previous { await shell.close() }
        for connection in clients.reversed() { try? await connection.client.close() }
    }

    deinit {
        guard !closed else { return }
        let pendingShells = Array(shells.values)
        let connections = clients
        let forwards = forwarding
        Task {
            await forwards.closeAll()
            for shell in pendingShells { await shell.close() }
            for connection in connections.reversed() { try? await connection.client.close() }
        }
    }
}

/// Transfers ownership into the connection actor without claiming that the
/// third-party client's mutable reconnect/authentication state is thread-safe.
/// Once connected, all normal operations are coordinated by SSHConnection.
private struct SSHClientReference: @unchecked Sendable {
    let client: SSHClient
}

/// Only immutable key material is captured by the factory; each authentication
/// attempt gets a fresh mutable Citadel delegate rather than reusing its state.
private final class SSHAuthenticationFactory: @unchecked Sendable {
    private let builder: () -> SSHAuthenticationMethod

    init(username: String, credential: SSHCredential) throws {
        switch credential {
        case .password(let password):
            guard !password.isEmpty, password.utf8.count <= 65536 else { throw SSHFailure.missingCredential }
            builder = { .passwordBased(username: username, password: password) }
        case .privateKey(let text, let passphrase):
            guard text.utf8.count <= 1_048_576 else { throw SSHFailure.unsupportedPrivateKey }
            let decryption = passphrase.map { Data($0.utf8) }
            do {
                let type = try SSHKeyDetection.detectPrivateKeyType(from: text)
                switch type.rawValue {
                case "ssh-ed25519":
                    let key = try Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: decryption)
                    builder = { .ed25519(username: username, privateKey: key) }
                case "ssh-rsa":
                    // This engine's RSA path signs with deprecated ssh-rsa/SHA1.
                    // Do not silently downgrade a modern server's policy.
                    throw SSHFailure.unsupportedPrivateKey
                default: throw SSHFailure.unsupportedPrivateKey
                }
            } catch { throw SSHFailure.unsupportedPrivateKey }
        }
    }

    func make() -> SSHAuthenticationMethod { builder() }
}

/// Host key verification finishes before NIOSSH offers credentials. The callback
/// must reject unknown keys and let the caller reconnect after explicit approval.
internal final class SSHIdentityValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private let host: SSHHost
    private let verify: @Sendable (SSHHostKey) async throws -> Void

    init(host: SSHHost, verify: @escaping @Sendable (SSHHostKey) async throws -> Void) {
        self.host = host; self.verify = verify
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let representation = String(openSSHPublicKey: hostKey)
        let fields = representation.split(separator: " ")
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else {
            validationCompletePromise.fail(SSHFailure.hostKeyRejected)
            return
        }
        let fingerprint = "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let identity = SSHHostKey(authority: host.authority, algorithm: String(fields[0]),
                                  publicKey: String(fields[1]), fingerprint: fingerprint)
        Task {
            do {
                try Task.checkCancellation()
                try await verify(identity)
                validationCompletePromise.succeed(())
            } catch { validationCompletePromise.fail(error) }
        }
    }
}

/// NIO clients are not Sendable. This box only transfers references for close(),
/// whose underlying Channel API is thread-safe; its mutable list is lock-owned.
private final class SSHConnectCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [SSHClient] = []
    private var cancelled = false
    private var finished = false

    func register(_ client: SSHClient) {
        let shouldClose = lock.withLock {
            if cancelled { return true }
            if !finished { clients.append(client) }
            return false
        }
        if shouldClose { Task { try? await client.close() } }
    }

    func cancel() {
        let previous = lock.withLock { () -> [SSHClient] in
            guard !finished else { return [] }
            cancelled = true
            let previous = clients; clients.removeAll(); return previous
        }
        Task { for client in previous.reversed() { try? await client.close() } }
    }

    func finish() { lock.withLock { finished = true; clients.removeAll() } }
}
