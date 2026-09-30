import UIKit
import SnapKit

/// 最近会话列表（玻璃档案 C+ · 素白）：按今天 / 昨天 / 更早分段，行直接铺在背景上。
/// 联系人详情的“聊天记录”也复用这个页面，只显示该联系人的会话。
final class RecentsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .grouped)
    private let navigationBar = NavigationBar(frame: .zero)
    private var hasPositionedTableView = false
    private var themeBackground: ThemeBackgroundView?
    private let contactID: String?
    private let store = RecentConversationStore.shared
    private var sections: [(title: String, entries: [RecentConversationStore.Conversation])] = []

    private var isRoot: Bool { navigationController?.viewControllers.first === self }

    init(contactID: String? = nil) {
        self.contactID = contactID
        super.init(nibName: nil, bundle: nil)
        title = contactID == nil ? "最近" : "聊天记录"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        NotificationCenter.default.addObserver(self, selector: #selector(reloadEntries),
                                               name: RecentConversationStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadEntries),
                                               name: ContactsStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: ThemeStore.changed, object: nil)
        reloadEntries()
    }

    private func setupUI() {
        view.backgroundColor = ThemeStore.shared.current.background
        let background = ThemeBackgroundView(theme: ThemeStore.shared.current)
        view.addSubview(background)
        background.snp.makeConstraints { make in make.edges.equalToSuperview() }
        themeBackground = background
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 68
        // 系统分组样式会在每段上下画通栏线；改由单元格自己画内缩的细线。
        tableView.separatorStyle = .none
        tableView.sectionFooterHeight = 0
        tableView.register(RecentConversationCell.self, forCellReuseIdentifier: RecentConversationCell.reuseIdentifier)
        tableView.register(ContactSectionHeaderView.self,
                           forHeaderFooterViewReuseIdentifier: ContactSectionHeaderView.reuseIdentifier)
        view.addSubview(tableView)

        // 联系人详情也会打开此列表，该路径继续使用系统导航栏（iOS 26 上自带玻璃按钮）。
        guard isRoot else {
            let analysisButton = UIBarButtonItem(
                image: UIImage(systemName: "square.and.pencil"), style: .plain,
                target: self, action: #selector(openAnalysis))
            analysisButton.accessibilityLabel = "手动分析"
            navigationItem.rightBarButtonItem = analysisButton
            tableView.snp.makeConstraints { make in make.edges.equalToSuperview() }
            return
        }
        navigationBar.backgroundColor = .clear
        navigationBar.setHomeTitle(title ?? "最近")
        navigationBar.setContentColor(.label)
        navigationBar.setSecondaryButton(
            image: UIImage(systemName: "square.and.pencil"), accessibilityLabel: "手动分析")
        navigationBar.onSecondaryButtonTapped = { [weak self] in self?.openAnalysis() }
        navigationBar.pinToTop(in: view)
        if #available(iOS 26.0, *) {
            tableView.snp.makeConstraints { make in make.edges.equalToSuperview() }
            tableView.contentInset.top = NavigationBar.homeTitleBarHeight
            tableView.verticalScrollIndicatorInsets.top = NavigationBar.homeTitleBarHeight
            navigationBar.attachScrollView(tableView)
        } else {
            tableView.snp.makeConstraints { make in
                make.top.equalTo(navigationBar.snp.bottom)
                make.leading.trailing.bottom.equalToSuperview()
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadEntries()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !hasPositionedTableView, view.window != nil else { return }
        hasPositionedTableView = true
        if #available(iOS 26.0, *), isRoot {
            tableView.setContentOffset(CGPoint(x: 0, y: -tableView.adjustedContentInset.top), animated: false)
        }
    }

    @objc private func reloadEntries() {
        let entries = store.conversations(contactID: contactID)
        let calendar = Calendar.current
        var today: [RecentConversationStore.Conversation] = []
        var yesterday: [RecentConversationStore.Conversation] = []
        var earlier: [RecentConversationStore.Conversation] = []
        for entry in entries {
            if calendar.isDateInToday(entry.updatedAt) { today.append(entry) }
            else if calendar.isDateInYesterday(entry.updatedAt) { yesterday.append(entry) }
            else { earlier.append(entry) }
        }
        sections = [("今天", today), ("昨天", yesterday), ("更早", earlier)].filter { !$0.1.isEmpty }
            .map { (title: $0.0, entries: $0.1) }

        let message = store.lastError ?? (entries.isEmpty
            ? (contactID == nil ? "暂无聊天记录\n点击底部“快速开启”识别聊天\n识别到的文字会保存在这里" : "还没有与此联系人的聊天记录")
            : nil)
        tableView.backgroundView = message.map(Self.messageLabel)
        tableView.tableFooterView = entries.isEmpty ? nil : footerView()
        tableView.reloadData()
    }

    private static func messageLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.text = text
        return label
    }

    private func footerView() -> UIView {
        let label = UILabel()
        label.text = "仅在本机保留最近 100 个会话，每个会话最近 500 条消息，每条最多 2000 字。可左滑删除存档；查看与纠正不会自动发起分析。"
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .tertiaryLabel
        label.numberOfLines = 0
        let container = UIView()
        container.addSubview(label)
        label.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 16, left: 20, bottom: 24, right: 20))
        }
        let width = view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width
        container.frame.size = container.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return container
    }

    /// 换主题：只换背景，内容不用重建。
    @objc private func themeChanged() {
        themeBackground?.removeFromSuperview()
        let background = ThemeBackgroundView(theme: ThemeStore.shared.current)
        view.insertSubview(background, at: 0)
        background.snp.makeConstraints { make in make.edges.equalToSuperview() }
        themeBackground = background
        view.backgroundColor = ThemeStore.shared.current.background
        tableView.reloadData()
    }

    @objc private func openAnalysis() {
        navigationController?.pushViewController(AnalysisViewController(), animated: true)
    }

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].entries.count
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: ContactSectionHeaderView.reuseIdentifier) as? ContactSectionHeaderView
        header?.titleLabel.text = sections[section].title
        return header
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { .leastNonzeroMagnitude }
    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? { UIView() }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: RecentConversationCell.reuseIdentifier,
                                                 for: indexPath) as! RecentConversationCell
        let entry = sections[indexPath.section].entries[indexPath.row]
        cell.configure(entry: entry, contact: ContactsStore.shared.contact(id: entry.contactID))
        cell.separator.isHidden = indexPath.row == sections[indexPath.section].entries.count - 1
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let entry = sections[indexPath.section].entries[indexPath.row]
        navigationController?.pushViewController(RecentConversationViewController(id: entry.id), animated: true)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let id = sections[indexPath.section].entries[indexPath.row].id
        let action = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            do { try self.store.delete(conversationID: id); completion(true) }
            catch { self.showRecentError(error); completion(false) }
        }
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
}

