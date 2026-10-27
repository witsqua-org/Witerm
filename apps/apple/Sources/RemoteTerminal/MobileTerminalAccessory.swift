#if os(iOS)
import SwiftUI
import SwiftTerm
import UIKit

/// A key the mobile key row can show. The order and selection are kept in
/// this device's preferences and edited under Settings → Keyboard Row.
enum MobileKey: String, CaseIterable, Identifiable {
    case escape, control, tab, interrupt, paste, snippets, left, down, up, right
    case bar, tilde, slash, hyphen, home, end, pageUp, pageDown

    static let key = "witerm.mobileKeys"
    var id: String { rawValue }

    /// The order and keys stored under `key`; empty or unreadable means all keys.
    static func decode(_ raw: String) -> [MobileKey] {
        var seen = Set<MobileKey>()
        let keys = raw.split(separator: ",").compactMap { MobileKey(rawValue: String($0)) }.filter { seen.insert($0).inserted }
        return keys.isEmpty ? allCases : keys
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
@MainActor final class MobileTerminalAccessory: UIInputView {
    private weak var terminal: RemoteNativeTerminalView.TerminalInputView?
    private let control = UIButton(type: .system)
    private let keys = UIStackView()
    private var keyHeightConstraint: NSLayoutConstraint?
    private var shown: [MobileKey] = []

    private var keyHeight: CGFloat { max(44, UIFont.preferredFont(forTextStyle: .callout, compatibleWith: traitCollection).lineHeight + 12) }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: keyHeight + 8) }

    init(terminal: RemoteNativeTerminalView.TerminalInputView) {
        self.terminal = terminal
        super.init(frame: CGRect(x: 0, y: 0, width: 360, height: 52), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = true
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        keys.axis = .horizontal
        keys.spacing = 6
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
            self?.updateControl()
        }
        rebuildKeys()
        NotificationCenter.default.addObserver(self, selector: #selector(updateControl),
                                              name: .terminalViewControlModifierReset, object: terminal)
        NotificationCenter.default.addObserver(self, selector: #selector(updateMetrics),
                                              name: UIContentSizeCategory.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildKeys),
                                              name: UserDefaults.didChangeNotification, object: nil)
        frame.size.height = keyHeight + 8
        updateControl()
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateMetrics()
    }

    /// Follows the saved key row; a changed setting applies to open terminals.
    @objc private func rebuildKeys() {
        let wanted = MobileKey.decode(UserDefaults.standard.string(forKey: MobileKey.key) ?? "")
        guard wanted != shown else { return }
        shown = wanted
        keys.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for key in wanted { keys.addArrangedSubview(key == .control ? control : button(for: key)) }
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
            configure(button, key: key) { [weak terminal] in
                guard let terminal else { return }
                Self.press(key, on: terminal)
            }
        }
        return button
    }

    private static func press(_ key: MobileKey, on terminal: RemoteNativeTerminalView.TerminalInputView) {
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

    @objc private func updateMetrics() {
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
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
        button.configuration = configuration
        button.titleLabel?.font = .preferredFont(forTextStyle: .callout)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.accessibilityLabel = key.label
        button.accessibilityIdentifier = key.identifier
        button.backgroundColor = .tertiarySystemFill
        button.tintColor = .label
        button.layer.cornerRadius = 8
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        if let action { button.addAction(UIAction { _ in action() }, for: .touchUpInside) }
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
                VStack(alignment: .leading, spacing: 16) {
                    Text(destination).font(.headline)
                    Text(String(localized: "Review the entire text before sending it to the terminal. Newlines may run commands.", bundle: .main))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(verbatim: text).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).privacySensitive()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("terminalPastePreview")
                }.padding()
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
