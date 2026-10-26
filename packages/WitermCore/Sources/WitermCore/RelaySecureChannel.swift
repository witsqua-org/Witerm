import Foundation

public final class RelayHostConnection: Sendable {
  public let offers: AsyncThrowingStream<RelayOffer, Error>
  private let socket: RelayWebSocket
  private let reader: Task<Void, Never>

  private init(socket: RelayWebSocket) {
    self.socket = socket
    let (stream, continuation) = AsyncThrowingStream<RelayOffer, Error>.makeStream(
      bufferingPolicy: .bufferingOldest(16))
    offers = stream
    continuation.onTermination = { _ in socket.close() }
    reader = Task {
      do {
        while !Task.isCancelled {
          let data = try await socket.control()
          let offer = try RelayMetadata.offer(data)
          switch continuation.yield(offer) {
          case .enqueued: break
          case .dropped: throw RelayError.backpressure
          case .terminated:
            socket.close()
            return
          @unknown default: throw RelayError.backpressure
          }
        }
      } catch {
        continuation.finish(throwing: RelayContext.map(error))
        socket.close()
      }
    }
  }

  public static func connect(pairing: PairingClient) async throws -> RelayHostConnection {
    let credentials = try await pairing.relayCredentials()
    guard credentials.device.platform == .macos else { throw RelayError.unauthorized }
    let socket = try RelayWebSocket(credentials: credentials, path: "v1/relay/host")
    do {
      let ready = try await relayDeadline(10) { try await socket.control() }
      try RelayMetadata.ready(ready)
      return RelayHostConnection(socket: socket)
    } catch {
      socket.close()
      throw RelayContext.map(error)
    }
  }

  deinit {
    reader.cancel()
    socket.close()
  }
  public func disconnect() async {
    reader.cancel()
    socket.close()
  }
}