/// 一行会话：头像、名称与状态标签、时间、最后一条消息、好感度。
private final class RecentConversationCell: UITableViewCell {
    static let reuseIdentifier = "RecentConversationCell"

    private let avatar = ContactAvatarView()
    private let nameLabel = UILabel()
    private let tagStack = UIStackView()
    private let timeLabel = UILabel()
    private let previewLabel = UILabel()
    private let affectionLabel = UILabel()
    let separator = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        let selection = UIView()
        selection.backgroundColor = .secondarySystemFill
        selectedBackgroundView = selection

        nameLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timeLabel.font = .systemFont(ofSize: 12)
        timeLabel.textColor = .tertiaryLabel
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        previewLabel.font = .systemFont(ofSize: 14)
        previewLabel.textColor = .secondaryLabel
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        affectionLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        affectionLabel.textColor = .galchatPink
        affectionLabel.setContentHuggingPriority(.required, for: .horizontal)
        affectionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        tagStack.spacing = 4

        let topRow = UIStackView(arrangedSubviews: [nameLabel, tagStack, UIView(), timeLabel])
        topRow.spacing = 6
        topRow.alignment = .center
        let bottomRow = UIStackView(arrangedSubviews: [previewLabel, affectionLabel])
        bottomRow.spacing = 8
        bottomRow.alignment = .center
        let textStack = UIStackView(arrangedSubviews: [topRow, bottomRow])
        textStack.axis = .vertical
        textStack.spacing = 3

