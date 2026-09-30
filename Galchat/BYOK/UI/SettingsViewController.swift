import UIKit
import SnapKit
import Synapse

/// BYOK 配置页：三路 provider / baseURL / model / key，每路一个连通性测试。
final class SettingsViewController: UIViewController {
    private let config = GCConfig.shared
    private let judgeClient = JudgeClient()
    private let replyClient = ReplyClient()

    private let providerControl = UISegmentedControl(
        items: SynapseProvider.allCases.map(\.displayName)
    )
    private let judgeBase = ConfigFieldView(title: "判断接口地址", placeholder: "https://openrouter.ai/api")
    private let judgeModel = ConfigFieldView(title: "判断模型", placeholder: "typesafe/jev-1.13")
    private let judgeKey = ConfigFieldView(title: "判断接口 API Key", placeholder: "sk-...", isSecure: true)
    private let judgeEndpointLabel = makeFootnoteLabel("")
    private let judgeStatus = makeFootnoteLabel("")
    private let judgeTestButton = UIButton(configuration: .tinted())

    private let replyBase = ConfigFieldView(title: "回复接口地址", placeholder: GCConfig.Defaults.replyBaseURL)
    private let replyModel = ConfigFieldView(title: "回复模型", placeholder: GCConfig.Defaults.replyModel)
    private let replyKey = ConfigFieldView(title: "回复接口 API Key", placeholder: "sk-...", isSecure: true)
    private let replyEndpointLabel = makeFootnoteLabel("")
    private let replyStatus = makeFootnoteLabel("")
    private let replyTestButton = UIButton(configuration: .tinted())

    private let visionSwitch = UISwitch()
    private let visionBase = ConfigFieldView(title: "视觉接口地址", placeholder: GCConfig.Defaults.visionBaseURL)
    private let visionModel = ConfigFieldView(title: "视觉模型", placeholder: GCConfig.Defaults.visionModel)
    private let visionKey = ConfigFieldView(title: "视觉接口 API Key", placeholder: "sk-...", isSecure: true)
    private let visionFields = UIStackView()

    private let imageBase = ConfigFieldView(title: "图像接口地址", placeholder: GCConfig.Defaults.imageBaseURL)
    private let imageModel = ConfigFieldView(title: "图像模型", placeholder: GCConfig.Defaults.imageModel)
    private let imageKey = ConfigFieldView(title: "图像接口 API Key", placeholder: "sk-...", isSecure: true)
    private let autoAvatarSwitch = UISwitch()

    private let relationshipField = ConfigFieldView(title: "关系描述", placeholder: GCConfig.Defaults.relationship)
    private let contextRow = StepperRowView(
        title: "分析上下文条数", range: GCConfig.Defaults.contextMessageRange,
        format: { "\($0) 条" },
        note: { "每次分析把长图里最新的 \($0) 条聊天（不含时间分隔线）发给判断和回复模型。条数越多理解越完整，token 消耗也越多。" }
    )
    private let ladderRow = StepperRowView(
        title: "长截图保留张数", range: GCConfig.Defaults.ladderCapacityRange,
        format: { "\($0) 张" },
        note: { "实时拼接时保留最近 \($0) 张不重复的画面，超出后最早的一端移出长图（文字记录仍保留）。每张约 100 KB，只存在内存里。" }
    )

