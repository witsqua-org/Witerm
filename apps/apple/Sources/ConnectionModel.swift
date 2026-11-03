import Foundation
import Observation
import WitermCore

enum ConnectionPhase: Equatable {
    case idle
    case checking
    case available(Date)
    case failed(ConnectionIssue)

    var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var accessibilityKey: String {
        switch self {
        case .idle: "idle"
        case .checking: "checking"
        case .available: "available"
        case .failed: "failed"
        }
    }
}

struct ConnectionIssue: Equatable {
    let title: String
    let recovery: String
    /// The relay server's name inside `recovery`, if it's there.
    let host: String?

    /// `host` names the relay server in the recovery text, so you know which one failed.
    init(error: Error, host: String? = nil) {
        self.host = host
        let server = host ?? String(localized: "The relay server", bundle: .main)
        if let error = error as? ServerClientError {
            switch error {
            case .invalidAddress:
                title = String(localized: "Invalid Address Format", bundle: .main)
                recovery = String(localized: "Enter the relay server’s host name, such as witerm.example.com.", bundle: .main)
            case .incompatibleServer:
                title = String(localized: "Incompatible Relay Server", bundle: .main)
                recovery = String(localized: "\(server) runs a Witerm version this app can’t use. Update the relay server or the app.", bundle: .main)
            case .notWiterm:
                title = String(localized: "Not a Relay Server", bundle: .main)
                recovery = String(localized: "\(server) answered, but it isn’t a Witerm relay server. If Witerm runs behind a reverse proxy such as nginx, check that the proxy forwards /v1/ and /readyz.", bundle: .main)
            case .notReady:
                title = String(localized: "Relay Server Not Ready", bundle: .main)
                recovery = String(localized: "\(server) is running but not ready. Its database may be unavailable. Try again shortly.", bundle: .main)
            case .unavailable:
                title = String(localized: "Relay Server Unavailable", bundle: .main)
                recovery = String(localized: "Check that the relay server is running, then try again.", bundle: .main)
            }
        } else if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost:
                title = String(localized: "Network Disconnected", bundle: .main)
                recovery = String(localized: "Connect to Wi-Fi or a cellular network, then try again.", bundle: .main)
            case .timedOut:
                title = String(localized: "Relay Server Timed Out", bundle: .main)
                recovery = String(localized: "\(server) didn’t answer. Check your network, or that the relay server is running.", bundle: .main)
            case .cannotFindHost, .dnsLookupFailed:
                title = String(localized: "Relay Server Not Found", bundle: .main)
                recovery = host.map { String(localized: "Nothing named \($0) was found. Check the spelling.", bundle: .main) }
                    ?? String(localized: "Check the relay server’s address.", bundle: .main)
            case .cannotConnectToHost:
                title = String(localized: "Connection Refused", bundle: .main)
                recovery = String(localized: "\(server) refused the connection. Check the port, and that Witerm is running there.", bundle: .main)
            case .appTransportSecurityRequiresSecureConnection:
                title = String(localized: "Secure Connection Required", bundle: .main)
                recovery = String(localized: "Use an HTTPS address for the relay server.", bundle: .main)
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot:
                title = String(localized: "Unable to Verify Secure Connection", bundle: .main)
                recovery = String(localized: "\(server)’s certificate isn’t trusted. Check the certificate, or this device’s date and time.", bundle: .main)
            default:
                title = String(localized: "Can’t Reach the Relay Server", bundle: .main)
                recovery = String(localized: "Check the address and your network, then try again.", bundle: .main)
            }
        } else {
            title = String(localized: "Unrecognized Response", bundle: .main)
            recovery = String(localized: "Check that you entered a relay server address.", bundle: .main)
        }
    }

    /// `recovery` for display: the relay server's name may break between any
    /// two characters, so a wrapped name never gains a hyphen that would read
    /// as part of it. VoiceOver reads `recovery` itself.
    var displayRecovery: String {
        guard let host, !host.isEmpty else { return recovery }
        return recovery.replacingOccurrences(of: host, with: host.breakingAnywhere)
    }

    /// Title and recovery as one sentence pair, for announcements.
    var spoken: String { String(localized: "\(title). \(recovery)", bundle: .main) }
}

/// One saved Witerm server and the result of checking it. `ServerList` owns
/// the saved set and its persistence.
@MainActor @Observable
final class ConnectionModel: Identifiable {
    let id = UUID()
    private(set) var address: String
    private(set) var phase: ConnectionPhase = .idle
    private(set) var successCount = 0
    private(set) var failureCount = 0
    private(set) var capabilities: [String] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let client = ServerClient()

    init(address: String) {
        self.address = address
    }

    var hasAddress: Bool { !address.isEmpty }
    // Capabilities persist from the last successful check of this address, so
    // a background recheck never tears down an open pairing or relay view.
    // They are cleared whenever the address changes.
    var supportsPairing: Bool { capabilities.contains("device_pairing_v1") }
    var supportsRelay: Bool { capabilities.contains("encrypted_relay_v1") }
    var hostName: String? { URL(string: address)?.host }
    /// Host plus any non-default port, enough to tell saved servers apart.
    var displayName: String {
        guard let parts = URLComponents(string: address), let host = parts.host else { return address }
        return parts.port.map { "\(host):\($0)" } ?? host
    }

    var statusTitle: String {
        switch phase {
        case .idle: hasAddress ? String(localized: "Not Checked", bundle: .main) : String(localized: "Not Set Up", bundle: .main)
        case .checking: String(localized: "Checking", bundle: .main)
        case .available: String(localized: "Check Passed", bundle: .main)
        case .failed: String(localized: "Connection Failed", bundle: .main)
        }
    }

    var statusTone: StatusBadge.Tone {
        switch phase {
        case .available: .positive
        case .failed: .warning
        case .idle, .checking: .neutral
        }
    }

    var statusSymbol: String {
        switch phase {
        case .idle: "circle.dashed"
        case .checking: "arrow.triangle.2.circlepath"
        case .available: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle"
        }
    }

    /// Changes the address and checks it. Capabilities from the old address
    /// never carry over.
    func update(address: String) {
        cancel()
        self.address = address
        capabilities = []
        phase = .idle
        check()
    }

    func check() {
        cancel()
        guard hasAddress else { return }
        let requestedAddress = address
        #if os(iOS) && DEBUG
        if RemoteFixture.isActive, address == RemoteFixture.serverAddress {
            capabilities = ["device_identity_v1", "device_pairing_v1", "encrypted_relay_v1"]
            phase = .available(.now)
            successCount += 1
            return
        }
        #endif
        phase = .checking
        task = Task { [weak self, client] in
            do {
                let info = try await client.checkConnection(address: requestedAddress)
                guard !Task.isCancelled, let self else { return }
                self.capabilities = info.capabilities
                self.phase = .available(.now)
                self.successCount += 1
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.phase = .failed(ConnectionIssue(error: error, host: self.displayName))
                self.failureCount += 1
            }
        }
    }

    /// Checks a configured server once per launch or foreground return. An
    /// explicit failure stays visible until the person checks again.
    func checkIfNeeded() {
        guard hasAddress, phase == .idle else { return }
        check()
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase.isChecking { phase = .idle }
    }
}
