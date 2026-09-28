import UIKit
import VisynCapture

// 横屏与竖屏两种 PiP 共用的配色、数据与小组件。视觉照落地页 `.pip` 卡片：
// 粉白渐变底、粉色渐变头像、「Galchat · 名字」抬头、情绪 + 建议、粉色进度条、心跳 + 分数 + 好感度。

/// 落地页 `styles.css` 的 `:root` 配色。
enum GCPiPPalette {
    static let ink = UIColor(hex: 0x2B1D24)
    static let ink2 = UIColor(hex: 0x5E4A54)
    static let muted = UIColor(hex: 0x7C6770)
    static let pink = UIColor(hex: 0xF04B7A)
    static let pink2 = UIColor(hex: 0xFF8FB0)
    static let pinkDeep = UIColor(hex: 0xC42A5A)
    static let blush = UIColor(hex: 0xFFE3EC)
    static let avatarTop = UIColor(hex: 0xFFB0C6)
    /// `.pip-emotion` 默认的平静绿、`--amber`，以及冲突时的深红；浅底上都 ≥ 4.5 : 1。
    static let calm = UIColor(hex: 0x2B4D3B)
    static let warn = UIColor(hex: 0x8A4B0F)
    static let danger = UIColor(hex: 0xA61E2E)
    static let track = UIColor.black.withAlphaComponent(0.07)
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// 一次 PiP 展示需要的全部数据；容器视图把它原样交给当前方向的视图。
struct GCPiPContent {
    var name = "当前会话"
    var emotion = "等待分析"
    var advice = "打开聊天，等待分析"
    var progress = "等待聊天"
    var tone: GCPiPView.Tone = .neutral
    var affection: GCPiPView.AffectionDisplay?
    var isLive = false
    var portrait: PiPPortrait?

    /// 状态文案里带「分析中」时，状态后面亮一个粉点（落地页 `.pip-state.busy`）。
    var isBusy: Bool { progress.contains("分析中") }
    var step: Int { affection?.step ?? 0 }
    var scoreText: String { affection.map { String(min(100, max(0, $0.total))) } ?? "—" }
    var fraction: CGFloat { affection.map { CGFloat(min(100, max(0, $0.total))) / 100 } ?? 0 }
    var initial: String { name.first.map(String.init) ?? "G" }

    /// 「+3」「−2」，持平时为空。
    var stepText: String {
        guard step != 0 else { return "" }
        return "\(step > 0 ? "+" : "−")\(abs(step))"
    }
    var stepColor: UIColor { step > 0 ? GCPiPPalette.pinkDeep : GCPiPPalette.danger }

    /// 情绪行跟着危险分换色：平静绿、试探琥珀、冲突深红；未分析时上升偏粉。
    var emotionColor: UIColor {
        switch tone {
        case .neutral: return step > 0 ? GCPiPPalette.pinkDeep : GCPiPPalette.ink
        case .calm: return GCPiPPalette.calm
        case .warn: return GCPiPPalette.warn
        case .danger: return GCPiPPalette.danger
        }
    }
}

/// 两种方向的视图都实现它，容器只管把数据推下去。
@MainActor
protocol GCPiPContentView: UIView {
    func render(_ content: GCPiPContent)
}

enum GCPiPFont {
    static func text(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        .systemFont(ofSize: max(1, size), weight: weight)
    }

    /// 分数用等宽数字，数值跳动时不左右晃。
    static func number(_ size: CGFloat) -> UIFont {
        .monospacedDigitSystemFont(ofSize: max(1, size), weight: .heavy)
    }

    /// 单行标签：不做缩字（缩字会把中文挤扁），放不下就省略号。
    @MainActor
    static func label(align: NSTextAlignment = .left, lines: Int = 1) -> UILabel {
        let label = UILabel()
        label.textAlignment = align
        label.numberOfLines = lines
        label.lineBreakMode = .byTruncatingTail
        label.adjustsFontSizeToFitWidth = false
        label.backgroundColor = .clear
        return label
    }
}

// MARK: - 背景

/// 落地页卡片底：`linear-gradient(100deg, #FFE3EC, #FFFFFF 55%)`，再在右上角铺一层淡粉光晕。
/// PiP 窗口的圆角由系统裁切，这里铺满整块、不自己做圆角，免得四角露出白边。
@MainActor
final class GCPiPBackgroundView: UIView {
    private let base = CAGradientLayer()
    private let glow = CAGradientLayer()

