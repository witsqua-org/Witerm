import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var runner: Runner?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let host = HostViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        let runner = Runner(host: host)
        self.runner = runner
        Task { @MainActor in await runner.run() }
    }
}

/// Holds the engine's view in the safe area. With no scenario arguments the
/// harness stays interactive: drag to scroll, pinch to zoom, long-press to
/// select a word.
final class HostViewController: UIViewController {
    var engine: TerminalEngine?
    private var pinchBase: CGFloat = 14

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
        view.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:))))
    }

    var terminalFrame: CGRect { view.bounds.inset(by: view.safeAreaInsets) }

    func install(_ engine: TerminalEngine) {
        self.engine?.view.removeFromSuperview()
        self.engine = engine
        view.addSubview(engine.view)
        engine.view.frame = terminalFrame
        engine.view.layoutIfNeeded()
        engine.didMoveToWindow()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let engine, engine.view.transform.isIdentity { engine.view.frame = terminalFrame }
    }

    /// Like Witerm: scale the drawn view while the fingers move, commit one
    /// font size when they lift.
    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        guard let engine else { return }
        switch pinch.state {
        case .began: pinchBase = engine.currentFontSize
        case .changed: engine.view.transform = CGAffineTransform(scaleX: pinch.scale, y: pinch.scale)
        case .ended, .cancelled:
            engine.view.transform = .identity
            engine.view.frame = terminalFrame
            engine.commitFont(size: min(32, max(11, (pinchBase * pinch.scale).rounded())))
        default: break
        }
    }

    @objc private func pressed(_ press: UILongPressGestureRecognizer) {
        guard press.state == .began, let engine else { return }
        let p = press.location(in: engine.view)
        let text = engine.selectWord(row: Int(p.y / engine.cellSize.height), col: Int(p.x / engine.cellSize.width))
        print("SELECTED \(text ?? "<none>")")
    }
}

extension TerminalEngine {
    var currentFontSize: CGFloat { (self as? FontReporting)?.fontSize ?? 14 }
}

@MainActor protocol FontReporting { var fontSize: CGFloat { get } }
