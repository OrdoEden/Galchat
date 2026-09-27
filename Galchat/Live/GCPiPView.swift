import UIKit
import VisynCapture

/// Galchat 的 PiP 业务内容：文案、好感度与 OCR 锚点。
/// 立绘（头像淡出到主题色）和心跳动图由 Visyn 渲染，这里只传图片与颜色。
@MainActor
final class GCPiPView: UIView {
    private let portraitView = VisynPortraitView()
    private let header = UILabel()
    private let identity = UILabel()
    private let footer = UILabel()
    private let title = UILabel()
    private let score = UILabel()
    private let emotion = UILabel()
    private let advice = UILabel()
    private let progress = UILabel()
    private let heart = VisynAnimatedImageView()
    private let track = UIView()
    private let fill = UIView()
    private var affectionTotal: Int?
    private var portraitID: UUID?
    private var displayedName = "当前会话"
    private var displayedProgress = "等待聊天"
    private var displayedStep = 0
    private var displayedEmotion = "等待分析"

    override init(frame: CGRect) {
        super.init(frame: frame)
        overrideUserInterfaceStyle = .light
        clipsToBounds = true
        addSubview(portraitView)
        heart.contentMode = .scaleAspectFit
        heart.tintColor = .galchatPink
        heart.fallbackImage = UIImage(systemName: "heart.fill")
        heart.animation = Bundle.main.url(forResource: "heartbeat", withExtension: "gif")
            .flatMap { VisynAnimatedImage(url: $0) }
        addSubview(heart)
        for label in [identity, header, footer, title, score, emotion, advice, progress] {
            label.textColor = UIColor(red: 0.17, green: 0.22, blue: 0.20, alpha: 1)
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        header.text = "Galchat"
        footer.text = "AI 估计"
        identity.text = "好感度"
        identity.backgroundColor = UIColor.white.withAlphaComponent(0.9)
        track.backgroundColor = UIColor.black.withAlphaComponent(0.08)
        fill.backgroundColor = .galchatPink
        track.clipsToBounds = true
        track.addSubview(fill)
        addSubview(track)
        isAccessibilityElement = true
        setPortrait(nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPortrait(_ portrait: PiPPortrait?) {
        guard portrait?.imageID != portraitID else { return }
        portraitID = portrait?.imageID
        portraitView.setPortrait(image: portrait?.image, tint: portrait?.tint ?? PiPPortrait.defaultTint)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let layout = GCPiPLayout(size: bounds.size)
        let s = layout.scale
        header.text = layout.contentWidth < 100 * s ? "Galchat" : "Galchat · \(displayedName.prefix(8))"
        footer.text = layout.contentWidth < 100 * s ? "AI 估计" : "AI 估计 · \(displayedProgress)"
        score.text = affectionTotal.map { String($0) } ?? "—"
        let change = displayedStep == 0 ? "" : " \(displayedStep > 0 ? "+" : "−")\(abs(displayedStep))"
        emotion.text = displayedEmotion + change
        portraitView.imageFrame = layout.avatarFrame
        portraitView.frame = bounds
        header.frame = layout.headerFrame
        identity.frame = layout.identityFrame
        footer.frame = layout.footerFrame
        title.frame = layout.titleFrame
        heart.frame = layout.heartFrame
        score.frame = layout.scoreFrame
        emotion.frame = layout.emotionFrame
        advice.frame = layout.adviceFrame
        progress.frame = layout.progressFrame
        header.font = .systemFont(ofSize: layout.markerFontSize, weight: .semibold)
        footer.font = .systemFont(ofSize: layout.markerFontSize, weight: .medium)
        identity.font = .systemFont(ofSize: min(layout.markerFontSize, layout.identityFrame.width / 3), weight: .semibold)
        title.font = .systemFont(ofSize: 14 * s, weight: .semibold)
        score.font = .monospacedDigitSystemFont(ofSize: (layout.isPortrait ? 24 : 20) * s, weight: .semibold)
        score.adjustsFontSizeToFitWidth = true
        score.minimumScaleFactor = 0.65
        emotion.font = .systemFont(ofSize: 12 * s, weight: .medium)
        advice.font = .systemFont(ofSize: 11 * s)
        advice.numberOfLines = layout.isPortrait ? 3 : 1
        progress.font = .systemFont(ofSize: 10 * s)
        progress.numberOfLines = 2
        title.isHidden = !layout.isPortrait || title.frame.maxY >= layout.footerFrame.minY
        advice.isHidden = advice.frame.maxY > layout.trackFrame.minY
        progress.isHidden = !layout.isPortrait || progress.frame.maxY > layout.trackFrame.minY
        emotion.isHidden = emotion.frame.maxY > layout.trackFrame.minY
        heart.isHidden = heart.frame.maxY > layout.trackFrame.minY
        score.isHidden = heart.isHidden
        track.frame = layout.trackFrame
        track.layer.cornerRadius = track.bounds.height / 2
        fill.frame = CGRect(x: 0, y: 0, width: track.bounds.width * CGFloat(affectionTotal ?? 0) / 100,
                            height: track.bounds.height)
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
        let shortName = String(name.prefix(8))
        displayedName = name
        displayedProgress = progressText
        displayedStep = affection?.step ?? 0
        displayedEmotion = emotionText
        header.text = "Galchat"
        footer.text = "AI 估计"
        title.text = shortName
        emotion.text = emotionText
        advice.text = adviceText
        progress.text = progressText
        affectionTotal = affection.map { min(100, max(0, $0.total)) }
        score.text = affectionTotal.map { String($0) } ?? "—"
        heart.playsAnimation = isLive && affection != nil && affection?.ruptured == false
        heart.alpha = affection == nil ? 0.35 : 1
        fill.backgroundColor = affection?.ruptured == true ? .systemRed : .galchatPink
        switch tone {
        case .neutral, .calm: emotion.textColor = UIColor(red: 0.17, green: 0.30, blue: 0.23, alpha: 1)
        case .warn: emotion.textColor = UIColor(red: 0.50, green: 0.27, blue: 0.06, alpha: 1)
        case .danger: emotion.textColor = UIColor(red: 0.65, green: 0.12, blue: 0.18, alpha: 1)
        }
        accessibilityLabel = "\(name)，好感度 \(affectionTotal.map { String($0) } ?? "未知")，\(emotionText)，\(adviceText)，\(progressText)"
        setNeedsLayout()
    }
}

/// Jev 判断键 → 画中画里能一眼看懂的中文。
enum JudgeLabels {
    /// 与参考项目的危险分段一致；仅描述模型对当前语气的估计。
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
