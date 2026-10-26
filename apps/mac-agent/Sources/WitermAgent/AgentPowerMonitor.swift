import AppKit
import Foundation
import OSLog

// User-session power notifications only; no privilege, sleep inhibition, or
// attempt to keep the machine running. tmux remains owned by the local broker.
final class AgentPowerMonitor {
    private let center: NotificationCenter
    private let observers: [NSObjectProtocol]

    @MainActor
    init(willSleep: @escaping @Sendable () -> Void, didWake: @escaping @Sendable () -> Void) {
        center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                Logger(subsystem: "com.witerm.agent", category: "Power").info("Preparing terminal relay for sleep")
                willSleep()
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                Logger(subsystem: "com.witerm.agent", category: "Power").info("Resuming terminal relay after wake")
                didWake()
            }
        ]
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
    }
}
