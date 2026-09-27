import UIKit
import VisynTransport

final class MainTabBarController: UITabBarController, UITabBarControllerDelegate, UINavigationControllerDelegate {
    enum Tab: Int {
        case recents = 0, contacts = 1, persona = 3, settings = 4
    }

    private let quickStartButton = UIButton(configuration: .filled())
    private let captureSession = CaptureSessionController.shared
    private var captureObserver: UUID?
    private var lastObservedCaptureError: String?
    private var pendingCaptureError: String?
    private var isErrorPresentationScheduled = false
    private var isNavigationTransitioning = false

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        view.backgroundColor = .systemBackground
        view.tintColor = .galchatPink
        if #available(iOS 17.0, *) {
            traitOverrides.horizontalSizeClass = .compact
        }
        if #available(iOS 18.0, *) { mode = .tabBar }
        let quickStart = UIViewController()
        quickStart.tabBarItem = UITabBarItem(title: nil, image: nil, tag: 2)
        quickStart.tabBarItem.isAccessibilityElement = false
        viewControllers = [
            navigation(for: RecentsViewController(), tab: .recents, title: "最近", image: "TabBarRecent"),
            navigation(for: ContactsViewController(), tab: .contacts, title: "联系", image: "TabBarContacts"),
            quickStart,
            navigation(for: PersonaViewController(), tab: .persona, title: "人格", image: "TabBarPersona"),
            navigation(for: AppSettingsViewController(), tab: .settings, title: "设置", image: "TabBarSettings")
        ]
        configureAppearance()
        configureQuickStart()
        captureObserver = captureSession.observe { [weak self] in self?.captureSessionDidChange() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(presentPendingCaptureError),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        captureSession.attachHost(view)
        if !isNavigationTransitioning { synchronizeQuickStartButton() }
        scheduleCaptureErrorPresentation()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !isNavigationTransitioning { layoutQuickStartButton() }
        view.bringSubviewToFront(quickStartButton)
    }

    private func layoutQuickStartButton() {
        // 放在容器中，突出 TabBar 的部分也拥有完整的公开 UIKit 点击区域。
        let barFrame = tabBar.convert(tabBar.bounds, to: view)
        let size: CGFloat = 60
        quickStartButton.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        quickStartButton.center = CGPoint(x: barFrame.midX, y: barFrame.minY - 25 + size / 2)
        quickStartButton.layer.cornerRadius = size / 2
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let captureObserver {
            MainActor.assumeIsolated { CaptureSessionController.shared.removeObserver(captureObserver) }
        }
    }

    func select(_ tab: Tab) {
        loadViewIfNeeded()
        view.endEditing(true)
        selectedIndex = tab.rawValue
        (selectedViewController as? UINavigationController)?.popToRootViewController(animated: false)
        synchronizeQuickStartButton()
        view.setNeedsLayout()
    }

    /// 从外部打开 `.personal` 人格文件：切到“人格”页，按“从文件导入”的流程确认后保存。
    func importPersonaFile(at url: URL) {
        select(.persona)
        let root = (selectedViewController as? UINavigationController)?.viewControllers.first
        (root as? PersonaViewController)?.importFile(at: url)
    }

    private func navigation(
        for root: UIViewController, tab: Tab, title: String, image: String
    ) -> UINavigationController {
        root.title = title
        root.navigationItem.backButtonDisplayMode = .minimal
        // 为中央按钮高出底栏的 25 点留出内容间距。
        root.additionalSafeAreaInsets.bottom = 29
        let navigation = UINavigationController(rootViewController: root)
        navigation.setNavigationBarHidden(true, animated: false)
        navigation.delegate = self
        // 同一矢量轮廓只切换颜色，选中前后保持相同尺寸和线宽。
        let icon = UIImage(named: image)?.withRenderingMode(.alwaysTemplate)
        navigation.tabBarItem = UITabBarItem(title: title, image: icon, selectedImage: icon)
        navigation.tabBarItem.tag = tab.rawValue
        navigation.tabBarItem.accessibilityIdentifier = "main.tab.\(tab)"
        return navigation
    }

    private func configureQuickStart() {
        quickStartButton.configuration?.image = UIImage(named: "TabBarQuick")?.withRenderingMode(.alwaysTemplate)
        quickStartButton.configuration?.preferredSymbolConfigurationForImage = nil
        quickStartButton.configuration?.baseBackgroundColor = .galchatPinkStrong
        quickStartButton.configuration?.baseForegroundColor = .white
        quickStartButton.configuration?.cornerStyle = .capsule
        quickStartButton.configuration?.contentInsets = .zero
        quickStartButton.layer.shadowColor = UIColor.black.cgColor
        quickStartButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        quickStartButton.layer.shadowOpacity = 0.2
        quickStartButton.layer.shadowRadius = 8
        quickStartButton.layer.masksToBounds = false
        quickStartButton.accessibilityIdentifier = "main.quickStart"
        quickStartButton.accessibilityLabel = "快速开启"
        quickStartButton.isExclusiveTouch = true
        quickStartButton.addTarget(self, action: #selector(quickStartTouchDown), for: [.touchDown, .touchDragEnter])
        quickStartButton.addTarget(self, action: #selector(quickStartTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        quickStartButton.addAction(UIAction { [weak self] _ in self?.quickStart() }, for: .touchUpInside)
        view.addSubview(quickStartButton)
        updateQuickStartState()
    }

    @objc private func quickStartTouchDown() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        UIView.animate(withDuration: 0.1, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.quickStartButton.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        }
    }

    @objc private func quickStartTouchUp() {
        guard !UIAccessibility.isReduceMotionEnabled else {
            quickStartButton.transform = .identity
            return
        }
        UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.6,
                       initialSpringVelocity: 0.8, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.quickStartButton.transform = .identity
        }
    }

    private func updateQuickStartState() {
        let active = captureSession.state != .stopped
        quickStartButton.configuration?.baseBackgroundColor = active
            ? .systemTeal : .galchatPinkStrong
        quickStartButton.accessibilityValue = active ? "录屏进行中" : "尚未录屏"
        quickStartButton.accessibilityHint = active ? "查看如何停止录屏" : "打开系统录屏确认面板，确认后开始识别"
    }

    private func synchronizeQuickStartButton() {
        let navigation = selectedViewController as? UINavigationController
        let hidden = navigation?.topViewController == nil
            || navigation?.topViewController?.hidesBottomBarWhenPushed == true
        quickStartButton.isHidden = hidden
        quickStartButton.alpha = hidden ? 0 : 1
        quickStartButton.isUserInteractionEnabled = !hidden && !isNavigationTransitioning
        layoutQuickStartButton()
    }

    private func captureSessionDidChange() {
        updateQuickStartState()
        let message = captureSession.errorMessage
        if message != lastObservedCaptureError {
            lastObservedCaptureError = message
            pendingCaptureError = message
        }
        scheduleCaptureErrorPresentation()
    }

    private func scheduleCaptureErrorPresentation() {
        guard pendingCaptureError != nil, !isErrorPresentationScheduled else { return }
        isErrorPresentationScheduled = true
        // 快启可能同步报错，等当前操作提交后再判断转场状态。
        DispatchQueue.main.async { [weak self] in
            self?.isErrorPresentationScheduled = false
            self?.presentPendingCaptureError()
        }
    }

    @objc private func presentPendingCaptureError() {
        let navigation = selectedViewController as? UINavigationController
        guard let message = pendingCaptureError,
              viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
              presentedViewController == nil, !isBeingPresented, !isBeingDismissed,
              transitionCoordinator == nil,
              navigation?.presentedViewController == nil,
              navigation?.topViewController?.presentedViewController == nil,
              navigation?.transitionCoordinator == nil,
              navigation?.topViewController?.transitionCoordinator == nil else { return }
        pendingCaptureError = nil
        let alert = UIAlertController(title: "录屏与画中画提示", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }

    private func quickStart() {
        guard !isNavigationTransitioning, presentedViewController == nil, view.window != nil else { return }
        view.endEditing(true)
        captureSession.attachHost(view)
        // 明确重试是新操作；相同错误可再次提醒，帧回调则不会重复弹出。
        lastObservedCaptureError = nil
        pendingCaptureError = nil
        UISelectionFeedbackGenerator().selectionChanged()
        if captureSession.quickStart() { showStopRecordingInstruction() }
        captureSessionDidChange()
    }

    private func showStopRecordingInstruction() {
        let alert = UIAlertController(
            title: "如何停止录屏？",
            message: "请点击屏幕顶部的【红色录屏指示】或【灵动岛中的录屏图标】，然后在系统提示中确认停止录屏。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }

    private func configureAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            layout.normal.iconColor = .secondaryLabel
            layout.normal.titleTextAttributes = [.foregroundColor: UIColor.secondaryLabel]
            layout.selected.iconColor = .galchatPink
            layout.selected.titleTextAttributes = [.foregroundColor: UIColor.galchatPink]
        }
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.tintColor = .galchatPink
        tabBar.unselectedItemTintColor = .secondaryLabel
        tabBar.itemPositioning = .fill
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        if viewController.tabBarItem.tag == 2 {
            quickStart()
            return false
        }
        view.endEditing(true)
        if selectedViewController === viewController,
           let navigation = viewController as? UINavigationController {
            navigation.popToRootViewController(animated: true)
        }
        return true
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        if !isNavigationTransitioning { synchronizeQuickStartButton() }
        view.setNeedsLayout()
        scheduleCaptureErrorPresentation()
    }

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        navigationController.setNavigationBarHidden(
            viewController === navigationController.viewControllers.first, animated: animated
        )
        guard navigationController === selectedViewController else { return }
        guard animated, let coordinator = navigationController.transitionCoordinator else {
            quickStartButton.isHidden = viewController.hidesBottomBarWhenPushed
            quickStartButton.alpha = viewController.hidesBottomBarWhenPushed ? 0 : 1
            quickStartButton.isUserInteractionEnabled = !viewController.hidesBottomBarWhenPushed
            return
        }

        let source = coordinator.viewController(forKey: .from)
        let sourceHidden = source?.hidesBottomBarWhenPushed == true
        let destinationHidden = viewController.hidesBottomBarWhenPushed
        isNavigationTransitioning = true
        quickStartButton.isHidden = sourceHidden && destinationHidden
        quickStartButton.alpha = sourceHidden ? 0 : 1
        quickStartButton.isUserInteractionEnabled = false

        // 独立按钮与系统底栏共用转场进度，包含侧滑返回及取消时的回退动画。
        let registered = coordinator.animate(alongsideTransition: { [weak self] _ in
            guard let self else { return }
            view.layoutIfNeeded()
            layoutQuickStartButton()
            quickStartButton.alpha = destinationHidden ? 0 : 1
        }, completion: { [weak self] _ in
            guard let self else { return }
            isNavigationTransitioning = false
            synchronizeQuickStartButton()
        })
        if !registered {
            isNavigationTransitioning = false
            synchronizeQuickStartButton()
        }
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        navigationController.setNavigationBarHidden(
            viewController === navigationController.viewControllers.first, animated: false
        )
        guard navigationController === selectedViewController else { return }
        isNavigationTransitioning = false
        synchronizeQuickStartButton()
        view.setNeedsLayout()
        scheduleCaptureErrorPresentation()
    }
}
