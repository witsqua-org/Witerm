import Foundation
import SwiftTerm
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A terminal color scheme. Each scheme has a light and a dark variant and
/// follows the system appearance; there is no separate light/dark choice.
/// Enhanced contrast takes precedence over any scheme.
enum TerminalColorScheme: String, CaseIterable, Identifiable {
    case system, graphite, paper, ocean

    static let key = "witerm.terminalColorScheme"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "System", bundle: .main)
        case .graphite: String(localized: "Graphite", bundle: .main)
        case .paper: String(localized: "Paper", bundle: .main)
        case .ocean: String(localized: "Ocean", bundle: .main)
        }
    }

    /// Background, foreground, and the 16 ANSI colors, as 0xRRGGBB. Nil for
    /// `system`, which keeps the platform's text colors and SwiftTerm's palette.
    /// Every color a program uses for text (ANSI 1–6 and 9–14, plus 7 and 15 on
    /// dark and 0 on light) keeps 4.5:1 against the background; body text 13:1.
    func values(dark: Bool) -> (background: UInt32, foreground: UInt32, ansi: [UInt32])? {
        switch (self, dark) {
        case (.system, _): nil
        case (.graphite, false): (0xF4F5F7, 0x111215, [
            0x111215, 0xC32222, 0x257E34, 0x87690F, 0x2265C3, 0xAC39AC, 0x1C7A82, 0x838995,
            0x686E7B, 0xAD1F1F, 0x257E34, 0x87690F, 0x1F5AAD, 0x993399, 0x1C7A82, 0x838995])
        case (.graphite, true): (0x0F1013, 0xECEEF2, [
            0x5F6570, 0xE25A5A, 0x69D37B, 0xECC551, 0x5A93E2, 0xCF6ECF, 0x5FD3DD, 0xBABEC4,
            0x777D8B, 0xEA8686, 0x90DF9D, 0xF1D47E, 0x86AFEA, 0xDB94DB, 0x89DEE6, 0xFFFFFF])
        case (.paper, false): (0xFBF8F1, 0x2B2A27, [
            0x2B2A27, 0xC32222, 0x258034, 0x8A6B0F, 0x2265C3, 0xAC39AC, 0x1C7C85, 0x848A97,
            0x6B717D, 0xAD1F1F, 0x258034, 0x8A6B0F, 0x1F5AAD, 0x993399, 0x1C7C85, 0x848A97])
        case (.paper, true): (0x1E1C19, 0xEAE4D8, [
            0x666C78, 0xE25A5A, 0x69D37B, 0xECC551, 0x5A93E2, 0xCF6ECF, 0x5FD3DD, 0xBABEC4,
            0x808793, 0xEA8686, 0x90DF9D, 0xF1D47E, 0x86AFEA, 0xDB94DB, 0x89DEE6, 0xFFFFFF])
        case (.ocean, false): (0xF2F7FA, 0x0E2A3A, [
            0x0E2A3A, 0xC32222, 0x258034, 0x8A6B0F, 0x2265C3, 0xAC39AC, 0x1C7A82, 0x848A97,
            0x6A707C, 0xAD1F1F, 0x258034, 0x8A6B0F, 0x1F5AAD, 0x993399, 0x1C7A82, 0x848A97])
        case (.ocean, true): (0x0B1A24, 0xD8E8F0, [
            0x646975, 0xE25A5A, 0x69D37B, 0xECC551, 0x5A93E2, 0xCF6ECF, 0x5FD3DD, 0xBABEC4,
            0x7C8390, 0xEA8686, 0x90DF9D, 0xF1D47E, 0x86AFEA, 0xDB94DB, 0x89DEE6, 0xFFFFFF])
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
