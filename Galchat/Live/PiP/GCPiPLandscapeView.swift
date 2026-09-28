import UIKit
import VisynCapture

/// 横屏 PiP 的几何：基准 414 × 80（Visyn 横屏预设），一行式卡片，照落地页 `.pip`。
///
///     ┌──────┬──────────────────────────────────┬────────┐
///     │      │ Galchat · 小林          本地识别中 ● │  ❤︎    │
///     │  林  │ 轻松/平和 +3                       │  68    │
///     │      │ 需要关心 · 先回应感受                │ 好感度  │
///     │      │ ▰▰▰▰▰▰▰▰▰▰▱▱▱▱▱                  │        │
///     └──────┴──────────────────────────────────┴────────┘
///
/// 纵向尺寸按 `scale` 等比缩放并在窗口里居中；横向主列吃掉剩余宽度，自定义宽窗也不留空。
nonisolated struct GCPiPLandscapeLayout: Sendable {
    static let baseSize = CGSize(width: 414, height: 80)

    let size: CGSize

    var scale: CGFloat {
        guard size.width > 0, size.height > 0 else { return 0.05 }
        return max(0.05, min(size.width / Self.baseSize.width, size.height / Self.baseSize.height))
    }
    /// 基准 80 高的内容块在窗口里垂直居中后的顶边。
    private var top: CGFloat { max(0, (size.height - Self.baseSize.height * scale) / 2) }
    private var insetX: CGFloat { 14 * scale }
    private func y(_ base: CGFloat) -> CGFloat { top + base * scale }

    // MARK: 字号

    /// 抬头「Galchat · 名字」的字号，也是 OCR 遮挡用的锚点字号。
    var headerFontSize: CGFloat { 12 * scale }
    var stateFontSize: CGFloat { 10.5 * scale }
    var emotionFontSize: CGFloat { 15 * scale }
    var stepFontSize: CGFloat { 12 * scale }
    var adviceFontSize: CGFloat { 12 * scale }
    var scoreFontSize: CGFloat { 24 * scale }
    var identityFontSize: CGFloat { 11 * scale }

    // MARK: 左：头像

    var avatarFrame: CGRect {
        CGRect(x: insetX, y: y(14), width: 52 * scale, height: 52 * scale)
    }

    // MARK: 右：心 + 分数 + 好感度

    var scoreColumn: CGRect {
        let width = 62 * scale
        return CGRect(x: size.width - insetX - width, y: y(8), width: width, height: 64 * scale)
    }
    var heartFrame: CGRect {
        let side = 26 * scale
        return CGRect(x: scoreColumn.midX - side / 2, y: y(7), width: side, height: side)
    }
    var scoreFrame: CGRect {
        CGRect(x: scoreColumn.minX, y: y(31), width: scoreColumn.width, height: 28 * scale)
    }
    /// 「好感度」字锚点。
    var identityFrame: CGRect {
        CGRect(x: scoreColumn.minX, y: y(59), width: scoreColumn.width, height: 14 * scale)
    }

    // MARK: 中：主列

    var contentX: CGFloat { avatarFrame.maxX + 12 * scale }
    var contentWidth: CGFloat { max(0, scoreColumn.minX - 8 * scale - contentX) }
    /// 抬头整行；视图在行内右侧放状态，抬头标签只占左边剩下的宽度。
    var headerRow: CGRect { CGRect(x: contentX, y: y(9), width: contentWidth, height: 16 * scale) }
    var emotionFrame: CGRect { CGRect(x: contentX, y: y(27), width: contentWidth, height: 20 * scale) }
    var adviceFrame: CGRect { CGRect(x: contentX, y: y(47), width: contentWidth, height: 16 * scale) }
    var trackFrame: CGRect { CGRect(x: contentX, y: y(66), width: contentWidth, height: 5 * scale) }

    /// 状态最多占抬头行的 45%，剩下的留给「Galchat · 名字」。
    var stateMaxWidth: CGFloat { contentWidth * 0.45 }
    /// 抬头标签的 frame（状态隐藏时占满整行）；OCR 遮挡按这里的中心反推窗口位置。
    var headerFrame: CGRect { headerRow }

    /// 分数块背后的光晕。
    var glowCenter: CGPoint { CGPoint(x: scoreColumn.midX, y: scoreColumn.midY) }
    var glowRadius: CGFloat { 70 * scale }
}

