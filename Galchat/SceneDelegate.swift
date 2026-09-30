//
//  SceneDelegate.swift
//  Galchat
//
//  Created by gidon on 2026/9/22.
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    /// 引导未完成时打开的人格文件，等进入主界面后再导入。
    private var pendingPersonaURL: URL?


    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        self.window = window
        window.tintColor = .galchatPink
        ThemeStore.shared.applyToWindows()
        if OnbViewController.hasCompleted {
            window.rootViewController = MainTabBarController()
        } else {
            window.rootViewController = OnbViewController { [weak self] in
                self?.finishOnboarding()
            }
        }
        window.makeKeyAndVisible()
        openPersonaFile(from: connectionOptions.urlContexts)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        openPersonaFile(from: URLContexts)
    }

    /// 只接管 `.personal` 人格文件；其余 URL 保持原样不处理。
    private func openPersonaFile(from contexts: Set<UIOpenURLContext>) {
        guard let url = contexts.map(\.url).first(where: {
            $0.isFileURL && $0.pathExtension.lowercased() == PersonaPackage.fileExtension
        }) else { return }
        if let tabBar = window?.rootViewController as? MainTabBarController {
            tabBar.importPersonaFile(at: url)
        } else {
            pendingPersonaURL = url
        }
    }

    private func finishOnboarding() {
        guard let window, window.rootViewController is OnbViewController else { return }
        OnbViewController.markCompleted()
        UIView.transition(
            with: window,
            duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25,
            options: .transitionCrossDissolve,
            animations: { window.rootViewController = MainTabBarController() },
            completion: { [weak self] _ in
                guard let self, let url = self.pendingPersonaURL,
                      let tabBar = window.rootViewController as? MainTabBarController else { return }
                self.pendingPersonaURL = nil
                tabBar.importPersonaFile(at: url)
            }
        )
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Called as the scene is being released by the system.
        // This occurs shortly after the scene enters the background, or when its session is discarded.
        // Release any resources associated with this scene that can be re-created the next time the scene connects.
        // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // 每次回到前台（最多每 30 分钟一次）同步人格库：执行远程下架，并更新未改动的人格。
        if OnbViewController.hasCompleted {
            ResourceCatalog.shared.refreshIfNeeded()
        }
        // Called when the scene has moved from an inactive state to an active state.
        // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Called when the scene will move from an active state to an inactive state.
        // This may occur due to temporary interruptions (ex. an incoming phone call).
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Called as the scene transitions from the background to the foreground.
        // Use this method to undo the changes made on entering the background.
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Called as the scene transitions from the foreground to the background.
        // Use this method to save data, release shared resources, and store enough scene-specific state information
        // to restore the scene back to its current state.
    }


}
