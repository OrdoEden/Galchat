import UIKit
import SnapKit
import UniformTypeIdentifiers

/// 人格页：顶部头像条一次露出所有人格，中间是可滑动的形象走马灯，下方是简介和“使用”按钮。
final class PersonaViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate,
    UIDocumentPickerDelegate {
    private enum StripItem {
        case persona(Int)
        case none
        case library
    }

    private let scrollView = UIScrollView()
    private let navigationBar = NavigationBar(frame: .zero)
    private lazy var strip: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = PersonaAvatarCell.size
        layout.minimumLineSpacing = 10
        layout.sectionInset = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        return UICollectionView(frame: .zero, collectionViewLayout: layout)
    }()
    private let carouselLayout = PersonaCarouselLayout()
    private lazy var carousel = UICollectionView(frame: .zero, collectionViewLayout: carouselLayout)
    private let nameLabel = UILabel()
    private let summaryLabel = UILabel()
    private let useButton = UIButton(configuration: .filled())
    private let detailButton = UIButton(configuration: .plain())
    private let hintLabel = UILabel()
    private let emptyLabel = UILabel()
    private let emptyButton = UIButton(configuration: .filled())
    private var carouselHeight: Constraint?
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private var hasPositionedScrollView = false
    private var isImporting = false
    /// 走马灯当前居中的人格；按标识记录，列表变化后仍能停在同一个人格上。
    private var focusedID: String?

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "人格"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupNavigationBar()
        setupContent()
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: PersonaStore.changed, object: nil)
    }

    private func setupNavigationBar() {
        view.backgroundColor = .systemGroupedBackground
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)
        navigationBar.setHomeTitle(title ?? "人格")
        navigationBar.setContentColor(.label)
        let menu = UIMenu(children: [
            UIAction(title: "人格库", image: UIImage(systemName: "arrow.down.circle")) { [weak self] _ in
                self?.openLibrary()
            },
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
            scrollView.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
            scrollView.contentInset.top = NavigationBar.homeTitleBarHeight
            scrollView.verticalScrollIndicatorInsets.top = NavigationBar.homeTitleBarHeight
            navigationBar.attachScrollView(scrollView)
        } else {
            scrollView.snp.makeConstraints { make in
                make.top.equalTo(navigationBar.snp.bottom)
                make.leading.trailing.bottom.equalToSuperview()
            }
        }
    }

    private func setupContent() {
        for collectionView in [strip, carousel] {
            collectionView.backgroundColor = .clear
            collectionView.showsHorizontalScrollIndicator = false
            collectionView.dataSource = self
            collectionView.delegate = self
        }
        strip.register(PersonaAvatarCell.self, forCellWithReuseIdentifier: PersonaAvatarCell.reuseID)
        carousel.register(PersonaCarouselCell.self, forCellWithReuseIdentifier: PersonaCarouselCell.reuseID)
        carousel.decelerationRate = .fast
        carousel.clipsToBounds = false

        nameLabel.font = UIFont(descriptor: UIFont.systemFont(ofSize: 26, weight: .heavy).fontDescriptor.withDesign(.serif)
                                ?? UIFont.systemFont(ofSize: 26, weight: .heavy).fontDescriptor, size: 26)
        nameLabel.textAlignment = .center
        nameLabel.accessibilityTraits = .header
        summaryLabel.font = .systemFont(ofSize: 15)
        summaryLabel.textColor = .secondaryLabel
        summaryLabel.textAlignment = .center
        summaryLabel.numberOfLines = 0

        useButton.configuration?.cornerStyle = .large
        useButton.configuration?.buttonSize = .large
        useButton.addAction(UIAction { [weak self] _ in
            guard let self, let id = self.focusedID else { return }
            self.select(id: id)
        }, for: .touchUpInside)

        detailButton.configuration?.title = "查看完整说明 / 编辑"
        detailButton.configuration?.baseForegroundColor = .secondaryLabel
        detailButton.addAction(UIAction { [weak self] _ in
            guard let self, let profile = self.focusedProfile else { return }
            self.edit(profile)
        }, for: .touchUpInside)

        hintLabel.font = .systemFont(ofSize: 13)
        hintLabel.textColor = .secondaryLabel
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0

        emptyLabel.text = "还没有人格。可以从人格库下载，也可以新建或导入人格文件。"
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyButton.configuration?.title = "打开人格库"
        emptyButton.configuration?.cornerStyle = .large
        emptyButton.addAction(UIAction { [weak self] _ in self?.openLibrary() }, for: .touchUpInside)

        let details = UIStackView(arrangedSubviews: [nameLabel, summaryLabel, useButton, detailButton, emptyLabel, emptyButton, hintLabel])
        details.axis = .vertical
        details.spacing = 10
        details.setCustomSpacing(18, after: summaryLabel)
        details.setCustomSpacing(4, after: useButton)
        details.setCustomSpacing(16, after: emptyLabel)

        scrollView.addSubview(strip)
        scrollView.addSubview(carousel)
        scrollView.addSubview(details)
        strip.snp.makeConstraints { make in
            make.top.equalTo(scrollView.contentLayoutGuide).offset(8)
            make.leading.trailing.equalTo(scrollView.frameLayoutGuide)
            make.height.equalTo(PersonaAvatarCell.size.height)
        }
        carousel.snp.makeConstraints { make in
            make.top.equalTo(strip.snp.bottom).offset(6)
            make.leading.trailing.equalTo(scrollView.frameLayoutGuide)
            carouselHeight = make.height.equalTo(420).constraint
        }
        details.snp.makeConstraints { make in
            make.top.equalTo(carousel.snp.bottom).offset(6)
            make.leading.trailing.equalTo(scrollView.frameLayoutGuide).inset(24)
            make.bottom.equalTo(scrollView.contentLayoutGuide).inset(24)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
        ResourceCatalog.shared.refreshIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        showRevokedNoticeIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        carouselHeight?.update(offset: PersonaCarouselLayout.height(for: view.bounds.width))
        guard !hasPositionedScrollView, view.window != nil else { return }
        hasPositionedScrollView = true
        if #available(iOS 26.0, *) {
            scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.adjustedContentInset.top), animated: false)
        }
        scrollCarousel(toFocus: false)
    }

    // MARK: 数据

    private var profiles: [PersonaPackage] { PersonaStore.shared.profiles }
    private var focusedIndex: Int? { profiles.firstIndex { $0.id == focusedID } }
    private var focusedProfile: PersonaPackage? { focusedIndex.map { profiles[$0] } }

    private var stripItems: [StripItem] {
        profiles.indices.map { .persona($0) } + [.none, .library]
    }

    @objc private func reload() {
        if focusedIndex == nil {
            focusedID = profiles.first(where: { $0.id == PersonaStore.shared.activeID })?.id ?? profiles.first?.id
        }
        strip.reloadData()
        carousel.reloadData()
        updateDetails()
        if !carousel.isDragging && !carousel.isDecelerating { scrollCarousel(toFocus: false) }
        if viewIfLoaded?.window != nil { showRevokedNoticeIfNeeded() }
    }

    private func updateDetails() {
        let isEmpty = profiles.isEmpty
        carousel.isHidden = isEmpty
        [nameLabel, summaryLabel, useButton, detailButton].forEach { $0.isHidden = isEmpty }
        emptyLabel.isHidden = !isEmpty
        emptyButton.isHidden = !isEmpty
        if let profile = focusedProfile {
            nameLabel.text = profile.manifest.name
            summaryLabel.text = profile.manifest.summary
            let isActive = profile.id == PersonaStore.shared.activeID
            var configuration = isActive ? UIButton.Configuration.tinted() : .filled()
            configuration.title = isActive ? "正在使用" : "使用这个人格"
            configuration.image = isActive ? UIImage(systemName: "checkmark") : nil
            configuration.imagePadding = 6
            configuration.cornerStyle = .large
            configuration.buttonSize = .large
            configuration.baseBackgroundColor = .galchatPink
            configuration.baseForegroundColor = isActive ? .galchatPink : .white
            useButton.configuration = configuration
            useButton.accessibilityTraits = isActive ? [.button, .selected] : .button
        }
        let hint: String?
        if isImporting {
            hint = "正在读取人格…"
        } else if let error = PersonaStore.shared.lastError {
            hint = error
        } else if PersonaStore.shared.activeID.isEmpty && !isEmpty {
            hint = "当前不使用人格，回复建议按聊天内容生成。"
        } else {
            hint = nil
        }
        hintLabel.text = hint
        hintLabel.isHidden = hint == nil
    }

    private func setFocus(_ index: Int, animatedStrip: Bool) {
        guard profiles.indices.contains(index), profiles[index].id != focusedID else { return }
        focusedID = profiles[index].id
        selectionFeedback.selectionChanged()
        strip.reloadData()
        strip.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredHorizontally, animated: animatedStrip)
        updateDetails()
    }

    private func scrollCarousel(toFocus animated: Bool) {
        guard let index = focusedIndex, carouselLayout.pageWidth > 0 else { return }
        carousel.setContentOffset(CGPoint(x: CGFloat(index) * carouselLayout.pageWidth, y: 0), animated: animated)
    }

    private func select(id: String) {
        guard id != PersonaStore.shared.activeID else { return }
        do { try PersonaStore.shared.select(id: id) }
        catch { showError("未能切换人格", error: error) }
    }

    private func openLibrary() {
        present(UINavigationController(rootViewController: PersonaLibraryViewController()), animated: true)
    }

    private func showRevokedNoticeIfNeeded() {
        guard presentedViewController == nil else { return }
        let names = PersonaStore.shared.takeRevokedNotice()
        guard !names.isEmpty else { return }
        let alert = UIAlertController(title: "人格已下架",
                                      message: "“\(names.joined(separator: "”“"))”已被人格库下架，已从本机移除。",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }

    // MARK: UICollectionView

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        collectionView === strip ? stripItems.count : profiles.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let activeID = PersonaStore.shared.activeID
        if collectionView === strip {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PersonaAvatarCell.reuseID, for: indexPath) as! PersonaAvatarCell
            switch stripItems[indexPath.item] {
            case .persona(let index):
                let profile = profiles[index]
                cell.configure(.persona(image: PersonaImages.avatar(for: profile), name: profile.manifest.name),
                               isFocused: profile.id == focusedID, isActive: profile.id == activeID)
            case .none:
                cell.configure(.none, isFocused: false, isActive: activeID.isEmpty)
            case .library:
                cell.configure(.library, isFocused: false, isActive: false)
            }
            return cell
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PersonaCarouselCell.reuseID, for: indexPath) as! PersonaCarouselCell
        let profile = profiles[indexPath.item]
        cell.configure(profile: profile, isActive: profile.id == activeID)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if collectionView === carousel {
            setFocus(indexPath.item, animatedStrip: true)
            scrollCarousel(toFocus: true)
            return
        }
        switch stripItems[indexPath.item] {
        case .persona(let index):
            setFocus(index, animatedStrip: true)
            scrollCarousel(toFocus: true)
        case .none:
            select(id: "")
        case .library:
            openLibrary()
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === carousel, carouselLayout.pageWidth > 0,
              carousel.isDragging || carousel.isDecelerating else { return }
        let index = Int((carousel.contentOffset.x / carouselLayout.pageWidth).rounded())
        setFocus(min(max(0, index), profiles.count - 1), animatedStrip: true)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard collectionView === carousel, let indexPath = indexPaths.first,
              profiles.indices.contains(indexPath.item) else { return nil }
        let profile = profiles[indexPath.item]
        let isActive = profile.id == PersonaStore.shared.activeID
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: isActive ? "正在使用" : "使用这个人格", image: UIImage(systemName: "checkmark.circle"),
                         attributes: isActive ? .disabled : []) { _ in self?.select(id: profile.id) },
                UIAction(title: "查看与编辑", image: UIImage(systemName: "square.and.pencil")) { _ in self?.edit(profile) },
                UIAction(title: "导出人格文件", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                    self?.export(profile, from: collectionView.cellForItem(at: indexPath))
                },
                UIAction(title: "删除", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    self?.confirmDelete(profile)
                }
            ])
        }
    }

    private func export(_ profile: PersonaPackage, from sourceView: UIView?) {
        do {
            let url = try PersonaStore.shared.exportPackage(id: profile.id)
            let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            controller.popoverPresentationController?.sourceView = sourceView ?? view
            present(controller, animated: true)
        } catch { showError("未能导出", error: error) }
    }

    private func confirmDelete(_ profile: PersonaPackage) {
        let message = profile.id == PersonaStore.shared.activeID ? "删除后将不再使用人格。需要保留的话，可以先导出。" : "需要保留的话，可以先导出。"
        let alert = UIAlertController(title: "删除“\(profile.manifest.name)”？", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            do { try PersonaStore.shared.delete(id: profile.id) }
            catch { self?.showError("未能删除", error: error) }
        })
        alertHost.present(alert, animated: true)
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
        scrollView.isUserInteractionEnabled = false
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
                self.scrollView.isUserInteractionEnabled = true
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
            field.snp.makeConstraints { make in
                make.height.equalTo(280)
            }
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
