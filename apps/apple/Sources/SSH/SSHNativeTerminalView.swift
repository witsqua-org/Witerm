import SwiftUI
import SwiftTerm
import WitermCore
import WitermSSH
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The live renderer of one SSH session. It is created with the session and
/// keeps consuming shell output whether or not any view currently shows it,
/// so switching between hosts never stalls or disconnects a session.
@MainActor final class SSHTerminalHost {
    let coordinator: SSHTerminalCoordinator
    #if os(macOS)
    let surface: NativeTerminalView.TerminalSurface
    #else
    let surface: RemoteNativeTerminalView.TerminalSurface
    #endif

    init(shell: SSHShell, onEnded: @escaping (Error?) -> Void) {
        coordinator = SSHTerminalCoordinator(shell: shell, onEnded: onEnded)
        #if os(macOS)
        surface = NativeTerminalView.TerminalSurface(mode: .control, columns: 80, rows: 24)
        surface.terminal.setAccessibilityLabel(String(localized: "SSH Terminal", bundle: .main))
        surface.terminal.setAccessibilityIdentifier("sshTerminalSurface")
        #else
        TerminalView.textInputDebugEnabled = false
        let session = LocalSessionInfo(id: UUID().uuidString, name: "SSH", createdAt: Date(), columns: 80, rows: 24)
        surface = RemoteNativeTerminalView.TerminalSurface(mode: .control, session: session, fontSize: 14, isInteractive: true)
        surface.readingView.accessibilityLabel = String(localized: "SSH Terminal Text", bundle: .main)
        surface.readingView.accessibilityIdentifier = "sshTerminalSurface"
        #endif
        surface.terminal.terminalDelegate = coordinator
        coordinator.start(surface.terminal)
    }

    func stop() {
        surface.terminal.terminalDelegate = nil
        coordinator.stop()
    }
}

#if os(macOS)
/// Shows a session's persistent renderer. Removing this view only detaches
/// the renderer; the session ends only when it is disconnected.
struct SSHNativeTerminalView: NSViewRepresentable {
    let host: SSHTerminalHost
    let fontSize: CGFloat
    let highContrast: Bool
    let scheme: ColorScheme?
    let announceOutput: Bool

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if host.surface.superview !== container { attach(to: container) }
        host.surface.updateAppearance(fontSize: fontSize, highContrast: highContrast, scheme: scheme)
        host.surface.terminal.announceOutput = announceOutput
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(to container: NSView) {
        let surface = host.surface
        surface.removeFromSuperview()
        surface.frame = container.bounds
        surface.autoresizingMask = [.width, .height]
        container.addSubview(surface)
    }
}
#else
/// Shows a session's persistent renderer. Removing this view only detaches
/// the renderer; the session ends only when it is disconnected.
struct SSHNativeTerminalView: UIViewRepresentable {
    let host: SSHTerminalHost
    let fontSize: CGFloat
    let highContrast: Bool
    let scheme: ColorScheme?
    let announceOutput: Bool
    let keyboardRequest: Int

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if host.surface.superview !== container { attach(to: container) }
        host.surface.updateFontSize(fontSize)
        host.surface.updateAppearance(highContrast: highContrast, scheme: scheme)
        host.surface.announceOutput = announceOutput
        host.coordinator.toggleKeyboard(keyboardRequest)
    }

    static func dismantleUIView(_ container: UIView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(to container: UIView) {
        let surface = host.surface
        surface.removeFromSuperview()
        surface.frame = container.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(surface)
    }
}
#endif

@MainActor final class SSHTerminalCoordinator: NSObject, @preconcurrency TerminalViewDelegate {
    private let shell: SSHShell
    private let onEnded: (Error?) -> Void
    private weak var terminal: TerminalView?
    private var outputTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var input: [Data] = []
    private var inputBytes = 0
    private var pendingSize: (Int, Int)?
    private var lastSize = (80, 24)
    private var stopped = false
    #if os(iOS)
    private var keyboardRequest = 0
    #endif

    init(shell: SSHShell, onEnded: @escaping (Error?) -> Void) {
        self.shell = shell; self.onEnded = onEnded
    }

