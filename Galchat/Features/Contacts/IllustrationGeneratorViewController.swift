import UIKit
import SnapKit
import Synapse

/// 用联系人头像生成立绘：OpenAI 兼容的 `/images/edits`，头像以文件形式上传。
/// （实测 vibeapi 的 gpt-image-2.5 会忽略 `/images/generations` 里的 `reference_image_urls`。）
/// 返回 `b64_json` 或图片 `url` 两种都接受。
enum IllustrationClient {
    enum Style: Int, CaseIterable {
        case galgame, painterly, chibi, watercolor
        var title: String { ["日系立绘", "厚涂", "Q 版", "水彩"][rawValue] }
        var prompt: String {
            [
                "日系柔和水彩动画插画，细腻线条，低饱和的米白、薄荷绿、柔粉配色，温暖柔光",
                "厚涂风格的动漫插画，色彩饱满，光影立体",
                "Q 版二到三头身的可爱插画，圆润线条，明快配色",
                "清新透明的水彩插画，带纸张纹理，淡雅配色"
            ][rawValue]
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// 生成一张要 30 秒到 2 分钟，`URLSession.shared` 默认 60 秒会先超时。
    nonisolated private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()

    static func prompt(style: Style, fullBody: Bool, note: String) -> String {
        let extra = note.isEmpty ? "" : "补充要求：\(note)。"
        return "根据参考图（聊天头像）画一个动漫角色\(fullBody ? "全身" : "半身")立绘："
            + "保留参考图的主要特征（发型或毛色、配饰、服装、配色、神态）；参考图是动物或玩偶时，拟人化成可爱的角色；"
            + "参考图是真人照片时，画成动漫风格，不需要还原真人长相。竖版构图，人物在画面中偏右，左下角留出干净的背景。"
            + "画风：\(style.prompt)，背景有轻微景深。\(extra)"
            + "画面中不要出现任何文字、字母、数字、水印、边框或界面元素。"
    }

    /// 返回压缩后的 JPEG。网络与解码在后台执行。
    nonisolated static func generate(baseURL: String, model: String, apiKey: String,
                                      prompt: String, avatar: Data) async throws -> Data {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/images/edits") else { throw Failure(errorDescription: "图像接口地址无效。") }
        let isPNG = avatar.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let boundary = "Galchat-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        for (name, value) in [("model", model), ("prompt", prompt), ("size", "1024x1536"), ("quality", "high")] {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"avatar.\(isPNG ? "png" : "jpg")\"\r\n")
        append("Content-Type: \(isPNG ? "image/png" : "image/jpeg")\r\n\r\n")
        body.append(avatar)
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw Failure(errorDescription: "图像接口超过 5 分钟没有返回，请稍后重试。")
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw Failure(errorDescription: "网络未连接。")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw Failure(errorDescription: status == 401 ? "图像接口认证失败，请检查 API Key。" : "图像接口返回 \(status)。\(detail)")
        }
        let item = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]])?.first
        var imageData: Data?
        if let b64 = item?["b64_json"] as? String {
            imageData = Data(base64Encoded: b64)
        } else if let link = (item?["url"] as? String).flatMap(URL.init(string:)) {
            imageData = try await session.data(from: link).0
        }
        guard let imageData, let image = UIImage(data: imageData), let jpeg = image.jpegData(compressionQuality: 0.85) else {
            throw Failure(errorDescription: "图像接口没有返回图片。")
        }
        return jpeg
    }
}

/// 生成立绘：选风格和构图，预览满意后点“使用这张”才保存。
final class IllustrationGeneratorViewController: UIViewController {
    private let contactID: String
    private let avatarData: Data
    private let config = GCConfig.shared

    private let preview = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let styleControl = UISegmentedControl(items: IllustrationClient.Style.allCases.map(\.title))
    private let bodyControl = UISegmentedControl(items: ["半身", "全身"])
    private let noteField = UITextField()
    private let statusLabel = makeFootnoteLabel("")
    private let primaryButton = UIButton(configuration: .filled())
    private let retryButton = UIButton(configuration: .plain())
    private var result: Data?
    private var task: Task<Void, Never>?

    init(contactID: String, avatarData: Data) {
        self.contactID = contactID
        self.avatarData = avatarData
        super.init(nibName: nil, bundle: nil)
        title = "生成立绘"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(close))
        isModalInPresentation = true

        let avatar = UIImageView(image: UIImage(data: avatarData))
        avatar.contentMode = .scaleAspectFill
        avatar.clipsToBounds = true
        avatar.layer.cornerRadius = 40
        avatar.snp.makeConstraints { make in make.size.equalTo(80) }
        let arrow = UIImageView(image: UIImage(systemName: "arrow.right"))
        arrow.tintColor = .tertiaryLabel
        preview.contentMode = .center
        preview.clipsToBounds = true
        preview.layer.cornerRadius = 16
        preview.layer.cornerCurve = .continuous
        preview.backgroundColor = .tertiarySystemFill
        preview.tintColor = .tertiaryLabel
        preview.image = UIImage(systemName: "wand.and.stars", withConfiguration: UIImage.SymbolConfiguration(pointSize: 28))
        preview.snp.makeConstraints { make in
            make.width.equalTo(120)
            make.height.equalTo(180)
        }
        preview.addSubview(spinner)
        spinner.snp.makeConstraints { make in make.center.equalToSuperview() }
        let previewRow = UIStackView(arrangedSubviews: [avatar, arrow, preview])
        previewRow.spacing = 18
        previewRow.alignment = .center