    init(vertical: Bool) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        base.colors = [GCPiPPalette.blush.cgColor, UIColor.white.cgColor]
        base.locations = [0, 0.58]
        base.startPoint = vertical ? CGPoint(x: 0.3, y: 0) : CGPoint(x: 0, y: 0.35)
        base.endPoint = vertical ? CGPoint(x: 0.7, y: 1) : CGPoint(x: 1, y: 0.65)
        glow.type = .radial
        // 渐变终点用透明粉而不是 .clear（透明黑），否则光栅化后边缘发灰。
        glow.colors = [GCPiPPalette.pink2.withAlphaComponent(0.2).cgColor,
                       GCPiPPalette.pink2.withAlphaComponent(0).cgColor]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(base)
        layer.addSublayer(glow)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 光晕放在分数块后面，让「心 + 分数」成为视觉焦点。
    func layout(glowCenter: CGPoint, glowRadius: CGFloat) {
        base.frame = bounds
        glow.frame = CGRect(x: glowCenter.x - glowRadius, y: glowCenter.y - glowRadius,
                            width: glowRadius * 2, height: glowRadius * 2)
    }
}

// MARK: - 头像

/// 落地页 `.pip-avatar`：粉色渐变圆角方块 + 白色首字；识别到立绘时换成立绘。
@MainActor
final class GCPiPAvatarView: UIView {
    private let clip = UIView()
    private let gradient = CAGradientLayer()
    private let image = UIImageView()
    private let initial = UILabel()
    private var portraitID: UUID?
    /// 外圈白描边宽度（竖屏用，照方向 B 的头像）；0 为无描边。
    var ringWidth: CGFloat = 0 { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerCurve = .continuous
        layer.shadowColor = GCPiPPalette.pink.cgColor
        layer.shadowOpacity = 0.28
        clip.clipsToBounds = true
        clip.layer.cornerCurve = .continuous
        gradient.colors = [GCPiPPalette.avatarTop.cgColor, GCPiPPalette.pink.cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        clip.layer.addSublayer(gradient)
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        clip.addSubview(image)
        initial.textColor = .white
        initial.textAlignment = .center
        initial.adjustsFontSizeToFitWidth = false
        clip.addSubview(initial)
        addSubview(clip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func render(initial text: String, portrait: PiPPortrait?) {
        initial.text = text
        guard portrait?.imageID != portraitID else { return }
        portraitID = portrait?.imageID
        image.image = portrait?.image
        image.isHidden = portrait == nil
        initial.isHidden = portrait != nil
        gradient.isHidden = portrait != nil
        clip.backgroundColor = portrait?.tint
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = bounds.width * 0.29
        let ring = min(ringWidth, bounds.width / 4)
        backgroundColor = ring > 0 ? .white : .clear
        layer.cornerRadius = radius
        clip.frame = bounds.insetBy(dx: ring, dy: ring)
        clip.layer.cornerRadius = max(0, radius - ring)
        gradient.frame = clip.bounds
        image.frame = clip.bounds
        initial.frame = clip.bounds
        initial.font = GCPiPFont.text(clip.bounds.height * 0.48, .bold)
        layer.shadowRadius = bounds.height * 0.14
        layer.shadowOffset = CGSize(width: 0, height: bounds.height * 0.08)
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
    }
}

// MARK: - 进度条

/// 落地页 `.pip-track`：浅灰轨道 + 粉色渐变填充；关系破裂时整条变红。
@MainActor
final class GCPiPProgressView: UIView {
    private let fill = CAGradientLayer()
    private var fraction: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = GCPiPPalette.track
        clipsToBounds = true
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(fill)
        render(fraction: 0, ruptured: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func render(fraction: CGFloat, ruptured: Bool) {
        self.fraction = min(1, max(0, fraction))
        fill.colors = ruptured
            ? [UIColor.systemRed.cgColor, UIColor.systemRed.cgColor]
            : [GCPiPPalette.pink2.cgColor, GCPiPPalette.pink.cgColor]
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
        fill.cornerRadius = bounds.height / 2
        CATransaction.commit()
    }
}

// MARK: - 心跳动图

/// 好感度变化方向对应的 GIF：持平心跳、上升动心、下降或破裂心碎。三者首帧与静止位置一致。
/// PiP 是离屏光栅化，UIImageView 自带动画不会被录进去，由 Visyn 在每帧前按时间戳选帧。
@MainActor
enum GCPiPHeart {
    private static let animations: [String: VisynAnimatedImage] = [
        "heartbeat", "heartflutter", "heartbreak"
    ].reduce(into: [:]) { result, name in
        if let url = Bundle.main.url(forResource: name, withExtension: "gif"),
           let animation = VisynAnimatedImage(url: url) {
            result[name] = animation
        }
    }

    static func make() -> VisynAnimatedImageView {
        let view = VisynAnimatedImageView()
        view.contentMode = .scaleAspectFit
        view.tintColor = GCPiPPalette.pink
        view.fallbackImage = UIImage(systemName: "heart.fill")
        view.animation = animations["heartbeat"]
        return view
    }

    /// 录屏进行中就一直播（没有分数时也是心跳），停止录屏后停在首帧。
    static func render(_ view: VisynAnimatedImageView, for content: GCPiPContent) {
        let name: String
        if content.affection?.ruptured == true || content.step < 0 {
            name = "heartbreak"
        } else if content.step > 0 {
            name = "heartflutter"
        } else {
            name = "heartbeat"
        }
        let animation = animations[name] ?? animations["heartbeat"]
        if view.animation !== animation { view.animation = animation }
        view.playsAnimation = content.isLive
    }
}