        contentView.addSubview(avatar)
        contentView.addSubview(textStack)
        avatar.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(20)
            make.centerY.equalToSuperview()
            make.size.equalTo(44)
            make.top.greaterThanOrEqualToSuperview().inset(10)
        }
        textStack.snp.makeConstraints { make in
            make.leading.equalTo(avatar.snp.trailing).offset(12)
            make.trailing.equalToSuperview().inset(20)
            make.top.bottom.equalToSuperview().inset(11)
        }
        separator.backgroundColor = .separator.withAlphaComponent(0.5)
        contentView.addSubview(separator)
        separator.snp.makeConstraints { make in
            make.leading.equalTo(textStack)
            make.trailing.bottom.equalToSuperview()
            make.height.equalTo(0.5)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(entry: RecentConversationStore.Conversation, contact: ContactsStore.Contact?) {
        let name = contact?.displayName ?? entry.sourceTitle
        nameLabel.text = name
        avatar.configure(name: name, key: contact?.id ?? entry.sourceTitle, imageData: contact?.avatarData)
        timeLabel.text = ContactUI.shortTime(entry.updatedAt)
        let last = entry.messages.last(where: { !$0.isGap })
        previewLabel.text = last.map { "\($0.speakerLabel)：\($0.effectiveText.replacingOccurrences(of: "\n", with: " "))" } ?? "暂无消息"

        tagStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var tags: [String] = []
        if contact == nil {
            tagStack.addArrangedSubview(StatusTagLabel("待确认", kind: .warning)); tags.append("待确认联系人")
        }
        if entry.messages.contains(where: { $0.correction != nil }) {
            tagStack.addArrangedSubview(StatusTagLabel("已纠正", kind: .positive)); tags.append("已纠正")
        }
        if contact?.rupturedUntilResolved == true {
            tagStack.addArrangedSubview(StatusTagLabel("待修复", kind: .negative)); tags.append("关系待修复")
        }
        tagStack.isHidden = tagStack.arrangedSubviews.isEmpty

        if let contact {
            let text = NSMutableAttributedString(attachment: NSTextAttachment(
                image: UIImage(systemName: "heart.fill",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))!
                    .withTintColor(.galchatPink, renderingMode: .alwaysOriginal)))
            text.append(NSAttributedString(string: " \(contact.total)"))
            affectionLabel.attributedText = text
            affectionLabel.isHidden = false
        } else {
            affectionLabel.isHidden = true
        }

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = ([name] + tags + [timeLabel.text ?? "", previewLabel.text ?? ""]
            + (contact.map { ["好感度 \($0.total)"] } ?? [])).joined(separator: "，")
    }
}

/// 会话详情：像 iMessage 一样的只读气泡，一左一右，用来审计识别出的上下文。
/// 点气泡仍是纠正消息；绑定会话归属和发起分析收进导航栏的菜单。
private final class RecentConversationViewController: UITableViewController {
    private let id: String
    private let store = RecentConversationStore.shared
    private var entry: RecentConversationStore.Conversation?

