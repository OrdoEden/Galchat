import UIKit
import VisynCapture

@MainActor
final class PiPSizeControlsView: UIView {
    var onApply: ((CGSize) -> Void)?
    var isEnabled = false {
        didSet { updateEnabledState() }
    }

    private let presets = UISegmentedControl(items: ["横屏", "竖屏", "矩形"])
    private let presetSizes = [VisynPictureInPictureSize.landscape,
                               VisynPictureInPictureSize.portrait,
                               VisynPictureInPictureSize.rectangle]
    private let widthField = UITextField()
    private let heightField = UITextField()
    private let applyButton = UIButton(configuration: .tinted())
    private let inputError = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let title = UILabel()
        title.text = "画中画内容尺寸"
        title.font = .preferredFont(forTextStyle: .headline)
        title.accessibilityTraits.insert(.header)
        presets.accessibilityLabel = "画中画尺寸预设"
        presets.addTarget(self, action: #selector(selectPreset), for: .valueChanged)
        var inputs: [UIView] = []
        for (field, name) in [(widthField, "宽"), (heightField, "高")] {
            let label = UILabel()
            label.text = "\(name)（点）"
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.adjustsFontForContentSizeCategory = true
            field.borderStyle = .roundedRect
            field.font = .preferredFont(forTextStyle: .body)
            field.adjustsFontForContentSizeCategory = true
            field.keyboardType = .decimalPad
            field.placeholder = "1–640"
            field.accessibilityLabel = "画中画\(name)度，单位点"
            let column = UIStackView(arrangedSubviews: [label, field])
            column.axis = .vertical
            column.spacing = 4
            inputs.append(column)
        }
        let fields = UIStackView(arrangedSubviews: inputs)
        fields.spacing = 12
        fields.distribution = .fillEqually
        applyButton.configuration?.title = "应用尺寸"
        applyButton.addTarget(self, action: #selector(applyInput), for: .touchUpInside)
        inputError.font = .preferredFont(forTextStyle: .footnote)
        inputError.textColor = .systemRed
        inputError.isHidden = true
        let hint = UILabel()
        hint.text = "输入内容宽高（1–640 点），应用后自动保存。系统小窗的实际大小由 iOS 控制，可双指缩放。"
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.textColor = .secondaryLabel
        for label in [title, inputError, hint] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        let stack = UIStackView(arrangedSubviews: [title, presets, fields, applyButton, inputError, hint])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            presets.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            widthField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            heightField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        setAppliedSize(VisynPictureInPictureSize.landscape)
        updateEnabledState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setAppliedSize(_ size: CGSize) {
        widthField.text = String(Int(size.width))
        heightField.text = String(Int(size.height))
        presets.selectedSegmentIndex = presetSizes.firstIndex(of: size) ?? UISegmentedControl.noSegment
        inputError.isHidden = true
    }

    @objc private func selectPreset() {
        guard isEnabled, presetSizes.indices.contains(presets.selectedSegmentIndex) else { return }
        endEditing(true)
        onApply?(presetSizes[presets.selectedSegmentIndex])
    }

    @objc private func applyInput() {
        guard isEnabled else { return }
        let separator = Locale.current.decimalSeparator ?? "."
        func number(_ field: UITextField) -> Double? {
            Double((field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: separator, with: "."))
        }
        guard let width = number(widthField), let height = number(heightField),
              width.isFinite, height.isFinite else {
            inputError.text = "请输入有效的宽度和高度。"
            inputError.isHidden = false
            UIAccessibility.post(notification: .announcement, argument: inputError.text)
            return
        }
        endEditing(true)
        // 范围校验和取整由 Visyn 统一处理。
        onApply?(CGSize(width: width, height: height))
    }

    private func updateEnabledState() {
        presets.isEnabled = isEnabled
        widthField.isEnabled = isEnabled
        heightField.isEnabled = isEnabled
        applyButton.isEnabled = isEnabled
        alpha = isEnabled ? 1 : 0.5
    }
}
