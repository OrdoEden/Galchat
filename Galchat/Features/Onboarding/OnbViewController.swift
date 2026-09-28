import UIKit
import SnapKit

final class OnbViewController: UIViewController {
    private static let completionKey = "Galchat.onboarding.completed"

    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: completionKey)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completionKey)
    }

    private let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
    private let pageControl = UIPageControl()
    private let continueButton = UIButton(configuration: .filled())
    private let skipButton = UIButton(configuration: .plain())
    private var onFinish: (() -> Void)?
    private var currentIndex = 0
    private var isTransitioning = false
    private let pages = [
        OnbPageViewController(
            symbol: "bubble.left.and.bubble.right.fill",
            title: "欢迎使用 Galchat",
            message: "读懂聊天，找到更合适的回应。\n从屏幕识别到回复建议，让每次对话多一点从容。",
            detail: "先了解使用方式，再由你决定何时开始录屏或分析。"
        ),
        OnbPageViewController(
            symbol: "pip",
            title: "连接屏幕，随时查看",
            message: "点底部中央“快速开启”，确认系统录屏后，在画中画中查看识别和分析进展。",
            detail: "OCR 文字识别在设备本地进行。启动录屏需在系统面板确认；配置模型后，识别到的聊天文本可自动发送至所选服务进行分析。"
        ),
        OnbPageViewController(
            symbol: "text.bubble.fill",
            title: "记住对话，也记住你",
            message: "在“最近”查看并纠正聊天上下文，在“联系人”完善对方资料，在“人格”保存你的聊天风格与回复预设。",
            detail: "分析与生成回复会将聊天文本发送至你配置的模型服务。建议仅供参考，发送前请自行确认。"
        ),
        OnbPageViewController(
            symbol: "key.fill",
            title: "模型由你选择",
            message: "在设置中配置模型服务、接口地址和 API Key。视觉模型默认关闭，可按需配置。",
            detail: "使用 Galchat 键盘前，请在系统“设置 → 通用 → 键盘 → 键盘 → 添加新键盘”中启用，再通过地球键切换，选用已生成的回复。"
        )
    ]

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.tintColor = .galchatPink
        pager.dataSource = self
        pager.delegate = self
        addChild(pager)
        view.addSubview(pager.view)
        pager.didMove(toParent: self)
        pager.setViewControllers([pages[0]], direction: .forward, animated: false)

        pageControl.numberOfPages = pages.count
        pageControl.currentPageIndicatorTintColor = .galchatPink
        pageControl.pageIndicatorTintColor = .systemGray3
        pageControl.accessibilityLabel = "使用引导页码"
        pageControl.addTarget(self, action: #selector(pageSelected), for: .valueChanged)
        continueButton.configuration?.baseBackgroundColor = .galchatPinkStrong
        continueButton.configuration?.cornerStyle = .capsule
        continueButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 24, bottom: 16, trailing: 24)
        continueButton.titleLabel?.adjustsFontForContentSizeCategory = true
        continueButton.addTarget(self, action: #selector(continueTapped), for: .touchUpInside)
        skipButton.configuration?.title = "跳过"
        skipButton.titleLabel?.adjustsFontForContentSizeCategory = true
        skipButton.accessibilityHint = "结束使用引导"
        skipButton.addTarget(self, action: #selector(finish), for: .touchUpInside)

        let footer = UIStackView(arrangedSubviews: [pageControl, continueButton])
        footer.axis = .vertical
        footer.spacing = 12
        view.addSubview(footer)
        view.addSubview(skipButton)
        skipButton.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top).offset(4)
            make.trailing.equalTo(view.safeAreaLayoutGuide.snp.trailing).offset(-20)
            make.height.greaterThanOrEqualTo(44)
        }
        pager.view.snp.makeConstraints { make in
            make.top.equalTo(skipButton.snp.bottom)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide)
            make.bottom.equalTo(footer.snp.top).offset(-12)
        }
        footer.snp.makeConstraints { make in
            make.centerX.equalTo(view.safeAreaLayoutGuide)
            make.width.lessThanOrEqualTo(520)
            make.width.equalTo(view.safeAreaLayoutGuide).offset(-48).priority(.high)
            make.leading.greaterThanOrEqualTo(view.safeAreaLayoutGuide.snp.leading).offset(24)
            make.trailing.lessThanOrEqualTo(view.safeAreaLayoutGuide.snp.trailing).offset(-24)
            make.bottom.equalTo(view.safeAreaLayoutGuide.snp.bottom).offset(-16)
        }
        continueButton.snp.makeConstraints { make in
            make.height.greaterThanOrEqualTo(52)
        }
        updateControls()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.settlePage(announce: false)
        }
    }

    @objc private func continueTapped() {
        guard !isTransitioning, onFinish != nil else { return }
        if currentIndex == pages.count - 1 {
            finish()
        } else {
            showPage(currentIndex + 1)
        }
    }

    @objc private func pageSelected() {
        showPage(pageControl.currentPage)
    }

    @objc private func finish() {
        guard let completion = onFinish else { return }
        onFinish = nil
        pager.view.isUserInteractionEnabled = false
        updateControls()
        completion()
    }

    private func showPage(_ index: Int) {
        guard !isTransitioning, onFinish != nil, pages.indices.contains(index), index != currentIndex else {
            pageControl.currentPage = currentIndex
            return
        }
        isTransitioning = true
        updateControls()
        pager.view.isUserInteractionEnabled = false
        pager.setViewControllers(
            [pages[index]], direction: index > currentIndex ? .forward : .reverse,
            animated: !UIAccessibility.isReduceMotionEnabled
        ) { [weak self] _ in
            self?.settlePage(announce: true)
        }
    }

    private func settlePage(announce: Bool) {
        if let visible = pager.viewControllers?.first,
           let index = pages.firstIndex(where: { $0 === visible }) {
            currentIndex = index
        }
        isTransitioning = false
        pager.view.isUserInteractionEnabled = onFinish != nil
        updateControls()
        if announce, onFinish != nil, view.window != nil {
            UIAccessibility.post(notification: .screenChanged, argument: pages[currentIndex].headingLabel)
        }
    }

    private func updateControls() {
        pageControl.currentPage = currentIndex
        pageControl.accessibilityValue = "第 \(currentIndex + 1) 页，共 \(pages.count) 页"
        pageControl.isEnabled = !isTransitioning && onFinish != nil
        continueButton.isEnabled = !isTransitioning && onFinish != nil
        skipButton.isEnabled = onFinish != nil
        continueButton.configuration?.title = currentIndex == pages.count - 1 ? "开始使用" : "下一步"
        continueButton.accessibilityHint = currentIndex == pages.count - 1 ? "结束使用引导" : "显示下一页"
    }
}

