import UIKit
import SnapKit

/// 联系人详情里的“好感走势”玻璃卡片：7 天 / 30 天折线，以及最近几次加减分的原因。
final class AffectionTrendCardView: UIView {
    var onRangeChange: ((Int) -> Void)?

    private let chart = AffectionTrendChartView()
    private let rangeControl = UISegmentedControl(items: ["7 天", "30 天"])
    private let startLabel = UILabel()
    private let endLabel = UILabel()
    private let ledgerStack = UIStackView()
    private let emptyLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let glass = ContactUI.glassBackground(cornerRadius: 24)
        addSubview(glass)
        glass.snp.makeConstraints { make in make.edges.equalToSuperview() }

        let title = UILabel()
        title.text = "好感走势"
        title.font = .systemFont(ofSize: 15, weight: .bold)
        title.accessibilityTraits = .header
        rangeControl.selectedSegmentIndex = 0
        rangeControl.accessibilityLabel = "走势范围"
        rangeControl.addTarget(self, action: #selector(rangeChanged), for: .valueChanged)
        let titleRow = UIStackView(arrangedSubviews: [title, UIView(), rangeControl])
        titleRow.alignment = .center

        [startLabel, endLabel].forEach {
            $0.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
            $0.textColor = .tertiaryLabel
        }
        let axisRow = UIStackView(arrangedSubviews: [startLabel, UIView(), endLabel])

        ledgerStack.axis = .vertical
        ledgerStack.spacing = 7
        emptyLabel.text = "识别并分析聊天后，这里会记录每次好感度变化。"
        emptyLabel.font = .preferredFont(forTextStyle: .footnote)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.numberOfLines = 0

        let separator = UIView()
        separator.backgroundColor = .separator.withAlphaComponent(0.5)
        separator.snp.makeConstraints { make in make.height.equalTo(0.5) }

        let stack = UIStackView(arrangedSubviews: [titleRow, chart, axisRow, separator, ledgerStack, emptyLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(12, after: titleRow)
        stack.setCustomSpacing(4, after: chart)
        stack.setCustomSpacing(10, after: axisRow)
        stack.setCustomSpacing(10, after: separator)
        addSubview(stack)
        stack.snp.makeConstraints { make in make.edges.equalToSuperview().inset(UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)) }
        chart.snp.makeConstraints { make in make.height.equalTo(72) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func rangeChanged() {
        onRangeChange?(rangeControl.selectedSegmentIndex == 0 ? 7 : 30)
    }

    func configure(values: [Int], days: Int, events: [GalchatDatabase.AffectionEvent]) {
        chart.values = values
        if let first = values.first, let last = values.last,
           let start = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Date()) {
            startLabel.text = "\(start.formatted(.dateTime.month(.defaultDigits).day())) · \(first)"
            endLabel.text = "今天 · \(last)"
            chart.accessibilityLabel = "近 \(days) 天好感度从 \(first) 变为 \(last)"
        }

        ledgerStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for event in events { ledgerStack.addArrangedSubview(Self.ledgerRow(event)) }
        ledgerStack.isHidden = events.isEmpty
        emptyLabel.isHidden = !events.isEmpty
    }

    private static func ledgerRow(_ event: GalchatDatabase.AffectionEvent) -> UIView {
        let delta = UILabel()
        delta.text = event.delta > 0 ? "+\(event.delta)" : "−\(abs(event.delta))"
        delta.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        delta.textColor = event.delta > 0 ? ContactUI.positive : ContactUI.negative
        delta.snp.makeConstraints { make in make.width.equalTo(30) }
        let reason = UILabel()
        reason.text = event.reason ?? (event.source == .manual ? "手动调整" : "聊天分析")
        reason.font = .systemFont(ofSize: 13)
        reason.lineBreakMode = .byTruncatingTail
        reason.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        reason.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let time = UILabel()
        time.text = ContactUI.shortTime(event.at)
        time.font = .systemFont(ofSize: 11.5)
        time.textColor = .tertiaryLabel
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        time.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [delta, reason, time])
        row.spacing = 8
        row.alignment = .firstBaseline
        row.isAccessibilityElement = true
        row.accessibilityLabel = "\(event.delta > 0 ? "加" : "减") \(abs(event.delta)) 分，\(reason.text ?? "")，\(time.text ?? "")"
        return row
    }
}

/// 面积折线图。纵轴按数据范围自适应（至少 10 分跨度），最后一个点加圆点强调。
final class AffectionTrendChartView: UIView {
    var values: [Int] = [] { didSet { setNeedsLayout() } }

    private let fill = CAShapeLayer()
    private let line = CAShapeLayer()
    private let guide = CAShapeLayer()
    private let dot = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        guide.lineDashPattern = [3, 3]
        guide.lineWidth = 1
        guide.fillColor = nil
        line.fillColor = nil
        line.lineWidth = 2
        line.lineJoin = .round
        line.lineCap = .round
        [guide, fill, line, dot].forEach(layer.addSublayer)
        isAccessibilityElement = true
        accessibilityTraits = .image
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle { applyColors() }
    }

    private func applyColors() {
        let pink = UIColor.galchatPink.resolvedColor(with: traitCollection)
        line.strokeColor = pink.cgColor
        fill.fillColor = ContactUI.ringTrack.resolvedColor(with: traitCollection).cgColor
        guide.strokeColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        dot.fillColor = pink.cgColor
        dot.strokeColor = UIColor.systemBackground.resolvedColor(with: traitCollection).cgColor
        dot.lineWidth = 2
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard values.count > 1, bounds.width > 0 else {
            [fill, line, guide, dot].forEach { $0.path = nil }
            return
        }
        let low = Double(values.min()!), high = Double(values.max()!)
        let padding = max(0, 10 - (high - low)) / 2
        let minValue = max(0, low - padding - 2), maxValue = min(100, high + padding + 2)
        let span = max(maxValue - minValue, 1)
        let inset: CGFloat = 5
        let width = bounds.width - inset * 2, height = bounds.height - inset * 2
        let points = values.enumerated().map { index, value in
            CGPoint(x: inset + width * CGFloat(index) / CGFloat(values.count - 1),
                    y: inset + height * CGFloat(1 - (Double(value) - minValue) / span))
        }
        let path = UIBezierPath()
        path.move(to: points[0])
        points.dropFirst().forEach(path.addLine(to:))
        let area = path.copy() as! UIBezierPath
        area.addLine(to: CGPoint(x: points.last!.x, y: bounds.height))
        area.addLine(to: CGPoint(x: points[0].x, y: bounds.height))
        area.close()
        let midY = inset + height / 2
        let guidePath = UIBezierPath()
        guidePath.move(to: CGPoint(x: 0, y: midY))
        guidePath.addLine(to: CGPoint(x: bounds.width, y: midY))
        let end = points.last!

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.path = path.cgPath
        fill.path = area.cgPath
        guide.path = guidePath.cgPath
        dot.path = UIBezierPath(ovalIn: CGRect(x: end.x - 4, y: end.y - 4, width: 8, height: 8)).cgPath
        CATransaction.commit()
    }
}
