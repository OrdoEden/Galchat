import UIKit

/// 与系统中文键盘一致的输入法：常驻候选条 + 26 键键盘。
///
/// 候选条按输入状态切换内容，对应系统键盘上方的预测条：
/// 还没开始拼写时显示模型给出的三条回复建议（对应英文键盘的三条预测），
/// 正在拼写时显示拼音候选（对应中文键盘的选词条），右侧 ⌄ 展开完整候选网格。
///
/// 键盘上**没有**品牌文字、好感度或状态行。录屏解析器因此改用按键行定位键盘区域
/// （`AppFrameExclusion`），改动键盘顶部结构时必须同步改 `KeyboardTopMetrics`。
final class KeyboardViewController: UIInputViewController {
    private enum Layout { case letters, numbers, symbols }
    /// 系统 shift 的三态：单击大写一次，双击锁定大写。
    private enum Shift { case off, once, locked }

    // MARK: 几何（按系统键盘截图实测，单位 pt）

    private enum Metrics {
        static let sideInset: CGFloat = 4
        static let keyGap: CGFloat = 6
        static let keyHeight: CGFloat = 42.5
        static let rowGap: CGFloat = 11.5
        static let compactKeyHeight: CGFloat = 32
        static let compactRowGap: CGFloat = 6
        static let bottomInset: CGFloat = 5
        static let cornerRadius: CGFloat = 7
        /// ⇧ / ⌫ 宽度，以字母键宽为单位。
        static let shiftUnits: CGFloat = 1.34
        /// 123 / 🌐 宽度。
        static let modeUnits: CGFloat = 1.3
        /// 换行键宽度。
        static let returnUnits: CGFloat = 2.8
        static let doubleTapInterval: TimeInterval = 0.35
    }

