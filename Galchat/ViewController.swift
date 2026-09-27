import UIKit
import VisynCapture
import VisynTransport

final class ViewController: UIViewController {
    private let captureSession = CaptureSessionController.shared
    private let statusLabel = UILabel()
    private let frameLabel = UILabel()
    private let errorLabel = UILabel()
    private let recordButton = UIButton(configuration: .filled())
    private let pipButton = UIButton(configuration: .tinted())
    private let analysisButton = UIButton(configuration: .tinted())
    private let liveButton = UIButton(configuration: .filled())
    private let liveStatusLabel = UILabel()
    private let pipSizeControls = PiPSizeControlsView()
    private let live = LiveChatCoordinator.shared
    private var liveObserver: UUID?
    private var captureObserver: UUID?
    private var displayedSize: CGSize?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "录屏与画中画"
        buildHome()
        liveObserver = live.observe { [weak self] in self?.renderLiveStatus() }
        captureObserver = captureSession.observe { [weak self] in self?.renderCaptureStatus() }
        renderLiveStatus()
        renderCaptureStatus()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let host = tabBarController?.view else { return }
        captureSession.attachHost(host)
        captureSession.prepareIfNeeded()
        renderCaptureStatus()
    }

    deinit {
        if let liveObserver {
            MainActor.assumeIsolated { LiveChatCoordinator.shared.removeObserver(liveObserver) }
        }
        if let captureObserver {
            MainActor.assumeIsolated { CaptureSessionController.shared.removeObserver(captureObserver) }
        }
    }

    private func renderLiveStatus() {
        let analysis = live.analysisLine
        liveStatusLabel.text = analysis.isEmpty ? live.statusLine : "\(live.statusLine)\n\(analysis)"
    }

    private func renderCaptureStatus() {
        statusLabel.text = captureSession.statusDescription
        frameLabel.text = captureSession.frameDescription
        recordButton.configuration?.title = captureSession.state == .stopped ? "开始录屏" : "停止录屏"
        pipButton.configuration?.title = captureSession.isPictureInPictureActive ? "关闭画中画" : "开启画中画"
        errorLabel.text = captureSession.errorMessage
        errorLabel.isHidden = captureSession.errorMessage == nil
        pipSizeControls.isEnabled = captureSession.isPrepared
        if displayedSize != captureSession.contentSize {
            displayedSize = captureSession.contentSize
            pipSizeControls.setAppliedSize(captureSession.contentSize)
        }
    }

    private func applyPictureInPictureRoute(_ route: VisynPictureInPictureRoute) {
        captureSession.applyRoute(route)
        pipSizeControls.setRoute(route)
        UIAccessibility.post(notification: .announcement,
                             argument: route == .videoCall ? "已选择通话式画中画，重新开启后生效。" : "已选择标准画中画。")
    }

    private func applyPictureInPictureContentSize(_ size: CGSize) {
        captureSession.applyContentSize(size)
        pipSizeControls.setAppliedSize(captureSession.contentSize)
        if let error = captureSession.errorMessage {
            UIAccessibility.post(notification: .announcement, argument: error)
        }
    }

    private func buildHome() {
        view.backgroundColor = .systemBackground
        view.tintColor = .galchatPink
        pipSizeControls.onApply = { [weak self] size in self?.applyPictureInPictureContentSize(size) }
        pipSizeControls.onRouteChange = { [weak self] route in self?.applyPictureInPictureRoute(route) }

        let subtitleLabel = UILabel()
        subtitleLabel.text = "调整画中画尺寸，管理当前录屏。日常使用可点底部“快速开启”。"
        subtitleLabel.font = .preferredFont(forTextStyle: .body)
        subtitleLabel.textColor = .secondaryLabel
        statusLabel.text = "准备就绪"
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        frameLabel.text = "等待屏幕数据"
        frameLabel.font = .preferredFont(forTextStyle: .subheadline)
        frameLabel.textColor = .secondaryLabel
        errorLabel.font = .preferredFont(forTextStyle: .footnote)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        recordButton.configuration?.title = "开始录屏"
        recordButton.configuration?.image = UIImage(systemName: "record.circle")
        recordButton.configuration?.baseBackgroundColor = .galchatPinkStrong
        recordButton.addAction(UIAction { [weak self] _ in
            self?.captureSession.showBroadcastPicker()
        }, for: .touchUpInside)
        pipButton.configuration?.title = "开启画中画"
        pipButton.configuration?.image = UIImage(systemName: "pip")
        pipButton.addAction(UIAction { [weak self] _ in
            self?.captureSession.togglePictureInPicture()
        }, for: .touchUpInside)
        liveButton.configuration?.title = "实时会话"
        liveButton.configuration?.image = UIImage(systemName: "text.bubble")
        liveButton.configuration?.baseBackgroundColor = .galchatPinkStrong
        liveButton.addAction(UIAction { [weak self] _ in
            self?.navigationController?.pushViewController(LiveSessionViewController(), animated: true)
        }, for: .touchUpInside)
        liveStatusLabel.font = .preferredFont(forTextStyle: .subheadline)
        liveStatusLabel.textColor = .secondaryLabel
        analysisButton.configuration?.title = "手动分析"
        analysisButton.configuration?.image = UIImage(systemName: "sparkles")
        analysisButton.addAction(UIAction { [weak self] _ in
            self?.navigationController?.pushViewController(AnalysisViewController(), animated: true)
        }, for: .touchUpInside)
        for button in [recordButton, pipButton, liveButton, analysisButton] {
            button.configuration?.imagePadding = 10
            button.configuration?.cornerStyle = .large
            button.configuration?.contentInsets = .init(top: 16, leading: 20, bottom: 16, trailing: 20)
        }
        let hintLabel = UILabel()
        hintLabel.text = "录屏的开始与停止都需要在系统面板中确认。录屏期间打开聊天窗口，Jarvis 会在本机识别文字、"
            + "随滚动自动拼接长截图，并在对方发来新消息时调用判断接口分析。画中画可在切换 App 后继续显示。"
        hintLabel.font = .preferredFont(forTextStyle: .footnote)
        hintLabel.textColor = .secondaryLabel
        for label in [subtitleLabel, statusLabel, frameLabel, liveStatusLabel, errorLabel, hintLabel] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }

        let scrollView = UIScrollView()
        scrollView.keyboardDismissMode = .interactive
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        let stack = UIStackView(arrangedSubviews: [
            subtitleLabel, statusLabel, frameLabel, liveStatusLabel,
            errorLabel, recordButton, pipButton, pipSizeControls, liveButton, analysisButton, hintLabel
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(36, after: subtitleLabel)
        stack.setCustomSpacing(8, after: statusLabel)
        stack.setCustomSpacing(8, after: frameLabel)
        stack.setCustomSpacing(28, after: liveStatusLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -28),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -48)
        ])
    }
}
