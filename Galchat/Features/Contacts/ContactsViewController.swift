import UIKit
import SnapKit

/// 联系人列表（玻璃档案 C+ · 素白）：搜索框、常聊、按拼音分组的列表与右侧字母索引。
/// 每个头像外圈是好感度圆环。
final class ContactsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchTextFieldDelegate {
    private let tableView = UITableView(frame: .zero, style: .grouped)
    private let navigationBar = NavigationBar(frame: .zero)
    private let headerView = UIView()
    private let searchField = UISearchTextField()
    private let favoritesTitle = UILabel()
    private let favoritesStack = UIStackView()
    private let headerStack = UIStackView()
    private var favoritesTitleWrapper: UIView?
    private var hasPositionedTableView = false
    private var themeBackground: ThemeBackgroundView?
    private var lastHeaderWidth: CGFloat = 0

    private var contacts: [ContactsStore.Contact] = []
    private var sections: [(letter: String, contacts: [ContactsStore.Contact])] = []
    private var query: String { searchField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "联系人"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: ContactsStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: ThemeStore.changed, object: nil)
        reload()
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
        tableView.keyboardDismissMode = .onDrag
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        // 系统分组样式会在每段上下画通栏线；改由单元格自己画内缩的细线。
        tableView.separatorStyle = .none
        tableView.sectionIndexColor = .galchatPink
        tableView.sectionIndexBackgroundColor = .clear
        tableView.register(ContactRowCell.self, forCellReuseIdentifier: ContactRowCell.reuseIdentifier)
        tableView.register(ContactSectionHeaderView.self,
                           forHeaderFooterViewReuseIdentifier: ContactSectionHeaderView.reuseIdentifier)
        view.addSubview(tableView)
        setupHeader()

        navigationBar.backgroundColor = .clear
        navigationBar.setHomeTitle(title ?? "联系人")
        navigationBar.setContentColor(.label)
        navigationBar.setSecondaryButton(image: UIImage(systemName: "plus"), accessibilityLabel: "添加联系人")
        navigationBar.onSecondaryButtonTapped = { [weak self] in self?.addContact() }
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

    private func setupHeader() {
        let searchContainer = UIView()
        let glass = ContactUI.glassBackground(cornerRadius: 20)
        searchContainer.addSubview(glass)
        glass.snp.makeConstraints { make in make.edges.equalToSuperview() }
        searchField.placeholder = "搜索名称、别名或备注"
        searchField.backgroundColor = .clear
        searchField.borderStyle = .none
        searchField.font = .preferredFont(forTextStyle: .body)
        searchField.adjustsFontForContentSizeCategory = true
        searchField.returnKeyType = .search
        searchField.delegate = self
        searchField.accessibilityLabel = "搜索联系人"
        searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        searchContainer.addSubview(searchField)
        searchField.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(8)
            make.top.bottom.equalToSuperview()
        }

        favoritesTitle.text = "常聊"
        favoritesTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        favoritesTitle.textColor = .secondaryLabel
        favoritesTitle.accessibilityTraits = .header
        favoritesStack.distribution = .fillEqually
        favoritesStack.alignment = .top
        favoritesStack.spacing = 10

