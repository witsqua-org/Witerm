import Network
import Observation
import SwiftUI

/// Whether this device has any usable network path. It explains a disconnect
/// before a connection times out; it never reconnects or resends on its own.
@MainActor @Observable
final class NetworkStatus {
    private(set) var online = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.online = online }
        }
        monitor.start(queue: DispatchQueue(label: "com.witerm.network-status"))
    }

    deinit { monitor.cancel() }
}

/// Shown above remote work while the device is offline.
struct OfflineBanner: View {
    /// Applied only while shown, so the banner takes no space when online.
    var insets = EdgeInsets()
    @Environment(NetworkStatus.self) private var network: NetworkStatus?

    var body: some View {
        if network?.online == false {
            IssueBanner(String(localized: "No Network Connection", bundle: .main),
                        message: Self.message, systemImage: "wifi.slash") { EmptyView() }
                .accessibilityIdentifier("offlineBanner")
                .padding(insets)
                .transition(.opacity)
        }
    }

    private static var message: String {
        #if os(macOS)
        String(localized: "SSH hosts and paired devices can't be reached. Terminals on this Mac keep running. Reconnect when the network returns; earlier input is never resent.", bundle: .main)
        #else
        String(localized: "SSH hosts and your Mac can't be reached. Reconnect when the network returns; earlier input is never resent.", bundle: .main)
        #endif
    }
}
