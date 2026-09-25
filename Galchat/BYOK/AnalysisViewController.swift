import UIKit

/// 手动分析页：粘贴聊天文本 → Judge 判断 → Reply 生成 3 条 → Judge 排序。
///
/// 首版由用户明确触发一次分析，不做自动分析，避免没有新消息时重复计费。
final class AnalysisViewController: UIViewController {
    private let config = JarvisConfig.shared
    private let judgeClient = JudgeClient()
    private let replyClient = ReplyClient()

    private let chatInputView = UITextView()
    private let placeholderLabel = makeFootnoteLabel(
        "每行一条消息，用「我：」或「对方：」开头。\n例如：\n对方：你是不是又忘了\n我：没有\n对方：那你说说看"
    )
    private let runButton = UIButton(configuration: .filled())
    private let statusLabel = makeFootnoteLabel("")
    private let judgeResultLabel = UILabel()
    private let candidatesStack = UIStackView()

    private var currentTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "手动分析"
        view.backgroundColor = .systemBackground
        view.tintColor = .systemIndigo
        buildLayout()
    }

    deinit {
        currentTask?.cancel()
    }

    // MARK: - 分析链路

    private func runAnalysis() {
        view.endEditing(true)
        let snapshot = Self.parse(chatInputView.text)
        guard snapshot.messages.count >= 1 else {
            setStatus("请先粘贴至少一条聊天消息", isError: true)
            return
        }
        guard config.isConfigured(.judge), config.isConfigured(.reply) else {
            setStatus("判断接口和回复接口都需要先在设置里配置完整", isError: true)
            return
        }

        currentTask?.cancel()
        clearResults()
        setBusy(true)
        let models = AnalysisModelContext(config: config)

        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                setStatus("正在判断…", isError: false)
                let analysis = try await judgeClient.judge(
                    snapshot: snapshot,
                    relationship: models.relationship,
                    route: models.judge
                )
                try Task.checkCancellation()
                // 判断结果先落地：后面生成或排序失败时，这部分仍然可用。
                showJudge(analysis)

                setStatus("正在生成候选回复…", isError: false)
                let candidates = try await replyClient.draft(
                    snapshot: snapshot,
                    relationship: models.relationship,
                    route: models.reply
                )
                try Task.checkCancellation()

                setStatus("正在排序…", isError: false)
                let ranked = try await judgeClient.rank(
                    snapshot: snapshot,
                    relationship: models.relationship,
                    candidates: candidates,
                    route: models.judge
                )
                try Task.checkCancellation()
                showCandidates(ranked)
                setStatus("完成 · 判断耗时 \(analysis.latencyMs)ms", isError: false)
            } catch is CancellationError {
                setStatus("已取消", isError: false)
            } catch {
                setStatus(error.localizedDescription, isError: true)
            }
            setBusy(false)
        }
    }

    /// 解析「我：」「对方：」前缀。无法判断发言人的行标为 unknown，
    /// 不默认归成对方——整屏误判成对方消息会让判断结果完全跑偏。
    static func parse(_ raw: String) -> ChatSnapshot {
        let messages = raw
            .split(separator: "\n")
            .compactMap { line -> ChatMessage? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                for (prefixes, speaker) in Self.prefixes {
                    for prefix in prefixes where trimmed.hasPrefix(prefix) {
                        let text = String(trimmed.dropFirst(prefix.count))
                            .trimmingCharacters(in: .whitespaces)
                        return text.isEmpty ? nil : ChatMessage(speaker: speaker, text: text)
                    }
                }
                return ChatMessage(speaker: .unknown, text: trimmed)
            }
        return ChatSnapshot(messages: messages)
    }

    private static let prefixes: [([String], Speaker)] = [
        (["我：", "我:", "me:", "me："], .me),
        (["对方：", "对方:", "other:", "other："], .other)
    ]

    // MARK: - 结果展示

    private func showJudge(_ analysis: Analysis) {
        let lines = AnalysisPresentation.judgeLines(analysis)
        judgeResultLabel.text = lines.isEmpty ? "判断接口未返回可解析的结果" : lines.joined(separator: "\n")
        judgeResultLabel.isHidden = false
    }

    private func showCandidates(_ ranked: [RankedReply]) {
        AnalysisPresentation.fill(candidatesStack, with: ranked, unranked: false) { [weak self] _ in
            self?.setStatus("已复制，可切回聊天 App 粘贴", isError: false)
        }
        candidatesStack.isHidden = false
    }

    private func clearResults() {
        judgeResultLabel.isHidden = true
        candidatesStack.isHidden = true
        candidatesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    private func setBusy(_ busy: Bool) {
        runButton.isEnabled = !busy
        runButton.configuration?.showsActivityIndicator = busy
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusLabel.text = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabel
    }

    // MARK: - 布局

    private func buildLayout() {
        chatInputView.font = .preferredFont(forTextStyle: .body)
        chatInputView.adjustsFontForContentSizeCategory = true
        chatInputView.layer.borderColor = UIColor.separator.cgColor
        chatInputView.layer.borderWidth = 1
        chatInputView.layer.cornerRadius = 10
        chatInputView.textContainerInset = .init(top: 12, left: 8, bottom: 12, right: 8)
        chatInputView.accessibilityLabel = "聊天文本"
        chatInputView.delegate = self
        chatInputView.translatesAutoresizingMaskIntoConstraints = false
        chatInputView.heightAnchor.constraint(equalToConstant: 180).isActive = true

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        chatInputView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: chatInputView.topAnchor, constant: 14),
            placeholderLabel.leadingAnchor.constraint(equalTo: chatInputView.leadingAnchor, constant: 12),
            placeholderLabel.trailingAnchor.constraint(equalTo: chatInputView.trailingAnchor, constant: -12)
        ])

        runButton.configuration?.title = "开始分析"
        runButton.configuration?.image = UIImage(systemName: "sparkles")
        runButton.configuration?.imagePadding = 8
        runButton.configuration?.cornerStyle = .large
        runButton.configuration?.contentInsets = .init(top: 14, leading: 20, bottom: 14, trailing: 20)
        runButton.addAction(UIAction { [weak self] _ in self?.runAnalysis() }, for: .touchUpInside)

        judgeResultLabel.font = .preferredFont(forTextStyle: .subheadline)
        judgeResultLabel.numberOfLines = 0
        judgeResultLabel.adjustsFontForContentSizeCategory = true
        judgeResultLabel.isHidden = true

        candidatesStack.axis = .vertical
        candidatesStack.spacing = 12
        candidatesStack.isHidden = true

        let stack = UIStackView(arrangedSubviews: [
            makeSectionLabel("聊天内容"),
            chatInputView,
            runButton,
            statusLabel,
            makeSectionLabel("判断结果"),
            judgeResultLabel,
            makeSectionLabel("候选回复"),
            makeFootnoteLabel("从上到下推荐程度由低到高，第三条为优先推荐。推荐分是模型的相对偏好，不是正确率。"),
            candidatesStack
        ])
        stack.axis = .vertical
        stack.spacing = 14
        stack.setCustomSpacing(24, after: statusLabel)
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

extension AnalysisViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
    }
}
