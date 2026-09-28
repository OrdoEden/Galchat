import UIKit
import VisynCapture

/// 竖屏 PiP 的几何：基准 90 × 220（Visyn 竖屏预设 9 : 22）。
/// 设计稿：`docs/design/pip-portrait/竖屏PiP-C+B合成.html`（方向 C 温度计 + 方向 B 头像与气泡）。
///
///     ┌────────────┐
///     │ Galchat   ●│  品牌（OCR 锚点）+ 分析中粉点
///     │ ┃   ┌──┐   │
///     │ ┃   │林│   │  头像（白描边）
///     │ ┃   └──┘   │
///     │ ❤︎   小林   │  名字       ← 左侧竖轨是好感度温度计，
///     │ ┃   68⁺³   │  分数+变化     心跳 GIF 停在当前刻度
///     │ ┃  好感度   │  （OCR 锚点）
///     │╭──────────╮│
///     ││轻松/平和  ││  白色气泡：情绪
///     ││需要关心   ││           建议，一段一行，最多三行
///     ││先回应感受 ││
///     │╰──────────╯│
///     └────────────┘
///
/// 四角 10pt 内不放内容（系统 PiP 圆角会裁掉）。所有尺寸按 `scale` 等比缩放，内容块居中。
nonisolated struct GCPiPPortraitLayout: Sendable {
    static let baseSize = CGSize(width: 90, height: 220)

    let size: CGSize

    var scale: CGFloat {
        guard size.width > 0, size.height > 0 else { return 0.05 }
        return max(0.05, min(size.width / Self.baseSize.width, size.height / Self.baseSize.height))
    }
    private var origin: CGPoint {
        CGPoint(x: max(0, (size.width - Self.baseSize.width * scale) / 2),
                y: max(0, (size.height - Self.baseSize.height * scale) / 2))
    }
    /// 基准坐标 → 实际坐标。
    private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: origin.x + x * scale, y: origin.y + y * scale, width: width * scale, height: height * scale)
    }

    // MARK: 字号

    /// 品牌「Galchat」的字号，也是 OCR 遮挡用的锚点字号。
    var headerFontSize: CGFloat { 9.5 * scale }
    var nameFontSize: CGFloat { 11 * scale }
    var scoreFontSize: CGFloat { 28 * scale }
    var stepFontSize: CGFloat { 9.5 * scale }
    var identityFontSize: CGFloat { 9 * scale }
    var emotionFontSize: CGFloat { 11.5 * scale }
    var adviceFontSize: CGFloat { 9.5 * scale }
    var adviceLineHeight: CGFloat { 13 * scale }

    // MARK: 顶部

    var headerFrame: CGRect { rect(12, 9, 50, 13) }
    var busyDotFrame: CGRect { rect(73, 13, 5, 5) }
    /// 上半部的粉色光晕（方向 B 的头部色带），盖住温度计与分数区。
    var bandFrame: CGRect { rect(0, 0, Self.baseSize.width, 136) }

    // MARK: 左：温度计

    /// 竖轨：底端是 0 分，顶端是 100 分。
    var railFrame: CGRect { rect(11, 36, 7, 96) }
    var heartSide: CGFloat { 22 * scale }
    /// 心跳 GIF 的中心停在当前分数对应的高度。
    func heartFrame(fraction: CGFloat) -> CGRect {
        let rail = railFrame
        let y = rail.maxY - rail.height * min(1, max(0, fraction))
        return CGRect(x: rail.midX - heartSide / 2, y: y - heartSide / 2, width: heartSide, height: heartSide)
    }

    // MARK: 右列：头像、名字、分数

    /// 右列从竖轨右侧到右内边距，宽 58；头像、名字、分数都在这一列里居中。
    var avatarFrame: CGRect { rect(36, 29, 34, 34) }
    var nameFrame: CGRect { rect(24, 67, 58, 14) }
    /// 分数 + 变化值那一行；视图按实际文字宽度把两者作为一组居中。
    var scoreRow: CGRect { rect(24, 83, 58, 30) }
    /// 「好感度」字锚点。
    var identityFrame: CGRect { rect(24, 114, 58, 12) }

    // MARK: 底部：白色气泡

    var bubbleFrame: CGRect { rect(8, 142, 74, 68) }
    var bubbleCornerRadius: CGFloat { 11 * scale }
    /// 左下角是气泡「尾巴」，圆角收小。
    var bubbleTailRadius: CGFloat { 3 * scale }
    var emotionFrame: CGRect { rect(15, 149, 60, 15) }
    /// 建议第 i 行（0 起）。
    func adviceFrame(line: Int) -> CGRect { rect(15, 166 + CGFloat(line) * 13, 60, 13) }
}

