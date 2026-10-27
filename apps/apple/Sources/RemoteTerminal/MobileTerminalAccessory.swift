#if os(iOS)
import SwiftUI
import SwiftTerm
import UIKit

/// One accessible row shared by direct SSH and paired terminals. Actions are
/// committed on touch-up so scrolling the row never sends a key by accident.
@MainActor final class MobileTerminalAccessory: UIInputView {
    private weak var terminal: RemoteNativeTerminalView.TerminalInputView?
    private let control = UIButton(type: .system)
    private var keyHeightConstraint: NSLayoutConstraint?

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
        let keys = UIStackView()
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
        keys.addArrangedSubview(button("Esc", label: String(localized: "Escape", bundle: .main)) { [weak terminal] in terminal?.sendAccessory([0x1b]) })
        configure(control, title: "Ctrl", label: String(localized: "Control for Next Key", bundle: .main)) { [weak self, weak terminal] in
            guard let terminal, terminal.acceptsInput else { return }
            terminal.controlModifier.toggle()
            self?.updateControl()
        }
        control.accessibilityIdentifier = "terminalControlModifier"
        keys.addArrangedSubview(control)
        keys.addArrangedSubview(button("Tab", label: String(localized: "Tab", bundle: .main)) { [weak terminal] in terminal?.sendAccessory([0x09]) })
        let interrupt = button("Ctrl+C", label: String(localized: "Interrupt (Control-C)", bundle: .main)) { [weak terminal] in terminal?.sendAccessory([0x03]) }
        interrupt.accessibilityIdentifier = "terminalInterrupt"
        keys.addArrangedSubview(interrupt)
        keys.addArrangedSubview(button(String(localized: "Paste", bundle: .main), label: String(localized: "Paste", bundle: .main)) { [weak terminal] in terminal?.paste(nil) })
        for (title, label, code) in [("←", String(localized: "Left Arrow", bundle: .main), "D"),
                                      ("↓", String(localized: "Down Arrow", bundle: .main), "B"),
                                      ("↑", String(localized: "Up Arrow", bundle: .main), "A"),
                                      ("→", String(localized: "Right Arrow", bundle: .main), "C")] {
            keys.addArrangedSubview(button(title, label: label) { [weak terminal] in
                guard let terminal else { return }
                let prefix = terminal.getTerminal().applicationCursor ? "\u{1b}O" : "\u{1b}["
                terminal.sendAccessory(Array((prefix + code).utf8))
            })
        }
        NotificationCenter.default.addObserver(self, selector: #selector(updateControl),
                                              name: .terminalViewControlModifierReset, object: terminal)
        NotificationCenter.default.addObserver(self, selector: #selector(updateMetrics),
                                              name: UIContentSizeCategory.didChangeNotification, object: nil)
        frame.size.height = keyHeight + 8
        updateControl()
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateMetrics()
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

    private func button(_ title: String, label: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        configure(button, title: title, label: label, action: action)
        return button
    }

    private func configure(_ button: UIButton, title: String, label: String, action: @escaping () -> Void) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
        button.configuration = configuration
        button.titleLabel?.font = .preferredFont(forTextStyle: .callout)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.accessibilityLabel = label
        button.backgroundColor = .tertiarySystemFill
        button.tintColor = .label
        button.layer.cornerRadius = 8
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
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
