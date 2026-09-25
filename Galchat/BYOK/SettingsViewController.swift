import UIKit

/// BYOK 配置页：三路 provider / baseURL / model / key，每路一个连通性测试。
final class SettingsViewController: UIViewController {
    private let config = JarvisConfig.shared
    private let judgeClient = JudgeClient()
    private let replyClient = ReplyClient()

    private let providerControl = UISegmentedControl(
        items: JudgeProvider.allCases.map(\.displayName)
    )
    private let judgeBase = ConfigFieldView(title: "判断接口地址", placeholder: "https://openrouter.ai/api")
    private let judgeModel = ConfigFieldView(title: "判断模型", placeholder: "typesafe/jev-1.13")
    private let judgeKey = ConfigFieldView(title: "判断接口 API Key", placeholder: "sk-...", isSecure: true)
    private let judgeEndpointLabel = makeFootnoteLabel("")
    private let judgeStatus = makeFootnoteLabel("")
    private let judgeTestButton = UIButton(configuration: .tinted())

    private let replyBase = ConfigFieldView(title: "回复接口地址", placeholder: JarvisConfig.Defaults.replyBaseURL)
    private let replyModel = ConfigFieldView(title: "回复模型", placeholder: JarvisConfig.Defaults.replyModel)
    private let replyKey = ConfigFieldView(title: "回复接口 API Key", placeholder: "sk-...", isSecure: true)
    private let replyEndpointLabel = makeFootnoteLabel("")
    private let replyStatus = makeFootnoteLabel("")
    private let replyTestButton = UIButton(configuration: .tinted())

    private let visionSwitch = UISwitch()
    private let visionBase = ConfigFieldView(title: "视觉接口地址", placeholder: JarvisConfig.Defaults.visionBaseURL)
    private let visionModel = ConfigFieldView(title: "视觉模型", placeholder: JarvisConfig.Defaults.visionModel)
    private let visionKey = ConfigFieldView(title: "视觉接口 API Key", placeholder: "sk-...", isSecure: true)
    private let visionFields = UIStackView()

    private let relationshipField = ConfigFieldView(title: "关系描述", placeholder: JarvisConfig.Defaults.relationship)
    private let contextRow = StepperRowView(
        title: "分析上下文条数", range: JarvisConfig.Defaults.contextMessageRange,
        format: { "\($0) 条" },
        note: { "每次分析把长图里最新的 \($0) 条聊天（不含时间分隔线）发给判断和回复模型。条数越多理解越完整，token 消耗也越多。" }
    )
    private let ladderRow = StepperRowView(
        title: "长截图保留张数", range: JarvisConfig.Defaults.ladderCapacityRange,
        format: { "\($0) 张" },
        note: { "实时拼接时保留最近 \($0) 张不重复的画面，超出后最早的一端移出长图（文字记录仍保留）。每张约 100 KB，只存在内存里。" }
    )

