#if os(macOS)
import Accessibility
import AppKit
import Observation
import WitermCore

/// The devices paired with this Mac through the relay server in use, for
/// Open On ▸ and to notice at once when one of them unpairs itself (an
/// iPhone can delete its own grant). While the app is active the list is
/// rechecked every 10 seconds and whenever the app becomes active; the local
/// service is asked which pairings are one-time invitations, which aren't
/// listed. Settings → Devices and the Continue sheet refresh when it changes.
@MainActor @Observable
final class MacPairedDevices {
    static let interval: Duration = .seconds(10)

    private(set) var pairing: DevicePairingModel?
    private(set) var guestPairings: Set<String> = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var address: String?
    @ObservationIgnored private var agent: LocalAgentClient?

    /// Devices paired with this Mac, not invitation guests, in name order.
    var devices: [PairedDevice] {
        guard let pairing, let me = pairing.device else { return [] }
        return pairing.grants.filter { $0.host.id == me.id && !guestPairings.contains($0.pairingID) }
            .map(\.client).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Follows a relay server with remote access on; nil stops.
    func track(serverAddress: String?, agent: LocalAgentClient?) {
        self.agent = agent
        guard serverAddress != address || loop == nil else { return }
        loop?.cancel()
        loop = nil
        pairing?.suspend()
        address = serverAddress
        guard let serverAddress else { pairing = nil; return }
        if pairing?.serverAddress != serverAddress { pairing = DevicePairingModel(serverAddress: serverAddress) }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                if NSApp.isActive { await self?.recheck() }
                do { try await Task.sleep(for: Self.interval) } catch { return }
            }
        }
    }

    /// Now, such as when the app becomes active.
    func recheck() async {
        guard let pairing else { return }
        if let agent, let invites = try? await agent.guests() {
            let ids = Set(invites.map(\.pairingID))
            if ids != guestPairings { guestPairings = ids }
        }
        guard !pairing.isWorking, !pairing.hasLivePairing else { return }
        if pairing.device == nil { pairing.connect() } else { pairing.refresh() }
    }

    /// Names that left between two lists of one server, for "*device* unpaired".
    static func removed(from old: [PairedDevice], to new: [PairedDevice]) -> [String] {
        let kept = Set(new.map(\.id))
        return old.filter { !kept.contains($0.id) }.map(\.name)
    }
}

/// The paired devices of one server, for noticing which left.
struct PairedSnapshot: Equatable {
    let address: String?
    let devices: [PairedDevice]
}
#endif
