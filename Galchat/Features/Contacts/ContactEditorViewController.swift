import UIKit
import SnapKit
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

/// 模态表单统一提供显式保存、取消和未保存关闭保护。
class ProfileEditorViewController: UIViewController, UIAdaptivePresentationControllerDelegate, UITextViewDelegate {
    let stack = UIStackView()
    var hasChanges = false {
        didSet {
            isModalInPresentation = hasChanges
            navigationController?.isModalInPresentation = hasChanges
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(saveChanges))
        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 12
        scroll.addSubview(stack)
        scroll.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top)
            make.leading.trailing.equalToSuperview()
            make.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
        }
        stack.snp.makeConstraints { make in
            make.top.bottom.equalTo(scroll.contentLayoutGuide).inset(24)
            make.leading.trailing.equalTo(scroll.contentLayoutGuide).inset(20)
            make.width.equalTo(scroll.frameLayoutGuide).offset(-40)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.presentationController?.delegate = self
    }

    func addField(_ label: String, value: String, lines: Int = 3) -> UITextView {
        let heading = UILabel()
        heading.text = label
        heading.font = .preferredFont(forTextStyle: .headline)
        heading.adjustsFontForContentSizeCategory = true
        heading.numberOfLines = 0
        stack.addArrangedSubview(heading)
        let field = UITextView()
        field.text = value
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.backgroundColor = .secondarySystemGroupedBackground
        field.layer.cornerRadius = 10
        field.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        field.isScrollEnabled = false
        field.delegate = self
        field.accessibilityLabel = label
        field.snp.makeConstraints { make in
            make.height.greaterThanOrEqualTo(lines * 24 + 24)
        }
        stack.addArrangedSubview(field)
        stack.setCustomSpacing(24, after: field)
        return field
    }

    func addHint(_ text: String) {
        let hint = UILabel()
        hint.text = text
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.adjustsFontForContentSizeCategory = true
        hint.textColor = .secondaryLabel
        hint.numberOfLines = 0
        stack.addArrangedSubview(hint)
    }

    func textViewDidChange(_ textView: UITextView) { hasChanges = true }
    @objc func saveChanges() {}
    @objc func cancel() {
        view.endEditing(true)
        guard hasChanges else { dismiss(animated: true); return }
        let alert = UIAlertController(title: "放弃未保存的修改？", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "继续编辑", style: .cancel))
        alert.addAction(UIAlertAction(title: "放弃修改", style: .destructive) { [weak self] _ in self?.dismiss(animated: true) })
        present(alert, animated: true)
    }

    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) { cancel() }

    func showError(_ message: String) {
        let alert = UIAlertController(title: "未能完成", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }
}

final class ContactEditorViewController: ProfileEditorViewController, PHPickerViewControllerDelegate {
    private let original: ContactsStore.Contact
    private var nameField: UITextView!
    private var noteField: UITextView!
    private var personaField: UITextView!
    private var aliasField: UITextView!
    private var totalField: UITextView!
    private var avatarData: Data?
    private let avatarButton = UIButton(type: .system)
    private var photoRequest = UUID()

    init(contact: ContactsStore.Contact) {
        original = contact
        avatarData = contact.avatarData
        super.init(nibName: nil, bundle: nil)
        title = "编辑联系人"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        avatarButton.snp.makeConstraints { make in
            make.height.greaterThanOrEqualTo(72)
        }
        avatarButton.addTarget(self, action: #selector(chooseAvatar), for: .touchUpInside)
        stack.addArrangedSubview(avatarButton)
        updateAvatar()
        nameField = addField("名称", value: original.displayName, lines: 1)
        noteField = addField("备注", value: original.note ?? "")
        personaField = addField("对方人设", value: original.persona ?? "")
        aliasField = addField("识别别名 · 每行一个", value: original.aliases.joined(separator: "\n"))
        addHint("名称和别名用于匹配聊天标题。头像仅用于档案展示，人设用于分析与回复上下文。")
        totalField = addField("当前好感度 · 0 到 100", value: String(original.total), lines: 1)
        totalField.keyboardType = .numberPad
        addHint("仅在修改数字后校正好感度，已计分的聊天记录会保留。")
    }

    private func updateAvatar() {
        var config = UIButton.Configuration.plain()
        config.title = "更换头像"
        config.image = avatarData.flatMap(UIImage.init(data:))?.preparingThumbnail(of: CGSize(width: 56, height: 56)) ?? UIImage(systemName: "person.crop.circle.badge.plus")
        config.imagePadding = 12
        avatarButton.configuration = config
    }

    @objc private func chooseAvatar() {
        let alert = UIAlertController(title: "联系人头像", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "从照片选择", style: .default) { [weak self] _ in
            guard let self else { return }
            var config = PHPickerConfiguration()
            config.filter = .images
            config.selectionLimit = 1
            let picker = PHPickerViewController(configuration: config)
            picker.delegate = self
            self.present(picker, animated: true)
        })
        if avatarData != nil {
            alert.addAction(UIAlertAction(title: "移除头像", style: .destructive) { [weak self] _ in
                self?.photoRequest = UUID()
                self?.avatarData = nil
                self?.hasChanges = true
                self?.updateAvatar()
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.popoverPresentationController?.sourceView = avatarButton
        alert.popoverPresentationController?.sourceRect = avatarButton.bounds
        present(alert, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }
        let request = UUID()
        photoRequest = request
        avatarButton.isEnabled = false
        navigationItem.rightBarButtonItem?.isEnabled = false
        provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] url, _ in
            let data = url.flatMap(Self.avatarJPEG)
            Task { @MainActor [weak self] in
                guard let self, self.photoRequest == request, self.viewIfLoaded?.window != nil else { return }
                self.avatarButton.isEnabled = true
                self.navigationItem.rightBarButtonItem?.isEnabled = true
                guard let data else { self.showError("无法读取这张照片，或图片超过 30 MB。请选择其他图片。"); return }
                self.avatarData = data
                self.hasChanges = true
                self.updateAvatar()
            }
        }
    }

    // 使用 ImageIO 下采样，避免先解码完整高分辨率照片占用大量内存。
    nonisolated private static func avatarJPEG(_ url: URL) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 30_000_000,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= 100_000 else { return nil }
        return data as Data
    }

    override func saveChanges() {
        guard let total = Int(totalField.text.trimmingCharacters(in: .whitespacesAndNewlines)), (0...100).contains(total) else {
            showError("好感度须为 0 到 100 的整数。")
            return
        }
        do {
            try ContactsStore.shared.edit(contactID: original.id, displayName: nameField.text, note: noteField.text,
                                          persona: personaField.text, aliases: aliasField.text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                                          total: total == original.total ? nil : total, avatarData: avatarData)
            AffectionProjectionPublisher.shared.publishImmediately()
            dismiss(animated: true)
        } catch { showError(error.localizedDescription) }
    }
}
