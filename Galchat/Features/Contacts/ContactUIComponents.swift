import UIKit
import SnapKit

/// 最近 / 联系 / 联系人详情共用的视觉组件。
///
/// - 列表页纯白底；联系人详情按素材选背景：立绘海报、头像模糊色、或头像配色的浅渐变。
/// - 玻璃：只用在浮在内容上的控件、好感标签与走势卡片；iOS 26 用 `UIGlassEffect`，之前的系统降级为半透明材质。
/// - 列表行直接铺在背景上，不再套分组卡片。
enum ContactUI {
    /// 好感环未填满部分。
    static let ringTrack = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.56, blue: 0.69, alpha: 0.18)
            : UIColor(red: 0.94, green: 0.29, blue: 0.48, alpha: 0.14)
    }
    static let ringStart = UIColor(red: 1.0, green: 0.69, blue: 0.77, alpha: 1)
    static let ruptured = UIColor(red: 0.88, green: 0.63, blue: 0.29, alpha: 1)
    static let rupturedLight = UIColor(red: 0.95, green: 0.76, blue: 0.49, alpha: 1)
    static let positive = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.44, green: 0.81, blue: 0.59, alpha: 1)
            : UIColor(red: 0.18, green: 0.56, blue: 0.36, alpha: 1)
    }
    static let negative = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.54, blue: 0.50, alpha: 1)
            : UIColor(red: 0.75, green: 0.27, blue: 0.25, alpha: 1)
    }
    static let warning = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.95, green: 0.76, blue: 0.40, alpha: 1)
            : UIColor(red: 0.72, green: 0.47, blue: 0.12, alpha: 1)
    }

    /// 字母头像的渐变（上浅下深）：樱、天、薄荷、柠、葡萄、珊瑚。按联系人 id 固定，重启后不变。
    private static let palette: [(top: UIColor, bottom: UIColor)] = [
        (UIColor(hex: 0xFFA6C9), UIColor(hex: 0xFF5C98)),
        (UIColor(hex: 0x8FD0FF), UIColor(hex: 0x3D8BFF)),
        (UIColor(hex: 0x7BE8CB), UIColor(hex: 0x1FB889)),
        (UIColor(hex: 0xFFE07A), UIColor(hex: 0xFFAA2B)),
        (UIColor(hex: 0xC6ADFF), UIColor(hex: 0x7A57F5)),
        (UIColor(hex: 0xFFB38F), UIColor(hex: 0xFF6B5A))
    ]

    static func gradient(for key: String) -> (top: UIColor, bottom: UIColor) {
        // 不用 hashValue：它每次启动都会变。
        let sum = key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palette[sum % palette.count]
    }

    static func initials(_ name: String, count: Int) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }
        // 中文名取末尾字（“小满”），英文名取首字母。
        if trimmed.unicodeScalars.first.map({ CharacterSet.letters.contains($0) && $0.isASCII }) == true {
            return String(trimmed.prefix(1)).uppercased()
        }
        return String(trimmed.suffix(count))
    }

    /// 拼音首字母分组，非字母归入 “#”。
    static func indexLetter(for name: String) -> String {
        let latin = sortKey(for: name)
        guard let first = latin.first, first.isASCII, first.isLetter else { return "#" }
        return String(first).uppercased()
    }

    static func sortKey(for name: String) -> String {
        let latin = name.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? name
        return latin.lowercased()
    }

    /// 今天显示时间，昨天显示“昨天”，一周内显示星期，更早显示日期。
    static func shortTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let startOfToday = calendar.startOfDay(for: Date())
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday), date >= weekAgo {
            return date.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "zh_CN")))
        }
        return date.formatted(.dateTime.month(.defaultDigits).day().locale(Locale(identifier: "zh_CN")))
    }

    /// 玻璃背景视图。iOS 26 以下用半透明材质加细边，避免在白底上完全看不见。
    /// `clear` 用于压在图片上的小控件（好感标签），更通透，白字更清楚。
    static func glassBackground(cornerRadius: CGFloat, clear: Bool = false) -> UIView {
        let view: UIVisualEffectView
        if #available(iOS 26.0, *) {
            // 好感标签等压在图片上的小控件用 .clear：.regular 会糊上一层白，看不到背景。
            view = UIVisualEffectView(effect: UIGlassEffect(style: clear ? .clear : .regular))
            view.contentView.backgroundColor = .clear
        } else {
            view = UIVisualEffectView(effect: UIBlurEffect(style: clear ? .systemUltraThinMaterialLight : .systemThinMaterial))
            view.layer.borderWidth = 0.5
            view.layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        }
        view.layer.cornerRadius = cornerRadius
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        return view
    }

    static func glassButtonConfiguration(systemImage: String, pointSize: CGFloat = 17) -> UIButton.Configuration {
        var config: UIButton.Configuration
        if #available(iOS 26.0, *) {
            config = .glass()
        } else {
            config = .gray()
            config.baseBackgroundColor = .secondarySystemBackground
        }
        config.cornerStyle = .capsule
        config.image = UIImage(systemName: systemImage,
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .medium))
        config.baseForegroundColor = .galchatPink
        return config
    }
}

