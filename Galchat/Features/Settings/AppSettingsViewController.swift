import UIKit
import SnapKit

final class AppSettingsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let navigationBar = NavigationBar(frame: .zero)
    private var hasPositionedTableView = false

    private enum Item {
        case models, capture, onboarding, keyboard, privacy, about

        var title: String {
            switch self {
            case .models: return "BYOK 模型设置"
            case .capture: return "录屏与画中画"
            case .onboarding: return "重新查看欢迎引导"
            case .keyboard: return "键盘使用说明"
            case .privacy: return "数据与隐私说明"
            case .about: return "关于 Galchat"
            }
        }

        var symbol: String {
            switch self {
            case .models: return "sparkles"
            case .capture: return "pip"
            case .onboarding: return "hand.wave"
            case .keyboard: return "keyboard"
            case .privacy: return "hand.raised"
            case .about: return "info.circle"
            }
        }
    }

    private let sections: [[Item]] = [[.models, .capture], [.onboarding, .keyboard], [.privacy, .about]]

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "设置"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Setting")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.backgroundColor = .systemGroupedBackground
    }

    private func setupUI() {
        view.backgroundColor = .systemGroupedBackground
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)
        navigationBar.setHomeTitle(title ?? "设置")
        navigationBar.setContentColor(.label)
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
        tableView.reloadData()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !hasPositionedTableView, view.window != nil else { return }
        hasPositionedTableView = true
        if #available(iOS 26.0, *) {
            tableView.setContentOffset(CGPoint(x: 0, y: -tableView.adjustedContentInset.top), animated: false)
        }
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 1: return "使用帮助"
        case 2: return "应用信息"
        default: return nil
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? "配置状态仅表示信息已填齐。连通性可进入模型设置手动测试。" : nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Setting", for: indexPath)
        let item = sections[indexPath.section][indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = item.title
        content.image = UIImage(systemName: item.symbol)
        content.imageProperties.tintColor = .galchatPink
        content.textProperties.font = .preferredFont(forTextStyle: item == .models ? .headline : .body)
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.numberOfLines = 0
        content.directionalLayoutMargins.top = 16
        content.directionalLayoutMargins.bottom = 16

        if item == .models {
            let config = GCConfig.shared
            let judge = config.isConfigured(.judge) ? "已配置" : "待配置"
            let reply = config.isConfigured(.reply) ? "已配置" : "待配置"
            content.secondaryText = "判断模型：\(judge)\n回复模型：\(reply)"
        } else if item == .about {
            content.secondaryText = Self.versionDescription
        }

        cell.contentConfiguration = content
        var background = UIBackgroundConfiguration.listGroupedCell()
        if item == .models {
            background.backgroundColor = UIColor.galchatPink.withAlphaComponent(0.10)
        }
        cell.backgroundConfiguration = background
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityTraits.insert(.button)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = sections[indexPath.section][indexPath.row]
        switch item {
        case .models:
            navigationController?.pushViewController(SettingsViewController(), animated: true)
        case .capture:
            navigationController?.pushViewController(ViewController(), animated: true)
        case .onboarding:
            let onboarding = OnbViewController { [weak self] in
                self?.dismiss(animated: true)
            }
            onboarding.modalPresentationStyle = .fullScreen
            present(onboarding, animated: true)
        case .keyboard:
            showDetail(item, text: """
            1. 添加键盘
            打开系统“设置 → 通用 → 键盘 → 键盘 → 添加新键盘”，选择“Galchat 键盘”。

            2. 切换输入
            在聊天输入框中长按地球键，选择 Galchat 键盘。普通拼音、英文、数字和符号输入不需要开始录屏。部分应用和密码输入框可能不允许第三方键盘。

            3. 获取回复建议
            先在 Galchat 中配置判断和回复模型，再点底部“快速开启”并在系统面板确认录屏。返回聊天页面，等待分析产生候选。键盘从主 App 读取短期回复建议，本身不调用模型接口。

            4. 核对后插入
            确认候选对应的联系人与会话后，点选回复插入输入框；你仍可修改并自行发送。候选不会自动发送。停止录屏后，已生成的建议可能保留到原有效期结束；会话变化或建议过期后，旧建议不可用，普通输入仍可使用。
            """)
        case .privacy:
            showDetail(item, text: """
            模型请求
            使用分析和回复功能时，相关聊天文字、关系描述等上下文会发送到你在 BYOK 设置中配置的模型服务。手动连通性测试也会发起请求，服务商可能按其规则计费和处理数据。请确认服务地址及服务商的数据政策。

            本机配置与密钥
            模型配置和 API Key 保存在本机 UserDefaults 中，当前并非 Keychain 加密存储，可能随设备备份导出。各模型路线分别保存凭据，不会借用其他路线的密钥。

            采集与共享
            录屏需在系统面板确认。聊天识别和长截图在本机处理，跨进程帧传输会临时写入 JPEG；你可以主动导出长图。主 App 与扩展通过共享容器交换短期回复候选等数据；联系人档案、好感度记录、最近聊天上下文和人工纠正也会保存到本机共享容器，可在对应页面删除。人格预设保存在本机。

            你的控制
            不需要分析时可停止录屏。发送或分享前请检查内容和接收对象。阅读本说明、查看设置状态或重看欢迎引导不会主动调用模型接口。
            """)
        case .about:
            showDetail(item, text: """
            Galchat
            \(Self.versionDescription)

            通过录屏识别聊天内容，提供分析、回复建议和画中画辅助，并支持自定义键盘插入候选。

            模型分析可能不准确，请结合实际语境判断。回复由你核对、编辑并发送。
            """)
        }
    }

    private func showDetail(_ item: Item, text: String) {
        let detail = SettingsTextViewController(title: item.title, text: text)
        navigationController?.pushViewController(detail, animated: true)
    }

    private static var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "版本 \(version)（\(build)）"
    }
}

private final class SettingsTextViewController: UIViewController {
    private let text: String

    init(title: String, text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let textView = UITextView()
        textView.text = text
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.backgroundColor = .systemBackground
        textView.isEditable = false
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 28, right: 16)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }
}
