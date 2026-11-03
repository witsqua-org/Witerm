#if os(iOS)
import SwiftUI
import SwiftTerm
import UIKit

/// A key the mobile key row can show. The order and selection are kept in
/// this device's preferences and edited under Settings → Keyboard Row.
enum MobileKey: String, CaseIterable, Identifiable {
    // Ordered by how often they are needed: the first seven fit an iPhone's
    // width without scrolling the row.
    case escape, control, tab, left, up, down, right, interrupt, paste, snippets
    case bar, slash, tilde, hyphen, home, end, pageUp, pageDown

    static let key = "witerm.mobileKeys"
    var id: String { rawValue }

    /// The default row before arrows moved forward. A saved row identical to
    /// it was never customized, so it follows the current default.
    static let previousDefault = "escape,control,tab,interrupt,paste,snippets,left,down,up,right,bar,tilde,slash,hyphen,home,end,pageUp,pageDown"

    /// The order and keys stored under `key`; empty or unreadable means all keys.
    static func decode(_ raw: String) -> [MobileKey] {
        guard raw != previousDefault else { return allCases }
        var seen = Set<MobileKey>()
        let keys = raw.split(separator: ",").compactMap { MobileKey(rawValue: String($0)) }.filter { seen.insert($0).inserted }
        return keys.isEmpty ? allCases : keys
    }

    /// Keys that repeat while held, like a hardware keyboard's.
    var repeats: Bool {
        switch self {
        case .left, .down, .up, .right, .pageUp, .pageDown: true
        default: false
        }
    }

    static func encode(_ keys: [MobileKey]) -> String { keys.map(\.rawValue).joined(separator: ",") }

    /// What the key shows. Terminal key names stay in English, like a keyboard.
    var face: String {
        switch self {
        case .escape: "Esc"
        case .control: "Ctrl"
        case .tab: "Tab"
        case .interrupt: "Ctrl+C"
        case .paste: String(localized: "Paste", bundle: .main)
        case .snippets: String(localized: "Snippets", bundle: .main)
        case .left: "←"
        case .down: "↓"
        case .up: "↑"
        case .right: "→"
        case .bar: "|"
        case .tilde: "~"
        case .slash: "/"
        case .hyphen: "-"
        case .home: "Home"
        case .end: "End"
        case .pageUp: "PgUp"
        case .pageDown: "PgDn"
        }
    }

    /// The spoken and listed name.
    var label: String {
        switch self {
        case .escape: String(localized: "Escape", bundle: .main)
        case .control: String(localized: "Control for Next Key", bundle: .main)
        case .tab: String(localized: "Tab", bundle: .main)
        case .interrupt: String(localized: "Interrupt (Control-C)", bundle: .main)
        case .paste: String(localized: "Paste", bundle: .main)
        case .snippets: String(localized: "Snippets", bundle: .main)
        case .left: String(localized: "Left Arrow", bundle: .main)
        case .down: String(localized: "Down Arrow", bundle: .main)
        case .up: String(localized: "Up Arrow", bundle: .main)
        case .right: String(localized: "Right Arrow", bundle: .main)
        case .bar: String(localized: "Vertical Bar", bundle: .main)
        case .tilde: String(localized: "Tilde", bundle: .main)
        case .slash: String(localized: "Slash", bundle: .main)
        case .hyphen: String(localized: "Hyphen", bundle: .main)
        case .home: String(localized: "Home", bundle: .main)
        case .end: String(localized: "End", bundle: .main)
        case .pageUp: String(localized: "Page Up", bundle: .main)
        case .pageDown: String(localized: "Page Down", bundle: .main)
        }
    }

    /// What a Voice Control user can say: the visible face first, so "Tap
    /// Ctrl" works, then the spoken name.
    var inputLabels: [String] {
        var labels = [face]
        switch self {
        case .control: labels.append("Control")
        case .interrupt: labels += ["Control C", "Interrupt"]
        case .pageUp: labels.append("Page Up")
        case .pageDown: labels.append("Page Down")
        default: break
        }
        labels.append(label)
        var seen = Set<String>()
        return labels.filter { seen.insert($0).inserted }
    }

