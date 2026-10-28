#if os(iOS)
import SwiftUI
import UIKit

extension View {
    /// Swiping in from the leading edge goes back, like a navigation stack's
    /// back gesture, on screens that switch their content in place (so a
    /// live terminal can finish releasing control before it goes away).
    /// The content follows the finger; the action runs once the swipe passes
    /// a third of the width or ends quickly. VoiceOver's escape gesture does
    /// the same.
    func edgeSwipeBack(enabled: Bool = true, action: @escaping () -> Void) -> some View {
        modifier(EdgeSwipeBack(enabled: enabled, action: action))
    }
}

private struct EdgeSwipeBack: ViewModifier {
    let enabled: Bool
    let action: () -> Void
    @State private var offset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background {
                EdgeSwipeInstaller(enabled: enabled) { translation in
                    if !reduceMotion { offset = max(0, translation) }
                } ended: { commit, width in
                    guard commit else {
                        withAnimation(.snappy(duration: 0.2)) { offset = 0 }
                        return
                    }
                    if reduceMotion {
                        action()
                        return
                    }
                    withAnimation(.easeOut(duration: 0.18)) { offset = width } completion: {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            action()
                            offset = 0
                        }
                    }
                }
            }
            .accessibilityAction(.escape) { if enabled { action() } }
    }
}

/// Installs a screen-edge pan on the window while this view is in it, and
/// removes it when the view leaves (such as on another tab).
private struct EdgeSwipeInstaller: UIViewRepresentable {
    let enabled: Bool
    let changed: (CGFloat) -> Void
    let ended: (_ commit: Bool, _ width: CGFloat) -> Void

    func makeUIView(context: Context) -> InstallerView { InstallerView() }

    func updateUIView(_ view: InstallerView, context: Context) {
        view.enabled = enabled
        view.changed = changed
        view.ended = ended
    }

    final class InstallerView: UIView {
        var enabled = true
        var changed: (CGFloat) -> Void = { _ in }
        var ended: (Bool, CGFloat) -> Void = { _, _ in }
        private var gesture: UIScreenEdgePanGestureRecognizer?
        private lazy var delegate = Delegate(owner: self)

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { nil }

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            if let gesture { gesture.view?.removeGestureRecognizer(gesture) }
            gesture = nil
            guard let newWindow else { return }
            let pan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(pan(_:)))
            pan.edges = effectiveUserInterfaceLayoutDirection == .rightToLeft ? .right : .left
            pan.delegate = delegate
            newWindow.addGestureRecognizer(pan)
            gesture = pan
        }

        private var leadingSign: CGFloat { effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1 }

        @objc private func pan(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            let width = max(1, recognizer.view?.bounds.width ?? bounds.width)
            let translation = recognizer.translation(in: recognizer.view).x * leadingSign
            switch recognizer.state {
            case .changed: changed(translation)
            case .ended:
                let velocity = recognizer.velocity(in: recognizer.view).x * leadingSign
                ended(translation > width / 3 || velocity > 600, width * leadingSign)
            case .cancelled, .failed: ended(false, width)
            default: break
            }
        }

        fileprivate var canBegin: Bool { enabled && window != nil && !isHiddenInHierarchy }

        /// Gestures in the content (such as a terminal's scrolling and
        /// selection) wait for an edge swipe to fail, which happens at once
        /// for touches away from the edge.
        fileprivate func outranks(_ other: UIGestureRecognizer) -> Bool {
            guard let host = owningController?.view, let view = other.view else { return false }
            return view.isDescendant(of: host)
        }

        /// The controller hosting this screen; SwiftUI places this view as a
        /// background, not as an ancestor of the content.
        private var owningController: UIViewController? {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController { return controller }
                responder = current.next
            }
            return nil
        }

        private var isHiddenInHierarchy: Bool {
            var view: UIView? = self
            while let current = view {
                if current.isHidden || current.alpha == 0 { return true }
                view = current.superview
            }
            return false
        }
    }
}
/// A separate delegate: UIView already has its own `gestureRecognizerShouldBegin`.
private final class Delegate: NSObject, UIGestureRecognizerDelegate {
    weak var owner: EdgeSwipeInstaller.InstallerView?

    init(owner: EdgeSwipeInstaller.InstallerView) { self.owner = owner }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool { owner?.canBegin ?? false }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        owner?.outranks(other) ?? false
    }
}
#endif
