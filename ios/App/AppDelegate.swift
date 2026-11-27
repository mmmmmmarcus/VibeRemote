import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        try? VoiceConfiguration.migrateHostConfiguration()
        MobileConfiguration.sync.start()
        return true
    }
}
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var privacyCover: UIView?
    func sceneWillResignActive(_ scene: UIScene) { setPrivacyCovered(true) }
    func setPrivacyCovered(_ covered: Bool) {
        guard covered else { privacyCover?.removeFromSuperview(); privacyCover = nil; return }
        guard let window, privacyCover == nil else { return }
        let cover = UIView(frame: window.bounds)
        cover.backgroundColor = .systemBackground
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.accessibilityViewIsModal = true
        window.addSubview(cover); privacyCover = cover
    }
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let home = MainSettingsViewController()
        let navigation = UINavigationController(rootViewController: home)
        navigation.navigationBar.prefersLargeTitles = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--keyboard-test") || ProcessInfo.processInfo.arguments.contains("--verify-cursor") || ProcessInfo.processInfo.arguments.contains("--verify-haptics") || ProcessInfo.processInfo.arguments.contains("--verify-dictation") {
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
        // Legacy setup URLs remain accepted; microphone capture no longer lives here.
        VoiceIPC.remove("activation.json")
    }
    func sceneDidBecomeActive(_ scene: UIScene) {
        setPrivacyCovered(false)
        MobileConfiguration.sync.refresh()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--verify-cursor") || ProcessInfo.processInfo.arguments.contains("--verify-haptics") || ProcessInfo.processInfo.arguments.contains("--verify-dictation") { return }
        #endif
        // Setup grants permission and migrates settings, without activating audio.
        VoiceHost.shared.enable()
    }
}
