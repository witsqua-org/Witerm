#if DEBUG
    import SwiftUI
    import SwiftTerm
    import WitermCore
    #if os(macOS)
        import AppKit
    #else
        import UIKit
    #endif

    enum TerminalAccessibilityHarness {
        static var requested: Bool {
            #if os(macOS)
                ProcessInfo.processInfo.arguments.contains(
                    "--witerm-terminal-accessibility-harness")
                    || plainBaselineRequested
            #else
                ProcessInfo.processInfo.arguments.contains(
                    "--witerm-terminal-accessibility-harness")
            #endif
        }
        #if os(macOS)
            static var plainBaselineRequested: Bool {
                ProcessInfo.processInfo.arguments.contains("--witerm-voiceover-plain-baseline")
            }
        #endif
        static let session = LocalSessionInfo(
            id: "44444444-4444-4444-8444-444444444444", name: "固定朗读验证",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), columns: 100, rows: 36)
        static let normal =
            "\u{1b}[?1049l\u{1b}[2J\u{1b}[H中文终端验证 👩‍💻 e\u{301}\r\n第二行：阅读不会发送输入。\r\n第三行：alpha beta gamma\u{1b}[1;65H横向右端验证\u{1b}[20;1H纵向下页验证\u{1b}[5;1H终端光标位置\u{1b}[6;1Habcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij\u{1b}[1;1H"
        static let alternate =
            "\u{1b}[?1049h\u{1b}[2J\u{1b}[H备用屏幕验证\r\n备用第二行：👩‍💻 e\u{301}\r\n备用第三行：alpha beta gamma\u{1b}[5;1H备用光标位置\u{1b}[1;1H"
    }

    #if os(macOS)
        private enum TerminalHarnessAnchor: String, Hashable {
            case before, after, baselineOne, baselineTwo
        }
    #endif

    /// DEBUG-only, memory-only native surface. It never constructs a workspace,
    /// attachment, identity, helper service, URLSession or persisted preference.
    @MainActor
    struct TerminalAccessibilityHarnessView: View {
        @StateObject private var state = TerminalAccessibilityHarnessState()
        #if os(macOS)
            @AccessibilityFocusState(for: .voiceOver) private var voiceOverAnchor:
                TerminalHarnessAnchor?
        #endif

        var body: some View {
            #if os(macOS)
                if TerminalAccessibilityHarness.plainBaselineRequested {
                    plainBaseline
                } else {
                    terminalFixture
                }
            #else
                terminalFixture
            #endif
        }

        #if os(macOS)
            // This branch deliberately never constructs TerminalHarnessSurface.
            // It isolates ordinary SwiftUI navigation from native terminal AX/rendering.
            private var plainBaseline: some View {
                VStack(alignment: .leading, spacing: 8) {
                    Text("普通导航基线").font(.headline)
                    Text(state.ready ? "已就绪" : "准备中")
                        .accessibilityIdentifier("harnessReady")
                    Text(state.anchor?.rawValue ?? "none")
                        .accessibilityLabel("朗读锚点状态")
                        .accessibilityValue(state.anchor?.rawValue ?? "none")
                        .accessibilityIdentifier("harnessAnchorState")
                    Text("\(state.anchorActivation)")
                        .accessibilityLabel("朗读锚点调用次数")
                        .accessibilityValue("\(state.anchorActivation)")
                        .accessibilityIdentifier("harnessAnchorActivation")
                    Button("导航基准一") {
                        state.anchor = .baselineOne
                        state.anchorActivation += 1
                        voiceOverAnchor = .baselineOne
                    }
                    .accessibilityIdentifier("harnessBaselineOne")
                    .accessibilityFocused($voiceOverAnchor, equals: .baselineOne)
                    Button("导航基准二") {
                        state.anchor = .baselineTwo
                        state.anchorActivation += 1
                        voiceOverAnchor = .baselineTwo
                    }
                    .accessibilityIdentifier("harnessBaselineTwo")
                    .accessibilityFocused($voiceOverAnchor, equals: .baselineTwo)
                }
                .padding(12)
                .frame(
                    minWidth: 260, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading
                )
                .onAppear { state.ready = true }
            }
        #endif

        private var terminalFixture: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("终端朗读验证").font(.headline)
                Text(state.mode == .view ? "只读" : "受控").accessibilityIdentifier("harnessMode")
                HStack {
                    Text("输入次数：\(state.inputCalls)，字节：\(state.inputBytes)")
                        .accessibilityLabel("终端输入计数")
                        .accessibilityValue("\(state.inputCalls):\(state.inputBytes)")
                        .accessibilityIdentifier("harnessInputCount")
                    Text(state.ready ? "已就绪" : "准备中").accessibilityIdentifier("harnessReady")
                }.font(.caption)
                #if os(macOS)
                    Text(state.anchor?.rawValue ?? "none")
                        .accessibilityLabel("朗读锚点状态")
                        .accessibilityValue(state.anchor?.rawValue ?? "none")
                        .accessibilityIdentifier("harnessAnchorState")
                    Text("\(state.anchorActivation)")
                        .accessibilityLabel("朗读锚点调用次数")
                        .accessibilityValue("\(state.anchorActivation)")
                        .accessibilityIdentifier("harnessAnchorActivation")
                    Button("导航基准一") {
                        state.anchor = .baselineOne
                        state.anchorActivation += 1
                        voiceOverAnchor = .baselineOne
                    }
                    .accessibilityIdentifier("harnessBaselineOne")
                    .accessibilityFocused($voiceOverAnchor, equals: .baselineOne)
                    Button("导航基准二") {
                        state.anchor = .baselineTwo
                        state.anchorActivation += 1
                        voiceOverAnchor = .baselineTwo
                    }
                    .accessibilityIdentifier("harnessBaselineTwo")
                    .accessibilityFocused($voiceOverAnchor, equals: .baselineTwo)
                    Button("朗读前锚点") {
                        state.anchor = .before
                        state.anchorActivation += 1
                        voiceOverAnchor = .before
                    }
                    .accessibilityIdentifier("harnessBefore")
                    .accessibilityFocused($voiceOverAnchor, equals: .before)
                #else
                    Button("朗读前锚点") { state.anchor = "before" }.accessibilityIdentifier(
                        "harnessBefore")
                #endif
                TerminalHarnessSurface(state: state)
                    .frame(width: state.narrow ? 260 : nil, height: 280)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .border(.secondary)
                #if os(macOS)
                    Button("朗读后锚点") {
                        state.anchor = .after
                        state.anchorActivation += 1
                        voiceOverAnchor = .after
                    }
                    .accessibilityIdentifier("harnessAfter")
                    .accessibilityFocused($voiceOverAnchor, equals: .after)
                #else
                    Button("朗读后锚点") { state.anchor = "after" }.accessibilityIdentifier(
                        "harnessAfter")
                #endif
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 110))], alignment: .leading, spacing: 8
                ) {
                    Button(state.largeFont ? "标准字号" : "放大字号") { state.largeFont.toggle() }
                        .accessibilityIdentifier("harnessFont")
                    Button(state.narrow ? "标准视口" : "窄视口") { state.narrow.toggle() }
                        .accessibilityIdentifier("harnessNarrow")
                    Button(state.highContrast ? "标准对比" : "增强对比") { state.highContrast.toggle() }
                        .accessibilityIdentifier("harnessContrast")
                    Button(state.alternate ? "返回主屏幕" : "备用屏幕") { state.alternate.toggle() }
                        .accessibilityIdentifier("harnessAlternate")
                    Button("测试阅读") { state.probeReading() }.accessibilityIdentifier(
                        "harnessReadingProbe")
                    Button("测试输入") { state.probeInput() }.accessibilityIdentifier(
                        "harnessInputProbe")
                    Button("显示键盘") { state.focusKeyboard() }.disabled(state.mode == .view)
                        .accessibilityIdentifier("harnessKeyboard")
                }.buttonStyle(.bordered)
                Text(
                    "字号 \(state.largeFont ? 24 : 14)，\(state.narrow ? "窄视口" : "标准视口")，\(state.highContrast ? "增强对比" : "标准对比")"
                )
                .font(.caption).accessibilityIdentifier("harnessAppearanceStatus")
                Text("阅读检查：\(state.readingAttempts)，输入检查：\(state.inputAttempts)")
                    .font(.caption).accessibilityValue(
                        "\(state.readingAttempts):\(state.inputAttempts)"
                    )
                    .accessibilityIdentifier("harnessProbeCount")
            }
            .padding(12)
            .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @MainActor
    private final class TerminalAccessibilityHarnessState: NSObject, ObservableObject,
        @preconcurrency TerminalViewDelegate
    {
        let mode: LocalAttachmentMode =
            ProcessInfo.processInfo.arguments.contains("--witerm-terminal-read-only")
            ? .view : .control
        @Published var inputCalls = 0
        @Published var inputBytes = 0
        @Published var readingAttempts = 0
        @Published var inputAttempts = 0
        @Published var ready = false
        @Published var largeFont = false
        @Published var narrow = false
        @Published var highContrast = false
        @Published var alternate = false
        #if os(macOS)
            @Published var anchor: TerminalHarnessAnchor?
            @Published var anchorActivation = 0
            weak var surface: NativeTerminalView.TerminalSurface?
        #else
            var anchor = ""
            weak var surface: RemoteNativeTerminalView.TerminalSurface?
        #endif

        func probeInput() {
            inputAttempts += 1
            #if os(macOS)
                surface?.terminal.insertText(
                    "k", replacementRange: NSRange(location: NSNotFound, length: 0))
            #else
                surface?.terminal.insertText("k")
            #endif
        }

        func probeReading() {
            readingAttempts += 1
            #if os(macOS)
                surface?.terminal.setAccessibilitySelectedTextRange(NSRange(location: 0, length: 2))
                _ = surface?.terminal.accessibilityString(for: NSRange(location: 0, length: 2))
            #else
                surface?.readingView.setReadingSelection(NSRange(location: 0, length: 2))
                surface?.readingView.insertText("x")
                surface?.readingView.deleteBackward()
            #endif
        }

        func focusKeyboard() {
            guard mode == .control, let surface else { return }
            #if os(macOS)
                _ = surface.window?.makeFirstResponder(surface.terminal)
            #else
                _ = surface.terminal.becomeFirstResponder()
            #endif
        }

        // Count every actual delegate write, including an accidental readonly one.
        // No mode guard here can hide a defect in the real terminal input surface.
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard !data.isEmpty else { return }
            inputCalls += 1
            inputBytes += data.count
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) { refresh() }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) { refresh() }
        func bell(source: TerminalView) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        private func refresh() {
            #if os(macOS)
                surface?.terminal.refreshReadingDocument()
            #else
                surface?.refreshReadingDocument()
            #endif
        }
    }

    #if os(macOS)
        private struct TerminalHarnessSurface: NSViewRepresentable {
            @ObservedObject var state: TerminalAccessibilityHarnessState
            @MainActor final class Coordinator {
                var alternate: Bool?
                func render(
                    _ view: NativeTerminalView.TerminalSurface,
                    state: TerminalAccessibilityHarnessState
                ) {
                    view.layoutSubtreeIfNeeded()
                    if alternate != state.alternate {
                        view.terminal.feed(
                            text: state.alternate
                                ? TerminalAccessibilityHarness.alternate
                                : TerminalAccessibilityHarness.normal)
                        alternate = state.alternate
                    }
                    // This fixed UI fixture does not exercise blinking; keep
                    // native keyboard hit testing quiescent for XCTest.
                    view.terminal.getTerminal().setCursorStyle(.steadyBlock)
                    view.terminal.refreshReadingDocument()
                }
                func prepare(
                    _ view: NativeTerminalView.TerminalSurface,
                    state: TerminalAccessibilityHarnessState, attempts: Int = 20
                ) {
                    guard view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else {
                        guard attempts > 0 else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                            [weak self, weak view, weak state] in
                            guard let view, let state else { return }
                            self?.prepare(view, state: state, attempts: attempts - 1)
                        }
                        return
                    }
                    render(view, state: state)
                    state.ready = true
                }
            }
            func makeCoordinator() -> Coordinator { Coordinator() }
            func makeNSView(context: Context) -> NativeTerminalView.TerminalSurface {
                let view = NativeTerminalView.TerminalSurface(
                    mode: state.mode, columns: 100, rows: 36)
                state.surface = view
                view.terminal.getTerminal().setCursorStyle(.steadyBlock)
                view.terminal.terminalDelegate = state
                update(view, context: context)
                let coordinator = context.coordinator
                DispatchQueue.main.async { [weak view, weak state] in
                    guard let view, let state else { return }
                    coordinator.prepare(view, state: state)
                }
                return view
            }
            func updateNSView(_ view: NativeTerminalView.TerminalSurface, context: Context) {
                update(view, context: context)
            }
            private func update(_ view: NativeTerminalView.TerminalSurface, context: Context) {
                view.updateAppearance(
                    fontSize: state.largeFont ? 24 : 14, highContrast: state.highContrast,
                    scheme: .light)
                // The first fixture is installed only by the post-layout ready phase.
                if context.coordinator.alternate != nil, view.bounds.width > 0,
                    view.bounds.height > 0
                {
                    context.coordinator.render(view, state: state)
                }
            }
        }
    #else
        private struct TerminalHarnessSurface: UIViewRepresentable {
            @ObservedObject var state: TerminalAccessibilityHarnessState
            @MainActor final class Coordinator {
                var alternate: Bool?
                func render(
                    _ view: RemoteNativeTerminalView.TerminalSurface,
                    state: TerminalAccessibilityHarnessState
                ) {
                    view.layoutIfNeeded()
                    if alternate != state.alternate {
                        view.terminal.feed(
                            text: state.alternate
                                ? TerminalAccessibilityHarness.alternate
                                : TerminalAccessibilityHarness.normal)
                        alternate = state.alternate
                    }
                    // This fixed UI fixture does not exercise blinking; keep
                    // native keyboard hit testing quiescent for XCTest.
                    view.terminal.getTerminal().setCursorStyle(.steadyBlock)
                    view.refreshReadingDocument()
                }
                func prepare(
                    _ view: RemoteNativeTerminalView.TerminalSurface,
                    state: TerminalAccessibilityHarnessState, attempts: Int = 20
                ) {
                    guard view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else {
                        guard attempts > 0 else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                            [weak self, weak view, weak state] in
                            guard let view, let state else { return }
                            self?.prepare(view, state: state, attempts: attempts - 1)
                        }
                        return
                    }
                    render(view, state: state)
                    state.ready = true
                }
            }
            func makeCoordinator() -> Coordinator { Coordinator() }
            func makeUIView(context: Context) -> RemoteNativeTerminalView.TerminalSurface {
                let view = RemoteNativeTerminalView.TerminalSurface(
                    mode: state.mode, session: TerminalAccessibilityHarness.session,
                    fontSize: state.largeFont ? 24 : 14, isInteractive: state.mode == .control)
                state.surface = view
                view.terminal.getTerminal().setCursorStyle(.steadyBlock)
                view.terminal.terminalDelegate = state
                update(view, context: context)
                let coordinator = context.coordinator
                DispatchQueue.main.async { [weak view, weak state] in
                    guard let view, let state else { return }
                    coordinator.prepare(view, state: state)
                }
                return view
            }
            func updateUIView(_ view: RemoteNativeTerminalView.TerminalSurface, context: Context) {
                update(view, context: context)
            }
            private func update(_ view: RemoteNativeTerminalView.TerminalSurface, context: Context)
            {
                view.updateFontSize(state.largeFont ? 24 : 14)
                view.updateAppearance(highContrast: state.highContrast, scheme: .light)
                // The first fixture is installed only by the post-layout ready phase.
                if context.coordinator.alternate != nil, view.bounds.width > 0,
                    view.bounds.height > 0
                {
                    context.coordinator.render(view, state: state)
                }
            }
        }
    #endif
#endif
