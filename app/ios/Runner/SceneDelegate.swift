// iOS 26 makes the scene lifecycle compulsory for apps built against the new
// SDK: without it the system kills the app at launch with
// _UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption.
//
// Flutter supplies the delegate; all this adds is the app's own wiring. With a
// scene the window belongs to the scene rather than to the app delegate, so
// everything that needs the Flutter messenger runs here, once, when the window
// actually exists.
import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
    override func scene(_ scene: UIScene,
                        willConnectTo session: UISceneSession,
                        options connectionOptions: UIScene.ConnectionOptions) {
        super.scene(scene, willConnectTo: session, options: connectionOptions)
        attachWhenReady(scene)
    }

    /// Flutter's view controller does not exist the instant the scene
    /// connects — the engine is still starting — and on a cold launch that can
    /// take seconds. Look everywhere a window might be, and keep looking for a
    /// good while, because giving up means the app runs with no native
    /// channels at all: no pendant, no health, no Scribe.
    private func attachWhenReady(_ scene: UIScene, attempt: Int = 0) {
        guard let delegate = UIApplication.shared.delegate as? AppDelegate else { return }
        if let controller = Self.findFlutterController(scene) {
            delegate.attachChannels(controller)
            NSLog("[Scene] native channels attached after \(attempt) tries")
            return
        }
        guard attempt < 300 else {   // 30 seconds
            NSLog("[Scene] ERROR: no FlutterViewController after \(attempt) tries; native channels are not attached")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.attachWhenReady(scene, attempt: attempt + 1)
        }
    }

    private static func findFlutterController(_ scene: UIScene?) -> FlutterViewController? {
        var windows: [UIWindow] = []
        if let ws = scene as? UIWindowScene { windows += ws.windows }
        for s in UIApplication.shared.connectedScenes {
            if let ws = s as? UIWindowScene { windows += ws.windows }
        }
        for w in windows {
            if let c = w.rootViewController as? FlutterViewController { return c }
            if let c = descend(w.rootViewController) { return c }
        }
        return nil
    }

    /// The Flutter controller is sometimes presented or wrapped rather than the root.
    private static func descend(_ vc: UIViewController?) -> FlutterViewController? {
        guard let vc else { return nil }
        if let c = vc as? FlutterViewController { return c }
        for child in vc.children {
            if let c = descend(child) { return c }
        }
        return descend(vc.presentedViewController)
    }
}
