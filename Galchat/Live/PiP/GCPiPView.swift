import UIKit
import VisynCapture

/// Galchat 的 PiP 业务内容：落地页那张卡片的一比一实现（粉色渐变、头像、来源与状态、
/// 情绪与建议、好感度进度条，以及右侧的桃心 + 分数 + 「好感度」）。
///
/// 立绘（头像淡出到主题色）与心跳动图由 Visyn 渲染，这里只传图片与颜色。
/// 横屏是一行式卡片：头像在左，抬头与状态右上，情绪与建议一列，进度条贴底，分数块在右上角。
/// 竖屏把同一份信息纵向重排：分数块在顶部，头像在其下，然后抬头、姓名、情绪、建议，
/// 进度条与状态贴底。
@MainActor
final class GCPiPView: UIView {
    /// 好感度变化方向对应的动图：上升动心、下降心碎、持平心跳。三者首帧与静止位置一致。
    private static let heartAnimations: [Int: VisynAnimatedImage] = [
        0: "heartbeat", 1: "heartflutter", -1: "heartbreak"
    ].compactMapValues { name in
        Bundle.main.url(forResource: name, withExtension: "gif").flatMap { VisynAnimatedImage(url: $0) }
    }

    // MARK: - 落地页配色

    private enum Palette {
        /// 主文字与分数：落地页是 #2B1D24 那一族的暖黑。
        static let ink = UIColor(red: 0.17, green: 0.11, blue: 0.14, alpha: 1)
        /// 建议等次级文字。
        static let ink2 = UIColor(red: 0.37, green: 0.29, blue: 0.33, alpha: 1)
        /// 状态与说明文字。
        static let muted = UIColor(red: 0.49, green: 0.40, blue: 0.44, alpha: 1)
        static let pink = UIColor(red: 0.94, green: 0.29, blue: 0.48, alpha: 1)
        static let pinkDeep = UIColor(red: 0.77, green: 0.16, blue: 0.35, alpha: 1)
        static let pink2 = UIColor(red: 1, green: 0.56, blue: 0.69, alpha: 1)
        static let blush = UIColor(red: 1, green: 0.89, blue: 0.93, alpha: 1)
        /// 平静与紧张两种情绪色：浅底上都要达到 4.5 : 1 对比度。
        static let calm = UIColor(red: 0.17, green: 0.30, blue: 0.23, alpha: 1)
        static let warn = UIColor(red: 0.54, green: 0.29, blue: 0.06, alpha: 1)
        static let danger = UIColor(red: 0.65, green: 0.12, blue: 0.18, alpha: 1)
    }

    private let backgroundGradient = CAGradientLayer()
    private let progressGradient = CAGradientLayer()
    private let avatarCard = UIView()
    private let avatar = UIImageView()
    private let avatarInitial = UILabel()
    private let header = UILabel()
    private let state = UILabel()
    private let title = UILabel()
    private let emotion = UILabel()
    private let advice = UILabel()
    private let footer = UILabel()
    private let score = UILabel()
    private let instruction = UILabel()
    private let identity = UILabel()
    private let heart = VisynAnimatedImageView()
    private let track = UIView()
    private let fill = UIView()
    private var affectionTotal: Int?
    private var portraitID: UUID?
    private var displayedName = "当前会话"
    private var displayedProgress = "等待聊天"
    private var displayedStep = 0
    private var displayedEmotion = "等待分析"
    private var displayedTone: Tone = .neutral

