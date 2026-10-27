#if os(macOS)
import Crypto
import Darwin
import Foundation
@preconcurrency import Network
import XCTest
@testable import WitermSSH

private struct SSHFixture: Decodable, Sendable {
    let targetPort: Int
    let jumpPort: Int
    let privateKeyFile: String
    let encryptedKeyFile: String
    let targetPublicKeyFile: String
    let jumpPublicKeyFile: String
    static func load() throws -> Self {
        guard let path = ProcessInfo.processInfo.environment["WITERM_SSH_INTEGRATION_CONFIG"] else {
            throw XCTSkip("Set WITERM_SSH_INTEGRATION_CONFIG to an isolated OpenSSH fixture config")
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
    func publicKey(_ path: String) throws -> String {
        String(try String(contentsOfFile: path, encoding: .utf8).split(separator: " ")[1])
    }
    func profile(jump: Bool = false) -> SSHProfile {
        SSHProfile(name: "隔离 SSH 验收", host: SSHHost(hostname: jump ? "target" : "127.0.0.1",
                    port: jump ? 22 : targetPort, username: "fixture"),
                   jumpHosts: jump ? [SSHHost(hostname: "127.0.0.1", port: jumpPort, username: "fixture")] : [])
    }
    func connect(profile: SSHProfile, encrypted: Bool = false, password: Bool = false) async throws -> SSHConnection {
        let key = try String(contentsOfFile: encrypted ? encryptedKeyFile : privateKeyFile, encoding: .utf8)
        let credential: SSHCredential = password ? .password("witerm-fixture-only") : .privateKey(key, passphrase: encrypted ? "fixture-key-passphrase" : nil)
        let credentials = Dictionary(uniqueKeysWithValues: (profile.jumpHosts + [profile.host]).map { ($0.id, credential) })
        var expected = [profile.host.authority: try publicKey(targetPublicKeyFile)]
        for host in profile.jumpHosts { expected[host.authority] = try publicKey(jumpPublicKeyFile) }
        let pins = expected
        return try await SSHConnection.connect(profile: profile, credentials: credentials) { presented in
            guard pins[presented.authority] == presented.publicKey else { throw SSHFailure.hostKeyChanged }
        }
    }
}

private actor SSHOutputSink {
    var data = Data()
    func append(_ value: Data) { if data.count < 1_048_576 { data.append(value) } }
    func contains(_ value: String) -> Bool { String(decoding: data, as: UTF8.self).contains(value) }
    func wait(_ value: String) async throws {
        let end = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < end {
            if contains(value) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw SSHFailure.disconnected
    }
}

private actor SSHVerifiedAuthorities {
    var values: Set<String> = []
    func record(_ authority: String) { values.insert(authority) }
}

@MainActor final class SSHLiveTests: XCTestCase {
    private func read(_ shell: SSHShell) -> (SSHOutputSink, Task<Void, Never>) {
        let sink = SSHOutputSink()
        let reader = Task.detached {
            do { for try await data in shell.output { await sink.append(data) } }
            catch { /* No terminal payload or raw remote errors in test logs. */ }
        }
        return (sink, reader)
    }

    func testDirectPTYInputResizeAndEncryptedEd25519Authentication() async throws {
        let fixture = try SSHFixture.load()
        let connection = try await fixture.connect(profile: fixture.profile(), encrypted: true)
        do {
            let shell = try await connection.openShell(columns: 80, rows: 24)
            let (sink, reader) = read(shell)
            defer { reader.cancel() }
            try await shell.send(Data("printf 'WITERM_''SSH_INPUT_OK\\n'\n".utf8))
            try await sink.wait("WITERM_SSH_INPUT_OK\r\n")
            try await shell.resize(columns: 100, rows: 30)
            try await shell.send(Data("stty size\n".utf8))
            try await sink.wait("30 100\r\n")
            await connection.disconnect()
            do { try await shell.send(Data("x".utf8)); XCTFail("Disconnected input accepted") }
            catch { XCTAssertEqual(error as? SSHFailure, .disconnected) }
        } catch { await connection.disconnect(); throw error }
    }

    func testJumpPasswordAuthenticationAndSFTPStreamingNoOverwrite() async throws {
        let fixture = try SSHFixture.load()
        let connection = try await fixture.connect(profile: fixture.profile(jump: true), password: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("witerm-ssh-files-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = "/home/fixture/test-\(UUID().uuidString)"
        do {
            try await connection.createDirectory(path: remote)
            let bytes = Data((0..<1_048_793).map { UInt8($0 % 251) })
            let source = directory.appendingPathComponent("source.bin"), target = directory.appendingPathComponent("download.bin")
            try bytes.write(to: source)
            try await connection.upload(localURL: source, to: remote + "/binary.bin")
            let entries = try await connection.listDirectory(path: remote)
            XCTAssertEqual(entries.map(\.name), ["binary.bin"])
            XCTAssertEqual(entries.first?.size, UInt64(bytes.count))
            do { try await connection.upload(localURL: source, to: remote + "/binary.bin"); XCTFail("Remote overwrite accepted") }
            catch { /* Existing file must remain unchanged. */ }
            try await connection.download(remotePath: remote + "/binary.bin", to: target)
            XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: target)), SHA256.hash(data: bytes))
            do { try await connection.download(remotePath: remote + "/binary.bin", to: target); XCTFail("Local overwrite accepted") }
            catch { /* Existing destination must remain unchanged. */ }
            XCTAssertEqual(try Data(contentsOf: target), bytes)
            do { try await connection.createDirectory(path: "/root/forbidden-\(UUID())"); XCTFail("Permission denial reported success") }
            catch { /* Upstream STATUS failures must be surfaced. */ }
            try await connection.remove(path: remote + "/binary.bin", isDirectory: false)
            try await connection.remove(path: remote, isDirectory: true)
            await connection.disconnect()
        } catch {
            try? await connection.remove(path: remote + "/binary.bin", isDirectory: false)
            try? await connection.remove(path: remote, isDirectory: true)
            await connection.disconnect(); throw error
        }
    }

    func testNetworkFrameworkHalfCloseAgainstPOSIXEcho() async throws {
        _ = try SSHFixture.load()
        let payload = Data((0..<2_097_389).map { UInt8($0 % 251) })
        for attempt in 1...3 {
            let echo = try LocalSSHTestEcho()
            defer { echo.stop() }
            let client = SSHNWDirectTestClient(port: echo.port, payload: payload)
            let response = try await client.run()
            XCTAssertEqual(response, payload)
            print("SSH_NW_DIRECT_REPEAT pass=\(attempt)")
        }
    }

    func testLocalAndRemoteForwardsHalfCloseStopAndDisconnect() async throws {
        let fixture = try SSHFixture.load()
        let connection = try await fixture.connect(profile: fixture.profile())
        let echo = try LocalSSHTestEcho()
        defer { echo.stop() }
        do {
            print("SSH_FORWARD_PHASE local-start")
            let forward = try await connection.startForward(kind: .local, listenPort: 0, targetHost: "127.0.0.1", targetPort: 8081)
            let payload = Data((0..<2_097_389).map { UInt8($0 % 251) })
            print("SSH_FORWARD_PHASE local-roundtrip")
            let response = try await Task.detached { try Self.roundTrip(port: forward.listenPort, payload: payload) }.value
            XCTAssertEqual(response, payload)
            print("SSH_FORWARD_PHASE local-stop")
            await connection.stopForward(id: forward.id)
            do { _ = try Self.roundTrip(port: forward.listenPort, payload: Data([1])); XCTFail("Stopped listener still accepts") }
            catch { /* Local listener closed. */ }
            print("SSH_FORWARD_PHASE remote-start")
            let reverse = try await connection.startForward(kind: .remote, listenPort: 19081, targetHost: "127.0.0.1", targetPort: echo.port)
            print("SSH_FORWARD_PHASE remote-shell")
            let shell = try await connection.openShell()
            print("SSH_FORWARD_PHASE remote-shell-opened")
            let (sink, reader) = read(shell)
            defer { reader.cancel() }
            let program = """
            import socket, selectors, time
            data=bytes(i % 251 for i in range(2097389))
            s=socket.create_connection(("127.0.0.1",19081),3)
            s.setblocking(False)
            selector=selectors.DefaultSelector()
            selector.register(s,selectors.EVENT_READ|selectors.EVENT_WRITE)
            sent=0; received=bytearray(); eof=False; end=time.monotonic()+8
            while not eof and time.monotonic()<end:
                for _,mask in selector.select(0.1):
                    if mask & selectors.EVENT_WRITE and sent<len(data):
                        try: sent+=s.send(data[sent:sent+65536])
                        except BlockingIOError: pass
                        if sent==len(data):
                            s.shutdown(socket.SHUT_WR)
                            selector.modify(s,selectors.EVENT_READ)
                    if mask & selectors.EVENT_READ:
                        try: chunk=s.recv(65536)
                        except BlockingIOError: continue
                        if not chunk: eof=True; break
                        received.extend(chunk)
                        if len(received)>len(data): raise RuntimeError("excess data")
            s.close(); selector.close()
            print("WITERM_REMOTE_"+"FORWARD_OK" if eof and sent==len(data) and received==data else "FAIL")
            """
            let command = "python3 -c '" + program.replacingOccurrences(of: "'", with: "'\"'\"'") + "'\n"
            print("SSH_FORWARD_PHASE remote-command-send")
            try await shell.send(Data(command.utf8))
            print("SSH_FORWARD_PHASE remote-command-sent")
            try await sink.wait("WITERM_REMOTE_FORWARD_OK\r\n")
            print("SSH_FORWARD_PHASE remote-marker-received")
            print("SSH_FORWARD_PHASE remote-stop")
            await connection.stopForward(id: reverse.id)
            let remaining = await connection.activeForwards()
            XCTAssertTrue(remaining.isEmpty)
            let rebound = try await connection.startForward(kind: .remote, listenPort: 19081,
                                                            targetHost: "127.0.0.1", targetPort: echo.port)
            await connection.stopForward(id: rebound.id)
            let localAgain = try await connection.startForward(kind: .local, listenPort: 0, targetHost: "127.0.0.1", targetPort: 8081)
            await connection.disconnect()
            do { _ = try Self.roundTrip(port: localAgain.listenPort, payload: Data([1])); XCTFail("Disconnect left listener") }
            catch { /* All listeners close with transport. */ }
        } catch { await connection.disconnect(); throw error }
    }

    func testSFTPStalledRequestTimesOutAndOtherSSHChannelsSurvive() async throws {
        let fixture = try SSHFixture.load()
        let connection = try await fixture.connect(profile: fixture.profile())
        let fifo = "/home/fixture/blocked-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("witerm-ssh-stall-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let shell = try await connection.openShell()
            let (sink, reader) = read(shell)
            defer { reader.cancel() }
            try await shell.send(Data("mkfifo -- \(fifo) && printf 'WITERM_FIFO_''READY\\n'\n".utf8))
            try await sink.wait("WITERM_FIFO_READY\r\n")
            let began = ContinuousClock.now
            do {
                try await connection.download(remotePath: fifo, to: directory.appendingPathComponent("result"))
                XCTFail("A blocked FIFO request did not time out")
            } catch {
                let elapsed = began.duration(to: .now)
                XCTAssertGreaterThanOrEqual(elapsed, .seconds(25))
                XCTAssertLessThan(elapsed, .seconds(40))
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty,
                          "The cancelled download left a partial local file")
            try await shell.send(Data("printf 'WITERM_AFTER_''SFTP_TIMEOUT\\n'\n".utf8))
            try await sink.wait("WITERM_AFTER_SFTP_TIMEOUT\r\n")
            try await connection.remove(path: fifo, isDirectory: false)
            await connection.disconnect()
        } catch {
            try? await connection.remove(path: fifo, isDirectory: false)
            await connection.disconnect()
            throw error
        }
    }

    func testRejectedHostKeyFailsBeforeAuthenticationAndCannotCreateShell() async throws {
        let fixture = try SSHFixture.load(), profile = fixture.profile()
        let credentials: [UUID: SSHCredential] = [profile.host.id: .password("deliberately-wrong")]
        do {
            _ = try await SSHConnection.connect(profile: profile, credentials: credentials) { _ in throw SSHFailure.hostKeyChanged }
            XCTFail("Changed host key accepted")
        } catch { XCTAssertEqual(error as? SSHFailure, .hostKeyChanged) }
    }

    func testWrongPasswordReportsAuthenticationFailed() async throws {
        let fixture = try SSHFixture.load(), profile = fixture.profile()
        let expected = try fixture.publicKey(fixture.targetPublicKeyFile)
        do {
            _ = try await SSHConnection.connect(profile: profile, credentials: [profile.host.id: .password("deliberately-wrong")]) { key in
                guard key.publicKey == expected else { throw SSHFailure.hostKeyChanged }
            }
            XCTFail("Wrong password accepted")
        } catch { XCTAssertEqual(error as? SSHFailure, .authenticationFailed) }
    }

    func testUnreachableJumpTargetIsReportedSeparately() async throws {
        let fixture = try SSHFixture.load()
        var profile = fixture.profile(jump: true)
        profile.host.port = 1 // Nothing listens there on the target container.
        let expectedJump = try fixture.publicKey(fixture.jumpPublicKeyFile)
        let credentials = Dictionary(uniqueKeysWithValues: (profile.jumpHosts + [profile.host]).map {
            ($0.id, SSHCredential.password("witerm-fixture-only"))
        })
        do {
            _ = try await SSHConnection.connect(profile: profile, credentials: credentials) { key in
                guard key.publicKey == expectedJump else { throw SSHFailure.hostKeyChanged }
            }
            XCTFail("A missing jump target connected")
        } catch { XCTAssertEqual(error as? SSHFailure, .jumpTargetUnreachable) }
    }

    func testJumpRejectsChangedFinalIdentityAfterVerifiedJump() async throws {
        let fixture = try SSHFixture.load(), profile = fixture.profile(jump: true)
        let jump = profile.jumpHosts[0]
        let expectedJump = try fixture.publicKey(fixture.jumpPublicKeyFile)
        let credentials = Dictionary(uniqueKeysWithValues: (profile.jumpHosts + [profile.host]).map {
            ($0.id, SSHCredential.password("witerm-fixture-only"))
        })
        let visited = SSHVerifiedAuthorities()
        do {
            _ = try await SSHConnection.connect(profile: profile, credentials: credentials) { key in
                await visited.record(key.authority)
                if key.authority == jump.authority, key.publicKey == expectedJump { return }
                throw SSHFailure.hostKeyChanged
            }
            XCTFail("A verified jump bypassed the final host identity check")
        } catch { XCTAssertEqual(error as? SSHFailure, .hostKeyChanged) }
        let verified = await visited.values
        XCTAssertEqual(verified, Set([jump.authority, profile.host.authority]))
    }

    nonisolated static func roundTrip(port: Int, payload: Data) throws -> Data {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SSHFailure.disconnected }
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_port = UInt16(port).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else {
            print("SSH_FORWARD_FAIL phase=connect errno=\(errno)")
            throw SSHFailure.disconnected
        }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw SSHFailure.disconnected
        }
        var sent = 0, writeClosed = false
        var result = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        let end = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < end {
            var polled = pollfd(fd: fd,
                                events: Int16(POLLIN | (writeClosed ? 0 : POLLOUT)), revents: 0)
            let available = poll(&polled, 1, 100)
            if available < 0, errno == EINTR { continue }
            guard available >= 0, polled.revents & Int16(POLLNVAL | POLLERR) == 0 else {
                print("SSH_FORWARD_FAIL phase=poll errno=\(errno) revents=\(polled.revents) sent=\(sent) received=\(result.count)")
                throw SSHFailure.disconnected
            }
            if available == 0 { continue }
            if !writeClosed, polled.revents & Int16(POLLOUT) != 0 {
                let count = payload.withUnsafeBytes {
                    Darwin.send(fd, $0.baseAddress!.advanced(by: sent), min(65536, payload.count - sent), 0)
                }
                if count > 0 { sent += count }
                else if count < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                    print("SSH_FORWARD_FAIL phase=send errno=\(errno) sent=\(sent) received=\(result.count)")
                    throw SSHFailure.disconnected
                }
                if sent == payload.count {
                    guard shutdown(fd, SHUT_WR) == 0 else {
                        print("SSH_FORWARD_FAIL phase=shutdown errno=\(errno) sent=\(sent) received=\(result.count)")
                        throw SSHFailure.disconnected
                    }
                    writeClosed = true
                }
            }
            if polled.revents & Int16(POLLIN | POLLHUP) != 0 {
                let count = recv(fd, &buffer, buffer.count, 0)
                if count == 0 {
                    print("SSH_FORWARD_COUNTS sent=\(sent) received=\(result.count) eof=true")
                    return result
                }
                if count < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                    print("SSH_FORWARD_FAIL phase=recv errno=\(errno) sent=\(sent) received=\(result.count)")
                    throw SSHFailure.disconnected
                }
                guard result.count + count <= payload.count else {
                    print("SSH_FORWARD_FAIL phase=excess received=\(result.count) next=\(count)")
                    throw SSHFailure.disconnected
                }
                result.append(contentsOf: buffer.prefix(count))
            }
        }
        print("SSH_FORWARD_COUNTS sent=\(sent) received=\(result.count) eof=false")
        throw SSHFailure.disconnected
    }
}

