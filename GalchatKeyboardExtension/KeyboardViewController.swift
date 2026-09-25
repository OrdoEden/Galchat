import UIKit

/// 完整输入法：顶部三个 Jarvis 回复候选，下面保留本地拼音和普通输入。
/// “Jarvis 键盘”前缀供录屏解析器识别键盘区域，不能改成聊天内容。
final class KeyboardViewController: UIInputViewController {
    private enum Layout { case letters, numbers, symbols }
    private let headerLabel = UILabel()
    private let heartsLabel = UILabel()
    private let noteLabel = UILabel()
    private let confirmButton = UIButton(type: .system)
    private let candidateStack = UIStackView()
    private let contactRow = UIStackView()
    private let compositionLabel = UILabel()
    private let pinyinScroll = UIScrollView()
    private let pinyinStack = UIStackView()
    private let keyStack = UIStackView()
    private let pinyinEngine = PinyinInputEngine()
    private var pinyinCandidates: [PinyinInputEngine.Candidate] = []
    private var visiblePinyinCount = 30
    private var renderedComposition = ""
    private var layout: Layout = .letters
    private var chinese = true
    private var uppercase = false
    private var composition = ""
    private var compositionDocumentID: UUID?
    private var switchButton: UIButton?
    private var heightConstraint: NSLayoutConstraint?
    private var bundle: ReplyBundle?
    private var lastModified: Date?
    private var projection: AffectionProjection?
    private var projectionModified: Date?
    private var timer: Timer?
    private var deleteTimer: Timer?
    /// 已确认的联系人 id。
    ///
    /// 这是从"按 bundleID 确认"改过来的：`bundleID` 每来一轮新的排序结果就会变，
    /// 之前 `reload` 在 `bundleID` 变化时清空确认，导致每收到一条新建议就要重新确认一次。
    /// 确认的对象本来就是"我正在跟谁聊"，所以挂在联系人上才是对的。
    private var confirmedContactID: String?
    /// 没有绑定联系人时（匿名会话）的最终确认标记。
    private var confirmedAnonymousTitle: String?
    /// 确认时所在的输入框。换聊天窗口即失效。
    private var confirmedDocumentID: String?
    private var pendingReplace: (candidateID: String, until: Date)?
    private var feedback: (text: String, until: Date)?

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        rebuildKeys()
        renderComposition()
        reload(force: true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        pendingReplace = nil
        resetCompositionIfDocumentChanged()
        reload(force: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload(force: false) }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
        timer = nil
        stopDeleting()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        resetCompositionIfDocumentChanged()
        renderSuggestions()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        resetCompositionIfDocumentChanged()
        pendingReplace = nil
        renderSuggestions()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        switchButton?.isHidden = !needsInputModeSwitchKey
        // Keep the keyboard content above the system home-indicator/input-mode area.
        let compact = traitCollection.verticalSizeClass == .compact
        heightConstraint?.constant = (compact ? 308 : 354) + view.safeAreaInsets.bottom
    }

    // MARK: - Shared suggestions

    /// 确认是否成立。
    ///
    /// 两个条件：确认的对象没变（联系人或匿名标题），且输入框没换
    /// （同一个微信窗口里换到另一个人的聊天，`documentIdentifier` 会变）。
    private func isConfirmed() -> Bool {
        guard let usable = bundle, usable.isUsable() else { return false }
        let document = textDocumentProxy.documentIdentifier.uuidString
        if let contactID = projection?.activeContactID {
            return confirmedContactID == contactID && confirmedDocumentID == document
        }
        // 没有绑定联系人：退回按标题确认，并且仍然要求同一个输入框。
        guard let title = confirmedAnonymousTitle else { return false }
        return title == usable.sourceTitle && confirmedDocumentID == document
    }

    /// 记下当前确认状态。`contactID` 为空表示这是一次匿名确认。
    private func markConfirmed() {
        confirmedDocumentID = textDocumentProxy.documentIdentifier.uuidString
        if let contactID = projection?.activeContactID {
            confirmedContactID = contactID
            confirmedAnonymousTitle = nil
        } else {
            confirmedAnonymousTitle = bundle?.sourceTitle
            confirmedContactID = nil
        }
    }