/// 竖屏 PiP：左侧温度计 + 右列头像/名字/分数 + 底部白色气泡（情绪与建议）。
/// 文案在 `render` 时按 `GCPiPTextBudget.portrait` 截好，版面上不再做缩字或省略。
@MainActor
final class GCPiPPortraitView: UIView, GCPiPContentView {
    private let base = CALayer()
    private let band = CAGradientLayer()
    private let header = GCPiPFont.label()
    private let busyDot = UIView()
    private let rail = UIView()
    private let railFill = CAGradientLayer()
    private let heart = GCPiPHeart.make()
    private let avatar = GCPiPAvatarView()
    private let name = GCPiPFont.label(align: .center)
    private let score = GCPiPFont.label(align: .center)
    private let step = GCPiPFont.label()
    private let identity = GCPiPFont.label(align: .center)
    private let bubble = CAShapeLayer()
    private let emotion = GCPiPFont.label()
    private let adviceLabels = (0..<GCPiPTextBudget.portrait.adviceLines).map { _ in GCPiPFont.label() }
    private var content = GCPiPContent()
    private let budget = GCPiPTextBudget.portrait

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false

        base.backgroundColor = UIColor(red: 1, green: 0.969, blue: 0.98, alpha: 1).cgColor   // #FFF7FA
        band.type = .radial
        band.colors = [UIColor(red: 1, green: 0.76, blue: 0.83, alpha: 1).cgColor,             // #FFC2D4
                       GCPiPPalette.blush.cgColor,
                       GCPiPPalette.blush.withAlphaComponent(0).cgColor]
        band.locations = [0, 0.5, 1]
        band.startPoint = CGPoint(x: 0.6, y: 0)
        band.endPoint = CGPoint(x: 1.3, y: 1)
        layer.addSublayer(base)
        layer.addSublayer(band)

        header.text = "Galchat"
        identity.text = "好感度"
        busyDot.backgroundColor = GCPiPPalette.pinkDeep

        rail.backgroundColor = GCPiPPalette.pink.withAlphaComponent(0.14)
        rail.clipsToBounds = true
        railFill.startPoint = CGPoint(x: 0.5, y: 1)
        railFill.endPoint = CGPoint(x: 0.5, y: 0)
        rail.layer.addSublayer(railFill)

        avatar.ringWidth = 2

        bubble.fillColor = UIColor.white.cgColor
        bubble.strokeColor = GCPiPPalette.pink.withAlphaComponent(0.15).cgColor
        bubble.shadowColor = UIColor(red: 0.36, green: 0.12, blue: 0.22, alpha: 1).cgColor
        bubble.shadowOpacity = 0.08