    var identifier: String {
        switch self {
        case .control: "terminalControlModifier"
        case .interrupt: "terminalInterrupt"
        case .bar: "terminalKey-|"
        case .tilde: "terminalKey-~"
        case .slash: "terminalKey-/"
        case .hyphen: "terminalKey--"
        default: "terminalKey-\(rawValue)"
        }
    }
}

/// One accessible row shared by direct SSH and paired terminals. Actions are
/// committed on touch-up so scrolling the row never sends a key by accident.
@MainActor final class MobileTerminalAccessory: UIInputView, UIInputViewAudioFeedback {
    private weak var terminal: RemoteNativeTerminalView.TerminalInputView?
    private let control = UIButton(type: .system)
    private let keys = UIStackView()
    private var keyHeightConstraint: NSLayoutConstraint?
    private var shown: [MobileKey] = []
    /// Pinned at the row's end: Hide Keyboard, always (the keyboard button
    /// shows only while the keyboard is hidden, so this is how it goes away,
    /// and hiding it stops typing in a paired terminal), and the bar's own
    /// actions menu while the navigation bar steps aside for typing (iPhone
    /// in landscape).
    private let barKeys = UIStackView()
    private let hideKeyboard = UIButton(type: .system)
    private var barActions: UIHostingController<AnyView>?
    private var barKeyHeights: [NSLayoutConstraint] = []

