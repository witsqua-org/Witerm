import SwiftUI
import WitermCore
import WitermSSH
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A remote machine's identity color. The app chrome stays neutral; color
/// belongs to machines, so one host looks the same on every screen and an
/// open session shows which machine receives input. The local machine stays
/// uncolored.
@MainActor
enum IdentityHue {
    /// Light variants keep 4.5:1 on white and on their own 12% tint; dark
    /// variants keep it on the dark surface and under the dark action label.
    /// Neighbours sit far apart on the color wheel, because machines added
    /// one after another usually take neighbouring slots.
    private static let palette: [(light: UInt32, dark: UInt32)] = [
        (0xC2264F, 0xFF6B8B), // rose
        (0x0B7A57, 0x4FE3B0), // mint
        (0x8F6100, 0xFFC24B), // amber
        (0x2F55D4, 0x7AA2FF), // blue
        (0x426B0A, 0xB7F05A), // lime
        (0xA8288F, 0xF37BE0), // magenta
        (0x0B6FA8, 0x5CC8FF), // sky
        (0xB8441A, 0xFF8A5B), // coral
        (0x7A3FD6, 0xB58CFF), // violet
        (0x7A6630, 0xD9C38F), // sand
    ]

    private static let colors = palette.map { dynamic(light: $0.light, dark: $0.dark) }
    private static let storageKey = "witerm.identityHues"
    /// Identity (profile ID or device public key) to palette index. Holds no
    /// addresses, names, or credentials.
    private static var assigned = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Int] ?? [:]

    static func color(for identity: String) -> Color {
        colors[index(for: identity)]
    }

    /// Frees a removed machine's hue for the next one.
    static func forget(_ identity: String) {
        guard assigned.removeValue(forKey: identity) != nil else { return }
        UserDefaults.standard.set(assigned, forKey: storageKey)
    }

    /// A machine takes the least-used hue the first time it appears, starting
    /// from its hashed slot, and keeps it. Hashing alone would give two of a
    /// handful of hosts the same color too often.
    private static func index(for identity: String) -> Int {
        if let index = assigned[identity], palette.indices.contains(index) { return index }
        var uses = Array(repeating: 0, count: palette.count)
        for index in assigned.values where palette.indices.contains(index) { uses[index] += 1 }
        let fewest = uses.min() ?? 0
        let preferred = hashedIndex(for: identity)
        let index = palette.indices.lazy.map { (preferred + $0) % palette.count }.first { uses[$0] == fewest } ?? preferred
        assigned[identity] = index
        UserDefaults.standard.set(assigned, forKey: storageKey)
        return index
    }

    /// FNV-1a, so the starting slot is the same across launches; `Hasher` is
    /// seeded per process.
    private static func hashedIndex(for identity: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int(hash % UInt64(palette.count))
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            rgb(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
        #else
        Color(uiColor: UIColor { traits in rgb(traits.userInterfaceStyle == .dark ? dark : light) })
        #endif
    }

    #if os(macOS)
    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
    #else
    private static func rgb(_ value: UInt32) -> UIColor {
        UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
    #endif
}

extension SSHProfile {
    @MainActor var identityHue: Color { IdentityHue.color(for: id.uuidString) }
}

extension PairedDevice {
    /// Keyed to the device's public key, the identity pairing verifies.
    @MainActor var identityHue: Color { IdentityHue.color(for: publicKey) }
}
