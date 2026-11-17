import Foundation
import SwiftTerm
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A terminal color scheme: the theme's own (the default), the platform's
/// plain colors, or any theme's terminal colors. Each scheme has a light and
/// a dark variant and follows the system appearance; there is no separate
/// light/dark choice. Enhanced contrast takes precedence over any scheme.
enum TerminalColorScheme: String, CaseIterable, Identifiable {
    case theme, system, graphite, paper, ocean, forest, dusk, ember

    static let key = "witerm.terminalColorScheme"
    static let standard = TerminalColorScheme.theme

    var id: String { rawValue }

    var title: String {
        switch self {
        case .theme: String(localized: "Match Theme", bundle: .main)
        case .system: String(localized: "System", bundle: .main)
        default: appTheme?.title ?? rawValue
        }
    }

    /// The theme whose terminal colors this scheme uses, if it names one.
    var appTheme: AppTheme? { AppTheme(rawValue: rawValue) }

    /// The scheme a terminal draws with: Match Theme becomes the chosen
    /// theme's scheme. Read in a view's body, so a theme change redraws.
    @MainActor func resolved() -> TerminalColorScheme {
        self == .theme ? TerminalColorScheme(rawValue: ThemeStore.shared.theme.rawValue) ?? .graphite : self
    }

    /// Background, foreground, and the 16 ANSI colors, as 0xRRGGBB. Nil for
    /// `system`, which keeps the platform's text colors and SwiftTerm's palette.
    /// Every color a program uses for text (ANSI 1–6 and 9–14, plus 7 and 15 on
    /// dark and 0 on light) keeps 4.5:1 against the background; body text 13:1.
    /// `theme` reads the stored theme; renderers get `resolved()` schemes.
    func values(dark: Bool) -> (background: UInt32, foreground: UInt32, ansi: [UInt32])? {
        switch self {
        case .system: nil
        case .theme:
            (UserDefaults.standard.string(forKey: AppTheme.key).flatMap(AppTheme.init(rawValue:)) ?? .standard).terminal(dark: dark)
        default: appTheme?.terminal(dark: dark)
        }
    }
}

enum TerminalPalette {
    /// Foreground-oriented ANSI16 palette. True-color TUI choices remain owned
    /// by the remote application; this does not promise arbitrary color pairs.
    static func colors(highContrast: Bool, dark: Bool, scheme: TerminalColorScheme = .system) -> [SwiftTerm.Color] {
        guard highContrast else {
            return scheme.values(dark: dark)?.ansi.map(color) ?? SwiftTerm.Color.defaultInstalledColors
        }
        let values: [UInt32] = dark
            ? [0x767676, 0xFF8C8C, 0x8EE28E, 0xF4DE88, 0x91BEFF, 0xEAA4EA, 0x88DDDD, 0xEEEEEE,
               0xAAAAAA, 0xFFAFAF, 0xB2F4B2, 0xFFEDA5, 0xB8D5FF, 0xF4C2F4, 0xB0F2F2, 0xFFFFFF]
            : [0x111111, 0x9A1515, 0x226522, 0x725300, 0x174EA6, 0x792879, 0x006262, 0x595959,
               0x4A4A4A, 0xAB2020, 0x226822, 0x765300, 0x2055AD, 0x852985, 0x006767, 0x656565]
        return values.map(color)
    }

    static func color(_ value: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(red8: UInt16((value >> 16) & 255), green8: UInt16((value >> 8) & 255), blue8: UInt16(value & 255))
    }

    /// WCAG contrast ratio between two 0xRRGGBB colors.
    static func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        func luminance(_ value: UInt32) -> Double {
            zip([16, 8, 0], [0.2126, 0.7152, 0.0722]).reduce(0) { total, channel in
                let level = Double((value >> UInt32(channel.0)) & 255) / 255
                return total + channel.1 * (level <= 0.04045 ? level / 12.92 : pow((level + 0.055) / 1.055, 2.4))
            }
        }
        let first = luminance(first), second = luminance(second)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}

#if os(macOS)
extension NSColor {
    convenience init(terminalRGB value: UInt32) {
        self.init(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
#else
extension UIColor {
    convenience init(terminalRGB value: UInt32) {
        self.init(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
#endif