    /// Keys grow with the text up to the size terminal text stops at, so the
    /// largest accessibility sizes keep more than four keys on screen; a
    /// long press shows any key large (Large Content Viewer).
    private var keyHeight: CGFloat {
        let category = TerminalTextScale.capped(traitCollection.preferredContentSizeCategory)
        let font = UIFont.preferredFont(forTextStyle: .callout, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
        return max(44, font.lineHeight + 12)
    }

    var enableInputClicksWhenVisible: Bool { true }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: keyHeight + 8) }

    init(terminal: RemoteNativeTerminalView.TerminalInputView) {
        self.terminal = terminal
        super.init(frame: CGRect(x: 0, y: 0, width: 360, height: 52), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = true
        // The scrolling keys take whatever width the bar's keys leave.
        let row = UIStackView(arrangedSubviews: [scroll, barKeys])
        row.axis = .horizontal
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        barKeys.axis = .horizontal
        barKeys.alignment = .center
        barKeys.spacing = 6
        barKeys.isLayoutMarginsRelativeArrangement = true
        barKeys.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 6)
        barKeys.setContentHuggingPriority(.required, for: .horizontal)
        barKeys.setContentCompressionResistancePriority(.required, for: .horizontal)
        configureHideKeyboard()
        keys.axis = .horizontal
        // With Hide Keyboard pinned at the end, Esc, Ctrl, Tab and the
        // arrows still fit a 402 pt iPhone (MobileTerminalInputTests).
        keys.spacing = 5
        keys.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(keys)
        let height = keys.heightAnchor.constraint(equalToConstant: keyHeight)
        keyHeightConstraint = height
        NSLayoutConstraint.activate([
            keys.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 6),
            keys.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
            keys.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 4),
            keys.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -4),
            height
        ])
        configure(control, key: .control) { [weak self, weak terminal] in
            guard let terminal, terminal.acceptsInput else { return }
            terminal.controlModifier.toggle()
            UISelectionFeedbackGenerator().selectionChanged()
            self?.updateControl()
        }
        addInteraction(UILargeContentViewerInteraction())
        rebuildKeys()
        NotificationCenter.default.addObserver(self, selector: #selector(updateControl),
                                              name: .terminalViewControlModifierReset, object: terminal)
        NotificationCenter.default.addObserver(self, selector: #selector(updateMetrics),
                                              name: UIContentSizeCategory.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildKeys),
                                              name: UserDefaults.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applyOutline),
                                              name: UIAccessibility.darkerSystemColorsStatusDidChangeNotification, object: nil)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (row: MobileTerminalAccessory, _: UITraitCollection) in
            row.applyOutline()
        }
        frame.size.height = keyHeight + 8
        updateControl()
    }

    /// With Increase Contrast every key gets the shared outline
    /// (`WitermTheme.outline`), so its shape reaches 3:1 on the keyboard.
    @objc private func applyOutline() {
        let outlined = UIAccessibility.isDarkerSystemColorsEnabled
        let color = UIColor.label.withAlphaComponent(0.45).resolvedColor(with: traitCollection).cgColor
        for key in keys.arrangedSubviews + [hideKeyboard] {
            key.layer.borderWidth = outlined ? 1 : 0
            key.layer.borderColor = color
            key.layer.cornerRadius = 8
            key.layer.cornerCurve = .continuous
        }
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateMetrics()
        terminal?.keyRowMoved?()
    }

    /// The terminal measures the keyboard's space from where this row is,
    /// which is how it learns of a rotation with only the key row up.
    override func layoutSubviews() {
        super.layoutSubviews()
        terminal?.keyRowMoved?()
    }

    /// Follows the saved key row; a changed setting applies to open terminals.
    /// The Snippets key appears once there is a snippet to insert, rather
    /// than offering an empty menu.
    @objc private func rebuildKeys() {
        let hasSnippets = !CommandSnippets.load().isEmpty
        let wanted = MobileKey.decode(UserDefaults.standard.string(forKey: MobileKey.key) ?? "")
            .filter { $0 != .snippets || hasSnippets }
        guard wanted != shown else { return }
        shown = wanted
        keys.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for key in wanted {
            keys.addArrangedSubview(key == .control ? control : key == .paste ? pasteControl() : button(for: key))
        }
        applyOutline()
    }

    /// The system Paste control: pasting from it counts as the person's own
    /// choice, so iOS doesn't ask "Allow Paste?" each time, and it is
    /// enabled only when there's text to paste.
    private func pasteControl() -> UIView {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .labelOnly
        configuration.cornerStyle = .fixed
        configuration.cornerRadius = 8
        configuration.baseBackgroundColor = .tertiarySystemFill
        configuration.baseForegroundColor = .label
        let paste = UIPasteControl(configuration: configuration)
        paste.target = terminal
        paste.accessibilityIdentifier = MobileKey.paste.identifier
        paste.showsLargeContentViewer = true
        paste.largeContentTitle = MobileKey.paste.face
        paste.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        paste.setContentHuggingPriority(.required, for: .horizontal)
        paste.setContentCompressionResistancePriority(.required, for: .horizontal)
        return paste
    }

    private func button(for key: MobileKey) -> UIButton {
        let button = UIButton(type: .system)
        switch key {
        case .snippets:
            configure(button, key: key, action: nil)
            button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.snippetActions() ?? [])
            }])
            button.showsMenuAsPrimaryAction = true
        default:
            if key.repeats {
                configure(button, key: key, action: nil)
                addRepeat(to: button, key: key)
            } else {
                configure(button, key: key) { [weak terminal] in
                    guard let terminal else { return }
                    Self.press(key, on: terminal)
                }
            }
        }
        return button
    }

    /// Holding a repeating key sends it after a pause, then steadily; a short
    /// tap sends it once on touch-up. A cancelled touch (such as scrolling
    /// the row) never sends anything.
    private func addRepeat(to button: UIButton, key: MobileKey) {
        let state = KeyRepeat()
        button.addAction(UIAction { [weak terminal] _ in
            state.start { [weak terminal] in
                guard let terminal, terminal.acceptsInput, terminal.window != nil else { return false }
                Self.press(key, on: terminal)
                return true
            }
        }, for: .touchDown)
        button.addAction(UIAction { _ in state.stop() }, for: [.touchUpOutside, .touchCancel, .touchDragExit])
        button.addAction(UIAction { [weak terminal] _ in
            guard !state.stop(), let terminal else { return }
            Self.press(key, on: terminal)
        }, for: .touchUpInside)
    }

    private static func press(_ key: MobileKey, on terminal: RemoteNativeTerminalView.TerminalInputView) {
        UIDevice.current.playInputClick()
        let application = terminal.getTerminal().applicationCursor
        func cursor(_ code: String) -> [UInt8] { Array(((application ? "\u{1b}O" : "\u{1b}[") + code).utf8) }
        switch key {
        case .escape: terminal.sendAccessory([0x1b])
        case .tab: terminal.sendAccessory([0x09])
        case .interrupt: terminal.sendAccessory([0x03])
        case .paste: terminal.paste(nil)
        case .left: terminal.sendAccessory(cursor("D"))
        case .down: terminal.sendAccessory(cursor("B"))
        case .up: terminal.sendAccessory(cursor("A"))
        case .right: terminal.sendAccessory(cursor("C"))
        // Home and End follow cursor-key mode like the arrows; paging keys do not.
        case .home: terminal.sendAccessory(cursor("H"))
        case .end: terminal.sendAccessory(cursor("F"))
        case .pageUp: terminal.sendAccessory(Array("\u{1b}[5~".utf8))
        case .pageDown: terminal.sendAccessory(Array("\u{1b}[6~".utf8))
        case .bar, .tilde, .slash, .hyphen: terminal.sendAccessory(Array(key.face.utf8))
        case .control, .snippets: break
        }
    }

    private func snippetActions() -> [UIMenuElement] {
        let snippets = CommandSnippets.load()
        guard !snippets.isEmpty else {
            return [UIAction(title: String(localized: "No Snippets", bundle: .main),
                             subtitle: String(localized: "Add them in Settings → Snippets.", bundle: .main),
                             attributes: .disabled) { _ in }]
        }
        return snippets.map { snippet in
            UIAction(title: snippet.name, subtitle: snippet.text.split(whereSeparator: \.isNewline).first.map(String.init),
                     attributes: terminal?.acceptsInput == true ? [] : .disabled) { [weak terminal] _ in
                terminal?.sendSnippet(snippet)
            }
        }
    }

    private func configureHideKeyboard() {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "keyboard.chevron.compact.down")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .callout)
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
        hideKeyboard.configuration = configuration
        let label = String(localized: "Hide Keyboard", bundle: .main)
        hideKeyboard.accessibilityLabel = label
        hideKeyboard.accessibilityIdentifier = "terminalKey-hideKeyboard"
        hideKeyboard.showsLargeContentViewer = true
        hideKeyboard.largeContentTitle = label
        hideKeyboard.largeContentImage = UIImage(systemName: "keyboard.chevron.compact.down")
        hideKeyboard.backgroundColor = .tertiarySystemFill
        hideKeyboard.layer.cornerRadius = 8
        hideKeyboard.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        hideKeyboard.setContentHuggingPriority(.required, for: .horizontal)
        hideKeyboard.addAction(UIAction { [weak self] _ in
            guard let terminal = self?.terminal, terminal.isFirstResponder else { return }
            _ = terminal.resignFirstResponder()
        }, for: .touchUpInside)
        barKeys.addArrangedSubview(hideKeyboard)
        let height = hideKeyboard.heightAnchor.constraint(equalToConstant: keyHeight)
        height.isActive = true
        barKeyHeights.append(height)
    }

    /// Shows the bar's keys with `actions` as the menu, or hides them. The
    /// menu is hosted once per key row (one per terminal view) and keeps its
    /// first content, which reads what changes (such as typing or watching)
    /// as it opens, so SwiftUI's updates don't rebuild it each time.
    func setBarActions(_ actions: AnyView?) {
        guard let actions else {
            if barActions?.view.isHidden == false { barActions?.view.isHidden = true }
            return
        }
        if barActions == nil {
            let host = UIHostingController(rootView: actions)
            host.sizingOptions = .intrinsicContentSize
            host.view.backgroundColor = .clear
            host.view.setContentHuggingPriority(.required, for: .horizontal)
            host.view.setContentCompressionResistancePriority(.required, for: .horizontal)
            barKeys.addArrangedSubview(host.view)
            let height = host.view.heightAnchor.constraint(equalToConstant: keyHeight)
            height.isActive = true
            barKeyHeights.append(height)
            barActions = host
        }
        if barActions?.view.isHidden == true { barActions?.view.isHidden = false }
    }

    @objc private func updateMetrics() {
        barKeyHeights.forEach { $0.constant = keyHeight }
        guard let constraint = keyHeightConstraint, constraint.constant != keyHeight else { return }
        constraint.constant = keyHeight
        frame.size.height = keyHeight + 8
        invalidateIntrinsicContentSize()
        if terminal?.isFirstResponder == true { terminal?.reloadInputViews() }
    }

    @objc func updateControl() {
        let selected = terminal?.controlModifier == true
        control.isSelected = selected
        control.backgroundColor = selected ? .label : .tertiarySystemFill
        var configuration = control.configuration
        configuration?.baseForegroundColor = selected ? .systemBackground : .label
        control.configuration = configuration
        control.accessibilityValue = selected ? String(localized: "Next Key", bundle: .main) : String(localized: "Off", bundle: .main)
        control.accessibilityTraits = selected ? [.button, .selected] : .button
    }

    private func configure(_ button: UIButton, key: MobileKey, action: (() -> Void)?) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = key.face
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
        button.configuration = configuration
        button.titleLabel?.font = .preferredFont(forTextStyle: .callout)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.accessibilityLabel = key.label
        button.accessibilityUserInputLabels = key.inputLabels
        button.accessibilityIdentifier = key.identifier
        button.showsLargeContentViewer = true
        button.largeContentTitle = key.face
        button.backgroundColor = .tertiarySystemFill
        button.tintColor = .label
        button.layer.cornerRadius = 8
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        // Keys keep their own width. Without this the row's scroll content
        // had no width of its own, and every key stretched to the same 69 pt,
        // so only five keys fit an iPhone instead of Esc, Ctrl, Tab and arrows.
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        if let action { button.addAction(UIAction { _ in action() }, for: .touchUpInside) }
    }
}