        searchContainer.snp.makeConstraints { make in make.height.equalTo(40) }
        let titleWrapper = UIView()
        titleWrapper.addSubview(favoritesTitle)
        favoritesTitle.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview()
            make.leading.equalToSuperview().inset(4)
        }
        headerStack.axis = .vertical
        headerStack.spacing = 8
        headerStack.addArrangedSubview(searchContainer)
        headerStack.addArrangedSubview(titleWrapper)
        headerStack.addArrangedSubview(favoritesStack)
        headerStack.setCustomSpacing(16, after: searchContainer)
        favoritesTitleWrapper = titleWrapper
        headerView.addSubview(headerStack)
        headerStack.snp.makeConstraints { make in
            make.top.equalToSuperview().inset(8)
            make.leading.trailing.equalToSuperview().inset(16)
            make.bottom.equalToSuperview().inset(4)
        }
        tableView.tableHeaderView = headerView
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if tableView.bounds.width != lastHeaderWidth { sizeHeader() }
        guard !hasPositionedTableView, view.window != nil else { return }
        hasPositionedTableView = true
        if #available(iOS 26.0, *) {
            tableView.setContentOffset(CGPoint(x: 0, y: -tableView.adjustedContentInset.top), animated: false)
        }
    }

    /// 表头高度随“常聊”显示与否变化，需要手动计算。
    private func sizeHeader() {
        lastHeaderWidth = tableView.bounds.width
        guard lastHeaderWidth > 0 else { return }
        let height = headerView.systemLayoutSizeFitting(
            CGSize(width: lastHeaderWidth, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        headerView.frame = CGRect(x: 0, y: 0, width: lastHeaderWidth, height: height)
        tableView.tableHeaderView = headerView
    }

    @objc private func reload() {
        contacts = ContactsStore.shared.contacts()
        rebuildFavorites()
        applyFilter()
    }

    @objc private func searchChanged() { applyFilter() }

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

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    private func applyFilter() {
        let query = query.lowercased()
        let matched = query.isEmpty ? contacts : contacts.filter { contact in
            ([contact.displayName, contact.note ?? ""] + contact.aliases).contains { $0.lowercased().contains(query) }
                || ContactUI.sortKey(for: contact.displayName).replacingOccurrences(of: " ", with: "").contains(query)
        }
        var groups: [String: [ContactsStore.Contact]] = [:]
        for contact in matched { groups[ContactUI.indexLetter(for: contact.displayName), default: []].append(contact) }
        sections = groups.keys.sorted { lhs, rhs in
            lhs == "#" ? false : rhs == "#" ? true : lhs < rhs
        }.map { letter in
            (letter, groups[letter]!.sorted { ContactUI.sortKey(for: $0.displayName) < ContactUI.sortKey(for: $1.displayName) })
        }

        let hideFavorites = !query.isEmpty || contacts.count < 2
        if favoritesStack.isHidden != hideFavorites {
            favoritesStack.isHidden = hideFavorites
            favoritesTitleWrapper?.isHidden = hideFavorites
            sizeHeader()
        }

        let message = ContactsStore.shared.lastError
            ?? (contacts.isEmpty ? "还没有联系人\n识别聊天后可建立档案，也可以点右上角添加。"
                : matched.isEmpty ? "没有找到“\(self.query)”" : nil)
        tableView.backgroundView = message.map { text in
            let label = UILabel()
            label.text = text
            label.textAlignment = .center
            label.numberOfLines = 0
            label.textColor = .secondaryLabel
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            return label
        }
        tableView.reloadData()
    }

    private func rebuildFavorites() {
        favoritesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let favorites = contacts.sorted { $0.total > $1.total }.prefix(4)
        for contact in favorites {
            let item = FavoriteContactCard(contact: contact, illustration: ContactsStore.shared.illustration(for: contact.id))
            item.addAction(UIAction { [weak self] _ in self?.openDetail(contact.id) }, for: .touchUpInside)
            favoritesStack.addArrangedSubview(item)
        }
        // 不足四个时补空位，保持每个头像宽度一致。
        for _ in favorites.count..<4 { favoritesStack.addArrangedSubview(UIView()) }
        lastHeaderWidth = 0
        view.setNeedsLayout()
    }

    private func openDetail(_ id: String) {
        navigationController?.pushViewController(ContactDetailViewController(contactID: id), animated: true)
    }

    // MARK: - 列表

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].contacts.count }

    func sectionIndexTitles(for tableView: UITableView) -> [String]? {
        sections.count > 1 ? sections.map(\.letter) : nil
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: ContactSectionHeaderView.reuseIdentifier) as? ContactSectionHeaderView
        header?.titleLabel.text = sections[section].letter
        return header
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { .leastNonzeroMagnitude }
    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? { UIView() }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ContactRowCell.reuseIdentifier, for: indexPath) as! ContactRowCell
        let contact = sections[indexPath.section].contacts[indexPath.row]
        cell.configure(contact: contact, isActive: ContactsStore.shared.activeContact?.id == contact.id)
        cell.separator.isHidden = indexPath.row == sections[indexPath.section].contacts.count - 1
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        openDetail(sections[indexPath.section].contacts[indexPath.row].id)
    }

    // MARK: - 添加

    @objc private func addContact() {
        let alert = UIAlertController(title: "添加联系人", message: "填写聊天中显示的名称。", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "联系人名称" }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "添加", style: .default) { [weak self, weak alert] _ in
            do {
                let contact = try ContactsStore.shared.createProfile(displayName: alert?.textFields?.first?.text ?? "", alias: nil)
                self?.openDetail(contact.id)
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

// MARK: - 列表组件

/// “常聊”卡片：有立绘铺立绘；否则用头像的模糊色（没有头像用配色）做底，中间放头像。
/// 好感度只看底部居中的玻璃标签，卡片里的头像不再加好感环。
private final class FavoriteContactCard: UIControl {
    init(contact: ContactsStore.Contact, illustration: UIImage?) {
        super.init(frame: .zero)
        let card = UIView()
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.isUserInteractionEnabled = false

        if let illustration {
            let art = UIImageView(image: illustration)
            art.contentMode = .scaleAspectFill
            card.addSubview(art)
            art.snp.makeConstraints { make in make.edges.equalToSuperview() }
        } else {
            if let avatarImage = contact.avatarData.flatMap(UIImage.init(data:)) {
                let backdrop = UIImageView(image: avatarImage)
                backdrop.contentMode = .scaleAspectFill
                let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialLight))
                card.addSubview(backdrop)
                card.addSubview(blur)
                backdrop.snp.makeConstraints { make in make.edges.equalToSuperview().inset(-20) }
                blur.snp.makeConstraints { make in make.edges.equalToSuperview() }
            } else {
                card.backgroundColor = ContactUI.gradient(for: contact.id).top.withAlphaComponent(0.45)
            }
            let avatar = ContactAvatarView()
            avatar.configure(name: contact.displayName, key: contact.id, imageData: contact.avatarData, initials: 2)
            card.addSubview(avatar)
            avatar.snp.makeConstraints { make in
                make.centerX.equalToSuperview()
                make.top.equalToSuperview().inset(10)
                make.width.equalToSuperview().multipliedBy(0.68)
                make.height.equalTo(avatar.snp.width)
            }
        }

        let pill = AffectionPillView(fontSize: 12)
        pill.setScore(contact.total)
        card.addSubview(pill)
        pill.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalToSuperview().inset(8)
        }

        let name = UILabel()
        name.text = contact.displayName
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [card, name])
        stack.axis = .vertical
        stack.spacing = 6
        stack.isUserInteractionEnabled = false
        addSubview(stack)
        stack.snp.makeConstraints { make in make.edges.equalToSuperview() }
        card.snp.makeConstraints { make in make.height.equalTo(card.snp.width).multipliedBy(76.0 / 54.0) }
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 4)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "\(contact.displayName)，好感度 \(contact.total)"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.7 : 1 }
    }
}

