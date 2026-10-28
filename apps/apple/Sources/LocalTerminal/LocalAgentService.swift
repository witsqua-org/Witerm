#if os(macOS)
import Foundation
import Observation
import OSLog
import ServiceManagement
import SwiftUI
import WitermCore

extension EnvironmentValues {
    /// The background service's client while it runs, for views (such as
    /// pairing) that store this Mac's policy for a device.
    @Entry var localAgent: LocalAgentClient?
}

@MainActor @Observable
final class LocalAgentService {
    enum State: Equatable {
        case notRegistered, requiresApproval, starting, ready, unavailable
    }

    private(set) var state: State = .notRegistered
    private(set) var issue: String?
    private(set) var client: LocalAgentClient?
    /// Incremented before the service stops so open windows detach first.
    private(set) var stopRequests = 0
    @ObservationIgnored private let service = SMAppService.agent(plistName: "com.witerm.agent.plist")
    @ObservationIgnored private var changing = false
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private let logger = Logger(subsystem: "com.witerm.mac", category: "LocalAgentService")

    var canStop: Bool { service.status == .enabled || service.status == .requiresApproval }

    func refresh() async {
        guard !changing else { return }
        revision += 1
        let token = revision
        issue = nil
        do {
            let client = try makeClient()
            _ = try await client.status()
            guard revision == token, !changing else { return }
            self.client = client
            state = .ready
        } catch {
            guard revision == token, !changing else { return }
            client = nil
            switch service.status {
            case .notRegistered: state = .notRegistered
            case .requiresApproval: state = .requiresApproval
            case .enabled:
                state = .unavailable
                issue = String(localized: "The local service is unavailable. Try again.", bundle: .main)
            case .notFound:
                // A bundled but never registered LaunchAgent can report notFound.
                // Keep the explicit start action available; register() is authoritative.
                let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
                let files = ["Library/LaunchAgents/com.witerm.agent.plist", "Library/LaunchServices/WitermAgent.app/Contents/MacOS/witerm-agent"]
                if files.allSatisfy({ FileManager.default.fileExists(atPath: contents.appendingPathComponent($0).path) }) {
                    state = .notRegistered
                } else {
                    state = .unavailable
                    issue = String(localized: "The local service is incomplete. Reinstall Witerm.", bundle: .main)
                }
            @unknown default:
                state = .unavailable
                issue = String(localized: "Unable to confirm local service status.", bundle: .main)
            }
        }
    }

    func start() async {
        guard !changing else { return }
        changing = true
        revision += 1
        defer { changing = false }
        state = .starting
        issue = nil
        do {
            if service.status != .enabled { try service.register() }
            if service.status == .requiresApproval {
                state = .requiresApproval
                return
            }
            let client = try makeClient()
            for _ in 0..<20 {
                try Task.checkCancellation()
                if (try? await client.status()) != nil {
                    self.client = client
                    state = .ready
                    return
                }
                try await Task.sleep(for: .milliseconds(300))
            }
            self.client = nil
            state = service.status == .requiresApproval ? .requiresApproval : .unavailable
            if state == .unavailable { issue = String(localized: "The local service has not responded yet. Try again later.", bundle: .main) }
        } catch is CancellationError {
            state = .unavailable
            client = nil
        } catch {
            let failure = error as NSError
            logger.error("Local service start failed: \(failure.domain, privacy: .public) / \(failure.code)")
            client = nil
            state = service.status == .requiresApproval ? .requiresApproval : .unavailable
            if state == .unavailable { issue = String(localized: "Unable to start the local service. Check Login Items in System Settings.", bundle: .main) }
        }
    }

    func stop() async {
        guard !changing else { return }
        changing = true
        revision += 1
        defer { changing = false }
        stopRequests += 1
        await Task.yield()
        issue = nil
        do {
            if service.status != .notRegistered { try await service.unregister() }
            client = nil
            state = .notRegistered
        } catch {
            let failure = error as NSError
            logger.error("Local service stop failed: \(failure.domain, privacy: .public) / \(failure.code)")
            state = .unavailable
            issue = String(localized: "Unable to stop the local service. Try again later.", bundle: .main)
        }
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func makeClient() throws -> LocalAgentClient {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "WitermAppGroup") as? String,
              !group.isEmpty, !group.hasPrefix("."), !group.contains("$(") else {
            throw LocalAgentClientError.unavailable
        }
        return LocalAgentClient(socketURL: try LocalAgentPaths.socketURL(appGroupID: group))
    }
}
#endif
