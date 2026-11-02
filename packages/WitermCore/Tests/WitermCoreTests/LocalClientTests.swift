#if os(macOS)
  import Darwin
  import Foundation
  import XCTest
  @testable import WitermCore

  private final class LocalTestSignal: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func signal() { semaphore.signal() }
    func wait() async throws {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        DispatchQueue.global().async { [self] in
          if semaphore.wait(timeout: .now() + 8) == .success {
            continuation.resume()
          } else {
            continuation.resume(throwing: LocalAgentClientError.unavailable)
          }
        }
      }
    }
  }

  private final class LocalTestBroker: @unchecked Sendable {
    let directory: URL
    let socketURL: URL
    let ended = LocalTestSignal()
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private var connections = Set<Int32>()
    private let handler: @Sendable (LocalAgentRequest, Int32) throws -> Void

    init(handler: @escaping @Sendable (LocalAgentRequest, Int32) throws -> Void) throws {
      self.handler = handler
      directory = URL(
        fileURLWithPath: "/private/tmp/wlc-\(UUID().uuidString.prefix(8))", isDirectory: true)
      socketURL = directory.appendingPathComponent("agent.sock")
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
      guard listener >= 0 else { throw LocalAgentClientError.unavailable }
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
      withUnsafeMutableBytes(of: &address.sun_path) {
        $0.copyBytes(from: Array(socketURL.path.utf8) + [0])
      }
      let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard bound == 0, chmod(socketURL.path, 0o600) == 0, Darwin.listen(listener, 16) == 0 else {
        Darwin.close(listener)
        try? FileManager.default.removeItem(at: directory)
        throw LocalAgentClientError.unavailable
      }
      DispatchQueue(label: "witerm.tests.accept").async { [self] in
        while true {
          lock.lock()
          let finished = stopped
          lock.unlock()
          if finished { return }
          let connection = Darwin.accept(listener, nil, nil)
          if connection < 0 { return }
          var noSignal: Int32 = 1
          _ = setsockopt(
            connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
          lock.lock()
          if stopped {
            lock.unlock()
            Darwin.close(connection)
            return
          }
          connections.insert(connection)
          lock.unlock()
          DispatchQueue(label: "witerm.tests.connection").async { [self] in serve(connection) }
        }
      }
    }

    func stop() {
      lock.lock()
      if stopped {
        lock.unlock()
        return
      }
      stopped = true
      _ = Darwin.shutdown(listener, SHUT_RDWR)
      _ = Darwin.close(listener)
      for connection in connections { _ = Darwin.shutdown(connection, SHUT_RDWR) }
      lock.unlock()
      try? FileManager.default.removeItem(at: directory)
    }

    private func serve(_ descriptor: Int32) {
      defer {
        lock.lock()
        connections.remove(descriptor)
        _ = Darwin.close(descriptor)
        lock.unlock()
        ended.signal()
      }
      var buffer = Data()
      var bytes = [UInt8](repeating: 0, count: 8192)
      while true {
        let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { return }
        buffer.append(contentsOf: bytes.prefix(count))
        while let end = buffer.firstIndex(of: 10) {
          let line = Data(buffer.prefix(upTo: end))
          buffer.removeSubrange(...end)
          do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            try handler(decoder.decode(LocalAgentRequest.self, from: line), descriptor)
          } catch { return }
        }
      }
    }

    static func send(_ frame: LocalAgentFrame, to descriptor: Int32) throws {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      var bytes = try encoder.encode(frame)
      bytes.append(10)
      try sendRaw(bytes, to: descriptor)
    }

    static func sendRaw(_ bytes: Data, to descriptor: Int32) throws {
      var offset = 0
      while offset < bytes.count {
        let count = bytes.withUnsafeBytes {
          Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
        }
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw LocalAgentClientError.unavailable }
        offset += count
      }
    }
  }

  final class LocalClientTests: XCTestCase {
    private static let session = LocalSessionInfo(
      id: "11111111-1111-4111-8111-111111111111", name: "测试 shell",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000), columns: 80, rows: 24)

    func testWireUsesBinaryDataAndStableSnakeCase() throws {
      let data = Data([0, 27, 91, 50, 74, 255, 10])
      let request = LocalAgentRequest(operation: .input, sessionID: Self.session.id, data: data)
      XCTAssertEqual(UUID(uuidString: request.id)?.uuidString.lowercased(), request.id)
      let encoded = try LocalWire.encode(request)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
      XCTAssertEqual(object["session_id"] as? String, Self.session.id)
      XCTAssertEqual(object["data"] as? String, data.base64EncodedString())
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let frame = LocalAgentFrame(
        id: request.id, kind: .response, ok: true, sessions: [Self.session])
      XCTAssertEqual(try LocalWire.decode(encoder.encode(frame)), frame)
      XCTAssertThrowsError(try LocalWire.decode(Data("{\"version\":2,\"kind\":\"closed\"}".utf8)))
    }

    func testStatusAndListUseSeparateRealSocketRPCs() async throws {
      let broker = try LocalTestBroker { request, descriptor in
        if request.operation == .status {
          try LocalTestBroker.send(
            LocalAgentFrame(
              id: request.id, kind: .response, ok: true,
              status: LocalAgentStatus(tmuxAvailable: true)), to: descriptor)
        } else {
          try LocalTestBroker.send(
            LocalAgentFrame(id: request.id, kind: .response, ok: true, sessions: []), to: descriptor
          )
        }
      }
      defer { broker.stop() }
      let client = LocalAgentClient(socketURL: broker.socketURL)
      let status = try await client.status()
      XCTAssertTrue(status.tmuxAvailable)
      let sessions = try await client.sessions()
      XCTAssertEqual(sessions, [])
    }

    func testUnsafeDirectoryAndSymlinkAreRejectedBeforeConnection() async throws {
      let broker = try LocalTestBroker { _, _ in }
      defer { broker.stop() }
      XCTAssertEqual(chmod(broker.directory.path, 0o755), 0)
      do {
        _ = try await LocalAgentClient(socketURL: broker.socketURL).status()
        XCTFail("unsafe directory accepted")
      } catch { XCTAssertEqual(error as? LocalAgentClientError, .unsafeSocket) }
      XCTAssertEqual(chmod(broker.directory.path, 0o700), 0)
      let alias = broker.directory.appendingPathComponent("alias.sock")
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: broker.socketURL)
      do {
        _ = try await LocalAgentClient(socketURL: alias).status()
        XCTFail("symlink accepted")
      } catch { XCTAssertEqual(error as? LocalAgentClientError, .unsafeSocket) }
      XCTAssertEqual(chmod(broker.socketURL.path, 0o666), 0)
      do {
        _ = try await LocalAgentClient(socketURL: broker.socketURL).status()
        XCTFail("public socket accepted")
      } catch { XCTAssertEqual(error as? LocalAgentClientError, .unsafeSocket) }
    }

    func testMissingStateIsUnavailableRatherThanUnsafe() async throws {
      let url = URL(fileURLWithPath: "/private/tmp/wlc-missing-\(UUID().uuidString)/agent.sock")
      do {
        _ = try await LocalAgentClient(socketURL: url).status()
        XCTFail("missing agent succeeded")
      } catch { XCTAssertEqual(error as? LocalAgentClientError, .unavailable) }
    }

    func testMalformedOversizedAndWrongIDResponsesFailClosed() async throws {
      let wrongID = "22222222-2222-4222-8222-222222222222"
      let malformed = [
        Data("not-json\n".utf8),
        Data("{\"version\":1,\"kind\":\"unknown\"}\n".utf8),
        Data("{\"version\":2,\"kind\":\"response\",\"id\":\"\(wrongID)\",\"ok\":true}\n".utf8),
        Data("{\"version\":1,\"kind\":\"response\",\"id\":\"\(wrongID)\",\"ok\":true}\n".utf8),
        Data(repeating: 65, count: 65_536),
      ]
      for bytes in malformed {
        let broker = try LocalTestBroker { _, descriptor in
          try LocalTestBroker.sendRaw(bytes, to: descriptor)
        }
        do {
          _ = try await LocalAgentClient(socketURL: broker.socketURL).status()
          XCTFail("invalid response accepted")
        } catch { XCTAssertEqual(error as? LocalAgentClientError, .invalidResponse) }
        broker.stop()
      }
    }

    func testOutputBeforeAttachAcknowledgementIsRejected() async throws {
      let broker = try LocalTestBroker { _, descriptor in
        try LocalTestBroker.send(
          LocalAgentFrame(kind: .output, data: Data("bad-order".utf8)), to: descriptor)
      }
      defer { broker.stop() }
      do {
        _ = try await LocalAgentClient(socketURL: broker.socketURL).attach(
          sessionID: Self.session.id)
        XCTFail("out-of-order output accepted")
      } catch { XCTAssertEqual(error as? LocalAgentClientError, .invalidResponse) }
    }

    func testVTBytesAndInputAcknowledgementStayOnSeparateChannels() async throws {
      let initial = Data([27, 91, 50, 74, 0, 255])
      let input = Data([97, 13, 27, 91, 65])
      let broker = try LocalTestBroker { request, descriptor in
        switch request.operation {
        case .attach:
          try LocalTestBroker.send(
            LocalAgentFrame(
              id: request.id, kind: .response, ok: true, session: Self.session, mode: request.mode),
            to: descriptor)
          try LocalTestBroker.send(LocalAgentFrame(kind: .output, data: initial), to: descriptor)
        case .input:
          try LocalTestBroker.send(
            LocalAgentFrame(kind: .output, data: request.data), to: descriptor)
          try LocalTestBroker.send(
            LocalAgentFrame(id: request.id, kind: .response, ok: true), to: descriptor)
        case .resize, .detach:
          try LocalTestBroker.send(
            LocalAgentFrame(id: request.id, kind: .response, ok: true), to: descriptor)
        default: break
        }
      }
      defer { broker.stop() }
      let attachment = try await LocalAgentClient(socketURL: broker.socketURL).attach(
        sessionID: Self.session.id)
      var output = attachment.output.makeAsyncIterator()
      let first = try await output.next()
      XCTAssertEqual(first, initial)
      try await attachment.send(input)
      let echoed = try await output.next()
      XCTAssertEqual(echoed, input)
      try await attachment.resize(columns: 100, rows: 30)
      await attachment.disconnect()
      let final = try await output.next()
      XCTAssertNil(final)
    }

    func testReadOnlyAttachmentUsesAuthoritativeResponseSession() async throws {
      let broker = try LocalTestBroker { request, descriptor in
        if request.operation == .attach {
          XCTAssertEqual(request.columns, 120)
          XCTAssertEqual(request.rows, 40)
          XCTAssertEqual(request.mode, .view)
        }
        try LocalTestBroker.send(
          LocalAgentFrame(
            id: request.id, kind: .response, ok: true,
            session: request.operation == .attach ? Self.session : nil,
            mode: request.operation == .attach ? request.mode : nil), to: descriptor)
      }
      defer { broker.stop() }
      let attachment = try await LocalAgentClient(socketURL: broker.socketURL).attach(
        sessionID: Self.session.id, columns: 120, rows: 40, mode: .view)
      XCTAssertEqual(attachment.session, Self.session)
      XCTAssertEqual(attachment.session.columns, 80)
      XCTAssertEqual(attachment.session.rows, 24)
      await attachment.disconnect()
    }

    func testGeometryAndVTEventsKeepWireOrderAfterAttachAck() async throws {
      let original = Self.session
      let resized = LocalSessionInfo(
        id: original.id, name: original.name, createdAt: original.createdAt,
        columns: 111, rows: 39)
      let before = Data([27, 91])
      let after = Data([50, 74, 0, 255])
      let broker = try LocalTestBroker { request, descriptor in
        try LocalTestBroker.send(
          LocalAgentFrame(
            id: request.id, kind: .response, ok: true,
            session: request.operation == .attach ? original : nil,
            mode: request.operation == .attach ? request.mode : nil), to: descriptor)
        if request.operation == .attach {
          try LocalTestBroker.send(LocalAgentFrame(kind: .output, data: before), to: descriptor)
          try LocalTestBroker.send(
            LocalAgentFrame(kind: .geometry, session: resized), to: descriptor)
          try LocalTestBroker.send(LocalAgentFrame(kind: .output, data: after), to: descriptor)
        }
      }
      defer { broker.stop() }
      let attachment = try await LocalAgentClient(socketURL: broker.socketURL).attach(
        sessionID: original.id, mode: .view)
      XCTAssertEqual(attachment.session, original)
      var events = attachment.events.makeAsyncIterator()
      let first = try await events.next()
      let second = try await events.next()
      let third = try await events.next()
      XCTAssertEqual(first, .output(before))
      XCTAssertEqual(second, .geometry(resized))
      XCTAssertEqual(third, .output(after))
      var rejected = attachment.output.makeAsyncIterator()
      do {
        _ = try await rejected.next()
        XCTFail("mixed terminal consumers accepted")
      } catch { XCTAssertEqual(error as? LocalAgentClientError, .invalidResponse) }
      try await attachment.detach()
      let end = try await events.next()
      XCTAssertNil(end)
    }

    func testGeometryBeforeAckOrWithWrongSessionAndShapeIsRejected() async throws {
      let original = Self.session
      let wrongID = LocalSessionInfo(
        id: "22222222-2222-4222-8222-222222222222", name: original.name,
        createdAt: original.createdAt, columns: 100, rows: 30)
      let wrongDate = LocalSessionInfo(
        id: original.id, name: original.name,
        createdAt: original.createdAt.addingTimeInterval(1), columns: 100, rows: 30)
      let invalidSize = LocalSessionInfo(
        id: original.id, name: original.name,
        createdAt: original.createdAt, columns: 19, rows: 30)
      let variants = [
        LocalAgentFrame(kind: .geometry, session: wrongID),
        LocalAgentFrame(kind: .geometry, session: wrongDate),
        LocalAgentFrame(kind: .geometry, session: invalidSize),
        LocalAgentFrame(kind: .geometry, session: original, data: Data([0])),
        LocalAgentFrame(kind: .geometry, error: .unavailable, session: original),
      ]
      for index in -1..<variants.count {
        let broker = try LocalTestBroker { request, descriptor in
          if index >= 0 {
            try LocalTestBroker.send(
              LocalAgentFrame(
                id: request.id, kind: .response, ok: true,
                session: original, mode: request.mode), to: descriptor)
          }
          try LocalTestBroker.send(
            index < 0 ? LocalAgentFrame(kind: .geometry, session: original) : variants[index],
            to: descriptor)
        }
        defer { broker.stop() }
        do {
          let attachment = try await LocalAgentClient(socketURL: broker.socketURL).attach(
            sessionID: original.id)
          var events = attachment.events.makeAsyncIterator()
          _ = try await events.next()
          XCTFail("invalid geometry accepted")
        } catch { XCTAssertEqual(error as? LocalAgentClientError, .invalidResponse) }
      }
    }

    /// A terminal renamed while open keeps its attachment: the next geometry
    /// carries the new name, and the ID and creation time still match.
    func testGeometryAfterRenameKeepsTheAttachment() async throws {
      let original = Self.session
      let renamed = LocalSessionInfo(
        id: original.id, name: "Renamed", createdAt: original.createdAt, columns: 100, rows: 30)
      let broker = try LocalTestBroker { request, descriptor in
        try LocalTestBroker.send(
          LocalAgentFrame(id: request.id, kind: .response, ok: true, session: original, mode: request.mode),
          to: descriptor)
        try LocalTestBroker.send(LocalAgentFrame(kind: .geometry, session: renamed), to: descriptor)
      }
      defer { broker.stop() }
      let attachment = try await LocalAgentClient(socketURL: broker.socketURL).attach(sessionID: original.id)
      var events = attachment.events.makeAsyncIterator()
      let event = try await events.next()
      XCTAssertEqual(event, .geometry(renamed))
      await attachment.disconnect()
    }

    func testReadOnlyAttachmentRejectsInputAndResize() async throws {
      let broker = try LocalTestBroker { request, descriptor in
        try LocalTestBroker.send(
          LocalAgentFrame(
            id: request.id, kind: .response, ok: true,
            session: request.operation == .attach ? Self.session : nil,
            mode: request.operation == .attach ? request.mode : nil), to: descriptor)
      }
      defer { broker.stop() }
      let attachment = try await LocalAgentClient(socketURL: broker.socketURL).attach(
        sessionID: Self.session.id, mode: .view)
      do {
        try await attachment.send(Data("x".utf8))
        XCTFail("read-only input accepted")
      } catch { XCTAssertEqual(error as? LocalAgentClientError, .rejected(.readOnly)) }
      do {
        try await attachment.resize(columns: 100, rows: 30)
        XCTFail("read-only resize accepted")
      } catch { XCTAssertEqual(error as? LocalAgentClientError, .rejected(.readOnly)) }
      await attachment.disconnect()
    }

    func testSessionClosedEventAndTransportLossHaveDifferentSemantics() async throws {
      for graceful in [true, false] {
        let broker = try LocalTestBroker { request, descriptor in
          try LocalTestBroker.send(
            LocalAgentFrame(
              id: request.id, kind: .response, ok: true, session: Self.session, mode: request.mode),
            to: descriptor)
          try LocalTestBroker.send(
            LocalAgentFrame(kind: .output, data: Data("last VT bytes".utf8)), to: descriptor)
          if graceful {
            try LocalTestBroker.send(LocalAgentFrame(kind: .closed), to: descriptor)
          }
          _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        }
        let attachment = try await LocalAgentClient(socketURL: broker.socketURL).attach(
          sessionID: Self.session.id)
        var output = attachment.output.makeAsyncIterator()
        let lastBytes = try await output.next()
        XCTAssertEqual(lastBytes, Data("last VT bytes".utf8))
        do {
          let end = try await output.next()
          XCTAssertTrue(graceful)
          XCTAssertNil(end)
        } catch {
          XCTAssertFalse(graceful)
          XCTAssertEqual(error as? LocalAgentClientError, .unavailable)
        }
        broker.stop()
      }
    }

    func testBoundedStreamClosesInsteadOfDroppingVTBytes() async throws {
      let broker = try LocalTestBroker { request, descriptor in
        try LocalTestBroker.send(
          LocalAgentFrame(
            id: request.id, kind: .response, ok: true, session: Self.session, mode: request.mode),
          to: descriptor)
        for value in 0..<70 {
          try LocalTestBroker.send(
            LocalAgentFrame(kind: .output, data: Data([UInt8(value)])), to: descriptor)
        }
      }
      defer { broker.stop() }
      let attachment = try await LocalAgentClient(socketURL: broker.socketURL).attach(
        sessionID: Self.session.id)
      try await broker.ended.wait()
      var received = Data()
      do {
        for try await chunk in attachment.output { received.append(chunk) }
        XCTFail("overflow completed without an error")
      } catch { XCTAssertEqual(error as? LocalAgentClientError, .backpressure) }
      XCTAssertEqual(received, Data((0..<64).map(UInt8.init)))
    }

    func testCancellationClosesAnOutstandingRPC() async throws {
      let requested = LocalTestSignal()
      let broker = try LocalTestBroker { _, _ in requested.signal() }
      defer { broker.stop() }
      let client = LocalAgentClient(socketURL: broker.socketURL)
      let task = Task { try await client.status() }
      try await requested.wait()
      task.cancel()
      do {
        _ = try await task.value
        XCTFail("cancelled RPC succeeded")
      } catch { XCTAssertTrue(error is CancellationError) }
      try await broker.ended.wait()
    }

    func testSilentBrokerCannotLeaveRPCWaitingForever() async throws {
      let broker = try LocalTestBroker { _, _ in }
      defer { broker.stop() }
      let started = ContinuousClock.now
      do {
        _ = try await LocalAgentClient(socketURL: broker.socketURL).status()
        XCTFail("silent broker succeeded")
      } catch { XCTAssertEqual(error as? LocalAgentClientError, .unavailable) }
      XCTAssertLessThan(started.duration(to: .now), .seconds(8))
    }
  }