private final class ContactRowCell: UITableViewCell {
    static let reuseIdentifier = "ContactRowCell"

    private let ring = AffectionRingAvatarView()
    private let nameLabel = UILabel()
    private let tagStack = UIStackView()
    private let noteLabel = UILabel()
    private let scoreLabel = UILabel()
    let separator = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        let selection = UIView()
        selection.backgroundColor = .secondarySystemFill
        selectedBackgroundView = selection
        nameLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noteLabel.font = .systemFont(ofSize: 13.5)
        noteLabel.textColor = .secondaryLabel
        scoreLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        scoreLabel.textColor = .tertiaryLabel
        scoreLabel.setContentHuggingPriority(.required, for: .horizontal)
        scoreLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        tagStack.spacing = 4

        let nameRow = UIStackView(arrangedSubviews: [nameLabel, tagStack, UIView()])
        nameRow.spacing = 6
        nameRow.alignment = .center
        let textStack = UIStackView(arrangedSubviews: [nameRow, noteLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        contentView.addSubview(ring)
        contentView.addSubview(textStack)
        contentView.addSubview(scoreLabel)
        ring.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(20)
            make.centerY.equalToSuperview()
            make.size.equalTo(46)
            make.top.greaterThanOrEqualToSuperview().inset(8)
        }
        textStack.snp.makeConstraints { make in
            make.leading.equalTo(ring.snp.trailing).offset(14)
            make.top.bottom.equalToSuperview().inset(11)
            make.trailing.lessThanOrEqualTo(scoreLabel.snp.leading).offset(-8)
        }
        scoreLabel.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(16)
            make.centerY.equalToSuperview()
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

    func configure(contact: ContactsStore.Contact, isActive: Bool) {
        ring.configure(contact: contact)
        nameLabel.text = contact.displayName
        let note = contact.note?.isEmpty == false ? contact.note! : "未设置备注"
        noteLabel.text = note
        scoreLabel.text = "\(contact.total)"
        tagStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var tags: [String] = []
        if isActive { tagStack.addArrangedSubview(StatusTagLabel("在聊", kind: .accent)); tags.append("正在聊") }
        if contact.rupturedUntilResolved {
            tagStack.addArrangedSubview(StatusTagLabel("待修复", kind: .negative)); tags.append("关系待修复")
        }
        tagStack.isHidden = tags.isEmpty
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = ([contact.displayName] + tags + [note, "好感度 \(contact.total)"]).joined(separator: "，")
    }
}
