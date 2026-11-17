import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        VVObserveKeyboardHandoff()
        SeedKeychain.importDevelopmentConfiguration()
        return true
    }
}
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let keyboardReturn = KeyboardReturnCoordinator()
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let home = MainSettingsViewController()
        let navigation = UINavigationController(rootViewController: home)
        navigation.navigationBar.prefersLargeTitles = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--keyboard-test") {
            navigation.setViewControllers([home, KeyboardTestViewController()], animated: false)
        }
        #endif
        window.rootViewController = navigation
        window.makeKeyAndVisible(); self.window = window
        activateVoice(from: connectionOptions.urlContexts)
    }
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        activateVoice(from: URLContexts)
    }
    private func activateVoice(from contexts: Set<UIOpenURLContext>) {
        guard var request = VoiceIPC.read("activation.json", as: VoiceActivationRequest.self),
              let context = contexts.first(where: { request.accepts($0.url) }) else { return }
        VoiceIPC.remove("activation.json")
        if request.returnDestination == nil {
            request.returnBundleIdentifier = context.options.sourceApplication
        }
        guard let scene = window?.windowScene else { return }
        keyboardReturn.activate(request, in: scene)
    }
    func sceneDidBecomeActive(_ scene: UIScene) {
        // Opening the app, including a keyboard handoff, prepares voice input.
        // enable() coalesces duplicate requests and waits for microphone permission.
        VoiceHost.shared.enable()
    }
    func sceneDidEnterBackground(_ scene: UIScene) { keyboardReturn.cancel() }
}