    func start(_ view: TerminalView) {
        terminal = view
        stabilizeTestCursor(view)
        outputTask = Task { [weak self, weak view, shell] in
            do {
                for try await bytes in shell.output {
                    try Task.checkCancellation()
                    guard let self, !self.stopped, let view else { return }
                    view.feed(byteArray: Array(bytes)[...])
                    self.stabilizeTestCursor(view)
                    self.refreshReading(view, output: true)
                }
                guard let self, !self.stopped, !Task.isCancelled else { return }
                self.stop(); self.onEnded(nil)
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(error)
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        #if os(macOS)
        (terminal as? MacTerminalTextView)?.freezeInput()
        #else
        (terminal as? RemoteNativeTerminalView.TerminalInputView)?.disableInput()
        let oldTerminal = terminal
        DispatchQueue.main.async { [weak oldTerminal] in _ = oldTerminal?.resignFirstResponder() }
        #endif
        outputTask?.cancel(); inputTask?.cancel(); resizeTask?.cancel()
        input.removeAll(); inputBytes = 0; pendingSize = nil
        Task { [shell] in await shell.close() }
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !stopped, source === terminal, !data.isEmpty else { return }
        let chunks = (data.count + 16383) / 16384
        guard inputBytes + data.count <= 65536, input.count + chunks <= 256 else {
            fail(SSHFailure.backpressure); return
        }
        let bytes = Data(data)
        for offset in stride(from: 0, to: bytes.count, by: 16384) {
            let piece = bytes.subdata(in: offset..<min(offset + 16384, bytes.count))
            input.append(piece); inputBytes += piece.count
        }
        guard inputTask == nil else { return }
        inputTask = Task { [weak self, shell] in
            defer { self?.inputTask = nil }
            do {
                while let self, !self.stopped, !self.input.isEmpty {
                    let piece = self.input.removeFirst()
                    try await shell.send(piece)
                    try Task.checkCancellation()
                    guard !self.stopped else { return }
                    self.inputBytes -= piece.count
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(error)
            }
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard !stopped, source === terminal else { return }
        let size = (min(500, max(20, newCols)), min(200, max(5, newRows)))
        guard size != lastSize || pendingSize != nil else { return }
        pendingSize = size
        guard resizeTask == nil else { return }
        resizeTask = Task { [weak self, shell] in
            defer { self?.resizeTask = nil }
            do {
                while let self, !self.stopped, self.pendingSize != nil {
                    try await Task.sleep(for: .milliseconds(75))
                    guard !self.stopped, let size = self.pendingSize else { return }
                    self.pendingSize = nil
                    try await shell.resize(columns: size.0, rows: size.1)
                    try Task.checkCancellation()
                    self.lastSize = size
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(error)
            }
        }
    }

    #if os(iOS)
    func toggleKeyboard(_ request: Int) {
        guard request != keyboardRequest, !stopped else { return }
        keyboardRequest = request
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped, let terminal = self.terminal, terminal.window != nil else { return }
            if terminal.isFirstResponder { _ = terminal.resignFirstResponder() }
            else { _ = terminal.becomeFirstResponder() }
        }
    }
    #endif

    private func refreshReading(_ view: TerminalView, output: Bool = false) {
        #if os(macOS)
        (view as? MacTerminalTextView)?.refreshReadingDocument(outputChanged: output)
        #else
        (view as? RemoteNativeTerminalView.TerminalInputView)?.readingChanged?(output)
        #endif
    }

    private func stabilizeTestCursor(_ view: TerminalView) {
        #if DEBUG
        // Real SSH UI tests keep the production connection/input path. Only
        // this explicitly requested cursor animation is fixed for XCTest idle
        // detection; ordinary Debug launches and Release keep their defaults.
        // A blinking caret is an endlessly repeating animation, so XCTest
        // never sees the app idle and every later step waits 60 seconds.
        if ProcessInfo.processInfo.arguments.contains("--witerm-ui-test-steady-terminal-cursor") {
            view.getTerminal().setCursorStyle(.steadyBlock)
        }
        #endif
    }
    func scrolled(source: TerminalView, position: Double) { refreshReading(source) }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) { refreshReading(source) }
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func bell(source: TerminalView) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    // OSC links and clipboard requests never trigger system actions implicitly.
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    private func fail(_ error: Error) {
        guard !stopped else { return }
        stop(); onEnded(error)
    }
}
