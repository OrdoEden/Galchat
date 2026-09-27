import UIKit

/// 一组"标题 + 输入框"的配置行。
final class ConfigFieldView: UIView {
    let textField = UITextField()
    private let titleLabel = UILabel()

    init(title: String, placeholder: String, isSecure: Bool = false) {
        super.init(frame: .zero)
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.textColor = .secondaryLabel
        titleLabel.adjustsFontForContentSizeCategory = true

        textField.placeholder = placeholder
        textField.borderStyle = .roundedRect
        textField.font = .preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.clearButtonMode = .whileEditing
        textField.accessibilityLabel = title
        if isSecure {
            textField.isSecureTextEntry = true
            textField.textContentType = .password
        } else {
            textField.keyboardType = .URL
        }

        let stack = UIStackView(arrangedSubviews: [titleLabel, textField])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var text: String {
        get { textField.text ?? "" }
        set { textField.text = newValue }
    }
}

/// 分区标题。
func makeSectionLabel(_ text: String) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = .preferredFont(forTextStyle: .headline)
    label.adjustsFontForContentSizeCategory = true
    label.accessibilityTraits.insert(.header)
    return label
}

/// 说明性小字。
func makeFootnoteLabel(_ text: String) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = .preferredFont(forTextStyle: .footnote)
    label.textColor = .secondaryLabel
    label.numberOfLines = 0
    label.adjustsFontForContentSizeCategory = true
    return label
}

/// “标题 + 当前值 + 步进器”的数值配置行，附一行随数值变化的说明。
final class StepperRowView: UIView {
    let stepper = UIStepper()
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let noteLabel = makeFootnoteLabel("")
    private let format: (Int) -> String
    private let note: (Int) -> String
    var onChange: ((Int) -> Void)?

    init(title: String, range: ClosedRange<Int>, step: Int = 1,
         format: @escaping (Int) -> String, note: @escaping (Int) -> String) {
        self.format = format
        self.note = note
        super.init(frame: .zero)
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        valueLabel.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .semibold)
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        stepper.minimumValue = Double(range.lowerBound)
        stepper.maximumValue = Double(range.upperBound)
        stepper.stepValue = Double(step)
        stepper.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            refresh()
            onChange?(value)
        }, for: .valueChanged)

        let row = UIStackView(arrangedSubviews: [titleLabel, valueLabel, stepper])
        row.alignment = .center
        row.spacing = 12
        let stack = UIStackView(arrangedSubviews: [row, noteLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        accessibilityElements = [stepper, noteLabel]
        stepper.accessibilityLabel = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var value: Int {
        get { Int(stepper.value) }
        set { stepper.value = Double(newValue); refresh() }
    }

    private func refresh() {
        valueLabel.text = format(value)
        noteLabel.text = note(value)
        stepper.accessibilityValue = format(value)
    }
}