    init(id: String) {
        self.id = id
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.separatorStyle = .none
        tableView.backgroundColor = ThemeStore.shared.current.background
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 24, right: 0)
        tableView.register(MessageBubbleCell.self, forCellReuseIdentifier: MessageBubbleCell.reuseIdentifier)
        tableView.register(ConversationSummaryHeader.self,
                           forHeaderFooterViewReuseIdentifier: ConversationSummaryHeader.reuseIdentifier)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadEntry), name: RecentConversationStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadEntry), name: ContactsStore.changed, object: nil)
        reloadEntry()
    }

    @objc private func reloadEntry() {
        entry = store.conversation(id: id)
        title = ContactsStore.shared.contact(id: entry?.contactID)?.displayName ?? entry?.sourceTitle ?? "会话已删除"
        updateNavigationItems()
        tableView.reloadData()
    }

    private func updateNavigationItems() {
        guard let entry else {
            navigationItem.rightBarButtonItems = nil
            return
        }
        let owner = ContactsStore.shared.contact(id: entry.contactID)
        let ownerAction = UIAction(title: owner?.displayName ?? "待确认联系人",
                                   subtitle: "识别标题：\(entry.sourceTitle)") { [weak self] _ in
            self?.pickOwner()
        }
        let analyze = UIAction(title: "分析此上下文", image: UIImage(systemName: "sparkles")) { [weak self] _ in
            self?.analyze()
        }
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"),
                                   menu: UIMenu(children: [ownerAction, analyze]))
        more.accessibilityLabel = "会话归属与分析"
        navigationItem.rightBarButtonItem = more
    }

    private func pickOwner() {
        let picker = RecentContactPickerViewController { [weak self] contact in
            guard let self else { return }
            try self.store.bind(conversationID: self.id, contactID: contact.id)
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    private func analyze() {
        guard let entry else { return }
        let relationship = AnalysisModelContext.relationship(config: .shared, contactID: entry.contactID)
        navigationController?.pushViewController(
            AnalysisViewController(initialText: entry.analysisText, relationship: relationship), animated: true)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { entry == nil ? 0 : 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entry?.messages.count ?? 0
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: ConversationSummaryHeader.reuseIdentifier)
            as? ConversationSummaryHeader
        header?.label.text = entry.map { "\($0.messages.count) 条消息 · 点气泡可纠正" }
        return header
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 38 }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: MessageBubbleCell.reuseIdentifier, for: indexPath) as! MessageBubbleCell
        if let entry, indexPath.row < entry.messages.count {
            cell.configure(message: entry.messages[indexPath.row],
                           contact: ContactsStore.shared.contact(id: entry.contactID))
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let entry, indexPath.row < entry.messages.count else { return }
        let message = entry.messages[indexPath.row]
        guard !message.isGap else { return }
        let editor = RecentMessageEditorViewController(conversationID: id, message: message)
        let navigation = UINavigationController(rootViewController: editor)
        navigation.modalPresentationStyle = .pageSheet
        present(navigation, animated: true)
    }
}

/// 一条消息气泡：对方在左、自己在右，缺口画成居中的分隔线。
private final class MessageBubbleCell: UITableViewCell {
    static let reuseIdentifier = "MessageBubbleCell"