    private func reload(force: Bool) {
        let modified = ReplyBundleStore.modificationDate()
        if force || modified != lastModified {
            lastModified = modified
            let next = ReplyBundleStore.load()
            // 只在**目标对象**变了才清空确认，而不是每次新建议都清。
            if next?.bundleID != bundle?.bundleID {
                pendingReplace = nil
                feedback = nil
            }
            bundle = next
        }
        // 投影与候选是两个文件、两种生命周期，各自按自己的 mtime 刷新。
        let projectionModifiedNow = AffectionProjectionStore.modificationDate()
        if force || projectionModifiedNow != projectionModified {
            projectionModified = projectionModifiedNow
            projection = AffectionProjectionStore.load()
            // 换联系人了，之前的确认作废。
            if let contactID = projection?.activeContactID, contactID != confirmedContactID {
                confirmedContactID = nil
                confirmedAnonymousTitle = nil
            }
        }
        renderHearts()
        // Even an unchanged file can expire while the host app is suspended.
        renderSuggestions()
    }

    /// 好感度读数。**不套 `isUsable()` 门禁**——总分是持久事实，不是当下观察，
    /// 录屏停了也该继续显示。只有本轮 ± 会随新鲜度消失。
    private func renderHearts() {
        guard let projection else {
            heartsLabel.text = nil
            heartsLabel.isHidden = true
            return
        }
        heartsLabel.isHidden = false
        heartsLabel.text = projection.heartsText()
        heartsLabel.textColor = projection.ruptured ? .systemRed
            : (projection.hasContact ? .label : .secondaryLabel)
        // 匿名时说明分数归属未知，避免用户误以为是某个人的分。
        heartsLabel.accessibilityLabel = projection.displayName.map {
            "\($0) 好感度 \(projection.total)"
        } ?? "好感度 \(projection.total)，尚未确认联系人"
    }

    private func renderSuggestions() {
        clear(candidateStack)
        let usable = bundle.flatMap { $0.isUsable() ? $0 : nil }
        // 标题优先用投影里的联系人名：那才是用户确认过的身份，OCR 标题只是候选。
        let subject = projection?.displayName ?? usable?.sourceTitle ?? projection?.sourceTitle
        headerLabel.text = subject.map { "Jarvis 键盘 · \($0)" } ?? "Jarvis 键盘 · 暂无可用建议"
        let confirmed = isConfirmed()
        let anonymous = usable?.sourceTitle == "当前会话" || usable?.sourceConfidence == "recognized"
        confirmButton.isHidden = usable == nil || confirmed
        confirmButton.setTitle(anonymous ? "确认建议对应当前聊天" : "确认会话", for: .normal)
        confirmButton.accessibilityLabel = anonymous ? "确认建议对应当前聊天" : usable.map { "确认当前正在和「\($0.sourceTitle)」聊天" }

        renderContactRow()

        if let feedback, feedback.until > Date() {
            noteLabel.text = feedback.text
        } else if let usable {
            noteLabel.text = confirmed
                ? (usable.summary.map { "判断：\($0)" } ?? "点上方建议插入；下方可以继续输入和修改")
                : (anonymous ? "来源待核对：\(usable.sourceTitle) · 请确认当前聊天" : "确认当前是「\(usable.sourceTitle)」后，可插入建议")
        } else {
            // 候选不可用时仍然报好感度状态，因为它不依赖候选的新鲜度。
            noteLabel.text = unavailableReason() + " · 可继续打字"
        }
        let candidates = usable?.candidates.sorted { $0.rank < $1.rank } ?? []
        for index in 0..<3 {
            guard index < candidates.count else {
                let placeholder = makeKey(index == 1 ? "暂无回复建议" : "—", fontSize: 12)
                placeholder.isEnabled = false
                placeholder.alpha = 0.55
                candidateStack.addArrangedSubview(placeholder)
                continue
            }
            let candidate = candidates[index]
            let button = makeKey(candidate.text, fontSize: 13)
            button.titleLabel?.numberOfLines = 2
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.isEnabled = confirmed
            button.alpha = confirmed ? 1 : 0.5
            button.accessibilityLabel = "回复建议\(index + 1)：\(candidate.text)"
            if candidate.rank == 3 {
                button.backgroundColor = UIColor.systemIndigo.withAlphaComponent(0.18)
                button.accessibilityHint = "优先推荐，点击插入输入框"
            }
            button.addAction(UIAction { [weak self] _ in
                self?.insertSuggestion(candidate)
            }, for: .touchUpInside)
            candidateStack.addArrangedSubview(button)
        }
    }