    private let candidateBar = UIStackView()
    private let candidateScroll = UIScrollView()
    private let candidateStack = UIStackView()
    private let candidateSeparator = UIView()
    private let expandButton = UIButton(type: .system)
    private let candidateGrid = CandidateGridView()
    private let keyStack = UIStackView()
    private let pinyinEngine = PinyinInputEngine()
    private var pinyinCandidates: [PinyinInputEngine.Candidate] = []
    private var layout: Layout = .letters
    private var shift: Shift = .off
    private var lastShiftTap: Date?
    private var expanded = false
    private var composition = ""
    private var compositionDocumentID: UUID?
    private var switchButton: UIButton?
    private var spaceButton: UIButton?
    private var enterButton: UIButton?
    private var heightConstraint: NSLayoutConstraint?
    /// 回复建议模式下三条等宽平铺；拼音模式下按词宽横滑。
    private var equalWidthConstraint: NSLayoutConstraint?
    private var appliedSafeAreaInset: CGFloat = -1
    private var bundle: ReplyBundle?
    private var lastModified: Date?
    private var projection: AffectionProjection?
    private var projectionModified: Date?
    private var timer: Timer?
    private var deleteTimer: Timer?
    /// 已确认的联系人 id。
    ///
    /// 确认挂在联系人上而不是 `bundleID` 上：`bundleID` 每来一轮新的排序结果就会变，
    /// 之前按它清空确认，导致每收到一条新建议就要重新确认一次。
    private var confirmedContactID: String?
    /// 没有绑定联系人时（匿名会话）的最终确认标记。
    private var confirmedAnonymousTitle: String?
    /// 确认时所在的输入框。换聊天窗口即失效。
    private var confirmedDocumentID: String?
    private var pendingReplace: (candidateID: String, until: Date)?
    private var feedback: (text: String, until: Date)?
    /// 输入框里当前是否有本键盘设置的标记文本（带下划线的拼音）。
    private var markedTextActive = false
    /// 当前标记文本的内容（显示用拼音，如 `ni hao`）。
    private var markedDisplay = ""
    /// 这个输入框的 `documentContextBeforeInput` 是否包含标记文本。
    ///
    /// 各 App 的实现不一样：多数把标记文本算进光标前的上下文，也有不算的。
    /// 只有确认过「算」之后，才能用上下文不匹配来判断宿主改动了标记文本；
    /// 否则会在不算的 App 里每次回调都误判，导致拼音一打就丢。
    private var contextIncludesMarkedText = false

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
        // 高度只在出现前定一次。放进布局回调会让键盘每帧重设高度，呈现时逐帧长高。
        applyHeight()
        enterButton?.setTitle(enterTitle(), for: .normal)
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
        // 键盘收起时不留悬空的标记文本：和系统一样，把拼音原文上屏。
        commitLiteral()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        resetCompositionIfDocumentChanged()
        validateMarkedText()
        renderCandidateBar()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        resetCompositionIfDocumentChanged()
        validateMarkedText()
        pendingReplace = nil
        renderCandidateBar()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        switchButton?.isHidden = !needsInputModeSwitchKey
        // 安全区在首次布局后才确定；只在它变化时补一次高度。
        if view.safeAreaInsets.bottom != appliedSafeAreaInset { applyHeight() }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.verticalSizeClass != traitCollection.verticalSizeClass {
            keyStack.spacing = rowGap
            applyHeight()
        }
    }

    private var compact: Bool { traitCollection.verticalSizeClass == .compact }
    private var rowGap: CGFloat { compact ? Metrics.compactRowGap : Metrics.rowGap }

    /// 固定高度：候选条常驻 + 四排按键。与系统键盘一样不随输入状态变化。
    private func applyHeight() {
        let keyHeight = compact ? Metrics.compactKeyHeight : Metrics.keyHeight
        let keys = 4 * keyHeight + 3 * rowGap
        let inset = view.safeAreaInsets.bottom
        appliedSafeAreaInset = inset
        heightConstraint?.constant = KeyboardTopMetrics.reservedAboveKeys + keys + Metrics.bottomInset + inset
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
        // Even an unchanged file can expire while the host app is suspended.
        // 拼写中候选条由组合驱动，定时刷新不打断用户横滑。
        if composition.isEmpty { renderCandidateBar() }
    }

    // MARK: - 候选条

    /// 候选条内容：反馈 > 拼音候选 > 回复建议。三者共用一行，和系统键盘一样。
    ///
    /// 候选条常驻：没有内容时留空，不收起、不显示占位文字，键盘高度不变。
    private func renderCandidateBar() {
        clear(candidateStack)
        let composing = !composition.isEmpty
        if let feedback, feedback.until > Date() {
            setEqualWidth(false)
            candidateStack.addArrangedSubview(makeMessageLabel(feedback.text))
        } else if composing {
            setEqualWidth(false)
            renderPinyinCandidates()
        } else {
            renderReplyCandidates()
        }
        expandButton.isHidden = !composing
        candidateSeparator.isHidden = !composing
        if !composing, expanded { setExpanded(false) }
        candidateScroll.setContentOffset(.zero, animated: false)
    }

    /// 空输入状态：三条回复建议等宽平铺，样式对齐系统英文键盘的预测条。
    private func renderReplyCandidates() {
        let candidates = bundle.flatMap { $0.isUsable() ? $0 : nil }?
            .candidates.sorted { $0.rank < $1.rank } ?? []
        setEqualWidth(!candidates.isEmpty)
        for (index, candidate) in candidates.enumerated() {
            let button = makeCandidateButton(candidate.text, highlighted: false) { [weak self] in
                self?.insertSuggestion(candidate)
            }
            button.accessibilityLabel = "回复建议\(index + 1)：\(candidate.text)"
            candidateStack.addArrangedSubview(button)
        }
    }

    /// 输入状态：拼音候选横滑，首项白色托底。
    ///
    /// 拼音本身已经以带下划线的标记文本显示在输入框里，和系统一样不在候选条重复；
    /// 只有词库里一个候选都没有时，才把原文放进候选条供直接上屏。
    private func renderPinyinCandidates() {
        for (index, candidate) in pinyinCandidates.prefix(30).enumerated() {
            let button = makeCandidateButton(candidate.text, highlighted: index == 0) { [weak self] in
                self?.choose(candidate)
            }
            button.accessibilityLabel = "拼音候选：\(candidate.text)"
            candidateStack.addArrangedSubview(button)
        }
        if pinyinCandidates.isEmpty {
            let literal = makeCandidateButton(composition, highlighted: true) { [weak self] in
                self?.commitLiteral()
            }
            literal.accessibilityLabel = "直接输入拼音原文：\(composition)"
            candidateStack.addArrangedSubview(literal)
        }
        if expanded { renderGrid() }
    }

    private func setEqualWidth(_ equal: Bool) {
        candidateStack.distribution = equal ? .fillEqually : .fill
        equalWidthConstraint?.isActive = equal
    }

    /// ⌄ 展开：用完整候选网格盖住按键区，和系统一样。
    private func setExpanded(_ value: Bool) {
        expanded = value
        expandButton.setImage(UIImage(systemName: value ? "chevron.up" : "chevron.down"), for: .normal)
        expandButton.accessibilityLabel = value ? "收起候选" : "展开全部候选"
        candidateGrid.isHidden = !value
        keyStack.alpha = value ? 0 : 1
        keyStack.isUserInteractionEnabled = !value
        if value { renderGrid() } else { candidateGrid.setCells([]) }
    }

    private func renderGrid() {
        let cells: [UIView] = pinyinCandidates.prefix(300).map { candidate in
            let button = makeCandidateButton(candidate.text, highlighted: false) { [weak self] in
                self?.choose(candidate)
            }
            button.accessibilityLabel = "拼音候选：\(candidate.text)"
            return button
        }
        candidateGrid.setCells(cells)
    }

    private func showFeedback(_ text: String) {
        feedback = (text, Date().addingTimeInterval(4))
        renderCandidateBar()
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
            showFeedback("建议已更新，请重新选择")
            return
        }
        // 首次点击即确认会话——这是替代原「确认会话」按钮的隐式确认。
        // 仍未确认时只置位，再点一次才插入。
        guard isConfirmed() else {
            markConfirmed()
            renderCandidateBar()
            return
        }
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

    /// 换了输入框：旧输入框里的标记文本不归我们管了，只丢弃键盘侧的组合状态。
    private func resetCompositionIfDocumentChanged() {
        guard let compositionDocumentID,
              compositionDocumentID != textDocumentProxy.documentIdentifier else { return }
        dropComposition()
    }

    /// 丢弃组合，不再碰输入框——用于标记文本已经被宿主拿走或改掉的情况。
    private func dropComposition() {
        composition = ""
        compositionDocumentID = nil
        markedTextActive = false
        markedDisplay = ""
        contextIncludesMarkedText = false
        renderComposition()
    }

    /// 宿主是否还保留着我们的标记文本。
    ///
    /// 用户点了输入框别处、宿主发送后清空输入框等情况下，宿主会自行提交或删掉标记文本，
    /// 键盘这边的组合必须跟着作废，否则下一次按键会在新位置凭空冒出旧拼音。
    private func validateMarkedText() {
        guard markedTextActive, !composition.isEmpty else { return }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        if before.hasSuffix(markedDisplay) {
            contextIncludesMarkedText = true
            return
        }
        // 只有在这个输入框确认过「上下文包含标记文本」后，不匹配才说明被宿主改动
        // （点了别处、发送后清空等）。不包含标记文本的 App 里，空输入框打第一个字母时
        // 上下文本来就是空的，不能据此判断，否则拼音一打就丢。
        if contextIncludesMarkedText { dropComposition() }
    }

    private func renderComposition() {
        pinyinCandidates = composition.isEmpty ? [] : pinyinEngine.candidates(for: composition)
        syncMarkedText()
        spaceButton?.setTitle(composition.isEmpty ? "空格" : "选定", for: .normal)
        enterButton?.setTitle(enterTitle(), for: .normal)
        renderCandidateBar()
    }

    /// 让输入框里的带下划线拼音与当前组合一致。
    private func syncMarkedText() {
        guard !composition.isEmpty else {
            if markedTextActive {
                textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
                textDocumentProxy.unmarkText()
                markedTextActive = false
                markedDisplay = ""
            }
            return
        }
        let display = pinyinEngine.displaySpelling(for: composition)
        guard !markedTextActive || display != markedDisplay else { return }
        textDocumentProxy.setMarkedText(display, selectedRange: NSRange(location: (display as NSString).length, length: 0))
        markedTextActive = true
        markedDisplay = display
    }

    /// 用最终文本替换标记文本并上屏。先把标记内容换成最终文本再解除标记，
    /// 不依赖各 App 对「有标记文本时 insertText」的不同处理。
    private func commitMarkedText(as text: String) {
        if markedTextActive {
            textDocumentProxy.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
            textDocumentProxy.unmarkText()
            markedTextActive = false
            markedDisplay = ""
        } else {
            textDocumentProxy.insertText(text)
        }
    }

    /// 回车键标题。有未上屏的拼音时显示「确认」，否则跟随输入框的回车类型。
    private func enterTitle() -> String {
        if !composition.isEmpty { return "确认" }
        switch textDocumentProxy.returnKeyType {
        case .send: return "发送"
        case .search, .google, .yahoo: return "搜索"
        case .go: return "前往"
        case .done: return "完成"
        case .next: return "下一项"
        case .join: return "加入"
        case .route: return "路线"
        case .continue: return "继续"
        default: return "换行"
        }
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
        // 选中的词上屏；剩余拼音在 renderComposition 里重新设为标记文本（选「西」后剩 `an`）。
        commitMarkedText(as: candidate.text)
        if expanded { setExpanded(false) }
        renderComposition()
    }

    private func commitLiteral() {
        resetCompositionIfDocumentChanged()
        guard !composition.isEmpty else { return }
        // 上屏的是实际键入的字母，不含显示用的音节空格。
        let text = composition
        composition = ""
        compositionDocumentID = nil
        commitMarkedText(as: text)
        renderComposition()
    }

    /// 上屏当前组合：有覆盖整串拼音的候选就选它，否则上屏拼音原文。
    private func commitComposition() {
        guard !composition.isEmpty else { return }
        if let full = pinyinCandidates.first(where: { $0.consumedPinyinCount == composition.count }) {
            choose(full)
        } else {
            commitLiteral()
        }
    }

    private func type(_ text: String) {
        resetCompositionIfDocumentChanged()
        pendingReplace = nil
        let isLetter = text.range(of: "^[a-z]$", options: .regularExpression) != nil
        if layout == .letters, isLetter {
            guard shift == .off else {
                // shift 状态下字母直接以大写英文上屏，不进拼音——系统中文键盘就是这样输英文的。
                commitComposition()
                textDocumentProxy.insertText(text.uppercased())
                if shift == .once { setShift(.off) }
                return
            }
            guard composition.count < 64 else { return }
            compositionDocumentID = textDocumentProxy.documentIdentifier
            composition += text
            renderComposition()
            return
        }
        // 拼写中的 ' 是音节分隔符（xi'an = 西安），并回到字母键盘继续拼。
        if text == "'", !composition.isEmpty {
            if composition.last != "'", composition.count < 64 {
                composition += "'"
                renderComposition()
            }
            if layout != .letters {
                layout = .letters
                rebuildKeys()
            }
            return
        }
        commitComposition()
        textDocumentProxy.insertText(text)
    }

    private func tapShift() {
        let now = Date()
        let doubleTap = lastShiftTap.map { now.timeIntervalSince($0) < Metrics.doubleTapInterval } ?? false
        lastShiftTap = now
        switch shift {
        case .off: setShift(.once)
        case .once: setShift(doubleTap ? .locked : .off)
        case .locked: setShift(.off)
        }
    }

    private func setShift(_ value: Shift) {
        shift = value
        rebuildKeys()
    }

    private func space() {
        resetCompositionIfDocumentChanged()
        if !composition.isEmpty {
            if let first = pinyinCandidates.first { choose(first) } else { commitLiteral() }
        } else {
            textDocumentProxy.insertText(" ")
        }
    }

    /// 回车：有未上屏的拼音时按第一个候选确认，否则换行。
    private func enter() {
        resetCompositionIfDocumentChanged()
        guard !composition.isEmpty else {
            textDocumentProxy.insertText("\n")
            return
        }
        if let first = pinyinCandidates.first { choose(first) } else { commitLiteral() }
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
        commitComposition()
        handleInputModeList(from: sender, with: event)
    }

    /// 切换字母/数字/符号页。拼写中的组合保留，方便从 123 页取 ' 分隔音节。
    private func changeLayout(_ next: Layout) {
        layout = next
        rebuildKeys()
    }

    // MARK: - Key layout

    private func rebuildKeys() {
        stopDeleting()
        clear(keyStack)
        switch layout {
        case .letters:
            let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { row in
                row.map { character -> UIView in
                    let text = String(character)
                    let shown = shift == .off ? text : text.uppercased()
                    let key = makeKey(shown, fontSize: 24)
                    key.accessibilityLabel = shown
                    key.addAction(UIAction { [weak self] _ in self?.type(text) }, for: .touchUpInside)
                    return key
                }
            }
            addRow(rows[0].map { ($0, .units(1)) }, arrangement: .leading)
            addRow(rows[1].map { ($0, .units(1)) }, arrangement: .centered)
            let shiftKey = makeKey("", symbol: shiftSymbol(), accessibility: shiftAccessibility(), modifier: shift == .off)
            shiftKey.addAction(UIAction { [weak self] _ in self?.tapShift() }, for: .touchUpInside)
            addRow([(shiftKey, .units(Metrics.shiftUnits))] + rows[2].map { ($0, .units(1)) }
                   + [(makeDeleteKey(), .units(Metrics.shiftUnits))], arrangement: .pinnedEdges)
        case .numbers, .symbols:
            let rows = layout == .numbers
                ? ["1234567890", "-/：；（）¥@“”", "。，、？！'"]
                : ["[]{}#%^*+=", "_\\|~<>€£$•", ".,?!'"]
            for row in rows.prefix(2) {
                addRow(row.map { (makeCharacterKey(String($0)), .units(1)) }, arrangement: .leading)
            }
            let toggle = makeKey(layout == .numbers ? "#+=" : "123", fontSize: 16, modifier: true)
            toggle.accessibilityLabel = "切换数字符号"
            toggle.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                changeLayout(layout == .numbers ? .symbols : .numbers)
            }, for: .touchUpInside)
            addRow([(toggle, .units(Metrics.shiftUnits))] + rows[2].map { (makeCharacterKey(String($0)), .flex) }
                   + [(makeDeleteKey(), .units(Metrics.shiftUnits))], arrangement: .leading)
        }
        addBottomRow()
    }

    /// 底排：123 / 🌐 / 空格 / 换行，与系统中文键盘一致。
    private func addBottomRow() {
        let mode = makeKey(layout == .letters ? "123" : "拼音", fontSize: 17, modifier: true)
        mode.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            changeLayout(layout == .letters ? .numbers : .letters)
        }, for: .touchUpInside)
        let globe = makeKey("", symbol: "globe", accessibility: "切换输入法", modifier: true)
        globe.addTarget(self, action: #selector(switchInputMode(_:with:)), for: .allTouchEvents)
        globe.isHidden = !needsInputModeSwitchKey
        switchButton = globe
        let space = makeKey(composition.isEmpty ? "空格" : "选定", fontSize: 17)
        space.addAction(UIAction { [weak self] _ in self?.space() }, for: .touchUpInside)
        spaceButton = space
        let enter = makeKey(enterTitle(), fontSize: 17, modifier: true)
        enter.addAction(UIAction { [weak self] _ in self?.enter() }, for: .touchUpInside)
        enterButton = enter
        addRow([(mode, .units(Metrics.modeUnits)), (globe, .units(Metrics.modeUnits)),
                (space, .flex), (enter, .units(Metrics.returnUnits))], arrangement: .leading)
    }

    private func addRow(_ items: [(UIView, KeyRowView.Width)], arrangement: KeyRowView.Arrangement) {
        let row = KeyRowView()
        row.gap = Metrics.keyGap
        row.setItems(items, arrangement: arrangement)
        keyStack.addArrangedSubview(row)
    }

    private func makeCharacterKey(_ text: String) -> UIButton {
        let key = makeKey(text, fontSize: 22)
        key.addAction(UIAction { [weak self] _ in self?.type(text) }, for: .touchUpInside)
        return key
    }

    private func makeDeleteKey() -> UIButton {
        let delete = makeKey("", symbol: "delete.left", accessibility: "删除", modifier: true)
        delete.addAction(UIAction { [weak self] _ in self?.deleteBackward() }, for: .touchUpInside)
        delete.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(repeatDelete(_:))))
        return delete
    }

    private func shiftSymbol() -> String {
        switch shift {
        case .off: return "shift"
        case .once: return "shift.fill"
        case .locked: return "capslock.fill"
        }
    }

    private func shiftAccessibility() -> String {
        switch shift {
        case .off: return "大写"
        case .once: return "大写已开启"
        case .locked: return "大写锁定"
        }
    }

    private func buildLayout() {
        // 透明背景：系统在键盘下方合成毛玻璃，自绘底色会和它叠成一块死灰色。
        view.backgroundColor = .clear

        candidateScroll.showsHorizontalScrollIndicator = false
        candidateScroll.alwaysBounceHorizontal = true
        candidateScroll.addSubview(candidateStack)
        candidateStack.axis = .horizontal
        candidateStack.spacing = 2
        candidateStack.alignment = .center
        candidateStack.translatesAutoresizingMaskIntoConstraints = false
        let contentGuide = candidateScroll.contentLayoutGuide
        let frameGuide = candidateScroll.frameLayoutGuide
        equalWidthConstraint = candidateStack.widthAnchor.constraint(equalTo: frameGuide.widthAnchor, constant: -8)
        NSLayoutConstraint.activate([
            candidateStack.leadingAnchor.constraint(equalTo: contentGuide.leadingAnchor, constant: 4),
            candidateStack.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor, constant: -4),
            candidateStack.topAnchor.constraint(equalTo: contentGuide.topAnchor),
            candidateStack.bottomAnchor.constraint(equalTo: contentGuide.bottomAnchor),
            candidateStack.heightAnchor.constraint(equalTo: frameGuide.heightAnchor)
        ])

        candidateSeparator.backgroundColor = .separator
        expandButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        expandButton.setPreferredSymbolConfiguration(.init(pointSize: 18, weight: .regular), forImageIn: .normal)
        expandButton.tintColor = .label
        expandButton.accessibilityLabel = "展开全部候选"
        expandButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            setExpanded(!expanded)
        }, for: .touchUpInside)

        candidateBar.axis = .horizontal
        candidateBar.alignment = .center
        candidateBar.spacing = 0
        [candidateScroll, candidateSeparator, expandButton].forEach { candidateBar.addArrangedSubview($0) }

        keyStack.axis = .vertical
        keyStack.spacing = rowGap
        keyStack.distribution = .fillEqually

        let root = UIStackView(arrangedSubviews: [candidateBar, keyStack])
        root.axis = .vertical
        root.spacing = KeyboardTopMetrics.candidateBarGap
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        candidateGrid.isHidden = true
        candidateGrid.showsVerticalScrollIndicator = false
        candidateGrid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(candidateGrid)

        // 初值只给一个下界，真正的值在 viewWillAppear 里按安全区定一次。
        let height = view.heightAnchor.constraint(equalToConstant: 216)
        height.priority = .required
        heightConstraint = height
        NSLayoutConstraint.activate([
            height,
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.sideInset),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Metrics.sideInset),
            root.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                                         constant: -Metrics.bottomInset),
            candidateBar.heightAnchor.constraint(equalToConstant: KeyboardTopMetrics.candidateBarHeight),
            candidateScroll.heightAnchor.constraint(equalTo: candidateBar.heightAnchor),
            candidateSeparator.widthAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            candidateSeparator.heightAnchor.constraint(equalToConstant: 28),
            expandButton.widthAnchor.constraint(equalToConstant: 44),
            expandButton.heightAnchor.constraint(equalTo: candidateBar.heightAnchor),
            candidateGrid.topAnchor.constraint(equalTo: keyStack.topAnchor),
            candidateGrid.leadingAnchor.constraint(equalTo: keyStack.leadingAnchor),
            candidateGrid.trailingAnchor.constraint(equalTo: keyStack.trailingAnchor),
            candidateGrid.bottomAnchor.constraint(equalTo: keyStack.bottomAnchor)
        ])
    }

    /// 系统键帽配色：字母键白、功能键灰；按下时两者互换。
    private enum KeyStyle {
        static let plain = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.42, alpha: 1) : .white }
        static let modifier = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.27, alpha: 1) : UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1) }
        /// 候选条首项托底：比键盘底色更亮的白色块。
        static let chip = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.16) : UIColor(white: 1, alpha: 0.78) }
    }

    private func makeKey(_ title: String, symbol: String? = nil, accessibility: String? = nil,
                         fontSize: CGFloat = 18, modifier: Bool = false) -> UIButton {
        let button = UIButton(type: .custom)
        if let symbol {
            button.setImage(UIImage(systemName: symbol), for: .normal)
            button.setPreferredSymbolConfiguration(.init(pointSize: 19, weight: .regular), forImageIn: .normal)
        } else {
            button.setTitle(title, for: .normal)
        }
        button.titleLabel?.font = .systemFont(ofSize: fontSize)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.6
        button.tintColor = .label
        button.setTitleColor(.label, for: .normal)
        let normal = modifier ? KeyStyle.modifier : KeyStyle.plain
        let pressed = modifier ? KeyStyle.plain : KeyStyle.modifier
        button.backgroundColor = normal
        button.addAction(UIAction { [weak button] _ in button?.backgroundColor = pressed }, for: .touchDown)
        for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
            button.addAction(UIAction { [weak button] _ in button?.backgroundColor = normal }, for: event)
        }
        button.layer.cornerRadius = Metrics.cornerRadius
        button.layer.cornerCurve = .continuous
        button.layer.masksToBounds = false
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.3
        button.layer.shadowRadius = 0
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.accessibilityLabel = accessibility ?? title
        return button
    }

    /// 候选条条目：常规字重、统一 label 色；只有首项带白色托底，对齐系统候选条。
    private func makeCandidateButton(_ title: String, highlighted: Bool,
                                     action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        configuration.baseForegroundColor = .label
        configuration.titleLineBreakMode = .byTruncatingTail
        var attributed = AttributedString(title)
        attributed.font = .systemFont(ofSize: 20, weight: .regular)
        configuration.attributedTitle = attributed
        configuration.background.backgroundColor = highlighted ? KeyStyle.chip : .clear
        configuration.background.cornerRadius = 8
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.titleLabel?.numberOfLines = 1
        button.accessibilityLabel = title
        return button
    }

    private func makeMessageLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 15)
        label.textColor = .secondaryLabel
        label.lineBreakMode = .byTruncatingTail
        label.accessibilityLabel = text
        return label
    }

    private func clear(_ stack: UIStackView) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
    }
}