    private let bubble = UIView()
    private let avatar = ContactAvatarView()
    private let label = UILabel()
    private let meta = UILabel()
    private let gapLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        meta.font = .systemFont(ofSize: 11)
        meta.textColor = .tertiaryLabel
        meta.numberOfLines = 1
        bubble.layer.cornerRadius = 18
        bubble.layer.cornerCurve = .continuous
        bubble.addSubview(label)
        label.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12))
        }
        avatar.isHidden = true
        gapLabel.font = .preferredFont(forTextStyle: .footnote)
        gapLabel.textColor = .tertiaryLabel
        gapLabel.textAlignment = .center
        gapLabel.numberOfLines = 0
        contentView.addSubview(gapLabel)
        gapLabel.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 6, left: 40, bottom: 6, right: 40))
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(message: RecentConversationStore.Message, contact: ContactsStore.Contact?) {
        if message.isGap {
            gapLabel.isHidden = false
            gapLabel.text = "— \(message.effectiveText) —"
            return
        }
        gapLabel.isHidden = true

        let isOther = message.effectiveSpeaker != .me
        var text = message.effectiveText
        if message.clipped && message.correction == nil { text += "（原消息被裁切）" }
        label.text = text
        bubble.backgroundColor = isOther ? .secondarySystemBackground : .galchatPink
        label.textColor = isOther ? .label : .white
        meta.text = message.correction != nil ? "\(message.speakerLabel) · 已纠正" : message.speakerLabel
        meta.textAlignment = isOther ? .left : .right

        avatar.isHidden = !isOther
        if isOther {
            avatar.configure(name: contact?.displayName ?? "对方", key: contact?.id ?? "other",
                             imageData: contact?.avatarData)
        }

        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .bottom
        row.spacing = 8
        if isOther {
            avatar.snp.makeConstraints { make in make.size.equalTo(28) }
            row.addArrangedSubview(avatar)
            row.addArrangedSubview(bubble)
            row.addArrangedSubview(UIView())
        } else {
            row.addArrangedSubview(UIView())
            row.addArrangedSubview(bubble)
        }
        let column = UIStackView(arrangedSubviews: [row, meta])
        column.axis = .vertical
        column.spacing = 3
        column.isUserInteractionEnabled = false
        contentView.addSubview(column)
        column.snp.makeConstraints { make in
            make.top.equalToSuperview().inset(3)
            make.bottom.equalToSuperview().inset(3)
            if isOther {
                make.leading.equalToSuperview().inset(14)
                make.trailing.lessThanOrEqualToSuperview().inset(56)
            } else {
                make.trailing.equalToSuperview().inset(14)
                make.leading.greaterThanOrEqualToSuperview().inset(56)
            }
        }
        bubble.snp.makeConstraints { make in make.width.lessThanOrEqualToSuperview().multipliedBy(0.78) }
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "\(message.speakerLabel)：\(text)"
        accessibilityHint = "点按纠正这条消息"
    }
}

/// 气泡上方的说明：一共多少条、能点什么。
private final class ConversationSummaryHeader: UITableViewHeaderFooterView {
    static let reuseIdentifier = "ConversationSummaryHeader"
    let label = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        contentView.addSubview(label)
        label.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.greaterThanOrEqualToSuperview().inset(20)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class RecentContactPickerViewController: UITableViewController {
    private var contacts: [ContactsStore.Contact] = []
    private let onSelect: (ContactsStore.Contact) throws -> Void

    init(onSelect: @escaping (ContactsStore.Contact) throws -> Void) {
        self.onSelect = onSelect
        super.init(style: .insetGrouped)
        title = "选择联系人"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        contacts = ContactsStore.shared.contacts()
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "新建", style: .plain, target: self, action: #selector(create))
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { contacts.count }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        contacts.isEmpty ? "暂无联系人，可点击右上角新建档案。" : "绑定仅针对这段会话；如果它正在识别，将同步更新其联系人归属。已有识别别名保持不变。"
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let contact = contacts[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = contact.displayName
        content.secondaryText = contact.note
        cell.contentConfiguration = content
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let contact = contacts[indexPath.row]
        do {
            try onSelect(contact)
            navigationController?.popViewController(animated: true)
        } catch { showRecentError(error) }
    }
    @objc private func create() {
        let alert = UIAlertController(title: "新建联系人", message: "创建后会绑定此会话；头像、人设及别名可在联系人档案完善。", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "联系人名称" }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "创建", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            do {
                let contact = try ContactsStore.shared.createProfile(displayName: alert?.textFields?.first?.text ?? "", alias: nil)
                self.contacts = ContactsStore.shared.contacts()
                self.tableView.reloadData()
                try self.onSelect(contact)
                self.navigationController?.popViewController(animated: true)
            } catch { self.showRecentError(error) }
        })
        present(alert, animated: true)
    }
}