private final class LocalSSHTestEcho: @unchecked Sendable {
    let port: Int
    private let listener: Int32
    private let lock = NSLock()
    private var child: Int32 = -1
    private var stopped = false
    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        listener = fd
        guard fd >= 0 else { throw SSHFailure.disconnected }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 4) == 0 else { Darwin.close(fd); throw SSHFailure.disconnected }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread.detachNewThread { [self] in run() }
    }
    private func run() {
        defer { Darwin.close(listener) }
        while !lock.withLock({ stopped }) {
            var polled = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&polled, 1, 100) > 0 else { continue }
            let peer = accept(listener, nil, nil)
            guard peer >= 0 else { continue }
            let accepted = lock.withLock { if stopped { return false }; child = peer; return true }
            if !accepted { Darwin.close(peer); return }
            var noSignal: Int32 = 1
            _ = setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var bytes = [UInt8](repeating: 0, count: 65536)
            var receivedTotal = 0, sentTotal = 0
            print("SSH_ECHO_PHASE accepted")
            while true {
                let count = recv(peer, &bytes, bytes.count, 0)
                guard count > 0 else { break }
                receivedTotal += count
                var sent = 0
                while sent < count {
                    let written = bytes.withUnsafeBytes {
                        Darwin.send(peer, $0.baseAddress!.advanced(by: sent), count - sent, 0)
                    }
                    if written < 0, errno == EINTR { continue }
                    if written <= 0 { break }
                    sent += written
                }
                sentTotal += sent
                if sent != count { break }
            }
            print("SSH_ECHO_PHASE finished received=\(receivedTotal) sent=\(sentTotal)")
            lock.withLock { child = -1; Darwin.close(peer) }
        }
    }
    func stop() {
        lock.withLock { stopped = true; if child >= 0 { _ = shutdown(child, SHUT_RDWR) }; _ = shutdown(listener, SHUT_RDWR) }
    }
}
private final class SSHNWDirectTestClient: @unchecked Sendable {
    private let network: NWConnection
    private let payload: Data
    private let queue = DispatchQueue(label: "com.witerm.tests.nw-direct")
    private var continuation: CheckedContinuation<Data, Error>?
    private var sent = 0, received = Data()
    private var readEOF = false, writeEOF = false, started = false, ended = false
    private var receivePending = false
    private var stateFailure: Error?
    init(port: Int, payload: Data) {
        self.payload = payload
        network = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
    }
    func run() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.continuation = continuation
                network.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready:
                        if !started { started = true; receive(); send() }
                    case .failed(let error):
                        print("SSH_NW_DIRECT_STATE failureCode=\(error.errorCode) receivePending=\(receivePending)")
                        stateFailure = error
                        if !receivePending { finish(.failure(error)) }
                    case .cancelled: if !ended { finish(.failure(SSHFailure.disconnected)) }
                    default: break
                    }
                }
                network.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                    self?.finish(.failure(SSHFailure.disconnected))
                }
            }
        }
    }
    private func send() {
        guard !ended else { return }
        if sent == payload.count {
            network.send(content: nil, contentContext: .finalMessage, isComplete: true,
                         completion: .contentProcessed { [self] error in
                guard error == nil else { finish(.failure(error!)); return }
                writeEOF = true; finishIfComplete()
            })
            return
        }
        let count = min(65536, payload.count - sent)
        let data = payload.subdata(in: sent..<(sent + count))
        network.send(content: data, completion: .contentProcessed { [self] error in
            guard error == nil else { finish(.failure(error!)); return }
            sent += count; send()
        })
    }
    private func receive() {
        guard !ended else { return }
        receivePending = true
        network.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
            receivePending = false
            if complete || error != nil {
                print("SSH_NW_DIRECT_RECEIVE data=\(data?.count ?? 0) complete=\(complete) errorCode=\(error?.errorCode ?? 0)")
            }
            if let data { received.append(data) }
            guard error == nil else { finish(.failure(error!)); return }
            guard received.count <= payload.count else { finish(.failure(SSHFailure.transferTooLarge)); return }
            if complete { readEOF = true; finishIfComplete() }
            else { receive() }
        }
    }
    private func finishIfComplete() {
        if readEOF && writeEOF { finish(.success(received)) }
    }
    private func finish(_ result: Result<Data, Error>) {
        guard !ended else { return }; ended = true
        print("SSH_NW_DIRECT_COUNTS sent=\(sent) received=\(received.count) readEOF=\(readEOF) writeEOF=\(writeEOF)")
        network.stateUpdateHandler = nil
        network.cancel()
        let previous = continuation; continuation = nil
        previous?.resume(with: result)
    }
}
#endif
