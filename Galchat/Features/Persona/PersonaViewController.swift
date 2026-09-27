import UIKit
import SnapKit
import UniformTypeIdentifiers

final class PersonaViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let navigationBar = NavigationBar(frame: .zero)
    private var hasPositionedTableView = false
    private var isImporting = false

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
        let menu = UIMenu(children: [
            UIAction(title: "新建人格", image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in
                self?.edit(.new())
            },
            UIAction(title: "从文件导入", image: UIImage(systemName: "folder")) { [weak self] _ in
                self?.importProfile()
            }
        ])
        navigationBar.setSecondaryButton(image: UIImage(systemName: "plus"), accessibilityLabel: "添加人格", menu: menu)
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

    func numberOfSections(in tableView: UITableView) -> Int { 2 }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? nil : "我的人格"
    }
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 1 else { return nil }
        if isImporting { return "正在读取人格…" }
        return PersonaStore.shared.lastError ?? (PersonaStore.shared.profiles.isEmpty
            ? "点右上角添加人格，也可以导入下载到本地的人格文件。"
            : "选中的人格会影响回复建议，点右侧按钮可查看和编辑完整说明。")
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : PersonaStore.shared.profiles.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let profile = indexPath.section == 0 ? nil : PersonaStore.shared.profiles[indexPath.row]
        let active = (profile?.id ?? "") == PersonaStore.shared.activeID
        var content = cell.defaultContentConfiguration()
        content.text = (profile?.manifest.name ?? "不使用人格") + (active ? " · 使用中" : "")
        content.secondaryText = profile?.manifest.summary ?? "按当前聊天内容提供回复建议。"
        content.secondaryTextProperties.numberOfLines = 3
        content.image = UIImage(systemName: active ? "checkmark.circle.fill" : "circle")
        content.imageProperties.tintColor = .galchatPink
        cell.contentConfiguration = content
        cell.accessoryType = profile == nil ? .none : .detailButton
        cell.accessibilityHint = profile == nil ? "停止使用人格" : "使用这个人格，详情按钮可编辑"
        if active { cell.accessibilityTraits.insert(.selected) }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let id = indexPath.section == 0 ? "" : PersonaStore.shared.profiles[indexPath.row].id
        do { try PersonaStore.shared.select(id: id) }
        catch { showError("未能切换人格", error: error) }
    }

    func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
        guard indexPath.section == 1 else { return }
        edit(PersonaStore.shared.profiles[indexPath.row])
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 1 else { return nil }
        let profile = PersonaStore.shared.profiles[indexPath.row]
        let action = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            completion(false)
            guard let self else { return }
            let message = profile.id == PersonaStore.shared.activeID ? "删除后将不再使用人格。需要保留的话，可以先在编辑页导出。" : "需要保留的话，可以先在编辑页导出。"
            let alert = UIAlertController(title: "删除“\(profile.manifest.name)”？", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
                do { try PersonaStore.shared.delete(id: profile.id) }
                catch { self?.showError("未能删除", error: error) }
            })
            self.present(alert, animated: true)
        }
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    private func importProfile() {
        guard !isImporting, presentedViewController == nil else { return }
        let markdown = UTType(filenameExtension: "md") ?? .plainText
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.galchatPersonal, .folder, .json, markdown],
                                                    asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        importFile(at: url, picker: controller)
    }

    /// 从“文件”、隔空投送或浏览器下载中打开 `.personal` 时由场景代理调用，与“从文件导入”走同一流程。
    func importFile(at url: URL, picker: UIDocumentPickerViewController? = nil) {
        guard !isImporting else { return }
        isImporting = true
        navigationBar.rightButton.isEnabled = false
        tableView.isUserInteractionEnabled = false
        reload()
        Task { [weak self] in
            let result: Result<PersonaPackage, Error>
            do { result = .success(try await PersonaStore.shared.importPackage(from: url)) }
            catch { result = .failure(error) }
            guard let self else { return }
            let finish: (@escaping () -> Void) -> Void = { completion in
                if let picker { self.afterPickerCloses(picker, completion: completion) } else { completion() }
            }
            finish { [weak self] in
                guard let self else { return }
                self.isImporting = false
                self.navigationBar.rightButton.isEnabled = true
                self.tableView.isUserInteractionEnabled = true
                self.reload()
                switch result {
                case .success(let profile): self.confirmImportedProfile(profile)
                case .failure(let error): self.showError("未能导入人格", error: error)
                }
            }
        }
    }

    private func afterPickerCloses(_ picker: UIDocumentPickerViewController, completion: @escaping () -> Void) {
        var completed = false
        let finish = {
            guard !completed else { return }
            completed = true
            completion()
        }
        let dismissIfNeeded = {
            if picker.presentingViewController != nil {
                picker.dismiss(animated: true, completion: finish)
            } else {
                finish()
            }
        }
        if let coordinator = picker.transitionCoordinator,
           coordinator.animate(alongsideTransition: nil, completion: { _ in dismissIfNeeded() }) {
            return
        }
        dismissIfNeeded()
    }

    private func confirmImportedProfile(_ profile: PersonaPackage) {
        if let existing = PersonaStore.shared.profiles.first(where: { $0.id == profile.id }) {
            let alert = UIAlertController(title: "替换“\(existing.manifest.name)”？", message: "这个人格已经存在。替换会覆盖本地修改，原来的内容无法恢复。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "替换", style: .destructive) { [weak self] _ in
                self?.saveImported(profile)
            })
            alertHost.present(alert, animated: true)
        } else {
            saveImported(profile)
        }
    }

    private func saveImported(_ profile: PersonaPackage) {
        do { try PersonaStore.shared.save(profile) }
        catch { showError("未能导入人格", error: error) }
    }

    private func showError(_ title: String, error: Error) {
        let alert = UIAlertController(title: title, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        alertHost.present(alert, animated: true)
    }

    /// 从外部打开人格文件时，页面上可能已有编辑页等弹窗；提示放在最上层，不打断也不丢弃它们。
    private var alertHost: UIViewController {
        var host: UIViewController = self
        while let presented = host.presentedViewController, !presented.isBeingDismissed { host = presented }
        return host
    }

    private func edit(_ profile: PersonaPackage) {
        present(UINavigationController(rootViewController: PersonaEditorViewController(profile: profile)), animated: true)
    }
}

