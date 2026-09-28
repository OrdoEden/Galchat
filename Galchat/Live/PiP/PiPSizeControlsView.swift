import UIKit
import SnapKit
import VisynCapture

@MainActor
final class PiPSizeControlsView: UIView {
    var onApply: ((CGSize) -> Void)?
    /// 画中画路线：标准路线可后台常驻，通话式路线没有播放控件、能定小窗尺寸。
    var onRouteChange: ((VisynPictureInPictureRoute) -> Void)?
    var isEnabled = false {
        didSet { updateEnabledState() }
    }

    // 比例预设统一由 Visyn 提供：横屏长条与竖屏 9 : 22，不提供方形。
    private let presets = UISegmentedControl(items: VisynPictureInPictureSize.presets.map(\.title))
    private let presetSizes = VisynPictureInPictureSize.presets.map(\.size)
    private let routeControl = UISegmentedControl(items: VisynPictureInPictureRoute.presets.map(\.title))
    private let routeSizes = VisynPictureInPictureRoute.presets.map(\.route)
    private let ratioLabel = UILabel()
    private let widthField = UITextField()
    private let heightField = UITextField()
    private let applyButton = UIButton(configuration: .tinted())
    private let inputError = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let title = UILabel()
        title.text = "画中画方向"
        title.font = .preferredFont(forTextStyle: .headline)
        title.accessibilityTraits.insert(.header)
        presets.accessibilityLabel = "画中画方向预设"
        presets.addTarget(self, action: #selector(selectPreset), for: .valueChanged)
        routeControl.accessibilityLabel = "画中画路线"
        routeControl.addTarget(self, action: #selector(selectRoute), for: .valueChanged)
        var inputs: [UIView] = []
        for (field, name) in [(widthField, "宽"), (heightField, "高")] {
            let label = UILabel()
            label.text = name
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.adjustsFontForContentSizeCategory = true
            field.borderStyle = .roundedRect
            field.font = .preferredFont(forTextStyle: .body)
            field.adjustsFontForContentSizeCategory = true
            field.keyboardType = .decimalPad
            field.placeholder = "1–640"
            field.accessibilityLabel = "画中画宽高比中的\(name)"
            let column = UIStackView(arrangedSubviews: [label, field])
            column.axis = .vertical
            column.spacing = 4
            inputs.append(column)
        }
        let fields = UIStackView(arrangedSubviews: inputs)
        fields.spacing = 12
        fields.distribution = .fillEqually
        applyButton.configuration?.title = "应用比例"
        applyButton.addTarget(self, action: #selector(applyInput), for: .touchUpInside)
        inputError.font = .preferredFont(forTextStyle: .footnote)
        inputError.textColor = .systemRed
        inputError.isHidden = true
        let hint = UILabel()
        hint.text = "标准路线的形状只由宽和高的比例决定，小窗实际大小由 iOS 决定，可双指调整。通话式路线没有播放控件，宽高直接决定小窗尺寸与比例，但需要系统认作通话，被拒绝时自动退回标准路线。宽高可填 1–640，应用后自动保存；路线改完重新开启画中画生效。"
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.textColor = .secondaryLabel
        ratioLabel.font = .preferredFont(forTextStyle: .footnote)
        ratioLabel.textColor = .secondaryLabel
        for label in [title, ratioLabel, inputError, hint] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        let stack = UIStackView(arrangedSubviews: [title, presets, fields, ratioLabel, applyButton,
                                                   routeControl, inputError, hint])
        stack.axis = .vertical
        stack.spacing = 10
        addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        [presets, routeControl, widthField, heightField].forEach { control in
            control.snp.makeConstraints { make in
                make.height.greaterThanOrEqualTo(44)
            }
        }
        setAppliedSize(VisynPictureInPictureSize.landscape)
        setRoute(VisynPictureInPictureRoute.load() ?? .sampleBuffer)
        updateEnabledState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setAppliedSize(_ size: CGSize) {
        widthField.text = String(Int(size.width))
        heightField.text = String(Int(size.height))
        presets.selectedSegmentIndex = presetSizes.firstIndex(of: size) ?? UISegmentedControl.noSegment
        ratioLabel.text = Self.ratioDescription(size)
        inputError.isHidden = true
    }

    func setRoute(_ route: VisynPictureInPictureRoute) {
        routeControl.selectedSegmentIndex = routeSizes.firstIndex(of: route) ?? UISegmentedControl.noSegment
    }

    @objc private func selectRoute() {
        guard isEnabled, routeSizes.indices.contains(routeControl.selectedSegmentIndex) else { return }
        endEditing(true)
        onRouteChange?(routeSizes[routeControl.selectedSegmentIndex])
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

    /// 以短边为 1 描述形状，例如 90 × 220 → “竖向 1 : 2.44”。
    private static func ratioDescription(_ size: CGSize) -> String {
        guard size.width > 0, size.height > 0 else { return "" }
        let long = Double(max(size.width, size.height) / min(size.width, size.height))
        let value = long.formatted(FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2)))
        if size.width == size.height { return "当前形状：正方形 1 : 1" }
        return size.height > size.width ? "当前形状：竖向，宽 : 高 = 1 : \(value)"
                                        : "当前形状：横向，宽 : 高 = \(value) : 1"
    }

    private func updateEnabledState() {
        presets.isEnabled = isEnabled
        routeControl.isEnabled = isEnabled
        widthField.isEnabled = isEnabled
        heightField.isEnabled = isEnabled
        applyButton.isEnabled = isEnabled
        alpha = isEnabled ? 1 : 0.5
    }
}