#endif

#if os(macOS)
final class RemoteAccessFixtureTests: XCTestCase {
  func testSharedRemoteAccessFixtureDecodes() throws {
    struct Fixture: Decodable {
      let peer_list_response: LocalAgentFrame
      let local_share_request: LocalAgentRequest
      let local_session: LocalSessionInfo
      let access_request: LocalAgentRequest
      let access_response: LocalAgentFrame
      let access_listed_request: LocalAgentRequest
    }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let fixture = try decoder.decode(
      Fixture.self,
      from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/remote-access-v1.json")))
    let sessions = try XCTUnwrap(fixture.peer_list_response.sessions)
    XCTAssertEqual(sessions.map(\.access), [.control, .view])
    XCTAssertTrue(sessions.allSatisfy { $0.sharing == nil })
    // Who else can type: this Mac as {}, another device by name; an older
    // service (the second session) omits it.
    XCTAssertEqual(sessions.map(\.writers), [[LocalWriterInfo(name: nil), LocalWriterInfo(name: "iPad")], nil])
    try sessions.forEach(RemoteWire.validate)
    XCTAssertEqual(fixture.local_share_request.operation, .share)
    XCTAssertEqual(fixture.local_share_request.keepPrivate, false)
    XCTAssertEqual(fixture.local_share_request.remoteTyping, false)
    XCTAssertNil(fixture.local_share_request.shared)
    // Typing is shared: two controllers is valid.
    try LocalWire.validateSession(fixture.local_session)
    XCTAssertEqual(fixture.local_session.sharing?.controllers.count, 2)
    XCTAssertEqual(fixture.local_session.sharing?.remoteTyping, true)
    let access = try XCTUnwrap(fixture.access_request.access)
    XCTAssertEqual(access, LocalDeviceAccess(deviceID: "99999999-9999-4999-8999-999999999999", scope: .all, permission: .control))
    XCTAssertEqual(fixture.access_response.accesses, [access])
    // A policy may list single sessions besides shared ones.
    let listed = try XCTUnwrap(fixture.access_listed_request.access)
    XCTAssertEqual(listed.sessionIDs, [sessions[0].id])
    XCTAssertTrue(listed.lists(sessions[0].id))
    XCTAssertFalse(listed.lists(sessions[1].id))
    XCTAssertTrue(access.lists(sessions[1].id), "Every session is listed for scope all")
    // Sharing from a service before these fields existed still decodes.
    let legacy = try decoder.decode(
      LocalSessionSharing.self, from: Data(#"{"shared":true,"attachments":[]}"#.utf8))
    XCTAssertEqual(legacy, LocalSessionSharing(shared: true, attachments: []))
    let encoded = try JSONEncoder().encode(LocalDeviceAccess.default(for: access.deviceID))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertEqual(Set(object.keys), ["device_id", "scope", "permission", "co_typing", "session_ids"])
  }
}
#endif