    /// 联系人确认行。只在主 App 给出了候选人、且当前还没绑定到人时出现。
    ///
    /// 键盘本身不认识联系人——它只是把用户的一次点击回传成一个小 JSON 文件，
    /// 由主 App 决定是绑定、新建还是忽略。键盘因此仍然是只读的。
    private func renderContactRow() {
        clear(contactRow)
        guard let projection, !projection.hasContact, !projection.suggestions.isEmpty,
              ContactMatcher.isTrusted(projection.sourceTitle) else {
            contactRow.isHidden = true
            return
        }
        contactRow.isHidden = false
        for suggestion in projection.suggestions.prefix(AffectionProjection.maxSuggestions) {
            let button = makeKey("是他/她：\(suggestion.displayName)", fontSize: 12)
            button.addAction(UIAction { [weak self] _ in
                self?.sendDecision(.existing, contactID: suggestion.id)
            }, for: .touchUpInside)
            contactRow.addArrangedSubview(button)
        }
        let create = makeKey("新建联系人", fontSize: 12)
        create.addAction(UIAction { [weak self] _ in
            self?.sendDecision(.create, contactID: nil)
        }, for: .touchUpInside)
        contactRow.addArrangedSubview(create)
        let ignore = makeKey("忽略", fontSize: 12)
        ignore.addAction(UIAction { [weak self] _ in
            self?.sendDecision(.ignore, contactID: nil)
        }, for: .touchUpInside)
        contactRow.addArrangedSubview(ignore)
    }

    private func sendDecision(_ resolution: AffectionProjectionStore.ContactDecision.Resolution,
                              contactID: String?) {
        guard let projection else { return }
        let decision = AffectionProjectionStore.ContactDecision(
            resolution: resolution, contactID: contactID,
            sourceTitle: projection.sourceTitle, decidedAt: Date()
        )
        guard AffectionProjectionStore.writeDecision(decision) else {
            showFeedback("无法写入联系人确认，请返回 Jarvis 检查")
            return
        }
        if resolution == .existing, let contactID {
            // 乐观更新：主 App 落地后会用新投影覆盖。
            confirmedContactID = contactID
            confirmedDocumentID = textDocumentProxy.documentIdentifier.uuidString
        } else if resolution == .create {
            confirmedDocumentID = textDocumentProxy.documentIdentifier.uuidString
        }
        contactRow.isHidden = true
        showFeedback(resolution == .ignore ? "已忽略本次联系人确认" : "已提交，Jarvis 会更新联系人")
    }

    private func unavailableReason() -> String {
        guard let bundle else { return "等待聊天分析" }
        if bundle.status == .invalid { return bundle.note ?? "等待新的建议" }
        if Date() >= bundle.validUntil || Date() >= bundle.expiresAt { return "建议已过期" }
        return "建议暂不可用"
    }

    private func showFeedback(_ text: String) {
        feedback = (text, Date().addingTimeInterval(4))
        renderSuggestions()
    }

    private func insertSuggestion(_ candidate: ReplyBundle.Candidate) {
        guard composition.isEmpty else {
            showFeedback("请先选词或点拼音原文上屏，再插入回复建议")
            return
        }
        let latest = ReplyBundleStore.load()
        guard let shown = bundle, let latest, latest.isUsable(),
              latest.bundleID == shown.bundleID,
              latest.sessionID == shown.sessionID, latest.conversationID == shown.conversationID,
              latest.revision == shown.revision, latest.analysisRequestID == shown.analysisRequestID,
              latest.candidates.contains(where: { $0.id == candidate.id && $0.text == candidate.text })
        else {
            reload(force: true)
            showFeedback("建议已更新，请重新确认会话后选择")
            return
        }
        guard isConfirmed() else { return }
        if let selected = textDocumentProxy.selectedText, !selected.isEmpty {
            if pendingReplace?.candidateID != candidate.id || (pendingReplace?.until ?? .distantPast) < Date() {
                pendingReplace = (candidate.id, Date().addingTimeInterval(3))
                showFeedback("再点一次这条建议，替换选中的文字")
                return
            }
        }
        pendingReplace = nil
        textDocumentProxy.insertText(candidate.text)
        showFeedback("已插入，可继续修改；请自行发送")
    }

    // MARK: - Local composition

    private func resetCompositionIfDocumentChanged() {
        guard let compositionDocumentID,
              compositionDocumentID != textDocumentProxy.documentIdentifier else { return }
        composition = ""
        self.compositionDocumentID = nil
        renderComposition()
    }

