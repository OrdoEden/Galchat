import UIKit
import SnapKit

/// 联系人详情。顶部按素材选布局：
/// - 有立绘：立绘海报铺满上方，名字、好感度和进度条压在立绘底部，下方面板盖上来；
/// - 只有头像：头像放大模糊做背景，中间是带好感环的头像，提示可以生成立绘；
/// - 没有头像：配色浅渐变背景和字母头像，提示识别聊天时会自动提取。
/// 下方的快捷操作、好感走势和档案字段三种布局共用。
final class ContactDetailViewController: UIViewController {
    private let contactID: String
    private var contact: ContactsStore.Contact? { ContactsStore.shared.contact(id: contactID) }

    private let backdrop = UIView()
    private let scrollView = UIScrollView()
    private let content = UIView()
    private let trendCard = AffectionTrendCardView()
    private let emptyLabel = UILabel()
    private var trendDays = 7

    init(contactID: String) {
        self.contactID = contactID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ThemeStore.shared.current.background
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance

        view.addSubview(backdrop)
        backdrop.snp.makeConstraints { make in make.edges.equalToSuperview() }
        view.addSubview(scrollView)
        scrollView.alwaysBounceVertical = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.snp.makeConstraints { make in make.edges.equalToSuperview() }
        scrollView.addSubview(content)
        content.snp.makeConstraints { make in
            make.edges.equalTo(scrollView.contentLayoutGuide)
            make.width.equalTo(scrollView.frameLayoutGuide)
        }
        trendCard.onRangeChange = { [weak self] days in
            self?.trendDays = days
            self?.reloadTrend()
        }
        emptyLabel.text = "此联系人已不存在。"
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.isHidden = true
        view.addSubview(emptyLabel)
        emptyLabel.snp.makeConstraints { make in make.center.equalToSuperview() }

        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: ContactsStore.changed, object: nil)
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    /// 顶部让立绘铺到状态栏下，所以关闭了自动内边距；底部仍要避开标签栏。
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.contentInset.bottom = view.safeAreaInsets.bottom
        scrollView.verticalScrollIndicatorInsets.bottom = view.safeAreaInsets.bottom
    }

    // MARK: - 构建

    @objc private func reload() {
        guard let contact else {
            scrollView.isHidden = true
            emptyLabel.isHidden = false
            navigationItem.rightBarButtonItems = nil
            return
        }
        let illustration = ContactsStore.shared.illustration(for: contactID)
        let avatar = contact.avatarData.flatMap(UIImage.init(data:))
        updateNavigationItems(hasAvatar: avatar != nil, hasIllustration: illustration != nil)

        backdrop.subviews.forEach { $0.removeFromSuperview() }
        backdrop.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        content.subviews.forEach { $0.removeFromSuperview() }

        let body = makeBody(contact: contact, avatar: avatar, illustration: illustration)
        if let illustration {
            let poster = makePoster(contact: contact, image: illustration)
            let sheet = UIView()
            sheet.backgroundColor = ThemeStore.shared.current.background
            sheet.layer.cornerRadius = 28
            sheet.layer.cornerCurve = .continuous
            sheet.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            sheet.addSubview(body)
            content.addSubview(poster)
            content.addSubview(sheet)
            poster.snp.makeConstraints { make in
                make.top.leading.trailing.equalToSuperview()
                make.height.equalTo(poster.snp.width).multipliedBy(1.3)
            }
            sheet.snp.makeConstraints { make in
                make.top.equalTo(poster.snp.bottom).offset(-24)
                make.leading.trailing.bottom.equalToSuperview()
            }
            body.snp.makeConstraints { make in make.edges.equalToSuperview().inset(UIEdgeInsets(top: 18, left: 16, bottom: 32, right: 16)) }
        } else {
            makeBackdrop(contact: contact, avatar: avatar)
            let header = makeHeader(contact: contact)
            content.addSubview(header)
            content.addSubview(body)
            header.snp.makeConstraints { make in
                make.top.equalTo(content.safeAreaLayoutGuide).offset(52)
                make.leading.trailing.equalToSuperview().inset(16)
            }
            body.snp.makeConstraints { make in
                make.top.equalTo(header.snp.bottom).offset(18)
                make.leading.trailing.equalToSuperview().inset(16)
                make.bottom.equalToSuperview().inset(32)
            }
        }
        reloadTrend()
    }

    /// 立绘海报：名字、备注、好感度大数字和进度条压在立绘底部，不用额外的框。
    private func makePoster(contact: ContactsStore.Contact, image: UIImage) -> UIView {
        let poster = UIView()
        poster.clipsToBounds = true
        let art = UIImageView(image: image)
        art.contentMode = .scaleAspectFill
        poster.addSubview(art)
        art.snp.makeConstraints { make in make.edges.equalToSuperview() }
        let top = GradientView(colors: [UIColor(white: 0.1, alpha: 0.3), .clear])
        let bottom = GradientView(colors: [.clear, UIColor(red: 0.16, green: 0.08, blue: 0.16, alpha: 0.5)])
        poster.addSubview(top)
        poster.addSubview(bottom)
        top.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(140)
        }
        bottom.snp.makeConstraints { make in
            make.bottom.leading.trailing.equalToSuperview()
            make.height.equalToSuperview().multipliedBy(0.45)
        }

        let name = UILabel()
        name.text = contact.displayName
        name.font = .systemFont(ofSize: 38, weight: .heavy)
        name.textColor = .white
        name.adjustsFontSizeToFitWidth = true
        name.minimumScaleFactor = 0.6
        name.accessibilityTraits = .header
        shadow(name, radius: 10)

        let noteRow = UIStackView()
        noteRow.spacing = 6
        noteRow.alignment = .center
        let small = ContactAvatarView()
        small.configure(name: contact.displayName, key: contact.id, imageData: contact.avatarData)
        small.layer.borderWidth = 1.5
        small.layer.borderColor = UIColor.white.cgColor
        small.snp.makeConstraints { make in make.size.equalTo(22) }
        let note = UILabel()
        note.text = contact.note?.isEmpty == false ? contact.note : nil
        note.font = .systemFont(ofSize: 14, weight: .semibold)
        note.textColor = .white
        shadow(note, radius: 4)
        noteRow.addArrangedSubview(small)
        if note.text != nil { noteRow.addArrangedSubview(note) }

        let heart = UIImageView(image: UIImage(systemName: "heart.fill",
                                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)))
        heart.tintColor = UIColor(hex: 0xFF8DB4)
        let score = UILabel()
        score.text = "\(contact.total)"
        score.font = .systemFont(ofSize: 38, weight: .heavy)
        score.textColor = .white
        shadow(score, radius: 10)
        let scoreRow = UIStackView(arrangedSubviews: [heart, score])
        scoreRow.spacing = 8
        scoreRow.alignment = .center
        let today = ContactsStore.shared.affectionChangeToday(contactID: contactID)
        if today != 0 {
            let delta = PaddedLabel(text: today > 0 ? "+\(today)" : "−\(abs(today))")
            delta.backgroundColor = UIColor(hex: 0xFF78A5, alpha: 0.6)
            scoreRow.addArrangedSubview(delta)
        }
        if contact.rupturedUntilResolved {
            let tag = PaddedLabel(text: "关系待修复")
            tag.backgroundColor = ContactUI.ruptured.withAlphaComponent(0.7)
            scoreRow.addArrangedSubview(tag)
        }
        scoreRow.addArrangedSubview(UIView())
        let caption = UILabel()
        caption.text = "好感度"
        caption.font = .systemFont(ofSize: 13, weight: .medium)
        caption.textColor = UIColor.white.withAlphaComponent(0.9)
        scoreRow.addArrangedSubview(caption)
        scoreRow.isAccessibilityElement = true
        scoreRow.accessibilityLabel = "好感度 \(contact.total)，满分 100" + (today != 0 ? "，今天 \(today > 0 ? "加" : "减") \(abs(today))" : "")

        let bar = ProgressBarView(progress: CGFloat(contact.total) / 100, ruptured: contact.rupturedUntilResolved)
        bar.snp.makeConstraints { make in make.height.equalTo(6) }

        let block = UIStackView(arrangedSubviews: [name, noteRow, scoreRow, bar])
        block.axis = .vertical
        block.alignment = .fill
        block.spacing = 8
        block.setCustomSpacing(12, after: noteRow)
        noteRow.snp.makeConstraints { make in make.height.equalTo(22) }
        poster.addSubview(block)
        block.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(22)
            make.bottom.equalToSuperview().inset(46)
        }
        return poster
    }

    /// 没有立绘时的背景：有头像用头像模糊色，没有头像用配色浅渐变。固定在页面后面，不随内容滚动。
    private func makeBackdrop(contact: ContactsStore.Contact, avatar: UIImage?) {
        if let avatar {
            let image = UIImageView(image: avatar)
            image.contentMode = .scaleAspectFill
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
            let fade = GradientView(colors: [.clear, ThemeStore.shared.current.background.withAlphaComponent(0.6),
                                             ThemeStore.shared.current.background], locations: [0.35, 0.7, 1])
            backdrop.addSubview(image)
            backdrop.addSubview(blur)
            backdrop.addSubview(fade)
            image.snp.makeConstraints { make in make.edges.equalToSuperview().inset(-60) }
            blur.snp.makeConstraints { make in make.edges.equalToSuperview() }
            fade.snp.makeConstraints { make in make.edges.equalToSuperview() }
        } else {
            // 用预先混好的不透明色做渐变，再多放几个停靠点，从头像配色平滑淡进页面底色，
            // 不再出现一条横向的分界线；只铺到屏幕约一半的位置。
            let base = ThemeStore.shared.current.background
            let tint = ContactUI.gradient(for: contact.id).top
            let stops: [(CGFloat, NSNumber)] = [(0.34, 0), (0.24, 0.2), (0.14, 0.38), (0.06, 0.52), (0, 0.62)]
            let fade = GradientView(colors: stops.map { Self.blend(tint, into: base, amount: $0.0) },
                                    locations: stops.map(\.1))
            backdrop.backgroundColor = base
            backdrop.addSubview(fade)
            fade.snp.makeConstraints { make in make.edges.equalToSuperview() }
        }
    }

    /// 在底色上叠一层 `amount` 比例的颜色，得到一个不透明色。
    private static func blend(_ color: UIColor, into base: UIColor, amount: CGFloat) -> UIColor {
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        color.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        base.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r2 + (r1 - r2) * amount, green: g2 + (g1 - g2) * amount,
                       blue: b2 + (b1 - b2) * amount, alpha: 1)
    }

    private func makeHeader(contact: ContactsStore.Contact) -> UIView {
        let ring = AffectionRingAvatarView(lineWidth: 6, gap: 6)
        ring.configure(contact: contact, initials: 2)
        ring.isAccessibilityElement = true
        ring.accessibilityLabel = "好感度 \(contact.total)，满分 100"
        ring.snp.makeConstraints { make in make.size.equalTo(128) }
        let name = UILabel()
        name.text = contact.displayName
        name.font = .systemFont(ofSize: 26, weight: .heavy)
        name.textAlignment = .center
        name.numberOfLines = 2
        name.accessibilityTraits = .header
        let note = UILabel()
        note.text = contact.note
        note.font = .preferredFont(forTextStyle: .subheadline)
        note.textColor = .secondaryLabel
        note.textAlignment = .center
        note.numberOfLines = 2
        note.isHidden = contact.note?.isEmpty ?? true

        let tags = UIStackView(arrangedSubviews: [StatusTagLabel("♥ \(contact.total) / 100", kind: .accent, fontSize: 12)])
        tags.spacing = 6
        let today = ContactsStore.shared.affectionChangeToday(contactID: contactID)
        if today != 0 {
            tags.addArrangedSubview(StatusTagLabel("今天 \(today > 0 ? "+" : "−")\(abs(today))",
                                                   kind: today > 0 ? .positive : .negative, fontSize: 12))
        }
        if contact.rupturedUntilResolved {
            tags.addArrangedSubview(StatusTagLabel("关系待修复", kind: .warning, fontSize: 12))
        }

        let stack = UIStackView(arrangedSubviews: [ring, name, note, tags])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        stack.setCustomSpacing(10, after: ring)
        stack.setCustomSpacing(10, after: note)
        return stack
    }

    /// 三种布局共用：快捷操作、提示卡片、好感走势、档案字段、删除。
    private func makeBody(contact: ContactsStore.Contact, avatar: UIImage?, illustration: UIImage?) -> UIView {
        let actions = UIStackView(arrangedSubviews: [
            actionItem("聊天记录", icon: "bubble.left", action: #selector(openHistory)),
            actionItem("分析", icon: "sparkles", action: #selector(openAnalysis)),
            actionItem("人设", icon: "person.text.rectangle", action: #selector(editContact)),
            actionItem("别名", icon: "tag", action: #selector(editContact))
        ])
        actions.spacing = 18
        actions.alignment = .top
        let actionsRow = UIStackView(arrangedSubviews: [UIView(), actions, UIView()])
        actionsRow.distribution = .equalCentering

        let stack = UIStackView(arrangedSubviews: [actionsRow])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(18, after: actionsRow)
        if illustration == nil {
            let hint = avatar != nil
                ? HintCard(icon: "wand.and.stars", title: "用头像生成立绘", subtitle: "生成后详情页会换成海报布局") { [weak self] in self?.generateIllustration() }
                : HintCard(icon: "photo", title: "还没有头像", subtitle: "识别聊天时会自动提取，也可以手动选择") { [weak self] in self?.editContact() }
            stack.addArrangedSubview(hint)
        }
        stack.addArrangedSubview(trendCard)

        let info = UIStackView()
        info.axis = .vertical
        let rows: [(String, String)] = [
            ("备注", contact.note ?? ""),
            ("对方人设", contact.persona ?? ""),
            ("识别别名", contact.aliases.joined(separator: "、"))
        ]
        for (index, row) in rows.enumerated() {
            info.addArrangedSubview(ContactInfoRow(title: row.0, value: row.1, showsSeparator: index > 0) { [weak self] in
                self?.editContact()
            })
        }
        stack.addArrangedSubview(info)

        let delete = UIButton(configuration: .plain())
        delete.configuration?.title = "删除联系人"
        delete.configuration?.baseForegroundColor = .systemRed
        delete.addTarget(self, action: #selector(confirmDelete), for: .touchUpInside)
        stack.addArrangedSubview(delete)
        return stack
    }

    private func actionItem(_ title: String, icon: String, action: Selector) -> UIView {
        let button = UIButton(configuration: ContactUI.glassButtonConfiguration(systemImage: icon, pointSize: 18))
        button.addTarget(self, action: action, for: .touchUpInside)
        button.accessibilityLabel = title
        button.snp.makeConstraints { make in make.size.equalTo(50) }
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabel
        label.isAccessibilityElement = false
        let stack = UIStackView(arrangedSubviews: [button, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 5
        return stack
    }

    private func updateNavigationItems(hasAvatar: Bool, hasIllustration: Bool) {
        var items = [UIBarButtonItem(title: "编辑", style: .plain, target: self, action: #selector(editContact))]
        if hasIllustration {
            let menu = UIMenu(children: [
                UIAction(title: "重新生成立绘", image: UIImage(systemName: "wand.and.stars")) { [weak self] _ in
                    self?.generateIllustration()
                },
                UIAction(title: "删除立绘", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    self?.confirmDeleteIllustration()
                }
            ])
            let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: menu)
            more.accessibilityLabel = "立绘"
            items.append(more)
        }
        navigationItem.rightBarButtonItems = items
    }

    private func reloadTrend() {
        guard contact != nil else { return }
        trendCard.configure(values: ContactsStore.shared.affectionTrend(contactID: contactID, days: trendDays),
                            days: trendDays,
                            events: ContactsStore.shared.recentAffectionEvents(contactID: contactID, limit: 3))
    }

    private func shadow(_ label: UILabel, radius: CGFloat) {
        label.layer.shadowColor = UIColor(red: 0.24, green: 0.08, blue: 0.2, alpha: 1).cgColor
        label.layer.shadowOpacity = 0.35
        label.layer.shadowRadius = radius
        label.layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    // MARK: - 操作

    @objc private func openHistory() {
        navigationController?.pushViewController(RecentsViewController(contactID: contactID), animated: true)
    }

    @objc private func openAnalysis() {
        let latest = RecentConversationStore.shared.conversations(contactID: contactID).first
        let relationship = AnalysisModelContext.relationship(config: .shared, contactID: contactID)
        navigationController?.pushViewController(
            AnalysisViewController(initialText: latest?.analysisText ?? "", relationship: relationship), animated: true)
    }

    @objc private func editContact() {
        guard let contact else { return }
        present(UINavigationController(rootViewController: ContactEditorViewController(contact: contact)), animated: true)
    }

    private func generateIllustration() {
        guard let contact, let avatar = contact.avatarData else { return }
        let generator = IllustrationGeneratorViewController(contactID: contact.id, avatarData: avatar)
        present(UINavigationController(rootViewController: generator), animated: true)
    }

    private func confirmDeleteIllustration() {
        let alert = UIAlertController(title: "删除立绘？", message: "删除后详情页回到头像布局，可以随时重新生成。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do { try ContactsStore.shared.setIllustration(nil, contactID: self.contactID) }
            catch { self.showAlert("未能删除", error.localizedDescription) }
        })
        present(alert, animated: true)
    }

    @objc private func confirmDelete() {
        let alert = UIAlertController(title: "删除联系人？", message: "将删除联系人档案、好感度记录、走势与立绘。最近存档中的聊天正文会保留，并显示为未关联联系人。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                try ContactsStore.shared.deleteProfile(contactID: self.contactID)
                AffectionProjectionPublisher.shared.publishImmediately()
                self.navigationController?.popViewController(animated: true)
            } catch {
                self.showAlert("未能删除", error.localizedDescription)
            }
        })
        present(alert, animated: true)
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - 小组件

/// 竖直渐变，跟随深浅色切换。
private final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    private let colors: [UIColor]

    init(colors: [UIColor], locations: [NSNumber]? = nil) {
        self.colors = colors
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        (layer as? CAGradientLayer)?.locations = locations
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        applyColors()
    }

    private func applyColors() {
        (layer as? CAGradientLayer)?.colors = colors.map { $0.resolvedColor(with: traitCollection).cgColor }
    }
}

/// 海报上的好感度进度条：半透明白色轨道 + 粉色渐变。
private final class ProgressBarView: UIView {
    private let fill = CAGradientLayer()
    private let progress: CGFloat

    init(progress: CGFloat, ruptured: Bool) {
        self.progress = min(max(progress, 0), 1)
        super.init(frame: .zero)
        backgroundColor = UIColor.white.withAlphaComponent(0.35)
        clipsToBounds = true
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        fill.colors = ruptured
            ? [ContactUI.rupturedLight.cgColor, ContactUI.ruptured.cgColor]
            : [UIColor(hex: 0xFFB6CE).cgColor, UIColor(hex: 0xFF5C98).cgColor]
        layer.addSublayer(fill)
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        fill.cornerRadius = bounds.height / 2
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height)
    }
}

/// 海报上的小标签（“+3”“关系待修复”）。
private final class PaddedLabel: UILabel {
    init(text: String) {
        super.init(frame: .zero)
        self.text = text
        font = .systemFont(ofSize: 13, weight: .bold)
        textColor = .white
        textAlignment = .center
        clipsToBounds = true
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 14, height: size.height + 4)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}

/// 玻璃提示卡片：“用头像生成立绘”或“还没有头像”。
private final class HintCard: UIControl {
    private let onTap: () -> Void

    init(icon: String, title: String, subtitle: String, onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)
        let glass = ContactUI.glassBackground(cornerRadius: 22)
        addSubview(glass)
        glass.snp.makeConstraints { make in make.edges.equalToSuperview() }
        let iconView = UIImageView(image: UIImage(systemName: icon,
                                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)))
        iconView.tintColor = UIColor(hex: 0x7A4FE0)
        iconView.contentMode = .center
        iconView.backgroundColor = UIColor(hex: 0x7A4FE0, alpha: 0.12)
        iconView.layer.cornerRadius = 17
        iconView.snp.makeConstraints { make in make.size.equalTo(34) }
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0
        let texts = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        texts.axis = .vertical
        texts.spacing = 2
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right",
                                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))
        chevron.tintColor = .tertiaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [iconView, texts, chevron])
        row.spacing = 12
        row.alignment = .center
        row.isUserInteractionEnabled = false
        addSubview(row)
        row.snp.makeConstraints { make in make.edges.equalToSuperview().inset(UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)) }
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "\(title)，\(subtitle)"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    @objc private func tapped() { onTap() }
}

