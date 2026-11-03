import UIKit
import SwiftTerm
import WitermCore
import XCTest
@testable import WitermiOS

/// Round 15: SwiftTerm's Metal renderer is a DEBUG-only trial. Without the
/// `-witerm.debug.renderer metal` launch argument, terminals keep Core Graphics.
@MainActor final class TerminalRendererTrialTests: XCTestCase {
    func testCoreGraphicsIsTheDefault() {
        XCTAssertNil(UserDefaults.standard.string(forKey: "witerm.debug.renderer"), "Tests run without the trial's argument")
        XCTAssertFalse(RemoteNativeTerminalView.RendererTrial.usesMetal)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let session = LocalSessionInfo(id: UUID().uuidString, name: "Renderer", createdAt: .now, columns: 40, rows: 20)
        let surface = RemoteNativeTerminalView.TerminalSurface(mode: .control, session: session, fontSize: 14, isInteractive: true)
        surface.frame = CGRect(x: 0, y: 120, width: 402, height: 600)
        window.rootViewController?.view.addSubview(surface)
        surface.layoutIfNeeded()
        XCTAssertFalse(surface.terminal.isUsingMetalRenderer, "Terminals draw with Core Graphics unless the trial asks for Metal")
    }
}
