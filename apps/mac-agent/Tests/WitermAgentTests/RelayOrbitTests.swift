import Foundation
import XCTest
@testable import WitermCore
@testable import WitermAgent

/// Orbit from a paired phone (relay-v1 `orbit`, Round 32): through the
/// modeled relay and the real bridge, to an isolated terminal service and the
/// real `witerm orbit serve`, whose model requests go to a closed port on
/// this Mac, never to OpenAI.
final class RelayOrbitTests: XCTestCase {
    private var binary: URL {
        Bundle(for: RelayOrbitTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("witerm")
    }

    func testOnlyADeviceThatMayTypeEverywhereReachesOrbit() async throws {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("Build the witerm product first") }
        let service = try FlowService.start(self)
        let peers = try FlowTestPeers()
        let folder = URL(fileURLWithPath: "/private/tmp/witerm-orbit-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        let started = OrbitTestCounter()
        let keyReads = OrbitTestCounter()
        let processes = OrbitTestProcesses()
        addTeardownBlock {
            processes.stopAll()
            try? FileManager.default.removeItem(at: folder)
        }
        let client = OrbitClient(socketURL: folder.appendingPathComponent(OrbitPaths.socketName))
        let binary = binary
        let socket = service.directory.appendingPathComponent("agent.sock")
        let gateway = OrbitGateway(client: client, start: {
            started.increment()
            let process = Process()
            process.executableURL = binary
            process.arguments = ["orbit", "serve"]
            process.environment = ["WITERM_ORBIT_DIRECTORY": folder.path, "WITERM_AGENT_SOCKET": socket.path,
                                   "WITERM_ORBIT_OPENAI_URL": "http://127.0.0.1:9/v1/responses", "PATH": "/usr/bin:/bin"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            processes.keep(process)
            for _ in 0..<60 {
                if (try? await client.status()) != nil { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return false
        }, key: { keyReads.increment(); return "sk-test" })
        let open: @Sendable () async throws -> RelaySecureChannel = {
            let (phone, mac) = try await peers.channels(over: ModeledTunnel())
            let bridge = RelayTerminalBridge(channel: mac, pairing: peers.host, local: service.local, traceID: "orbit",
                                             orbit: gateway)
            Task { await bridge.run() }
            return phone
        }
        func refused(_ request: OrbitRequest, _ expected: RelayError, line: UInt = #line) async {
            do {
                _ = try await RemoteTerminalClient.orbit(request, open: open)
                XCTFail("Reached Orbit", line: line)
            } catch {
                XCTAssertEqual(error as? RelayError, expected, line: line)
            }
        }
        let device = peers.grant.client.id

        // Paired with the default access (terminals the Mac shares): no Orbit,
        // and nothing is started or read for it.
        await refused(OrbitRequest(operation: .threads), .readOnly)
        XCTAssertEqual(started.value, 0)
        XCTAssertEqual(keyReads.value, 0)

        // Every terminal, typing: Orbit starts, gets the key, and answers.
        _ = try await service.local.deviceAccess(LocalDeviceAccess(deviceID: device, scope: .all, permission: .control))
        let status = try await RemoteTerminalClient.orbit(OrbitRequest(operation: .status), open: open)
        XCTAssertTrue(status.ok)
        XCTAssertEqual(status.status?.hasKey, true)
        XCTAssertEqual(started.value, 1)
        XCTAssertEqual(keyReads.value, 1)
        let first = try await RemoteTerminalClient.orbit(
            OrbitRequest(operation: .start, text: "What runs in my terminals?", kind: .chat), open: open)
        let thread = try XCTUnwrap(first.thread)
        XCTAssertEqual(thread.entries.first?.text, "What runs in my terminals?")
        let list = try await RemoteTerminalClient.orbit(OrbitRequest(operation: .threads), open: open)
        XCTAssertEqual(list.threads?.map(\.id), [thread.summary.id])
        // Already keyed and running: neither is done again.
        XCTAssertEqual(started.value, 1)
        XCTAssertEqual(keyReads.value, 1)
        // Orbit's own refusals come back in its reply.
        let missing = try await RemoteTerminalClient.orbit(
            OrbitRequest(operation: .thread, threadID: UUID().uuidString.lowercased()), open: open)
        XCTAssertFalse(missing.ok)
        XCTAssertEqual(missing.error, .notFound)

        // Orbit stopped: the next request starts it again.
        processes.stopAll()
        let again = try await RemoteTerminalClient.orbit(OrbitRequest(operation: .threads), open: open)
        XCTAssertEqual(again.threads?.map(\.id), [thread.summary.id])
        XCTAssertEqual(started.value, 2)

        // Watching every terminal, or typing in chosen ones: no Orbit.
        _ = try await service.local.deviceAccess(LocalDeviceAccess(deviceID: device, scope: .all, permission: .view))
        await refused(OrbitRequest(operation: .threads), .readOnly)
        _ = try await service.local.deviceAccess(LocalDeviceAccess(deviceID: device, scope: .shared, permission: .control))
        await refused(OrbitRequest(operation: .threads), .readOnly)

        // What OrbitRelay doesn't admit never leaves the phone.
        _ = try await service.local.deviceAccess(LocalDeviceAccess(deviceID: device, scope: .all, permission: .control))
        await refused(OrbitRequest(operation: .configure, apiKey: "sk-elsewhere"), .invalidMessage)
        await refused(OrbitRequest(operation: .clear), .invalidMessage)
        await refused(OrbitRequest(operation: .takeOver, threadID: thread.summary.id, agent: "Phone"), .invalidMessage)
    }

    /// The service finds the app's helper from its own place in the bundle.
    func testTheServiceFindsTheAppsHelper() throws {
        let root = URL(fileURLWithPath: "/private/tmp/witerm-helper-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Witerm.app/Contents", isDirectory: true)
        let agent = contents.appendingPathComponent("Library/LaunchServices/WitermAgent.app/Contents/MacOS/witerm-agent")
        let helper = contents.appendingPathComponent("Helpers/witerm")
        try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: agent.path, contents: Data())
        XCTAssertNil(OrbitStarter.helper(agentExecutable: agent), "No helper yet")
        FileManager.default.createFile(atPath: helper.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(OrbitStarter.helper(agentExecutable: agent)?.resolvingSymlinksInPath().path,
                       helper.resolvingSymlinksInPath().path)
        // A service outside an app bundle (a development build) has none.
        XCTAssertNil(OrbitStarter.helper(agentExecutable: root.appendingPathComponent("witerm-agent")))
    }
}

final class OrbitTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

final class OrbitTestProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [Process] = []
    func keep(_ process: Process) { lock.withLock { processes.append(process) } }
    func stopAll() {
        let all = lock.withLock { () -> [Process] in defer { processes = [] }; return processes }
        for process in all where process.isRunning { process.terminate(); process.waitUntilExit() }
    }
}
