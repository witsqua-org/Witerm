import XCTest
@testable import WitermMac

/// Themes: every palette stays readable, and choosing one recolors the app
/// and Match Theme terminals.
@MainActor final class ThemeTests: XCTestCase {
    private let warning: (light: UInt32, dark: UInt32) = (0xA04D00, 0xFFB340)
    private let positive: (light: UInt32, dark: UInt32) = (0x157043, 0x5BD68A)

    func testEveryThemeKeepsTextAndMachineColorsReadable() {
        for theme in AppTheme.allCases {
            for dark in [false, true] {
                let chrome = theme.chrome(dark: dark)
                let name = "\(theme) dark=\(dark)"
                for background in [chrome.canvas, chrome.surface] {
                    XCTAssertGreaterThanOrEqual(TerminalPalette.contrast(chrome.ink, background), 13, name)
                    XCTAssertGreaterThanOrEqual(TerminalPalette.contrast(chrome.secondary, background), 4.5, name)
                    XCTAssertGreaterThanOrEqual(TerminalPalette.contrast(chrome.accent, background), 4.5, name)
                    XCTAssertGreaterThanOrEqual(TerminalPalette.contrast(dark ? warning.dark : warning.light, background), 4.5, name)
                    XCTAssertGreaterThanOrEqual(TerminalPalette.contrast(dark ? positive.dark : positive.light, background), 4.5, name)
                    for hue in IdentityHue.palette {
                        XCTAssertGreaterThanOrEqual(TerminalPalette.contrast(dark ? hue.dark : hue.light, background), 4.5,
                                                    "\(name) hue \(String(hue.light, radix: 16))")
                    }
                }
                XCTAssertGreaterThanOrEqual(TerminalPalette.contrast(chrome.actionLabel, chrome.accent), 4.5, "\(name) button label")
            }
        }
    }

    /// The terminal sits on the theme's canvas and writes in its ink.
    func testEachThemesTerminalMatchesItsWindow() {
        for theme in AppTheme.allCases {
            for dark in [false, true] {
                let terminal = theme.terminal(dark: dark), chrome = theme.chrome(dark: dark)
                XCTAssertEqual(terminal.background, chrome.canvas, "\(theme) dark=\(dark)")
                XCTAssertEqual(terminal.foreground, chrome.ink, "\(theme) dark=\(dark)")
            }
        }
    }

    func testChoosingAThemeRecolorsAndPersistsAndMatchThemeFollows() {
        let store = ThemeStore.shared
        let before = store.theme
        defer { store.theme = before }
        store.theme = .ocean
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppTheme.key), "ocean")
        XCTAssertEqual(TerminalColorScheme.theme.resolved(), .ocean)
        XCTAssertEqual(TerminalColorScheme.paper.resolved(), .paper, "A chosen scheme stays")
        XCTAssertEqual(TerminalColorScheme.system.resolved(), .system)
        XCTAssertEqual(TerminalColorScheme.theme.values(dark: true)?.background, AppTheme.ocean.terminal(dark: true).background)
        let ocean = WitermTheme.accent
        store.theme = .ember
        XCTAssertNotEqual(WitermTheme.accent, ocean)
        XCTAssertEqual(TerminalColorScheme.theme.resolved(), .ember)
        store.theme = .ocean
        XCTAssertEqual(WitermTheme.accent, ocean, "One color per theme, so comparisons hold")
    }

    func testEveryThemeHasATerminalScheme() {
        for theme in AppTheme.allCases {
            XCTAssertEqual(TerminalColorScheme(rawValue: theme.rawValue)?.appTheme, theme)
        }
    }
}