/// 详情页的一行档案字段：标题在上，内容在下，点按进入编辑。
private final class ContactInfoRow: UIControl {
    private let onTap: () -> Void

    init(title: String, value: String, showsSeparator: Bool, onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabel
        let valueLabel = UILabel()
        valueLabel.text = value.isEmpty ? "未设置" : value
        valueLabel.font = .preferredFont(forTextStyle: .body)
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.textColor = value.isEmpty ? .tertiaryLabel : .label
        valueLabel.numberOfLines = 4
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right",
                                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .center
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        stack.axis = .vertical
        stack.spacing = 3
        stack.isUserInteractionEnabled = false
        addSubview(stack)
        addSubview(chevron)
        stack.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(4)
            make.top.bottom.equalToSuperview().inset(11)
            make.trailing.equalTo(chevron.snp.leading).offset(-8)
        }
        chevron.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(4)
            make.centerY.equalToSuperview()
        }
        if showsSeparator {
            let separator = UIView()
            separator.backgroundColor = .separator.withAlphaComponent(0.5)
            addSubview(separator)
            separator.snp.makeConstraints { make in
                make.top.leading.trailing.equalToSuperview()
                make.height.equalTo(0.5)
            }
        }
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "\(title)，\(value.isEmpty ? "未设置" : value)"
        accessibilityHint = "编辑联系人"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.55 : 1 }
    }

    @objc private func tapped() { onTap() }
}