/// 横屏 PiP：一行式卡片，信息最全（含状态文案与进度条）。
/// 文案在渲染时按 `GCPiPTextBudget.landscape` 截好：状态只留第一个分句，建议放不下的段整段丢弃。
@MainActor
final class GCPiPLandscapeView: UIView, GCPiPContentView {
    private let background = GCPiPBackgroundView(vertical: false)
    private let avatar = GCPiPAvatarView()
    private let header = GCPiPFont.label()
    private let state = GCPiPFont.label(align: .right)
    private let busyDot = UIView()
    private let emotion = GCPiPFont.label()
    private let advice = GCPiPFont.label()
    private let track = GCPiPProgressView()
    private let heart = GCPiPHeart.make()
    private let score = GCPiPFont.label(align: .center)
    private let identity = GCPiPFont.label(align: .center)
    private var content = GCPiPContent()
    private let budget = GCPiPTextBudget.landscape

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        busyDot.backgroundColor = GCPiPPalette.pink
        identity.text = "好感度"
        for view in [background, avatar, header, state, busyDot, emotion, advice, track, heart, score, identity] {
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func render(_ content: GCPiPContent) {
        self.content = content
        avatar.render(initial: content.initial, portrait: content.portrait)
        track.render(fraction: content.fraction, ruptured: content.affection?.ruptured == true)
        GCPiPHeart.render(heart, for: content)
        state.text = budget.fitStatus(content.progress)
        advice.text = budget.fitAdvice(content.advice).first
        busyDot.isHidden = !content.isBusy
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let layout = GCPiPLandscapeLayout(size: bounds.size)
        let s = layout.scale

        background.frame = bounds
        background.layout(glowCenter: layout.glowCenter, glowRadius: layout.glowRadius)
        avatar.frame = layout.avatarFrame

        // 抬头：「Galchat」粗体 +「· 名字」，与落地页 `.pip-top b` 一致。
        header.attributedText = headerText(size: layout.headerFontSize)
        header.frame = layout.headerFrame

        // 状态靠右，宽度按文字实际宽度收紧，抬头标签只让出这么多。
        state.font = GCPiPFont.text(layout.stateFontSize)
        state.textColor = GCPiPPalette.muted
        let dotSide = 5 * s
        let dotSpace = busyDot.isHidden ? 0 : dotSide + 4 * s
        let row = layout.headerRow
        let stateWidth = min(layout.stateMaxWidth - dotSpace,
                             ceil(state.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: row.height)).width))
        let showsState = stateWidth > 24 * s
        state.isHidden = !showsState
        busyDot.alpha = showsState ? 1 : 0
        if showsState {
            state.frame = CGRect(x: row.maxX - dotSpace - stateWidth, y: row.minY, width: stateWidth, height: row.height)
            busyDot.frame = CGRect(x: row.maxX - dotSide, y: row.midY - dotSide / 2, width: dotSide, height: dotSide)
            busyDot.layer.cornerRadius = dotSide / 2
            header.frame.size.width = max(0, state.frame.minX - 8 * s - row.minX)
        }

        emotion.attributedText = emotionText(layout: layout)
        emotion.frame = layout.emotionFrame
        advice.font = GCPiPFont.text(layout.adviceFontSize)
        advice.textColor = GCPiPPalette.ink2
        advice.frame = layout.adviceFrame
        track.frame = layout.trackFrame

        heart.frame = layout.heartFrame
        score.text = content.scoreText
        score.font = content.affection == nil ? GCPiPFont.text(layout.scoreFontSize * 0.8, .semibold)
            : GCPiPFont.number(layout.scoreFontSize)
        score.textColor = content.affection == nil ? GCPiPPalette.muted : GCPiPPalette.ink
        score.frame = layout.scoreFrame
        identity.font = GCPiPFont.text(layout.identityFontSize, .semibold)
        identity.textColor = GCPiPPalette.muted
        identity.frame = layout.identityFrame
    }

    private func headerText(size: CGFloat) -> NSAttributedString {
        let text = NSMutableAttributedString(string: "Galchat", attributes: [
            .font: GCPiPFont.text(size, .bold), .foregroundColor: GCPiPPalette.ink
        ])
        text.append(NSAttributedString(string: " · \(budget.fitName(content.name))", attributes: [
            .font: GCPiPFont.text(size, .semibold), .foregroundColor: GCPiPPalette.ink
        ]))
        return text
    }

    /// 「轻松/平和 +3」：情绪按语气着色，变化值跟在后面用小一号的粉/红。
    private func emotionText(layout: GCPiPLandscapeLayout) -> NSAttributedString {
        let text = NSMutableAttributedString(string: budget.fitEmotion(content.emotion), attributes: [
            .font: GCPiPFont.text(layout.emotionFontSize, .heavy), .foregroundColor: content.emotionColor
        ])
        if !content.stepText.isEmpty {
            text.append(NSAttributedString(string: "  \(content.stepText)", attributes: [
                .font: GCPiPFont.number(layout.stepFontSize), .foregroundColor: content.stepColor
            ]))
        }
        return text
    }
}