        styleControl.selectedSegmentIndex = 0
        bodyControl.selectedSegmentIndex = 0
        noteField.placeholder = "补充描述（可选），例如：白色开衫、猫耳发夹"
        noteField.borderStyle = .roundedRect
        noteField.backgroundColor = .secondarySystemGroupedBackground
        noteField.returnKeyType = .done
        noteField.addAction(UIAction { [weak self] _ in self?.noteField.resignFirstResponder() }, for: .editingDidEndOnExit)

        let host = URL(string: config.image.baseURL)?.host ?? config.image.baseURL
        let hint = makeFootnoteLabel("头像会发送给 \(host.isEmpty ? "你配置的图像接口" : host)（模型 \(config.image.model)），费用由该服务收取，一张大约需要 30 秒。生成后先预览，点“使用这张”才会保存。")

        primaryButton.configuration?.cornerStyle = .capsule
        primaryButton.configuration?.baseBackgroundColor = .galchatPink
        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
        primaryButton.snp.makeConstraints { make in make.height.equalTo(50) }
        retryButton.configuration?.title = "重新生成"
        retryButton.addTarget(self, action: #selector(generate), for: .touchUpInside)

        previewRow.snp.makeConstraints { make in make.height.equalTo(180) }
        let previewWrap = UIStackView(arrangedSubviews: [previewRow])
        previewWrap.axis = .vertical
        previewWrap.alignment = .center
        let stack = UIStackView(arrangedSubviews: [
            previewWrap,
            makeSectionLabel("风格"), styleControl,
            makeSectionLabel("构图"), bodyControl,
            noteField, hint, statusLabel, primaryButton, retryButton
        ])
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .fill
        stack.setCustomSpacing(22, after: previewWrap)
        stack.setCustomSpacing(16, after: styleControl)
        stack.setCustomSpacing(16, after: bodyControl)

        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)
        scroll.addSubview(stack)
        scroll.snp.makeConstraints { make in make.edges.equalToSuperview() }
        stack.snp.makeConstraints { make in
            make.top.equalTo(scroll.contentLayoutGuide).offset(20)
            make.bottom.equalTo(scroll.contentLayoutGuide).offset(-32)
            make.leading.trailing.equalTo(scroll.frameLayoutGuide).inset(20)
        }
        updateState(generating: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateState(generating: task != nil)
    }

    private func updateState(generating: Bool) {
        let configured = config.image.isConfigured
        spinner.isHidden = !generating
        if generating { spinner.startAnimating() } else { spinner.stopAnimating() }
        [styleControl, bodyControl, noteField].forEach { $0.isEnabled = !generating }
        retryButton.isHidden = result == nil || generating
        primaryButton.isEnabled = !generating
        primaryButton.configuration?.title = !configured ? "先配置图像模型"
            : generating ? "生成中…" : result == nil ? "生成" : "使用这张"
    }

    @objc private func primaryTapped() {
        if !config.image.isConfigured {
            navigationController?.pushViewController(SettingsViewController(), animated: true)
        } else if let result {
            do {
                try ContactsStore.shared.setIllustration(result, contactID: contactID)
                dismiss(animated: true)
            } catch {
                show(error.localizedDescription, isError: true)
            }
        } else {
            generate()
        }
    }

    @objc private func generate() {
        guard task == nil, let style = IllustrationClient.Style(rawValue: styleControl.selectedSegmentIndex) else { return }
        let prompt = IllustrationClient.prompt(style: style, fullBody: bodyControl.selectedSegmentIndex == 1,
                                               note: noteField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        let (base, model, key, avatar) = (config.image.baseURL, config.image.model, config.image.apiKey, avatarData)
        show("正在生成…", isError: false)
        updateState(generating: true)
        task = Task { [weak self] in
            do {
                let data = try await IllustrationClient.generate(baseURL: base, model: model, apiKey: key, prompt: prompt, avatar: avatar)
                guard let self else { return }
                self.result = data
                self.preview.contentMode = .scaleAspectFill
                self.preview.image = UIImage(data: data)
                self.show("满意就点“使用这张”，不满意可以重新生成。", isError: false)
            } catch {
                self?.show("生成失败：\(error.localizedDescription)", isError: true)
            }
            self?.task = nil
            self?.updateState(generating: false)
        }
    }

    private func show(_ text: String, isError: Bool) {
        statusLabel.text = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabel
    }

    @objc private func close() {
        task?.cancel()
        dismiss(animated: true)
    }
}
