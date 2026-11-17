import Darwin
import Foundation
import WitermCore

/// Orbit for paired devices (relay-v1 `orbit`, Round 32). The relay endpoint
/// hands it requests `OrbitRelay` admitted, from devices that may type in
/// every terminal; it passes them to Orbit's own socket, as the app does.
///
/// When Orbit isn't running it starts it from the app's helper. When Orbit
/// has no API key it reads the key the user kept in the Keychain and gives it
/// to Orbit over the private socket (the owner's choice, 2026-11-18), so a
/// phone can use Orbit while Witerm's window is closed. The key is never
/// kept here, logged, or sent to a device.
actor OrbitGateway {
    private let client: OrbitClient
    private let start: @Sendable () async -> Bool
    private let key: @Sendable () -> String?

    init(client: OrbitClient, start: @escaping @Sendable () async -> Bool,
         key: @escaping @Sendable () -> String? = { OrbitKeychain.read() }) {
        self.client = client
        self.start = start
        self.key = key
    }

    /// Orbit's folder beside the service's own state folder, as `OrbitPaths`
    /// places it in the app group.
    static func directory(stateDirectory: URL) -> URL {
        stateDirectory.deletingLastPathComponent().appendingPathComponent("orbit", isDirectory: true)
    }

    /// The reply for the device: Orbit's own, or `unavailable` in Orbit's
    /// words when it can't be reached.
    func handle(_ request: OrbitRequest) async -> OrbitResponse {
        do {
            return try await exchange(request)
        } catch OrbitClientError.unavailable {
            guard await start() else { return refusal(request, .unavailable) }
            do { return try await exchange(request) } catch { return failure(request, error) }
        } catch {
            return failure(request, error)
        }
    }

    private func exchange(_ request: OrbitRequest) async throws -> OrbitResponse {
        if try await !client.status().hasKey, let key = key() {
            _ = try? await client.configure(apiKey: key, model: nil)
        }
        do {
            return try await client.rpc(request)
        } catch OrbitClientError.rejected(let code) {
            return OrbitResponse(id: request.id, ok: false, error: code)
        }
    }

    private func failure(_ request: OrbitRequest, _ error: Error) -> OrbitResponse {
        if case OrbitClientError.rejected(let code) = error { return refusal(request, code) }
        return refusal(request, .unavailable)
    }

    private func refusal(_ request: OrbitRequest, _ code: OrbitErrorCode) -> OrbitResponse {
        OrbitResponse(id: request.id, ok: false, error: code)
    }
}

/// Starts `witerm orbit serve` from the app this service belongs to:
/// `Witerm.app/Contents/Helpers/witerm`, found from the service's own place
/// at `Contents/Library/LaunchServices/WitermAgent.app/Contents/MacOS`.
enum OrbitStarter {
    private static let children = OrbitChildren()

    static func helper(agentExecutable: URL) -> URL? {
        var contents = agentExecutable.resolvingSymlinksInPath()
        for _ in 0..<6 { contents.deleteLastPathComponent() }
        guard contents.lastPathComponent == "Contents" else { return nil }
        let helper = contents.appendingPathComponent("Helpers/witerm")
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }

    static func start(client: OrbitClient) async -> Bool {
        guard let executable = Bundle.main.executableURL, let helper = helper(agentExecutable: executable) else { return false }
        let process = Process()
        process.executableURL = helper
        process.arguments = ["orbit", "serve"]
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        children.keep(process)
        for _ in 0..<30 {
            if (try? await client.status()) != nil { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}

/// Started helpers, kept so they're reaped when they exit.
private final class OrbitChildren: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [Process] = []
    func keep(_ process: Process) { lock.withLock { processes = processes.filter(\.isRunning) + [process] } }
}
