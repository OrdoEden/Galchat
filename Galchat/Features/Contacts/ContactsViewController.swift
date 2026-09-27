import UIKit
import SnapKit

final class ContactsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let navigationBar = NavigationBar(frame: .zero)
    private var hasPositionedTableView = false
    private var contacts: [ContactsStore.Contact] = []

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "联系人"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupNavigationBar()
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 76
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: ContactsStore.changed, object: nil)
        reload()
    }

    private func setupNavigationBar() {
        view.backgroundColor = .systemGroupedBackground
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)
        navigationBar.setHomeTitle(title ?? "联系人")
        navigationBar.setContentColor(.label)
        navigationBar.setSecondaryButton(image: UIImage(systemName: "plus"), accessibilityLabel: "添加联系人")
        navigationBar.onSecondaryButtonTapped = { [weak self] in self?.addContact() }
        navigationBar.pinToTop(in: view)
        if #available(iOS 26.0, *) {
            tableView.snp.makeConstraints { $0.edges.equalToSuperview() }
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
        reload()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !hasPositionedTableView, view.window != nil else { return }
        hasPositionedTableView = true
        if #available(iOS 26.0, *) {
            tableView.setContentOffset(CGPoint(x: 0, y: -tableView.adjustedContentInset.top), animated: false)
        }
    }

    @objc private func reload() {
        contacts = ContactsStore.shared.contacts()
        let message = ContactsStore.shared.lastError ?? (contacts.isEmpty ? "还没有联系人\n识别聊天后可建立档案，也可以点右上角添加。" : nil)
        let label = UILabel()
        label.text = message
        label.textAlignment = .center
        label.numberOfLines = 0
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        tableView.backgroundView = message == nil ? nil : label
        tableView.reloadData()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { contacts.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let contact = contacts[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = contact.displayName
        content.secondaryText = "好感度 \(contact.total)" + (contact.note.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? "")
        content.secondaryTextProperties.numberOfLines = 2
        content.image = contact.avatarData.flatMap(UIImage.init(data:)) ?? UIImage(systemName: "person.crop.circle")
        content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
        content.imageProperties.cornerRadius = 22
        content.imageProperties.tintColor = .galchatPink
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(ContactDetailViewController(contactID: contacts[indexPath.row].id), animated: true)
    }

    @objc private func addContact() {
        let alert = UIAlertController(title: "添加联系人", message: "填写聊天中显示的名称。", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "联系人名称" }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "添加", style: .default) { [weak self, weak alert] _ in
            do {
                let contact = try ContactsStore.shared.createProfile(displayName: alert?.textFields?.first?.text ?? "", alias: nil)
                self?.navigationController?.pushViewController(ContactDetailViewController(contactID: contact.id), animated: true)
            } catch { self?.showError(error.localizedDescription) }
        })
        present(alert, animated: true)
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "未能添加", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }
}

final class ContactDetailViewController: UITableViewController {
    private let contactID: String
    private var contact: ContactsStore.Contact? { ContactsStore.shared.contact(id: contactID) }

    init(contactID: String) {
        self.contactID = contactID
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "编辑", style: .plain, target: self, action: #selector(editContact))
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 70
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: ContactsStore.changed, object: nil)
        reload()
    }

    @objc private func reload() {
        title = contact?.displayName ?? "联系人不存在"
        navigationItem.rightBarButtonItem?.isEnabled = contact != nil
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { contact == nil ? 0 : 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 6 : 1 }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        guard let contact else { return cell }
        if indexPath.section == 1 {
            var content = cell.defaultContentConfiguration()
            content.text = "删除联系人"
            content.textProperties.color = .systemRed
            cell.contentConfiguration = content
            cell.accessibilityTraits.insert(.button)
            return cell
        }
        let values = [("头像与名称", contact.displayName), ("备注", contact.note ?? ""), ("对方人设", contact.persona ?? ""),
                      ("当前好感度", "\(contact.total) / 100"), ("识别别名", contact.aliases.joined(separator: "、")), ("聊天记录", "查看与此联系人的上下文")]
        var content = cell.defaultContentConfiguration()
        content.text = values[indexPath.row].0
        content.secondaryText = values[indexPath.row].1.isEmpty ? "未设置" : values[indexPath.row].1
        content.secondaryTextProperties.numberOfLines = 0
        if indexPath.row == 0 {
            content.image = contact.avatarData.flatMap(UIImage.init(data:)) ?? UIImage(systemName: "person.crop.circle")
            content.imageProperties.maximumSize = CGSize(width: 56, height: 56)
            content.imageProperties.cornerRadius = 28
        }
        cell.contentConfiguration = content
        cell.selectionStyle = indexPath.row == 5 ? .default : .none
        cell.accessoryType = indexPath.row == 5 ? .disclosureIndicator : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1 { confirmDelete(); return }
        guard indexPath.row == 5 else { return }
        navigationController?.pushViewController(RecentsViewController(contactID: contactID), animated: true)
    }

    @objc private func editContact() {
        guard let contact else { return }
        present(UINavigationController(rootViewController: ContactEditorViewController(contact: contact)), animated: true)
    }

    private func confirmDelete() {
        let alert = UIAlertController(title: "删除联系人？", message: "将删除联系人档案和好感度记录。最近存档中的聊天正文会保留，并显示为未关联联系人。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                try ContactsStore.shared.deleteProfile(contactID: self.contactID)
                AffectionProjectionPublisher.shared.publishImmediately()
                self.navigationController?.popViewController(animated: true)
            } catch {
                let failure = UIAlertController(title: "未能删除", message: error.localizedDescription, preferredStyle: .alert)
                failure.addAction(UIAlertAction(title: "知道了", style: .default))
                self.present(failure, animated: true)
            }
        })
        present(alert, animated: true)
    }
}