extension OnbViewController: UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let index = pages.firstIndex(where: { $0 === viewController }), index > 0 else { return nil }
        return pages[index - 1]
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let index = pages.firstIndex(where: { $0 === viewController }), index + 1 < pages.count else { return nil }
        return pages[index + 1]
    }

    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        isTransitioning = true
        updateControls()
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        settlePage(announce: completed)
    }
}

private final class OnbPageViewController: UIViewController {
    let headingLabel = UILabel()
    private let symbol: String
    private let message: String
    private let detail: String

    init(symbol: String, title: String, message: String, detail: String) {
        self.symbol = symbol
        self.message = message
        self.detail = detail
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = false
        let content = UIView()
        let symbolView = UIImageView(image: UIImage(systemName: symbol))
        symbolView.contentMode = .scaleAspectFit
        symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 88, weight: .medium)
        symbolView.tintColor = .galchatPink
        symbolView.isAccessibilityElement = false
        headingLabel.text = title
        headingLabel.font = .preferredFont(forTextStyle: .largeTitle)
        headingLabel.accessibilityTraits.insert(.header)
        let messageLabel = UILabel()
        messageLabel.text = message
        messageLabel.font = .preferredFont(forTextStyle: .title3)
        let detailLabel = UILabel()
        detailLabel.text = detail
        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.textColor = .secondaryLabel
        [headingLabel, messageLabel, detailLabel].forEach {
            $0.numberOfLines = 0
            $0.textAlignment = .center
            $0.adjustsFontForContentSizeCategory = true
            $0.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        let stack = UIStackView(arrangedSubviews: [symbolView, headingLabel, messageLabel, detailLabel])
        stack.axis = .vertical
        stack.spacing = 24
        view.addSubview(scroll)
        scroll.addSubview(content)
        content.addSubview(stack)
        scroll.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        content.snp.makeConstraints { make in
            make.edges.equalTo(scroll.contentLayoutGuide)
            make.width.equalTo(scroll.frameLayoutGuide)
            make.height.greaterThanOrEqualTo(scroll.frameLayoutGuide)
            make.height.equalTo(scroll.frameLayoutGuide).priority(.low)
        }
        stack.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.top.greaterThanOrEqualToSuperview().offset(24)
            make.bottom.lessThanOrEqualToSuperview().offset(-24)
            make.width.lessThanOrEqualTo(520)
            make.width.equalToSuperview().offset(-56).priority(.high)
            make.leading.greaterThanOrEqualToSuperview().offset(28)
            make.trailing.lessThanOrEqualToSuperview().offset(-28)
        }
        symbolView.snp.makeConstraints { make in
            make.height.equalTo(120)
        }
    }
}
