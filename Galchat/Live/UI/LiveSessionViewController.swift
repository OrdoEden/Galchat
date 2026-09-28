import UIKit
import SnapKit
import SeeU

/// 实时会话页：录屏期间识别到的聊天、拼接结果、自动分析状态、判断与候选回复。
final class LiveSessionViewController: UIViewController {
    private let coordinator = LiveChatCoordinator.shared
    private var observer: UUID?

    private let statusLabel = UILabel()
    private let analysisLabel = makeFootnoteLabel("")
    private let statsLabel = makeFootnoteLabel("")
    private let autoSwitch = UISwitch()
    private let recordSwitch = UISwitch()
    private let analyzeButton = UIButton(configuration: .filled())
    private let longShotButton = UIButton(configuration: .tinted())
    private let clearButton = UIButton(configuration: .plain())
    private let judgeLabel = UILabel()
    private let candidatesStack = UIStackView()
    private let replyNoteLabel = makeFootnoteLabel("")
    private let transcriptLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "实时会话"
        view.backgroundColor = .systemBackground
        view.tintColor = .galchatPink
        buildLayout()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if observer == nil {
            observer = coordinator.observe { [weak self] in self?.render() }
        }
        render()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if let observer {
            coordinator.removeObserver(observer)
            self.observer = nil
        }
    }

    deinit {
        if let observer {
            MainActor.assumeIsolated { LiveChatCoordinator.shared.removeObserver(observer) }
        }
    }

    // MARK: - 渲染

    private var renderedOutcomeKey: String?

    private func render() {
        statusLabel.text = coordinator.statusLine
        analysisLabel.text = coordinator.analysisLine
        if let latest = coordinator.latest {
            statsLabel.text = "收到 \(coordinator.framesReceived) 帧 · OCR \(latest.framesProcessed) 帧"
                + " · 最近一次 OCR \(latest.ocrMilliseconds)ms"
                + "\n长图：\(coordinator.isSavingLongScreenshot ? "后台拼接中" : "待机") · 候选：\(coordinator.replyLine)"
        } else {
            statsLabel.text = "收到 \(coordinator.framesReceived) 帧"
        }
        autoSwitch.isOn = coordinator.scheduler.autoAnalyze
        analyzeButton.configuration?.showsActivityIndicator = coordinator.scheduler.phase == .analyzing

        renderOutcome()
        renderTranscript()
    }

    private func renderOutcome() {
        var judge: [String] = []
        if let outcome = coordinator.scheduler.outcome {
            if outcome.stale { judge.append("⚠︎ 以下为上一次 Jev 判断，新判断完成后更新") }
            if let analysis = outcome.analysis {
                judge += AnalysisPresentation.judgeLines(analysis)
                judge.append("判断耗时 \(analysis.latencyMs)ms")
            } else if let error = outcome.judgeError { judge.append("判断失败：\(error)") }
        } else {
            judge.append(coordinator.analysisLine)
        }
        judgeLabel.text = judge.joined(separator: "\n")
        guard let outcome = coordinator.replyScheduler.outcome else {
            candidatesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            replyNoteLabel.text = coordinator.replyLine
            renderedOutcomeKey = nil
            return
        }
        // 候选只在内容变化时重建，避免每帧刷新打断用户点“复制”。
        let key = "\(outcome.request.id)|\(outcome.replies.map(\.text).joined())|\(outcome.repliesUnranked)|\(outcome.stale)"
        if key != renderedOutcomeKey {
            renderedOutcomeKey = key
            AnalysisPresentation.fill(
                candidatesStack, with: outcome.replies, unranked: outcome.repliesUnranked,
                enabled: !outcome.stale
            ) { [weak self] _ in
                self?.analysisLabel.text = "已复制，可切回聊天 App 粘贴"
            }
        }
        if outcome.stale {
            replyNoteLabel.text = "上一份候选暂不可复制，等待当前内容分析完成"
        } else if let error = outcome.error {
            replyNoteLabel.text = error
        } else {
            replyNoteLabel.text = outcome.repliesUnranked
                ? "排序失败，按生成顺序展示"
                : "从上到下推荐程度由低到高，第三条为优先推荐。推荐分是模型的相对偏好，不是正确率。"
        }
    }

    private func renderTranscript() {
        guard let latest = coordinator.latest else {
            transcriptLabel.attributedText = NSAttributedString(
                string: "开始录屏并打开一个聊天窗口，这里会显示逐屏拼接出的聊天记录。",
                attributes: [.foregroundColor: UIColor.secondaryLabel, .font: UIFont.preferredFont(forTextStyle: .footnote)]
            )
            return
        }
        let body = UIFont.preferredFont(forTextStyle: .subheadline)
        let caption = UIFont.preferredFont(forTextStyle: .caption1)
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "—— 当前屏 OCR（不依赖长图）——\n", attributes: [
            .font: caption, .foregroundColor: UIColor.secondaryLabel
        ]))
        for message in latest.currentMessages {
            let speaker = message.side == .me ? "我" : (message.side == .other ? "对方" : "未知")
            text.append(NSAttributedString(string: "\(speaker)：\(message.text)\(message.clipped ? "（部分可见）" : "")\n",
                                          attributes: [.font: body, .foregroundColor: UIColor.label]))
        }
        if latest.currentMessages.isEmpty {
            text.append(NSAttributedString(string: "本屏尚未识别到可读文字\n", attributes: [.font: caption]))
        }
        text.append(NSAttributedString(string: "\n"))
        // 实时段放最后，和聊天 App 里“越往下越新”的阅读顺序一致。
        let ordered = latest.segments.filter { !$0.isLive } + latest.segments.filter(\.isLive)
        for (index, segment) in ordered.enumerated() {
            let count = segment.messages.filter { $0.kind == .message }.count
            let header = segment.isLive
                ? "—— 最新片段 · \(count) 条 · 长图 \(coordinator.longScreenshotSummary[segment.id]?.rungCount ?? 0) 张 ——\n"
                : "—— 历史片段 \(index + 1) · \(count) 条（与其他片段之间可能有缺口）——\n"
            text.append(NSAttributedString(string: header, attributes: [
                .font: caption, .foregroundColor: UIColor.secondaryLabel
            ]))
            for message in segment.messages {
                if message.kind == .time {
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.alignment = .center
                    text.append(NSAttributedString(string: "\(message.text)\n", attributes: [
                        .font: caption, .foregroundColor: UIColor.tertiaryLabel, .paragraphStyle: paragraph
                    ]))
                    continue
                }
                let (label, color): (String, UIColor) = {
                    switch message.side {
                    case .me: return ("我", .systemGreen)
                    case .other: return (message.senderName ?? "对方", .galchatPink)
                    case .unknown: return ("未知", .systemOrange)
                    }
                }()
                let low = message.side != .unknown && message.sideConfidence < 0.75 ? "?" : ""
                text.append(NSAttributedString(string: "\(label)\(low)：", attributes: [
                    .font: body.withTraits(.traitBold), .foregroundColor: color
                ]))
                let suffix = message.clipped ? "（未显示完整）" : ""
                text.append(NSAttributedString(string: "\(message.text)\(suffix)\n", attributes: [
                    .font: body, .foregroundColor: UIColor.label
                ]))
                if let quote = message.quote {
                    text.append(NSAttributedString(string: "    ↳ 引用 \(quote)\n", attributes: [
                        .font: caption, .foregroundColor: UIColor.secondaryLabel
                    ]))
                }
            }
            text.append(NSAttributedString(string: "\n"))
        }
        transcriptLabel.attributedText = text
    }

    // MARK: - 操作

    private func showLongScreenshot() {
        longShotButton.configuration?.showsActivityIndicator = true
        Task { [weak self] in
            let image = await LiveChatCoordinator.shared.renderLongScreenshot()
            guard let self else { return }
            longShotButton.configuration?.showsActivityIndicator = false
            guard let image else {
                analysisLabel.text = "还没有可拼接的长截图"
                return
            }
            navigationController?.pushViewController(LongScreenshotViewController(image: image), animated: true)
        }
    }

    // MARK: - 布局

    private func buildLayout() {
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.numberOfLines = 0
        statusLabel.adjustsFontForContentSizeCategory = true

        autoSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            coordinator.scheduler.autoAnalyze = autoSwitch.isOn
        }, for: .valueChanged)
        let autoLabel = UILabel()
        autoLabel.text = "对方发来新消息时自动分析"
        autoLabel.font = .preferredFont(forTextStyle: .body)
        autoLabel.numberOfLines = 0
        let autoRow = UIStackView(arrangedSubviews: [autoLabel, autoSwitch])
        autoRow.alignment = .center
        autoRow.spacing = 12

        recordSwitch.isOn = FrameRecorder.shared.isEnabled
        recordSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            FrameRecorder.shared.isEnabled = recordSwitch.isOn
        }, for: .valueChanged)
        let recordLabel = UILabel()
        recordLabel.text = "录制识别帧（调试）"
        recordLabel.font = .preferredFont(forTextStyle: .body)
        recordLabel.numberOfLines = 0
        let recordRow = UIStackView(arrangedSubviews: [recordLabel, recordSwitch])
        recordRow.alignment = .center
        recordRow.spacing = 12
        let recordNote = makeFootnoteLabel("打开后，送去识别的每一帧会保存到“文件 → 我的 iPhone → Galchat → SeeUReplay”，每次录屏一个文件夹、最多 \(FrameRecorder.frameLimit) 帧。截图含聊天内容，只存本机，用于回放复现识别问题，用完请关闭并删除。")

        analyzeButton.configuration?.title = "立即分析"
        analyzeButton.configuration?.image = UIImage(systemName: "sparkles")
        analyzeButton.configuration?.baseBackgroundColor = .galchatPinkStrong
        analyzeButton.configuration?.baseForegroundColor = .white
        analyzeButton.addAction(UIAction { [weak self] _ in self?.coordinator.scheduler.analyzeNow() }, for: .touchUpInside)
        longShotButton.configuration?.title = "查看长截图"
        longShotButton.configuration?.image = UIImage(systemName: "rectangle.stack")
        longShotButton.addAction(UIAction { [weak self] _ in self?.showLongScreenshot() }, for: .touchUpInside)
        for button in [analyzeButton, longShotButton] {
            button.configuration?.imagePadding = 8
            button.configuration?.cornerStyle = .large
        }
        clearButton.configuration?.title = "清空本次识别"
        clearButton.configuration?.baseForegroundColor = .systemRed
        clearButton.addAction(UIAction { [weak self] _ in self?.coordinator.clear() }, for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [analyzeButton, longShotButton])
        buttons.distribution = .fillEqually
        buttons.spacing = 12

        judgeLabel.font = .preferredFont(forTextStyle: .subheadline)
        judgeLabel.numberOfLines = 0
        judgeLabel.adjustsFontForContentSizeCategory = true
        candidatesStack.axis = .vertical
        candidatesStack.spacing = 12
        transcriptLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [
            statusLabel, analysisLabel, statsLabel, autoRow, recordRow, recordNote, buttons,
            makeFootnoteLabel("判断结论显示在画中画里；三条候选回复会发到 Galchat 键盘。首次使用请在“设置 → 通用 → 键盘 → 键盘 → 添加新键盘”里添加 Galchat 键盘，聊天时用地球键切换过去。键盘不联网、不需要“完全访问”。"),
            makeSectionLabel("判断结果"), judgeLabel,
            makeSectionLabel("候选回复"), replyNoteLabel, candidatesStack,
            makeSectionLabel("拼接的聊天记录"),
            makeFootnoteLabel("逐屏识别并按重叠消息对齐、去重拼接；长图保留最近 \(GCConfig.shared.ladderCapacity) 张不重复的画面（可在设置里调整）。只保存在内存中，停止录屏后保留到下次录屏或手动清空。"),
            transcriptLabel, clearButton
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(20, after: buttons)
        stack.setCustomSpacing(20, after: candidatesStack)

        let scrollView = UIScrollView()
        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        scrollView.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top)
            make.bottom.equalToSuperview()
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

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