    private func renderComposition() {
        if renderedComposition != composition {
            renderedComposition = composition
            visiblePinyinCount = 30
        }
        pinyinCandidates = composition.isEmpty ? [] : pinyinEngine.candidates(for: composition)
        compositionLabel.text = composition.isEmpty ? (chinese ? "拼音" : "English") : composition
        clear(pinyinStack)
        if composition.isEmpty {
            let hint = UILabel()
            hint.text = chinese ? "输入拼音，空格选词 · v 输入 ü" : "英文输入"
            hint.font = .systemFont(ofSize: 12)
            hint.textColor = .secondaryLabel
            pinyinStack.addArrangedSubview(hint)
        } else {
            for candidate in pinyinCandidates.prefix(visiblePinyinCount) {
                let button = makeKey(candidate.text, fontSize: 18)
                button.accessibilityLabel = "拼音候选：\(candidate.text)"
                button.addAction(UIAction { [weak self] _ in self?.choose(candidate) }, for: .touchUpInside)
                pinyinStack.addArrangedSubview(button)
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            }
            // Common syllables can have hundreds of characters; instantiate more only on demand.
            if pinyinCandidates.count > visiblePinyinCount {
                let more = makeKey("更多", fontSize: 14)
                more.addAction(UIAction { [weak self] _ in
                    guard let self else { return }
                    let offset = pinyinScroll.contentOffset
                    visiblePinyinCount += 30
                    renderComposition()
                    pinyinScroll.layoutIfNeeded()
                    pinyinScroll.setContentOffset(offset, animated: false)
                }, for: .touchUpInside)
                pinyinStack.addArrangedSubview(more)
            }
            let literal = makeKey(composition, fontSize: 14)
            literal.accessibilityLabel = "直接输入拼音原文：\(composition)"
            literal.addAction(UIAction { [weak self] _ in self?.commitLiteral() }, for: .touchUpInside)
            pinyinStack.addArrangedSubview(literal)
        }
        pinyinScroll.setContentOffset(.zero, animated: false)
    }

    private func choose(_ candidate: PinyinInputEngine.Candidate) {
        resetCompositionIfDocumentChanged()
        guard !composition.isEmpty, candidate.consumedPinyinCount > 0,
              candidate.consumedPinyinCount <= composition.count,
              pinyinCandidates.contains(where: {
                  $0.text == candidate.text && $0.consumedPinyinCount == candidate.consumedPinyinCount
              }) else { return }
        composition = String(composition.dropFirst(candidate.consumedPinyinCount))
        if composition.isEmpty { compositionDocumentID = nil }
        textDocumentProxy.insertText(candidate.text)
        renderComposition()
    }

    private func commitLiteral() {
        resetCompositionIfDocumentChanged()
        guard !composition.isEmpty else { return }
        let text = composition
        composition = ""
        compositionDocumentID = nil
        textDocumentProxy.insertText(text)
        renderComposition()
    }

    private func type(_ text: String) {
        resetCompositionIfDocumentChanged()
        pendingReplace = nil
        if chinese && layout == .letters && (text == "'" || text.range(of: "^[a-z]+$", options: .regularExpression) != nil) {
            if text == "'", composition.isEmpty || composition.last == "'" { return }
            guard composition.count < 64 else { return }
            compositionDocumentID = textDocumentProxy.documentIdentifier
            composition += text
            renderComposition()
        } else {
            if chinese, text.rangeOfCharacter(from: .punctuationCharacters) != nil,
               let candidate = pinyinCandidates.first(where: { $0.consumedPinyinCount == composition.count }) {
                choose(candidate)
            } else {
                commitLiteral()
            }
            textDocumentProxy.insertText(text)
            if uppercase {
                uppercase = false
                rebuildKeys()
            }
        }
    }

    private func space() {
        resetCompositionIfDocumentChanged()
        if !composition.isEmpty {
            if let first = pinyinCandidates.first { choose(first) } else { commitLiteral() }
        } else {
            textDocumentProxy.insertText(" ")
        }
    }

    private func enter() {
        // Like an IME, Return first commits the literal composition without sending a message.
        if !composition.isEmpty { commitLiteral() } else { textDocumentProxy.insertText("\n") }
    }

