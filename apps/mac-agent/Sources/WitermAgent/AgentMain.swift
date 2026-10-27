import Darwin
import Foundation
import WitermCore

@main
@MainActor
enum AgentMain {
    static func main() {
        do {
            var values: [String: String] = [:]
            var iterator = CommandLine.arguments.dropFirst().makeIterator()
            while let argument = iterator.next() {
                if argument == "--help" {
                    print("witerm-agent --app-group <identifier> | --state-directory <absolute-path> [--tmux-path <path>] [--shell-path <path>]")
                    return
                }
                guard ["--app-group", "--state-directory", "--tmux-path", "--shell-path"].contains(argument), values[argument] == nil, let value = iterator.next() else { throw AgentFailure() }
                values[argument] = value
            }
            let directory: URL
            if let path = values["--state-directory"], values["--app-group"] == nil {
                guard path.hasPrefix("/") else { throw AgentFailure() }
                directory = URL(fileURLWithPath: path, isDirectory: true)
            } else if let group = values["--app-group"], values["--state-directory"] == nil,
                      let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
                directory = container.appendingPathComponent("local", isDirectory: true)
            } else { throw AgentFailure() }
            _ = umask(0o077)
            signal(SIGPIPE, SIG_IGN)
            let board = RelayStatusBoard()
            let relay = RelayHostCoordinator(stateDirectory: directory, board: board)
            let broker = try AgentBroker(configuration: AgentConfiguration(stateDirectory: directory, tmuxPath: values["--tmux-path"], shellPath: values["--shell-path"]),
                                         relays: board)
            signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
            let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            let end: @Sendable () -> Void = {
                Task { await relay.stop(); broker.stop(); exit(0) }
            }
            term.setEventHandler(handler: end); interrupt.setEventHandler(handler: end)
            term.resume(); interrupt.resume()
            try broker.start()
            let power = AgentPowerMonitor(
                willSleep: {
                    // Bound preparation; never hold a power notification while
                    // waiting indefinitely for an already stalled connection.
                    let finished = DispatchGroup()
                    finished.enter()
                    Task.detached {
                        await relay.prepareForSleep()
                        finished.leave()
                    }
                    _ = finished.wait(timeout: .now() + 2)
                },
                didWake: { Task.detached { await relay.resumeAfterWake() } }
            )
            Task { await relay.start() }
            // Workspace power notifications arrive through the main run loop;
            // the same loop also services the signal DispatchSources.
            withExtendedLifetime((broker, relay, term, interrupt, power)) { RunLoop.main.run() }
        } catch {
            // No terminal data, command strings, environment or raw OS errors.
            FileHandle.standardError.write(Data("Witerm agent could not start.\n".utf8))
            exit(1)
        }
    }
}