    private var runningTests = Set<APIRoute>()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "BYOK 设置"
        view.backgroundColor = .systemBackground
        view.tintColor = .systemIndigo
        buildLayout()
        loadConfig()
        refreshEndpointLabels()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveConfig()
    }

    // MARK: - 读写配置

    private func loadConfig() {
        providerControl.selectedSegmentIndex =
            JudgeProvider.allCases.firstIndex(of: config.judgeProvider) ?? 0
        judgeBase.text = config.judgeBaseURL
        judgeModel.text = config.judgeModel
        judgeKey.text = config.secrets.key(for: .judge)
        replyBase.text = config.replyBaseURL
        replyModel.text = config.replyModel
        replyKey.text = config.secrets.key(for: .reply)
        visionSwitch.isOn = config.visionEnabled
        visionBase.text = config.visionBaseURL
        visionModel.text = config.visionModel
        visionKey.text = config.secrets.key(for: .vision)
        relationshipField.text = config.relationship
        contextRow.value = config.contextMessageCount
        ladderRow.value = config.ladderCapacity
        visionFields.isHidden = !config.visionEnabled
    }

    private func saveConfig() {
        let previousJudgeKey = config.secrets.key(for: .judge)
        let previousReplyKey = config.secrets.key(for: .reply)
        let previousVisionKey = config.secrets.key(for: .vision)
        config.judgeBaseURL = judgeBase.text
        config.judgeModel = judgeModel.text
        clearInvalidatedKey(judgeKey, previous: previousJudgeKey, route: .judge)
        config.secrets.setKey(judgeKey.text, for: .judge)
        config.replyBaseURL = replyBase.text
        config.replyModel = replyModel.text
        clearInvalidatedKey(replyKey, previous: previousReplyKey, route: .reply)
        config.secrets.setKey(replyKey.text, for: .reply)
        config.visionEnabled = visionSwitch.isOn
        config.visionBaseURL = visionBase.text
        config.visionModel = visionModel.text
        clearInvalidatedKey(visionKey, previous: previousVisionKey, route: .vision)
        config.secrets.setKey(visionKey.text, for: .vision)
        config.relationship = relationshipField.text
        if config.contextMessageCount != contextRow.value { config.contextMessageCount = contextRow.value }
        if config.ladderCapacity != ladderRow.value { config.ladderCapacity = ladderRow.value }
    }

    /// 改服务地址后，不能把输入框里原服务的密钥自动保存回新服务。
    private func clearInvalidatedKey(_ field: ConfigFieldView, previous: String, route: APIRoute) {
        guard !previous.isEmpty, config.secrets.key(for: route).isEmpty,
              field.text.trimmingCharacters(in: .whitespacesAndNewlines) == previous else { return }
        field.text = ""
    }

    private func refreshEndpointLabels() {
        let provider = JudgeProvider.allCases[providerControl.selectedSegmentIndex]
        let judgeURL = provider.endpoint(baseURL: judgeBase.text)
        judgeEndpointLabel.text = judgeURL.isEmpty
            ? "实际请求地址：请填写完整地址"
            : "实际请求地址：\(judgeURL)"
        let replyURL = replyBase.text.isEmpty
            ? JarvisConfig.Defaults.replyBaseURL.trimmedTrailingSlash + "/chat/completions"
            : replyBase.text.trimmedTrailingSlash + "/chat/completions"
        replyEndpointLabel.text = "实际请求地址：\(replyURL)"
    }

    // MARK: - 连通性测试

    private func testJudge() {
        saveConfig()
        guard config.isConfigured(.judge) else {
            show(.judge, text: "请先填写接口地址、模型和 API Key", isError: true)
            return
        }
        runTest(.judge, button: judgeTestButton) { [self] in
            // 用一段固定的最小对话跑真实判断，验证的是完整协议而不只是鉴权。
            let snapshot = ChatSnapshot(messages: [
                ChatMessage(speaker: .other, text: "在吗？"),
                ChatMessage(speaker: .me, text: "在的"),
                ChatMessage(speaker: .other, text: "那你说说看")
            ])
            let analysis = try await judgeClient.judge(
                snapshot: snapshot,
                relationship: config.relationship
            )
            let intent = analysis.trueIntent?.choice ?? "未返回"
            return "连通成功 · 意图=\(intent) · \(analysis.latencyMs)ms"
        }
    }

    private func testReply() {
        saveConfig()
        guard config.isConfigured(.reply) else {
            show(.reply, text: "请先填写接口地址、模型和 API Key", isError: true)
            return
        }
        runTest(.reply, button: replyTestButton) { [self] in
            let answer = try await replyClient.ping()
            return "连通成功 · 模型回复：\(answer.prefix(20))"
        }
    }

    private func runTest(
        _ route: APIRoute,
        button: UIButton,
        work: @escaping () async throws -> String
    ) {
        guard !runningTests.contains(route) else { return }
        runningTests.insert(route)
        button.isEnabled = false
        button.configuration?.showsActivityIndicator = true
        show(route, text: "测试中…", isError: false)

        Task { [weak self] in
            let result: Result<String, Error>
            do {
                result = .success(try await work())
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            runningTests.remove(route)
            button.isEnabled = true
            button.configuration?.showsActivityIndicator = false
            switch result {
            case .success(let message):
                show(route, text: message, isError: false)
            case .failure(let error):
                show(route, text: error.localizedDescription, isError: true)
            }
        }
    }

    private func show(_ route: APIRoute, text: String, isError: Bool) {
        let label = route == .judge ? judgeStatus : replyStatus
        label.text = text
        label.textColor = isError ? .systemRed : .secondaryLabel
    }

    // MARK: - 布局

    private func buildLayout() {
        providerControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let provider = JudgeProvider.allCases[providerControl.selectedSegmentIndex]
            config.applyJudgeProvider(provider)
            judgeBase.text = config.judgeBaseURL
            judgeModel.text = config.judgeModel
            judgeKey.text = config.secrets.key(for: .judge)
            refreshEndpointLabels()
        }, for: .valueChanged)

        for field in [judgeBase, judgeModel, replyBase, replyModel] {
            field.textField.addAction(UIAction { [weak self] _ in
                self?.refreshEndpointLabels()
            }, for: .editingChanged)
        }

        judgeTestButton.configuration?.title = "测试判断接口"
        judgeTestButton.addAction(UIAction { [weak self] _ in self?.testJudge() }, for: .touchUpInside)
        replyTestButton.configuration?.title = "测试回复接口"
        replyTestButton.addAction(UIAction { [weak self] _ in self?.testReply() }, for: .touchUpInside)
        for button in [judgeTestButton, replyTestButton] {
            button.configuration?.cornerStyle = .large
            button.configuration?.contentInsets = .init(top: 12, leading: 16, bottom: 12, trailing: 16)
        }

        visionSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            visionFields.isHidden = !visionSwitch.isOn
        }, for: .valueChanged)
        let visionHeader = UIStackView(arrangedSubviews: [
            makeSectionLabel("视觉接口（可选）"), UIView(), visionSwitch
        ])
        visionHeader.alignment = .center
        visionHeader.spacing = 12
        visionFields.axis = .vertical
        visionFields.spacing = 14
        for field in [visionBase, visionModel, visionKey] {
            visionFields.addArrangedSubview(field)
        }

        relationshipField.textField.keyboardType = .default

        let stack = UIStackView(arrangedSubviews: [
            makeSectionLabel("判断接口（Jev）"),
            makeFootnoteLabel("排序复用同一路凭据，不需要第四套配置。"),
            providerControl,
            judgeBase, judgeModel, judgeKey,
            judgeEndpointLabel, judgeTestButton, judgeStatus,

            makeSectionLabel("回复接口（OpenAI 兼容）"),
            makeFootnoteLabel("地址填到 /v1 为止，程序会自动补 /chat/completions。"),
            replyBase, replyModel, replyKey,
            replyEndpointLabel, replyTestButton, replyStatus,

            visionHeader,
            makeFootnoteLabel("默认关闭。开启后才会把图片发往远端。"),
            visionFields,

            makeSectionLabel("分析上下文"),
            relationshipField,
            contextRow,

            makeSectionLabel("长截图"),
            ladderRow,

            makeFootnoteLabel("三路凭据互相独立，某一路留空不会去借用另一路的密钥。密钥保存在本机 UserDefaults，会随设备备份导出。")
        ])
        stack.axis = .vertical
        stack.spacing = 14
        stack.setCustomSpacing(24, after: replyStatus)
        stack.setCustomSpacing(24, after: judgeStatus)
        stack.setCustomSpacing(24, after: visionFields)
        stack.setCustomSpacing(24, after: contextRow)
        stack.setCustomSpacing(24, after: ladderRow)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = UIScrollView()
        scrollView.keyboardDismissMode = .interactive
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -32),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40)
        ])
    }
}
