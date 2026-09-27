import UIKit
import SnapKit

final class PersonaViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let navigationBar = NavigationBar(frame: .zero)
    private var hasPositionedTableView = false

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "人格"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupNavigationBar()
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 90
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: PersonaStore.changed, object: nil)
    }

    private func setupNavigationBar() {
        view.backgroundColor = .systemGroupedBackground
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)
        navigationBar.setHomeTitle(title ?? "人格")
        navigationBar.setContentColor(.label)
        navigationBar.setSecondaryButton(image: UIImage(systemName: "plus"), accessibilityLabel: "添加人格")
        navigationBar.onSecondaryButtonTapped = { [weak self] in self?.addProfile() }
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

    @objc private func reload() { tableView.reloadData() }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { "我的回复预设" }
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        PersonaStore.shared.lastError ?? "点选一项用于后续回复建议；点右侧详情编辑我的人设与回复方式。"
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { PersonaStore.shared.profiles.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let profile = PersonaStore.shared.profiles[indexPath.row]
        let active = profile.id == PersonaStore.shared.activeID
        var content = cell.defaultContentConfiguration()
        content.text = profile.name + (active ? " · 使用中" : "")
        content.secondaryText = [profile.identity, profile.replyStyle].filter { !$0.isEmpty }.joined(separator: "\n")
        content.secondaryTextProperties.numberOfLines = 3
        content.image = UIImage(systemName: active ? "checkmark.circle.fill" : "circle")
        content.imageProperties.tintColor = .galchatPink
        cell.contentConfiguration = content
        cell.accessoryType = .detailButton
        if active { cell.accessibilityTraits.insert(.selected) }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        do { try PersonaStore.shared.select(id: PersonaStore.shared.profiles[indexPath.row].id) }
        catch {
            let alert = UIAlertController(title: "未能切换人格", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "知道了", style: .default))
            present(alert, animated: true)
        }
    }

    func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
        edit(PersonaStore.shared.profiles[indexPath.row])
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard PersonaStore.shared.profiles.count > 1 else { return nil }
        let profile = PersonaStore.shared.profiles[indexPath.row]
        let action = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            completion(false)
            guard let self else { return }
            let message = profile.id == PersonaStore.shared.activeID ? "删除后将使用列表中剩余的第一个预设。" : nil
            let alert = UIAlertController(title: "删除“\(profile.name)”？", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
                do { try PersonaStore.shared.delete(id: profile.id) }
                catch {
                    let failure = UIAlertController(title: "未能删除", message: error.localizedDescription, preferredStyle: .alert)
                    failure.addAction(UIAlertAction(title: "知道了", style: .default))
                    self?.present(failure, animated: true)
                }
            })
            self.present(alert, animated: true)
        }
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    @objc private func addProfile() {
        edit(PersonaStore.Profile(id: UUID().uuidString, name: "", identity: "", replyStyle: ""))
    }

    private func edit(_ profile: PersonaStore.Profile) {
        present(UINavigationController(rootViewController: PersonaEditorViewController(profile: profile)), animated: true)
    }
}

private final class PersonaEditorViewController: ProfileEditorViewController {
    private let profile: PersonaStore.Profile
    private var nameField: UITextView!
    private var identityField: UITextView!
    private var styleField: UITextView!

    init(profile: PersonaStore.Profile) {
        self.profile = profile
        super.init(nibName: nil, bundle: nil)
        title = profile.name.isEmpty ? "新建人格" : "编辑人格"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        nameField = addField("预设名称", value: profile.name, lines: 1)
        identityField = addField("我的人设", value: profile.identity, lines: 5)
        styleField = addField("回复方式", value: profile.replyStyle, lines: 5)
        addHint("写下你的身份、性格、表达习惯与边界。使用中的预设会随聊天上下文发送到你配置的模型服务。")
    }

    override func saveChanges() {
        do {
            try PersonaStore.shared.save(.init(id: profile.id, name: nameField.text, identity: identityField.text, replyStyle: styleField.text))
            dismiss(animated: true)
        } catch { showError(error.localizedDescription) }
    }
}