    private func deleteBackward() {
        resetCompositionIfDocumentChanged()
        pendingReplace = nil
        if composition.isEmpty {
            textDocumentProxy.deleteBackward()
        } else {
            composition.removeLast()
            if composition.isEmpty { compositionDocumentID = nil }
            renderComposition()
        }
    }

    @objc private func repeatDelete(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began {
            deleteBackward()
            deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.deleteBackward() }
            }
        } else if recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed {
            stopDeleting()
        }
    }

    private func stopDeleting() {
        deleteTimer?.invalidate()
        deleteTimer = nil
    }

    @objc private func switchInputMode(_ sender: UIButton, with event: UIEvent) {
        commitLiteral()
        handleInputModeList(from: sender, with: event)
    }

    private func changeLayout(_ next: Layout) {
        commitLiteral()
        layout = next
        rebuildKeys()
    }

    private func toggleLanguage() {
        commitLiteral()
        chinese.toggle()
        uppercase = false
        layout = .letters
        rebuildKeys()
        renderComposition()
    }

    // MARK: - Key layout

    private func rebuildKeys() {
        stopDeleting()
        clear(keyStack)
        let rows: [String]
        switch layout {
        case .letters: rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        case .numbers: rows = ["1234567890", "-/:;()¥&@\"", ".,?!'"]
        case .symbols: rows = ["[]{}#%^*+=", "_\\|~<>$€£•", "…，。？！"]
        }
        for (index, characters) in rows.enumerated() {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 5
            row.distribution = .fillEqually
            if index == 2 {
                let title = layout == .letters ? (chinese ? "分词" : "⇧") : (layout == .numbers ? "#+=" : "123")
                let control = makeKey(title, fontSize: 15)
                if !chinese && uppercase && layout == .letters {
                    control.backgroundColor = UIColor.systemIndigo.withAlphaComponent(0.2)
                }
                control.accessibilityLabel = layout == .letters ? (chinese ? "拼音分隔符" : "切换大小写") : "切换数字符号"
                control.addAction(UIAction { [weak self] _ in
                    guard let self else { return }
                    if layout == .letters {
                        if chinese { type("'") } else { uppercase.toggle(); rebuildKeys() }
                    } else { changeLayout(layout == .numbers ? .symbols : .numbers) }
                }, for: .touchUpInside)
                row.addArrangedSubview(control)
            }
            for character in characters {
                let text = String(character)
                let displayed = !chinese && uppercase && layout == .letters ? text.uppercased() : text
                let button = makeKey(displayed, fontSize: 21)
                button.addAction(UIAction { [weak self] _ in self?.type(displayed) }, for: .touchUpInside)
                row.addArrangedSubview(button)
            }
            if index == 2 {
                let delete = makeKey("", symbol: "delete.left", accessibility: "删除")
                delete.addAction(UIAction { [weak self] _ in self?.deleteBackward() }, for: .touchUpInside)
                delete.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(repeatDelete(_:))))
                row.addArrangedSubview(delete)
            }
            keyStack.addArrangedSubview(row)
        }
        let bottom = UIStackView()
        bottom.axis = .horizontal
        bottom.spacing = 5
        let mode = makeKey(layout == .letters ? "123" : (chinese ? "拼音" : "ABC"), fontSize: 14)
        mode.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            changeLayout(layout == .letters ? .numbers : .letters)
        }, for: .touchUpInside)
        let globe = makeKey("", symbol: "globe", accessibility: "切换输入法")
        globe.addTarget(self, action: #selector(switchInputMode(_:with:)), for: .allTouchEvents)
        globe.isHidden = !needsInputModeSwitchKey
        switchButton = globe
        let language = makeKey(chinese ? "中/英" : "英/中", fontSize: 13)
        language.addAction(UIAction { [weak self] _ in self?.toggleLanguage() }, for: .touchUpInside)
        let space = makeKey("空格", fontSize: 15)
        space.addAction(UIAction { [weak self] _ in self?.space() }, for: .touchUpInside)
        let punctuation = makeKey(chinese ? "，" : ".", fontSize: 20)
        punctuation.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            type(chinese ? "，" : ".")
        }, for: .touchUpInside)
        let enter = makeKey("", symbol: "return", accessibility: "回车")
        enter.addAction(UIAction { [weak self] _ in self?.enter() }, for: .touchUpInside)
        for button in [mode, globe, language, space, punctuation, enter] { bottom.addArrangedSubview(button) }
        for button in [mode, globe, language, punctuation, enter] {
            let width = button.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: 0.13)
            width.priority = .defaultHigh
            width.isActive = true
        }
        keyStack.addArrangedSubview(bottom)
    }

    private func buildLayout() {
        view.backgroundColor = .systemGroupedBackground
        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = .secondaryLabel
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // 好感度读数。抗压缩优先级高于标题——分数比 OCR 标题更值得占用空间。
        heartsLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        heartsLabel.lineBreakMode = .byTruncatingHead
        heartsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        heartsLabel.isHidden = true
        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabel
        noteLabel.lineBreakMode = .byTruncatingTail
        confirmButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        confirmButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        confirmButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            markConfirmed()
            feedback = nil
            renderSuggestions()
        }, for: .touchUpInside)
        let dismiss = makeKey("", symbol: "keyboard.chevron.compact.down", accessibility: "收起键盘")
        dismiss.addAction(UIAction { [weak self] _ in
            self?.commitLiteral()
            self?.dismissKeyboard()
        }, for: .touchUpInside)
        dismiss.widthAnchor.constraint(equalToConstant: 34).isActive = true
        let header = UIStackView(arrangedSubviews: [headerLabel, heartsLabel, confirmButton, dismiss])
        header.spacing = 6
        header.alignment = .fill
        contactRow.axis = .horizontal
        contactRow.spacing = 5
        contactRow.distribution = .fillEqually
        contactRow.isHidden = true
        candidateStack.axis = .horizontal
        candidateStack.spacing = 5
        candidateStack.distribution = .fillEqually
        compositionLabel.font = .systemFont(ofSize: 12)
        compositionLabel.textColor = .secondaryLabel
        compositionLabel.lineBreakMode = .byTruncatingHead
        compositionLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true
        pinyinScroll.showsHorizontalScrollIndicator = false
        pinyinScroll.alwaysBounceHorizontal = true
        pinyinScroll.addSubview(pinyinStack)
        pinyinStack.axis = .horizontal
        pinyinStack.spacing = 10
        pinyinStack.alignment = .fill
        pinyinStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pinyinStack.leadingAnchor.constraint(equalTo: pinyinScroll.contentLayoutGuide.leadingAnchor),
            pinyinStack.trailingAnchor.constraint(equalTo: pinyinScroll.contentLayoutGuide.trailingAnchor),
            pinyinStack.topAnchor.constraint(equalTo: pinyinScroll.contentLayoutGuide.topAnchor),
            pinyinStack.bottomAnchor.constraint(equalTo: pinyinScroll.contentLayoutGuide.bottomAnchor),
            pinyinStack.heightAnchor.constraint(equalTo: pinyinScroll.frameLayoutGuide.heightAnchor)
        ])
        let compositionRow = UIStackView(arrangedSubviews: [compositionLabel, pinyinScroll])
        compositionRow.spacing = 6
        keyStack.axis = .vertical
        keyStack.spacing = 6
        keyStack.distribution = .fillEqually
        let root = UIStackView(arrangedSubviews: [header, candidateStack, contactRow, noteLabel, compositionRow, keyStack])
        root.axis = .vertical
        root.spacing = 5
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        let height = view.heightAnchor.constraint(equalToConstant: 354)
        height.priority = .defaultHigh
        heightConstraint = height
        // 联系人确认行只在需要时占用高度；隐藏时收成 0，不挤占键盘。
        let contactRowHeight = contactRow.heightAnchor.constraint(equalToConstant: 30)
        contactRowHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            height,
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5),
            root.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -5),
            header.heightAnchor.constraint(equalToConstant: 26),
            candidateStack.heightAnchor.constraint(equalToConstant: 42),
            contactRowHeight,
            noteLabel.heightAnchor.constraint(equalToConstant: 16),
            compositionRow.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    private func makeKey(_ title: String, symbol: String? = nil, accessibility: String? = nil, fontSize: CGFloat = 18) -> UIButton {
        let button = UIButton(type: .system)
        if let symbol { button.setImage(UIImage(systemName: symbol), for: .normal) }
        else { button.setTitle(title, for: .normal) }
        button.titleLabel?.font = .systemFont(ofSize: fontSize)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.7
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.tintColor = .label
        button.setTitleColor(.label, for: .normal)
        button.backgroundColor = .secondarySystemGroupedBackground
        button.layer.cornerRadius = 5
        button.accessibilityLabel = accessibility ?? title
        return button
    }

    private func clear(_ stack: UIStackView) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
    }
}