// MARK: - 头像

/// 圆形头像：有照片显示照片，否则显示渐变字母头像。
final class ContactAvatarView: UIView {
    private let imageView = UIImageView()
    private let label = UILabel()
    private let gradient = CAGradientLayer()
    private var initialsCount = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        label.textAlignment = .center
        label.textColor = .white
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        layer.addSublayer(gradient)
        addSubview(label)
        addSubview(imageView)
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var image: UIImage? { imageView.image }

    func configure(name: String, key: String, imageData: Data?, initials count: Int = 1) {
        initialsCount = count
        let image = imageData.flatMap(UIImage.init(data:))
        imageView.image = image
        imageView.isHidden = image == nil
        label.isHidden = image != nil
        gradient.isHidden = image != nil
        label.text = ContactUI.initials(name, count: count)
        let colors = ContactUI.gradient(for: key)
        gradient.colors = [colors.top.cgColor, colors.bottom.cgColor]
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        imageView.frame = bounds
        label.frame = bounds.insetBy(dx: bounds.width * 0.1, dy: 0)
        label.font = .systemFont(ofSize: bounds.width * (initialsCount > 1 ? 0.34 : 0.42), weight: .bold)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }
}

/// 外圈带好感度圆环的头像（方案 A 的环 + 方案 C 的字母头像）。
/// 圆环长度 = 好感度 / 100；关系待修复时换成琥珀色。
final class AffectionRingAvatarView: UIView {
    let avatar = ContactAvatarView()
    private let track = CAShapeLayer()
    private let gradient = CAGradientLayer()
    private let progressMask = CAShapeLayer()
    private let lineWidth: CGFloat
    private let gap: CGFloat
    private var progress: CGFloat = 0
    /// 圆头在弧线两端各多出的角度（占整圈的比例），布局后才能算。
    private var capFraction: CGFloat = 0

    init(lineWidth: CGFloat = 2.5, gap: CGFloat = 2) {
        self.lineWidth = lineWidth
        self.gap = gap
        super.init(frame: .zero)
        track.fillColor = nil
        track.lineWidth = lineWidth
        progressMask.fillColor = nil
        progressMask.strokeColor = UIColor.black.cgColor
        progressMask.lineWidth = lineWidth
        progressMask.lineCap = .round
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.mask = progressMask
        gradient.locations = [0, 0.3, 1]
        layer.addSublayer(track)
        layer.addSublayer(gradient)
        addSubview(avatar)
        setRuptured(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var ruptured = false

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle { setRuptured(ruptured) }
    }

    func configure(contact: ContactsStore.Contact, initials count: Int = 1) {
        avatar.configure(name: contact.displayName, key: contact.id, imageData: contact.avatarData, initials: count)
        setRuptured(contact.rupturedUntilResolved)
        setProgress(CGFloat(contact.total) / 100)
    }

    func setProgress(_ value: CGFloat) {
        progress = min(max(value, 0), 1)
        progressMask.strokeEnd = progress
        applyGradientLocations()
    }

    /// conic 渐变顺时针铺满整圈，0 和 1 在同一条接缝上。起点的圆头会越过接缝，
    /// 落到渐变最末端（最深色）那一侧，所以之前起点总有一块深色半圆。
    /// 做法：把接缝逆时针挪过圆头的宽度，让起点圆头落在最浅色里；
    /// 再把三段颜色压到可见弧上（起点浅 → 中段主色 → 终点深），末端圆头沿用最深色。
    private func applyGradientLocations() {
        let visible = max(progress, 0.015)
        let offset = Double(capFraction)
        let end = min(offset + Double(visible), 1)
        gradient.locations = [NSNumber(value: offset), NSNumber(value: offset + Double(visible) * 0.55), NSNumber(value: end)]
        let angle = 2 * Double.pi * offset
        gradient.endPoint = CGPoint(x: 0.5 - 0.5 * sin(angle), y: 0.5 - 0.5 * cos(angle))
    }

    private func setRuptured(_ ruptured: Bool) {
        self.ruptured = ruptured
        let end = ruptured ? ContactUI.ruptured : UIColor.galchatPink
        let start = ruptured ? ContactUI.rupturedLight : ContactUI.ringStart
        gradient.colors = [start.cgColor,
                           (ruptured ? ContactUI.ruptured : UIColor(hex: 0xE8456F)).cgColor,
                           end.resolvedColor(with: traitCollection).cgColor]
        applyGradientLocations()
        track.strokeColor = ContactUI.ringTrack.resolvedColor(with: traitCollection).cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = lineWidth + gap
        avatar.frame = bounds.insetBy(dx: inset, dy: inset)
        let radius = (min(bounds.width, bounds.height) - lineWidth) / 2
        capFraction = radius > 0 ? (lineWidth / 2) / radius / (2 * .pi) : 0
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = UIBezierPath(arcCenter: center, radius: radius, startAngle: -.pi / 2,
                                endAngle: .pi * 1.5, clockwise: true).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        track.path = path
        gradient.frame = bounds
        progressMask.frame = bounds
        progressMask.path = path
        progressMask.strokeEnd = progress
        applyGradientLocations()
        CATransaction.commit()
    }
}

// MARK: - 状态标签

/// “待确认”“已纠正”“待修复”“在聊”等小标签。
final class StatusTagLabel: UILabel {
    enum Kind { case accent, warning, positive, negative }