/// The terminal's actions menu as the key row's last key, while the
/// navigation bar that usually holds it is hidden for typing.
struct TerminalKeyRowActions<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color(uiColor: .label))
                .frame(minWidth: 44, maxHeight: .infinity)
                .padding(.horizontal, 4)
                .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 8, style: .continuous))
                .overlay {
                    // The other keys' outline with Increase Contrast.
                    if contrast == .increased {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color(uiColor: .label).opacity(0.45), lineWidth: 1)
                    }
                }
                .contentShape(.rect(cornerRadius: 8, style: .continuous))
        }
        .accessibilityLabel(String(localized: "Terminal Actions", bundle: .main))
        .accessibilityIdentifier("terminalKey-actions")
    }
}

/// The timers behind one held key.
@MainActor private final class KeyRepeat {
    private var timer: Timer?
    private var repeated = false

    func start(_ send: @escaping @MainActor () -> Bool) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if send() { self.repeated = true } else { self.stop() }
                    }
                }
            }
        }
    }

    /// Ends the hold and reports whether it sent any key.
    @discardableResult func stop() -> Bool {
        timer?.invalidate()
        timer = nil
        defer { repeated = false }
        return repeated
    }
}

struct TerminalPasteReview: View {
    let text: String
    let destination: String
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: WitermMetrics.Space.l) {
                    Text(destination).font(WitermType.cardTitle)
                    Text(String(localized: "Review the entire text before sending it to the terminal. Newlines may run commands.", bundle: .main))
                        .font(WitermType.rowDetail).foregroundStyle(WitermTheme.secondary)
                    Text(verbatim: text).font(WitermType.code)
                        .textSelection(.enabled).privacySensitive()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("terminalPastePreview")
                }.padding(WitermMetrics.pagePadding)
            }
            .navigationTitle(String(localized: "Review Multiline Paste", bundle: .main))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .main), action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Send Text", bundle: .main), action: confirm)
                        .accessibilityIdentifier("confirmTerminalPaste")
                }
            }
        }
    }
}
#endif
