import Darwin
import Foundation
import WitermCore

/// Starts `witerm orbit serve` from this same executable when an outside
/// agent needs Orbit and it isn't running, so a handoff works without
/// opening Orbit in Witerm first. Orbit detaches (`setsid`) and outlives the
/// agent. It has no API key until Witerm gives it one, which Witerm does as
/// soon as Orbit starts while Witerm is open (docs/orbit.md).
enum OrbitLauncher {
    /// Children are kept so they're reaped when they exit.
    private static let children = Locked<[Process]>([])

    /// The environment Orbit gets: no inherited secrets or endpoint
    /// overrides from the agent, only the development folder and socket.
    static func environment(from parent: [String: String]) -> [String: String] {
        var environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for name in ["WITERM_ORBIT_DIRECTORY", "WITERM_AGENT_SOCKET"] {
            if let value = parent[name] { environment[name] = value }
        }
        return environment
    }

    static func start(client: OrbitClient, environment: [String: String], socket: String?) async -> Bool {
        guard let path = AgentLocator.executablePath(), let resolved = realpath(path, nil) else { return false }
        let executable = URL(fileURLWithPath: String(cString: resolved))
        free(resolved)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["orbit", "serve"] + (socket.map { ["--socket", $0] } ?? [])
        process.environment = Self.environment(from: environment)
        // The agent's stdin and stdout carry MCP; Orbit never touches them.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        children.set(children.get().filter(\.isRunning) + [process])
        for _ in 0..<30 {
            if (try? await client.status()) != nil { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}