    private var runningTests = Set<APIRoute>()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "BYOK 设置"
        view.backgroundColor = .systemBackground
        view.tintColor = .galchatPink
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
            SynapseProvider.allCases.firstIndex(of: config.judge.provider) ?? 0
        judgeBase.text = config.judge.baseURL
        judgeModel.text = config.judge.model
        judgeKey.text = config.judge.apiKey
        replyBase.text = config.reply.baseURL
        replyModel.text = config.reply.model
        replyKey.text = config.reply.apiKey
        visionSwitch.isOn = config.visionEnabled
        visionBase.text = config.vision.baseURL
        visionModel.text = config.vision.model
        visionKey.text = config.vision.apiKey
        relationshipField.text = config.relationship
        contextRow.value = config.contextMessageCount
        ladderRow.value = config.ladderCapacity
        visionFields.isHidden = !config.visionEnabled
        imageBase.text = config.image.baseURL
        imageModel.text = config.image.model
        imageKey.text = config.image.apiKey
        autoAvatarSwitch.isOn = config.autoContactAvatar
    }

    private func saveConfig() {
        config.judge.save(baseURL: judgeBase.text, model: judgeModel.text, apiKey: judgeKey.text)
        config.reply.save(baseURL: replyBase.text, model: replyModel.text, apiKey: replyKey.text)
        config.vision.save(baseURL: visionBase.text, model: visionModel.text, apiKey: visionKey.text)
        judgeKey.text = config.judge.apiKey
        replyKey.text = config.reply.apiKey
        visionKey.text = config.vision.apiKey
        config.visionEnabled = visionSwitch.isOn
        config.image.save(baseURL: imageBase.text, model: imageModel.text, apiKey: imageKey.text)
        imageKey.text = config.image.apiKey
        config.autoContactAvatar = autoAvatarSwitch.isOn
        config.relationship = relationshipField.text
        if config.contextMessageCount != contextRow.value { config.contextMessageCount = contextRow.value }
        if config.ladderCapacity != ladderRow.value { config.ladderCapacity = ladderRow.value }
    }

    private func refreshEndpointLabels() {
        let provider = SynapseProvider.allCases[providerControl.selectedSegmentIndex]
        let judgeBaseURL = judgeBase.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let judgeURL = provider.decisionsEndpoint(
            baseURL: judgeBaseURL.isEmpty ? provider.defaultDecisionsBaseURL : judgeBaseURL
        )
        judgeEndpointLabel.text = judgeURL.isEmpty
            ? "实际请求地址：请填写完整地址"
            : "实际请求地址：\(judgeURL)"
        let replyBaseURL = replyBase.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let replyURL = SynapseProvider.chatEndpoint(
            baseURL: replyBaseURL.isEmpty ? GCConfig.Defaults.replyBaseURL : replyBaseURL
        )
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
                show(route, text: "\(route.displayName)测试失败：\(error.localizedDescription)", isError: true)
            }
        }
    }

    private func show(_ route: APIRoute, text: String, isError: Bool) {
        let label = route == .judge ? judgeStatus : replyStatus
        label.text = text
        label.textColor = isError ? .systemRed : .secondaryLabel
    }

    // MARK: - 布局

    private func autoAvatarRow() -> UIView {
        let row = UIStackView(arrangedSubviews: [makeSectionLabel("从聊天中自动提取头像"), UIView(), autoAvatarSwitch])
        row.alignment = .center
        row.spacing = 12
        return row
    }

    private func buildLayout() {
        providerControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let provider = SynapseProvider.allCases[providerControl.selectedSegmentIndex]
            config.judge.applyProvider(provider)
            judgeBase.text = config.judge.baseURL
            judgeModel.text = config.judge.model
            judgeKey.text = config.judge.apiKey
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
            makeFootnoteLabel("默认关闭。开启后会把聊天中的表情包（压缩后的小图）发往视觉模型，解读含义后用于判断和回复；关闭时只标记为“[表情包]”，不上传图片。"),
            visionFields,

            makeSectionLabel("立绘生成（可选）"),
            makeFootnoteLabel("在联系人详情里用头像生成立绘。生成时会把头像发送给此接口，费用由该服务收取。地址填到 /v1 为止。"),
            imageBase, imageModel, imageKey,

            autoAvatarRow(),
            makeFootnoteLabel("只取单聊里对方的头像，至少在两条消息旁出现过才会保存，不会覆盖你手动选择的头像。"),

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
        stack.setCustomSpacing(24, after: imageKey)
        stack.setCustomSpacing(24, after: contextRow)
        stack.setCustomSpacing(24, after: ladderRow)

        let scrollView = UIScrollView()
        scrollView.keyboardDismissMode = .interactive
        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        scrollView.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top)
            make.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
            make.leading.trailing.equalToSuperview()
        }
        stack.snp.makeConstraints { make in
            make.top.equalTo(scrollView.contentLayoutGuide).offset(20)
            make.bottom.equalTo(scrollView.contentLayoutGuide).offset(-32)
            make.leading.trailing.equalTo(scrollView.contentLayoutGuide).inset(20)
            make.width.equalTo(scrollView.frameLayoutGuide).offset(-40)
        }
    }
}