    init(_ text: String, kind: Kind, fontSize: CGFloat = 10.5) {
        super.init(frame: .zero)
        self.text = text
        font = .systemFont(ofSize: fontSize, weight: .semibold)
        textAlignment = .center
        switch kind {
        case .accent: textColor = .galchatPink
        case .warning: textColor = ContactUI.warning
        case .positive: textColor = ContactUI.positive
        case .negative: textColor = ContactUI.negative
        }
        backgroundColor = textColor.withAlphaComponent(0.12)
        layer.cornerRadius = (fontSize + 6) / 2
        layer.cornerCurve = .continuous
        clipsToBounds = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 12, height: size.height + 4)
    }
}

// MARK: - 分段标题

/// 列表的分段标题：“今天”“A”等，直接写在背景上。
final class ContactSectionHeaderView: UITableViewHeaderFooterView {
    static let reuseIdentifier = "ContactSectionHeaderView"
    let titleLabel = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = .clear
        backgroundConfiguration = background
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabel
        titleLabel.adjustsFontForContentSizeCategory = true
        contentView.addSubview(titleLabel)
        titleLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(20)
            make.trailing.lessThanOrEqualToSuperview().inset(20)
            make.top.equalToSuperview().inset(12)
            make.bottom.equalToSuperview().inset(4)
        }
        titleLabel.accessibilityTraits = .header
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - 好感标签

/// 透明液态玻璃胶囊：粉色爱心 + 白色分数。用在立绘或头像模糊底之上。
final class AffectionPillView: UIView {
    private let label = UILabel()

    init(fontSize: CGFloat = 13) {
        super.init(frame: .zero)
        // 不用 UIGlassEffect：它自带一层镜面高光，小控件上会糊成一片白。
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialLight))
        blur.contentView.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        blur.layer.borderWidth = 0.5
        blur.layer.borderColor = UIColor.white.withAlphaComponent(0.4).cgColor
        blur.clipsToBounds = true
        addSubview(blur)
        blur.snp.makeConstraints { make in make.edges.equalToSuperview() }
        let heart = UIImageView(image: UIImage(systemName: "heart.fill",
                                               withConfiguration: UIImage.SymbolConfiguration(pointSize: fontSize * 0.85, weight: .bold)))
        heart.tintColor = UIColor(hex: 0xFF5C98)
        label.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
        label.textColor = .white
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.45
        label.layer.shadowRadius = 2.5
        label.layer.shadowOffset = CGSize(width: 0, height: 1)
        let stack = UIStackView(arrangedSubviews: [heart, label])
        stack.spacing = 5
        stack.alignment = .center
        addSubview(stack)
        stack.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview().inset(3)
            make.leading.equalToSuperview().inset(9)
            make.trailing.equalToSuperview().inset(10)
        }
        glassView = blur
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var glassView: UIView?

    func setScore(_ value: Int) {
        label.text = "\(value)"
        accessibilityLabel = "好感度 \(value)"
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glassView?.layer.cornerRadius = bounds.height / 2
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