        for view in [header, busyDot, rail, heart, avatar, name, score, step, identity] { addSubview(view) }
        layer.addSublayer(bubble)
        addSubview(emotion)
        adviceLabels.forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func render(_ content: GCPiPContent) {
        self.content = content
        avatar.render(initial: content.initial, portrait: content.portrait)
        GCPiPHeart.render(heart, for: content)
        busyDot.isHidden = !content.isBusy
        railFill.colors = content.affection?.ruptured == true
            ? [UIColor.systemRed.cgColor, UIColor.systemRed.cgColor]
            : [GCPiPPalette.pink.cgColor, GCPiPPalette.pink2.cgColor]

        name.text = budget.fitName(content.name)
        score.text = content.scoreText
        step.text = content.stepText
        emotion.text = budget.fitEmotion(content.emotion)
        let lines = budget.fitAdvice(content.advice)
        for (index, label) in adviceLabels.enumerated() {
            label.text = index < lines.count ? lines[index] : nil
            label.isHidden = index >= lines.count
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let layout = GCPiPPortraitLayout(size: bounds.size)
        let s = layout.scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        base.frame = bounds
        band.frame = CGRect(x: 0, y: 0, width: bounds.width, height: layout.bandFrame.maxY)

        header.font = GCPiPFont.text(layout.headerFontSize, .heavy)
        header.textColor = GCPiPPalette.pinkDeep
        header.frame = layout.headerFrame
        busyDot.frame = layout.busyDotFrame
        busyDot.layer.cornerRadius = layout.busyDotFrame.width / 2

        // 温度计：填充从底往上，心停在填充顶端。
        rail.frame = layout.railFrame
        rail.layer.cornerRadius = rail.bounds.width / 2
        let fillHeight = rail.bounds.height * content.fraction
        railFill.frame = CGRect(x: 0, y: rail.bounds.height - fillHeight, width: rail.bounds.width, height: fillHeight)
        railFill.cornerRadius = rail.bounds.width / 2
        heart.frame = layout.heartFrame(fraction: content.fraction)

        avatar.frame = layout.avatarFrame
        name.font = GCPiPFont.text(layout.nameFontSize, .bold)
        name.textColor = GCPiPPalette.ink
        name.frame = layout.nameFrame
        layoutScoreRow(layout)
        identity.font = GCPiPFont.text(layout.identityFontSize, .semibold)
        identity.textColor = GCPiPPalette.muted
        identity.frame = layout.identityFrame

        // 气泡：四角 11，左下角收成 3 当作尾巴。
        let box = layout.bubbleFrame
        let path = Self.bubblePath(in: box, radius: layout.bubbleCornerRadius, tail: layout.bubbleTailRadius)
        bubble.path = path.cgPath
        bubble.shadowPath = path.cgPath
        bubble.lineWidth = 0.5 * s
        bubble.shadowRadius = 4 * s
        bubble.shadowOffset = CGSize(width: 0, height: 2 * s)

        emotion.font = GCPiPFont.text(layout.emotionFontSize, .heavy)
        emotion.textColor = content.emotionColor
        emotion.frame = layout.emotionFrame
        for (index, label) in adviceLabels.enumerated() {
            label.font = GCPiPFont.text(layout.adviceFontSize)
            label.textColor = GCPiPPalette.ink2
            label.frame = layout.adviceFrame(line: index)
        }
    }

    /// 分数与变化值按实际宽度排成一组居中，变化值像角标贴在分数右上。
    private func layoutScoreRow(_ layout: GCPiPPortraitLayout) {
        let row = layout.scoreRow
        let hasScore = content.affection != nil
        score.font = hasScore ? GCPiPFont.number(layout.scoreFontSize)
            : GCPiPFont.text(layout.scoreFontSize * 0.75, .semibold)
        score.textColor = hasScore ? GCPiPPalette.ink : GCPiPPalette.muted
        step.font = GCPiPFont.number(layout.stepFontSize)
        step.textColor = content.stepColor

        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: row.height)
        var scoreWidth = ceil(score.sizeThatFits(unbounded).width)
        let stepWidth = step.text?.isEmpty == false ? ceil(step.sizeThatFits(unbounded).width) : 0
        let gap = stepWidth > 0 ? 1 * layout.scale : 0
        // 「100」加「+12」会超出 58pt 的右列：只把分数字号按比例调小到刚好放下（不压扁字形）。
        let available = row.width - gap - stepWidth
        if hasScore, scoreWidth > available, scoreWidth > 0 {
            score.font = GCPiPFont.number(layout.scoreFontSize * max(0.7, available / scoreWidth))
            scoreWidth = ceil(score.sizeThatFits(unbounded).width)
        }
        let total = min(row.width, scoreWidth + gap + stepWidth)
        let x = row.midX - total / 2
        score.frame = CGRect(x: x, y: row.minY, width: min(scoreWidth, row.width), height: row.height)
        step.isHidden = stepWidth == 0
        step.frame = CGRect(x: score.frame.maxX + gap, y: row.minY + 1 * layout.scale,
                            width: stepWidth, height: layout.stepFontSize * 1.3)
    }

    private static func bubblePath(in rect: CGRect, radius: CGFloat, tail: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(withCenter: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius,
                    startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addArc(withCenter: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius), radius: radius,
                    startAngle: 0, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX + tail, y: rect.maxY))
        path.addArc(withCenter: CGPoint(x: rect.minX + tail, y: rect.maxY - tail), radius: tail,
                    startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(withCenter: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius,
                    startAngle: .pi, endAngle: -.pi / 2, clockwise: true)
        path.close()
        return path
    }
}