private final class RecentMessageEditorViewController: UIViewController, UITextViewDelegate, UIAdaptivePresentationControllerDelegate {
    private let conversationID: String
    private let message: RecentConversationStore.Message
    private let speakerControl = UISegmentedControl(items: ["我", "对方", "未知"])
    private let textView = UITextView()
    private var hasChanges: Bool {
        let speaker: Speaker = speakerControl.selectedSegmentIndex == 0 ? .me : speakerControl.selectedSegmentIndex == 1 ? .other : .unknown
        return speaker != message.effectiveSpeaker || textView.text != message.effectiveText
    }

    init(conversationID: String, message: RecentConversationStore.Message) {
        self.conversationID = conversationID
        self.message = message
        super.init(nibName: nil, bundle: nil)
        title = "纠正消息"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(save))
        speakerControl.selectedSegmentIndex = message.effectiveSpeaker == .me ? 0 : message.effectiveSpeaker == .other ? 1 : 2
        speakerControl.accessibilityLabel = "消息发言方"
        speakerControl.addTarget(self, action: #selector(updateDismissProtection), for: .valueChanged)
        textView.text = message.effectiveText
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.layer.cornerRadius = 12
        textView.accessibilityLabel = "消息内容"
        textView.delegate = self
        let original = UITextView()
        original.isEditable = false
        original.font = .preferredFont(forTextStyle: .footnote)
        original.adjustsFontForContentSizeCategory = true
        original.textColor = .secondaryLabel
        original.backgroundColor = .clear
        let sourceSpeaker = Speaker(rawValue: message.speakerRaw) == .me ? "我" : Speaker(rawValue: message.speakerRaw) == .other ? "对方" : "未知"
        original.text = "OCR 原文（\(sourceSpeaker)）：\n\(message.text)\n\n最多保存 2000 字。纠正将用于此会话后续上下文；保存本身不发起模型请求。"
        let restore = UIButton(type: .system)
        restore.setTitle("恢复 OCR 原文", for: .normal)
        restore.isEnabled = message.correction != nil
        restore.addTarget(self, action: #selector(restoreOriginal), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [speakerControl, textView, original, restore])
        stack.axis = .vertical
        stack.spacing = 16
        view.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top).offset(20)
            make.leading.trailing.equalToSuperview().inset(20)
            make.bottom.equalTo(view.keyboardLayoutGuide.snp.top).offset(-12)
        }
        textView.snp.makeConstraints { make in
            make.height.equalTo(original).multipliedBy(1.5)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.presentationController?.delegate = self
    }

    func textViewDidChange(_ textView: UITextView) { updateDismissProtection() }

    @objc private func updateDismissProtection() {
        navigationController?.isModalInPresentation = hasChanges
    }

    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) { close() }

    @objc private func close() {
        guard hasChanges else { dismiss(animated: true); return }
        let alert = UIAlertController(title: "放弃未保存的纠正？", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "继续编辑", style: .cancel))
        alert.addAction(UIAlertAction(title: "放弃修改", style: .destructive) { [weak self] _ in self?.dismiss(animated: true) })
        present(alert, animated: true)
    }
    @objc private func save() {
        do {
            let speaker: Speaker = speakerControl.selectedSegmentIndex == 0 ? .me : speakerControl.selectedSegmentIndex == 1 ? .other : .unknown
            try RecentConversationStore.shared.correct(conversationID: conversationID, messageID: message.id, speaker: speaker, text: textView.text)
            dismiss(animated: true)
        } catch { showRecentError(error) }
    }
    @objc private func restoreOriginal() {
        do {
            try RecentConversationStore.shared.restore(conversationID: conversationID, messageID: message.id)
            dismiss(animated: true)
        } catch { showRecentError(error) }
    }
}

private extension UIViewController {
    func showRecentError(_ error: Error) {
        let alert = UIAlertController(title: "未能保存", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}
