import AppKit
import SwiftTerm
import XCTest
@testable import WitermMac

@MainActor final class TerminalCustomizationTests: XCTestCase {
    /// Every color a program uses for text stays readable in every scheme.
    func testColorSchemesKeepTextContrast() throws {
        for scheme in TerminalColorScheme.allCases where scheme != .system {
            for dark in [false, true] {
                let values = try XCTUnwrap(scheme.values(dark: dark))
                XCTAssertEqual(values.ansi.count, 16)
                XCTAssertGreaterThanOrEqual(TerminalPalette.contrast(values.foreground, values.background), 13, "\(scheme) \(dark)")
                let textColors = dark ? [1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15] : [0, 1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14]
                for index in textColors {
                    XCTAssertGreaterThanOrEqual(TerminalPalette.contrast(values.ansi[index], values.background), 4.5,
                                                "\(scheme) dark=\(dark) ANSI \(index)")
                }
            }
        }
        XCTAssertNil(TerminalColorScheme.system.values(dark: true))
    }

    /// Enhanced contrast wins over a scheme; changing schemes keeps the text.
    func testSchemeChangesColorsWithoutTouchingContents() throws {
        let surface = NativeTerminalView.TerminalSurface(mode: .view, columns: 40, rows: 5)
        surface.appearance = NSAppearance(named: .darkAqua)
        surface.terminal.feed(text: "keep this line")
        surface.updateAppearance(fontSize: 14, highContrast: false, scheme: .dark, palette: .ocean)
        XCTAssertEqual(surface.terminal.nativeBackgroundColor.usingColorSpace(.sRGB)?.hexValue, 0x0B1A24)
        surface.updateAppearance(fontSize: 14, highContrast: true, scheme: .dark, palette: .ocean)
        XCTAssertEqual(surface.terminal.nativeBackgroundColor.usingColorSpace(.sRGB)?.hexValue, 0x000000)
        let line = surface.terminal.getTerminal().getLine(row: 0)?.translateToString(trimRight: true)
        XCTAssertEqual(line, "keep this line")
        XCTAssertEqual(surface.terminal.getTerminal().cols, 40)
    }

    func testSnippetInputIsBracketedAndOnlyRunsSingleLines() {
        let single = CommandSnippet(name: "Status", text: "git status", runsImmediately: true)
        XCTAssertEqual(String(decoding: single.input(bracketedPaste: false), as: UTF8.self), "git status\r")
        XCTAssertEqual(String(decoding: single.input(bracketedPaste: true), as: UTF8.self), "\u{1b}[200~git status\u{1b}[201~\r")
        let multi = CommandSnippet(name: "Two", text: "a\nb", runsImmediately: true)
        XCTAssertEqual(String(decoding: multi.input(bracketedPaste: true), as: UTF8.self), "\u{1b}[200~a\rb\u{1b}[201~")
    }

    func testSnippetValidationAndStorageRoundTrip() {
        XCTAssertNil(CommandSnippets.validate(name: "Deploy", text: "make deploy\n\techo done"))
        XCTAssertNotNil(CommandSnippets.validate(name: " ", text: "ls"))
        XCTAssertNotNil(CommandSnippets.validate(name: "Escape", text: "\u{1b}[2J"))
        XCTAssertNotNil(CommandSnippets.validate(name: "Big", text: String(repeating: "x", count: 4_097)))
        let saved = [CommandSnippet(name: "One", text: "ls -la"), CommandSnippet(name: "Bad", text: "\u{7}")]
        XCTAssertEqual(CommandSnippets.decode(CommandSnippets.encode(saved)).map(\.name), ["One"])
        XCTAssertTrue(CommandSnippets.decode(Data("not json".utf8)).isEmpty)
    }
}

private extension NSColor {
    var hexValue: UInt32 {
        (UInt32((redComponent * 255).rounded()) << 16) | (UInt32((greenComponent * 255).rounded()) << 8) | UInt32((blueComponent * 255).rounded())
    }
}
