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

    /// The controller is normally there as soon as the scene connects, but the
    /// engine can take a beat on a cold start; retry briefly rather than lose
    /// every native channel for the life of the process.
    private func attachWhenReady(_ scene: UIScene, attempt: Int = 0) {
        guard let delegate = UIApplication.shared.delegate as? AppDelegate else { return }
        let controller = (self.window?.rootViewController as? FlutterViewController)
            ?? ((scene as? UIWindowScene)?.windows.first?.rootViewController as? FlutterViewController)
        if let controller {
            delegate.attachChannels(controller)
            NSLog("[Scene] native channels attached")
            return
        }
        guard attempt < 20 else {
            NSLog("[Scene] ERROR: no FlutterViewController after \(attempt) tries; native channels are not attached")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.attachWhenReady(scene, attempt: attempt + 1)
        }
    }
}
