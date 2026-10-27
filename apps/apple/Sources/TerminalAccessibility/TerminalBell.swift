#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Rings the terminal bell (BEL) the way the platform expects. Rings are
/// spaced out so a program printing many BELs cannot flood feedback.
@MainActor enum TerminalBell {
    static let key = "witerm.terminalBell"
    private static var last: ContinuousClock.Instant?

    static func ring() {
        guard UserDefaults.standard.object(forKey: key) as? Bool ?? true else { return }
        let now = ContinuousClock.now
        if let last, now - last < .milliseconds(300) { return }
        last = now
        #if os(macOS)
        NSSound.beep()
        // A bell from a finished task brings someone back to the app.
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        #else
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }
}
