import UIKit

/// 人格库：列出 GitHub 上可下载的人格，获取、更新都在这里完成。
final class PersonaLibraryViewController: UITableViewController {
    private var thumbnails: [String: UIImage] = [:]
    private var loadingThumbnails: Set<String> = []

    init() {
        super.init(style: .insetGrouped)
        title = "人格库"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 88
        refreshControl = UIRefreshControl()
        refreshControl?.addAction(UIAction { _ in ResourceCatalog.shared.refresh() }, for: .valueChanged)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: ResourceCatalog.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: PersonaStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: PromptStore.changed, object: nil)
        ResourceCatalog.shared.refresh()
    }

    private var items: [ResourceCatalog.Item] { ResourceCatalog.shared.items }

    @objc private func reload() {
        if !ResourceCatalog.shared.isRefreshing { refreshControl?.endRefreshing() }
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        let catalog = ResourceCatalog.shared
        var lines: [String] = []
        if let error = catalog.lastError {
            lines.append(error)
        } else if catalog.isRefreshing && items.isEmpty {
            lines.append("正在读取人格库…")
        } else if items.isEmpty {
            lines.append("人格库暂时没有可下载的人格。")
        }
        lines.append("来源：\(ResourceCatalog.sourceDescription)。下载的人格会随人格库自动更新（在本机编辑过的除外）；被人格库下架的人格会从本机移除。")
        lines.append("判断题目（Jev）版本 \(PromptStore.current.version)，同样随资源库自动更新。")
        return lines.joined(separator: "\n\n")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = items[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = item.entry.name
        content.secondaryText = item.entry.summary
        content.secondaryTextProperties.numberOfLines = 3
        content.secondaryTextProperties.color = .secondaryLabel
        content.image = thumbnail(for: item)
        content.imageProperties.maximumSize = CGSize(width: 48, height: 64)
        content.imageProperties.reservedLayoutSize = CGSize(width: 48, height: 64)
        content.imageProperties.cornerRadius = 10
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        cell.accessoryView = accessory(for: item)
        return cell
    }

    // MARK: 状态按钮

    private enum State {
        case available, installing, installed, update
    }

    private func state(of item: ResourceCatalog.Item) -> State {
        if ResourceCatalog.shared.isInstalling(item.entry.id) { return .installing }
        guard let installed = PersonaStore.shared.profiles.first(where: { $0.id == item.entry.id }) else { return .available }
        return PersonaPackage.isVersion(item.entry.version, newerThan: installed.manifest.version) ? .update : .installed
    }

    private func accessory(for item: ResourceCatalog.Item) -> UIView {
        let state = state(of: item)
        if state == .installing {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            return spinner
        }
        var configuration: UIButton.Configuration = state == .installed ? .gray() : .tinted()
        configuration.title = state == .installed ? "已安装" : (state == .update ? "更新" : "获取")
        configuration.cornerStyle = .capsule
        configuration.buttonSize = .small
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.install(item)
        })
        button.isEnabled = state != .installed
        button.accessibilityLabel = "\(configuration.title ?? "")\(item.entry.name)"
        button.sizeToFit()
        return button
    }

    private func install(_ item: ResourceCatalog.Item) {
        let store = PersonaStore.shared
        if store.profiles.contains(where: { $0.id == item.entry.id }), store.source(of: item.entry.id) == .local {
            let alert = UIAlertController(title: "更新“\(item.entry.name)”？",
                                          message: "这个人格在本机改过，更新会覆盖你的修改。需要保留的话，可以先在人格页长按导出。",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "更新", style: .destructive) { [weak self] _ in self?.performInstall(item) })
            present(alert, animated: true)
        } else {
            performInstall(item)
        }
    }

    private func performInstall(_ item: ResourceCatalog.Item) {
        Task { [weak self] in
            do { try await ResourceCatalog.shared.install(item) }
            catch {
                let alert = UIAlertController(title: "未能获取人格", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "知道了", style: .default))
                self?.present(alert, animated: true)
            }
        }
    }

    // MARK: 缩略图

    private func thumbnail(for item: ResourceCatalog.Item) -> UIImage? {
        let id = item.entry.id
        if let image = thumbnails[id] { return image }
        if let installed = PersonaStore.shared.profiles.first(where: { $0.id == id }),
           let portrait = PersonaImages.portrait(for: installed) {
            return portrait
        }
        if item.portraitURL != nil, !loadingThumbnails.contains(id) {
            loadingThumbnails.insert(id)
            Task { [weak self] in
                guard let data = await ResourceCatalog.shared.thumbnailData(for: item),
                      let image = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 144, height: 192)),
                      let self else { return }
                self.thumbnails[id] = image
                self.tableView.reloadData()
            }
        }
        return PersonaImages.logo
    }
}
