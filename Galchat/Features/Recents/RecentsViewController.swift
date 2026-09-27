import UIKit
import SnapKit

final class RecentsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let navigationBar = NavigationBar(frame: .zero)
    private var hasPositionedTableView = false
    private let contactID: String?
    private let store = RecentConversationStore.shared
    private var entries: [RecentConversationStore.Conversation] = []

    init(contactID: String? = nil) {
        self.contactID = contactID
        super.init(nibName: nil, bundle: nil)
        title = contactID == nil ? "最近" : "聊天记录"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 96
        NotificationCenter.default.addObserver(self, selector: #selector(reloadEntries),
                                               name: RecentConversationStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadEntries),
                                               name: ContactsStore.changed, object: nil)
        reloadEntries()
    }

    private func setupUI() {
        view.backgroundColor = .systemGroupedBackground
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)

        // 联系人详情也会打开此列表，该路径继续使用系统返回按钮。
        guard navigationController?.viewControllers.first === self else {
            let analysisButton = UIBarButtonItem(
                image: UIImage(systemName: "square.and.pencil"),
                style: .plain,
                target: self,
                action: #selector(openAnalysis)
            )
            analysisButton.accessibilityLabel = "手动分析"
            navigationItem.rightBarButtonItem = analysisButton
            tableView.snp.makeConstraints {
                $0.top.equalTo(view.safeAreaLayoutGuide.snp.top)
                $0.leading.trailing.bottom.equalToSuperview()
            }
            return
        }

        navigationBar.setHomeTitle(title ?? "最近")
        navigationBar.setContentColor(.label)
        navigationBar.setSecondaryButton(
            image: UIImage(systemName: "square.and.pencil"), accessibilityLabel: "手动分析"
        )
        navigationBar.onSecondaryButtonTapped = { [weak self] in self?.openAnalysis() }
        navigationBar.pinToTop(in: view)

        if #available(iOS 26.0, *) {
            tableView.snp.makeConstraints { $0.edges.equalToSuperview() }
            tableView.contentInset.top = NavigationBar.homeTitleBarHeight
            tableView.verticalScrollIndicatorInsets.top = NavigationBar.homeTitleBarHeight
            navigationBar.attachScrollView(tableView)
        } else {
            tableView.snp.makeConstraints {
                $0.top.equalTo(navigationBar.snp.bottom)
                $0.leading.trailing.bottom.equalToSuperview()
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
        if #available(iOS 26.0, *), navigationController?.viewControllers.first === self {
            tableView.setContentOffset(CGPoint(x: 0, y: -tableView.adjustedContentInset.top), animated: false)
        }
    }

    @objc private func reloadEntries() {
        entries = store.conversations(contactID: contactID)
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.text = store.lastError ?? (entries.isEmpty ? "暂无聊天记录\n点击底部“快速开启”识别聊天\n识别到的文字会保存在这里" : nil)
        tableView.backgroundView = label.text == nil ? nil : label
        tableView.reloadData()
    }

    @objc private func openAnalysis() {
        navigationController?.pushViewController(AnalysisViewController(), animated: true)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { entries.count }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "仅在本机保留最近 100 个会话，每个会话最近 500 条消息，每条最多 2000 字。可左滑删除存档；查看与纠正不会自动发起分析。"
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let entry = entries[indexPath.row]
        let contact = ContactsStore.shared.contact(id: entry.contactID)
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = contact?.displayName ?? "\(entry.sourceTitle) · 待确认"
        let date = entry.updatedAt.formatted(date: .abbreviated, time: .shortened)
        let preview = entry.messages.last(where: { !$0.isGap }).map { "\($0.speakerLabel)：\($0.effectiveText)" } ?? "暂无消息"
        content.secondaryText = "\(date)\n\(preview)"
        content.secondaryTextProperties.numberOfLines = 3
        content.secondaryTextProperties.color = .secondaryLabel
        content.image = contact?.avatarData.flatMap { UIImage(data: $0) } ?? UIImage(systemName: "person.crop.circle.fill")
        content.imageProperties.maximumSize = CGSize(width: 42, height: 42)
        content.imageProperties.cornerRadius = 21
        content.imageProperties.tintColor = .galchatPink
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(RecentConversationViewController(id: entries[indexPath.row].id), animated: true)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let id = entries[indexPath.row].id
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

private final class RecentConversationViewController: UITableViewController {
    private let id: String
    private let store = RecentConversationStore.shared
    private var entry: RecentConversationStore.Conversation?

    init(id: String) {
        self.id = id
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 88
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "分析", style: .plain, target: self, action: #selector(analyze))
        NotificationCenter.default.addObserver(self, selector: #selector(reloadEntry), name: RecentConversationStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadEntry), name: ContactsStore.changed, object: nil)
        reloadEntry()
    }

    @objc private func reloadEntry() {
        entry = store.conversation(id: id)
        title = ContactsStore.shared.contact(id: entry?.contactID)?.displayName ?? entry?.sourceTitle ?? "会话已删除"
        navigationItem.rightBarButtonItem?.isEnabled = entry != nil
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { entry == nil ? 0 : 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : (entry?.messages.count ?? 0)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "会话归属" : "聊天上下文 · 点按消息纠正"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 { return "绑定仅修改此会话归属；以后自动识别所需的名称与别名可在联系人档案维护。" }
        return "人工纠正会保留 OCR 原文，可随时恢复。这里的保存不会自动请求模型或更新好感度；点右上角“分析”后可预览并手动发起分析。"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        guard let entry else { return cell }
        var content = cell.defaultContentConfiguration()
        if indexPath.section == 0 {
            content.text = ContactsStore.shared.contact(id: entry.contactID)?.displayName ?? "待确认联系人"
            content.secondaryText = "识别标题：\(entry.sourceTitle)"
            content.image = UIImage(systemName: "person.crop.circle")
            cell.accessoryType = .disclosureIndicator
        } else {
            let message = entry.messages[indexPath.row]
            content.text = message.isGap ? "上下文缺口" : message.speakerLabel
            if message.correction != nil { content.text! += " · 已纠正" }
            else if message.clipped { content.text! += " · 原消息被裁切" }
            content.secondaryText = message.effectiveText
            content.secondaryTextProperties.numberOfLines = 0
            cell.selectionStyle = message.isGap ? .none : .default
            cell.accessoryType = message.isGap ? .none : .disclosureIndicator
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let entry else { return }
        if indexPath.section == 0 {
            let picker = RecentContactPickerViewController { [weak self] contact in
                guard let self else { return }
                try self.store.bind(conversationID: self.id, contactID: contact.id)
            }
            navigationController?.pushViewController(picker, animated: true)
        } else {
            let message = entry.messages[indexPath.row]
            guard !message.isGap else { return }
            let editor = RecentMessageEditorViewController(conversationID: id, message: message)
            let navigation = UINavigationController(rootViewController: editor)
            navigation.modalPresentationStyle = .pageSheet
            present(navigation, animated: true)
        }
    }

    @objc private func analyze() {
        guard let entry else { return }
        let relationship = AnalysisModelContext.relationship(config: .shared, contactID: entry.contactID)
        navigationController?.pushViewController(
            AnalysisViewController(initialText: entry.analysisText, relationship: relationship), animated: true)
    }
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
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
            textView.heightAnchor.constraint(equalTo: original.heightAnchor, multiplier: 1.5),
        ])
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