public actor RelaySecureChannel {
  public let grant: DeviceGrant
  nonisolated let traceID: String
  private let pairing: PairingClient
  private let socket: any RelaySocketIO
  private var sendCipher: RelayNoiseCipher
  private var receiveCipher: RelayNoiseCipher
  private var closed = false
  private var terminalError: RelayError?
  private var receiving = false
  private var trustWatch: Task<Void, Never>?
  private struct Pending {
    let plaintext: Data
    let continuation: CheckedContinuation<Void, Error>
  }
  private var pending: [Pending] = []
  private var queuedBytes = 0
  private var writer: Task<Void, Never>?

  private init(
    pairing: PairingClient, grant: DeviceGrant, socket: any RelaySocketIO,
    send: RelayNoiseCipher, receive: RelayNoiseCipher, traceID: String
  ) {
    self.pairing = pairing
    self.grant = grant
    self.socket = socket
    self.traceID = traceID
    sendCipher = send
    receiveCipher = receive
  }

  public static func host(pairing: PairingClient, offer: RelayOffer) async throws
    -> RelaySecureChannel
  {
    let grant = try await pairing.trustedRelayGrant(id: offer.grantID)
    let credentials = try await pairing.relayCredentials()
    guard credentials.device.platform == .macos,
      RelayContext.sameIdentity(credentials.device, grant.host),
      PairingEncoding.canonicalID(offer.tunnelID) == offer.tunnelID
    else { throw RelayError.untrusted }
    let socket = try RelayWebSocket(
      credentials: credentials, path: "v1/relay/tunnels/\(offer.tunnelID)")
    return try await establish(
      pairing: pairing, credentials: credentials, grant: grant,
      tunnelID: offer.tunnelID, role: .host, socket: socket)
  }

  static func client(pairing: PairingClient, grantID: String) async throws -> RelaySecureChannel {
    let grant = try await pairing.trustedRelayGrant(id: grantID)
    var credentials = try await pairing.relayCredentials()
    guard credentials.device.platform == .ios,
      RelayContext.sameIdentity(credentials.device, grant.client)
    else { throw RelayError.untrusted }
    let tunnel: String
    do {
      tunnel = try await RelayNetwork.createTunnel(credentials: credentials, grantID: grantID)
    } catch RelayError.unauthorized {
      credentials = try await pairing.relayCredentials(forceRefresh: true)
      tunnel = try await RelayNetwork.createTunnel(credentials: credentials, grantID: grantID)
    }
    let socket = try RelayWebSocket(credentials: credentials, path: "v1/relay/tunnels/\(tunnel)")
    return try await establish(
      pairing: pairing, credentials: credentials, grant: grant,
      tunnelID: tunnel, role: .client, socket: socket)
  }

  static func establish(
    pairing: PairingClient, credentials: RelayCredentials, grant: DeviceGrant,
    tunnelID: String, role: RelayRole, socket: any RelaySocketIO
  ) async throws -> RelaySecureChannel {
    do {
      return try await relayDeadline(10) {
        let fresh = try await pairing.trustedRelayGrant(id: grant.id)
        guard fresh == grant,
          RelayContext.sameIdentity(credentials.device, role == .host ? grant.host : grant.client)
        else { throw RelayError.untrusted }
        let prologue = try RelayContext.prologue(
          server: credentials.server, tunnelID: tunnelID, grant: grant)
        var noise = RelayNoiseHandshake(initiator: role == .client, prologue: prologue)
        if role == .client {
          try await socket.send(noise.write())
          guard try noise.read(await socket.receive()).isEmpty else {
            throw RelayError.invalidMessage
          }
          try await socket.send(noise.write())
        } else {
          guard try noise.read(await socket.receive()).isEmpty else {
            throw RelayError.invalidMessage
          }
          try await socket.send(noise.write())
          guard try noise.read(await socket.receive()).isEmpty else {
            throw RelayError.invalidMessage
          }
        }
        var (send, receive) = try noise.split()
        let proof = try await pairing.signRelayIdentity(
          grantID: grant.id, role: role, handshakeHash: noise.hash)
        if role == .client {
          try await socket.send(send.encrypt(JSONEncoder().encode(proof)))
        }
        let remoteBytes = try receive.decrypt(await socket.receive())
        guard remoteBytes.count <= 1024,
          let raw = try JSONSerialization.jsonObject(with: remoteBytes) as? [String: Any],
          Set(raw.keys) == ["role", "signature"]
        else { throw RelayError.invalidMessage }
        let remote = try JSONDecoder().decode(RelayIdentityProof.self, from: remoteBytes)
        try remote.verify(
          expectedRole: role == .client ? .host : .client, hash: noise.hash, grant: grant)
        guard try await pairing.trustedRelayGrant(id: grant.id) == grant else {
          throw RelayError.untrusted
        }
        if role == .host {
          try await socket.send(send.encrypt(JSONEncoder().encode(proof)))
        }
        let channel = RelaySecureChannel(
          pairing: pairing, grant: grant, socket: socket, send: send, receive: receive,
          traceID: String(tunnelID.prefix(8)) + "/" + role.rawValue)
        await channel.startTrustWatch()
        return channel
      }
    } catch {
      socket.close()
      if error is CancellationError { throw error }
      throw RelayContext.map(error)
    }
  }

  deinit {
    RelayTrace.event(traceID, "channel-deinit")
    socket.close()
    writer?.cancel()
    trustWatch?.cancel()
  }

  private func startTrustWatch() {
    guard trustWatch == nil, !closed else { return }
    trustWatch = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        // Resolve the weak actor only for this check, never across the sleep.
        guard await self?.checkLocalTrust() == true else { return }
      }
    }
  }

  private func checkLocalTrust() async -> Bool {
    guard !closed else { return false }
    do {
      guard try await pairing.trustedRelayGrant(id: grant.id) == grant else {
        fail(.revoked)
        return false
      }
      return !closed
    } catch {
      let mapped = RelayContext.map(error)
      // This established channel already authenticated the recorded grant.
      // A now-missing record is a local loss of trust, not a new invitation.
      fail(mapped == .untrusted || mapped == .revoked ? .revoked : mapped)
      return false
    }
  }

  public func send(_ plaintext: Data) async throws {
    guard !closed else { throw terminalError ?? RelayError.transport }
    guard plaintext.count <= 49_152 else {
      fail(.invalidMessage)
      throw RelayError.invalidMessage
    }
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        guard pending.count < 32, queuedBytes + plaintext.count <= 256 * 1024 else {
          fail(.backpressure)
          continuation.resume(throwing: RelayError.backpressure)
          return
        }
        pending.append(Pending(plaintext: plaintext, continuation: continuation))
        queuedBytes += plaintext.count
        if writer == nil { writer = Task { await self.drain() } }
      }
    } onCancel: {
      Task { await self.close() }
    }
  }

  private func drain() async {
    defer { writer = nil }
    while !closed, !pending.isEmpty {
      let item = pending.removeFirst()
      do {
        guard try await pairing.trustedRelayGrant(id: grant.id) == grant, !closed else {
          throw RelayError.revoked
        }
        let ciphertext = try sendCipher.encrypt(item.plaintext)
        let socket = socket
        try await relayDeadline(5) { try await socket.send(ciphertext) }
        queuedBytes -= item.plaintext.count
        item.continuation.resume()
      } catch {
        queuedBytes -= item.plaintext.count
        let mapped = terminalError ?? RelayContext.map(error)
        item.continuation.resume(throwing: mapped)
        fail(mapped)
      }
    }
  }

  public func receive() async throws -> Data {
    guard !closed, !receiving else {
      RelayTrace.event(traceID, closed ? "receive-already-closed" : "receive-competing")
      throw terminalError ?? RelayError.transport
    }
    receiving = true
    defer { receiving = false }
    do {
      guard try await pairing.trustedRelayGrant(id: grant.id) == grant else {
        throw RelayError.revoked
      }
      let bytes = try await socket.receive()
      guard !closed, try await pairing.trustedRelayGrant(id: grant.id) == grant else {
        throw RelayError.revoked
      }
      return try receiveCipher.decrypt(bytes)
    } catch {
      RelayTrace.event(traceID, "channel-receive-failed", error: error)
      let mapped = terminalError ?? RelayContext.map(error)
      fail(mapped)
      throw mapped
    }
  }

  private func fail(_ error: RelayError) {
    guard !closed else { return }
    RelayTrace.event(traceID, "channel-fail", error: error)
    closed = true
    terminalError = error
    socket.close()
    trustWatch?.cancel()
    writer?.cancel()
    for item in pending {
      item.continuation.resume(throwing: error)
      queuedBytes -= item.plaintext.count
    }
    pending.removeAll()
  }
  func terminalFailure() -> RelayError? { terminalError }

  public func close() async {
    let oldWriter = writer
    let oldWatch = trustWatch
    fail(.transport)
    await oldWriter?.value
    await oldWatch?.value
  }
}