private final class PersonaEditorViewController: ProfileEditorViewController {
    private let profile: PersonaPackage
    private var nameField: UITextView!
    private var summaryField: UITextView!
    private var documentFields: [(path: String, field: UITextView)] = []
    private var exportButton: UIBarButtonItem?

    init(profile: PersonaPackage) {
        self.profile = profile
        super.init(nibName: nil, bundle: nil)
        title = profile.manifest.name.isEmpty ? "新建人格" : "编辑人格"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        nameField = addField("名字", value: profile.manifest.name, lines: 1)
        summaryField = addField("一句话介绍", value: profile.manifest.summary, lines: 2)
        for (index, path) in profile.manifest.documents.enumerated() {
            let text = profile.files[path] ?? ""
            let heading = text.components(separatedBy: .newlines).first(where: { $0.hasPrefix("# ") })
                .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            let label = index == 0 ? "这个人是什么样" : (heading ?? "人格说明 \(index + 1)")
            let field = addField(label, value: text, lines: 6)
            field.isScrollEnabled = true
            field.heightAnchor.constraint(equalToConstant: 280).isActive = true
            field.smartQuotesType = .no
            field.smartDashesType = .no
            documentFields.append((path, field))
        }
        addHint("这里保留完整的人格说明；使用时会随聊天内容发送给你配置的模型服务。")
        if PersonaStore.shared.profiles.contains(where: { $0.id == profile.id }),
           let saveButton = navigationItem.rightBarButtonItem {
            let button = UIBarButtonItem(title: "导出", style: .plain, target: self, action: #selector(exportProfile))
            button.accessibilityHint = "导出已保存的完整人格文件"
            exportButton = button
            navigationItem.rightBarButtonItems = [saveButton, button]
        }
    }

    override func textViewDidChange(_ textView: UITextView) {
        super.textViewDidChange(textView)
        exportButton?.isEnabled = false
    }

    @objc private func exportProfile() {
        do {
            let url = try PersonaStore.shared.exportPackage(id: profile.id)
            let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            controller.popoverPresentationController?.barButtonItem = exportButton
            present(controller, animated: true)
        } catch { showError(error.localizedDescription) }
    }

    override func saveChanges() {
        do {
            var updated = profile
            updated.manifest.name = nameField.text.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.manifest.summary = summaryField.text.trimmingCharacters(in: .whitespacesAndNewlines)
            for document in documentFields {
                updated.files[document.path] = document.field.text
            }
            try PersonaStore.shared.save(updated)
            dismiss(animated: true)
        } catch { showError(error.localizedDescription) }
    }
}