    override init(frame: CGRect) {
        super.init(frame: frame)
        overrideUserInterfaceStyle = .light
        clipsToBounds = true
        layer.cornerCurve = .continuous
        backgroundGradient.startPoint = CGPoint(x: 0, y: 0)
        backgroundGradient.endPoint = CGPoint(x: 1, y: 1)
        backgroundGradient.colors = [Palette.blush.cgColor, UIColor.white.cgColor]
        layer.insertSublayer(backgroundGradient, at: 0)

        avatarCard.clipsToBounds = true
        avatarCard.layer.cornerCurve = .continuous
        avatarCard.backgroundColor = Palette.blush
        avatar.contentMode = .scaleAspectFill
        avatar.clipsToBounds = true
        avatarCard.addSubview(avatar)
        avatarInitial.font = .systemFont(ofSize: 18, weight: .bold)
        avatarInitial.textColor = .white
        avatarInitial.textAlignment = .center
        avatarCard.addSubview(avatarInitial)
        addSubview(avatarCard)

        heart.contentMode = .scaleAspectFit
        heart.tintColor = Palette.pink
        heart.fallbackImage = UIImage(systemName: "heart.fill")
        heart.animation = Self.heartAnimations[0]
        addSubview(heart)

        identity.text = "好感度"
        identity.textAlignment = .center
        identity.adjustsFontSizeToFitWidth = true
        identity.minimumScaleFactor = 0.7
        instruction.text = "AI 估计"
        instruction.textAlignment = .center
        instruction.adjustsFontSizeToFitWidth = true
        instruction.minimumScaleFactor = 0.7
        score.textAlignment = .center
        score.adjustsFontSizeToFitWidth = true
        score.minimumScaleFactor = 0.6
        // 状态标签独立成块：字号、颜色都与标题不同，右对齐贴着卡片边缘。
        state.textAlignment = .right
        footer.textAlignment = .left
        for label in [header, state, title, emotion, advice, footer, score, instruction, identity, avatarInitial] {
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        header.text = "Galchat"
        footer.text = "AI 估计"
        title.text = displayedName

        track.backgroundColor = UIColor.black.withAlphaComponent(0.08)
        track.clipsToBounds = true
        track.addSubview(fill)
        progressGradient.startPoint = CGPoint(x: 0, y: 0.5)
        progressGradient.endPoint = CGPoint(x: 1, y: 0.5)
        progressGradient.colors = [Palette.pink2.cgColor, Palette.pink.cgColor]
        fill.layer.addSublayer(progressGradient)
        addSubview(track)

        isAccessibilityElement = true
        applyTone()
        setPortrait(nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPortrait(_ portrait: PiPPortrait?) {
        guard portrait?.imageID != portraitID else { return }
        portraitID = portrait?.imageID
        avatar.image = portrait?.image
        let tint: UIColor
        if let portrait {
            tint = portrait.tint
            avatar.tintColor = nil
        } else {
            tint = .galchatPink
            avatar.tintColor = .white
            avatar.image = UIImage(systemName: "person.fill")
        }
        avatarCard.backgroundColor = tint
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let layout = GCPiPLayout(size: bounds.size)
        let s = layout.scale
        // 抬头带来源，和落地页一致：横屏没有姓名行，名字跟在抬头里；竖屏的姓名单独占一行。
        header.text = layout.headerShowsName ? "Galchat · \(displayedName.prefix(8))" : "Galchat"
        footer.text = "AI 估计 · \(displayedProgress)"

        backgroundGradient.frame = bounds
        backgroundGradient.cornerRadius = layout.backgroundCornerRadius
        layer.cornerRadius = layout.backgroundCornerRadius

        avatarCard.frame = layout.avatarFrame
        avatarCard.layer.cornerRadius = layout.avatarCornerRadius
        avatar.frame = avatarCard.bounds
        avatarInitial.frame = avatarCard.bounds
        avatarInitial.text = String(displayedName.prefix(1))
        avatarInitial.font = .systemFont(ofSize: max(10, layout.avatarFrame.height * 0.5), weight: .bold)
        avatarInitial.isHidden = avatar.image != nil && avatar.tintColor == nil

        header.frame = layout.headerFrame
        title.frame = layout.titleFrame
        state.frame = layout.stateFrame
        footer.frame = layout.footerFrame
        emotion.frame = layout.emotionFrame
        advice.frame = layout.adviceFrame
        heart.frame = layout.heartFrame
        score.frame = layout.scoreFrame
        instruction.frame = layout.instructionFrame
        identity.frame = layout.identityFrame

        // 字号与颜色照落地页：抬头 11、姓名 14 加粗、情绪 12.5 加粗、建议 10.5、
        // 状态与说明 9–10.5，整体随卡片缩放。
        header.font = .systemFont(ofSize: layout.markerFontSize, weight: .semibold)
        header.textColor = Palette.ink
        state.font = .systemFont(ofSize: 10.5 * s)
        state.textColor = Palette.muted
        title.font = .systemFont(ofSize: 14 * s, weight: .bold)
        title.textColor = Palette.ink
        emotion.font = .systemFont(ofSize: 12.5 * s, weight: .bold)
        advice.font = .systemFont(ofSize: 10.5 * s)
        advice.textColor = Palette.ink2
        footer.font = .systemFont(ofSize: 10.5 * s)
        footer.textColor = Palette.muted
        score.font = .systemFont(ofSize: layout.scoreFontSize, weight: .medium)
        score.textColor = Palette.ink
        instruction.font = .systemFont(ofSize: 9 * s)
        instruction.textColor = Palette.muted
        identity.font = .systemFont(ofSize: 9 * s, weight: .semibold)
        identity.textColor = Palette.ink2
        identity.backgroundColor = UIColor.white.withAlphaComponent(0.9)

        // 放不下的整行隐藏，几何里已经算好每一行是否放得下。
        advice.numberOfLines = layout.isPortrait ? 2 : 1
        footer.numberOfLines = 2
        title.isHidden = !layout.canShowTitle
        emotion.isHidden = !layout.canShowEmotion
        advice.isHidden = !layout.canShowAdvice
        footer.isHidden = !layout.canShowFooter
        state.isHidden = !layout.canShowState
        instruction.isHidden = !layout.canShowInstruction
        identity.isHidden = !layout.canShowIdentity

        track.frame = layout.trackFrame
        track.layer.cornerRadius = track.bounds.height / 2
        let fraction = CGFloat(affectionTotal ?? 0) / 100
        fill.frame = CGRect(x: 0, y: 0, width: track.bounds.width * fraction, height: track.bounds.height)
        progressGradient.frame = fill.bounds
        track.isHidden = affectionTotal == nil || track.frame.minY < layout.headerFrame.maxY
    }

    enum Tone { case neutral, calm, warn, danger }

    struct AffectionDisplay {
        let total: Int
        let step: Int
        let ruptured: Bool
    }

    func show(name: String, emotion emotionText: String, advice adviceText: String, progress progressText: String,
              tone: Tone, affection: AffectionDisplay?, isLive: Bool) {
        displayedName = name
        displayedProgress = progressText
        displayedStep = affection?.step ?? 0
        displayedEmotion = emotionText
        displayedTone = tone
        title.text = String(name.prefix(8))
        emotion.text = emotionText
        advice.text = adviceText
        affectionTotal = affection.map { min(100, max(0, $0.total)) }
        score.text = affectionTotal.map { String($0) } ?? "—"
        let trend = displayedStep.signum()
        let animation = Self.heartAnimations[trend] ?? Self.heartAnimations[0]
        if heart.animation !== animation { heart.animation = animation }
        heart.playsAnimation = isLive && affection != nil && affection?.ruptured == false
        heart.alpha = affection == nil ? 0.35 : 1
        fill.backgroundColor = affection?.ruptured == true ? .systemRed : .clear
        progressGradient.colors = affection?.ruptured == true
            ? [UIColor.systemRed.cgColor, UIColor.systemRed.cgColor]
            : [Palette.pink2.cgColor, Palette.pink.cgColor]
        applyTone()
        accessibilityLabel = "\(name)，好感度 \(affectionTotal.map { String($0) } ?? "未知")，\(emotionText)，\(adviceText)，\(progressText)"
        setNeedsLayout()
    }

    /// 情绪行跟着危险分换色：平静偏粉、试探偏琥珀、冲突偏红。
    private func applyTone() {
        let change = displayedStep == 0 ? "" : " \(displayedStep > 0 ? "+" : "−")\(abs(displayedStep))"
        emotion.text = displayedEmotion + change
        switch displayedTone {
        case .neutral: emotion.textColor = displayedStep > 0 ? Palette.pinkDeep : Palette.ink
        case .calm: emotion.textColor = Palette.calm
        case .warn: emotion.textColor = Palette.warn
        case .danger: emotion.textColor = Palette.danger
        }
        progressGradient.colors = fill.backgroundColor == .systemRed
            ? [UIColor.systemRed.cgColor, UIColor.systemRed.cgColor]
            : [Palette.pink2.cgColor, Palette.pink.cgColor]
    }
}

/// Jev 判断键 → 画中画里能一眼看懂的中文。
enum JudgeLabels {
    /// 与落地页的危险分段一致；仅描述模型对当前语气的估计。
    static func emotion(level: Int, maxLevel: Int) -> String {
        let scaled = Double(level) * 9 / Double(max(maxLevel, 1))
        if scaled >= 8 { return "高度紧张" }
        if scaled >= 6 { return "愤怒/冲突" }
        if scaled >= 3 { return "不满/试探" }
        return "轻松/平和"
    }

    static func intentSummary(_ analysis: Analysis) -> String {
        var parts: [String] = []
        if let intent = analysis.trueIntent { parts.append(Self.intent(intent.choice)) }
        if let resolved = analysis.tensionResolved {
            parts.append(resolved >= 0.7 ? "紧张已缓解" : "仍需留意情绪")
        }
        return parts.isEmpty ? "判断接口未返回意图" : parts.joined(separator: " · ")
    }

    static func advice(_ analysis: Analysis) -> String {
        var parts: [String] = []
        if let need = analysis.sheNeeds { parts.append(Self.need(need.choice)) }
        if let action = analysis.bestAction { parts.append(Self.action(action.choice)) }
        if let reply = analysis.shouldReplyNow { parts.append(reply >= 0.5 ? "可给实质答复" : "先别猜测事实") }
        return parts.isEmpty ? "暂无行动建议" : parts.joined(separator: " · ")
    }
    static func intent(_ key: String) -> String {
        [
            "confirm_you_care": "在试探你是否在乎",
            "vent_anger": "在发泄情绪",
            "request_action": "要你给出行动/答复",
            "seek_explanation": "想要一个解释",
            "casual_chat": "轻松闲聊",
            "close_topic": "话题可以收尾"
        ][key] ?? key
    }

    static func need(_ key: String) -> String {
        [
            "apology": "需要道歉",
            "action": "需要具体行动",
            "explanation": "需要解释",
            "care": "需要关心",
            "nothing": "不需要更多"
        ][key] ?? key
    }

    static func action(_ key: String) -> String {
        [
            "check_history": "先翻聊天记录再回",
            "apologize": "先真诚道歉",
            "give_commitment": "给出具体承诺",
            "explain": "解释清楚原因",
            "acknowledge": "先回应感受",
            "say_less": "少说为好",
            "make_plan": "直接约定安排"
        ][key] ?? key
    }

    /// 一句话判断：意图 → 需要 · 建议。
    static func summary(_ analysis: Analysis) -> String {
        var parts: [String] = []
        if let intent = analysis.trueIntent { parts.append(Self.intent(intent.choice)) }
        if let need = analysis.sheNeeds { parts.append(Self.need(need.choice)) }
        var text = parts.joined(separator: " → ")
        if let action = analysis.bestAction { text += (text.isEmpty ? "" : " · ") + "建议" + Self.action(action.choice) }
        return text.isEmpty ? "判断接口未返回结论" : text
    }
}
