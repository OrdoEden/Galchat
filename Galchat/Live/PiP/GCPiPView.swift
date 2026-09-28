import UIKit

/// Galchat 的 PiP 内容容器。对外接口（`show` / `setPortrait`）不变，
/// 按窗口形状把同一份 `GCPiPContent` 交给横屏或竖屏视图渲染：
///
/// - `GCPiPLandscapeView`：横屏一行式卡片（落地页 `.pip` 的原样）。
/// - `GCPiPPortraitView`：竖屏窄条，左侧好感度温度计 + 头像/名字/分数 + 底部白色气泡。
///
/// 两种形状能放下的字数不同（`GCPiPTextBudget`），各视图渲染时按自己的预算截断文案。
///
/// 两个视图各自维护、互不依赖；共用的配色、头像、进度条与心跳动图在 `GCPiPComponents.swift`。
/// 隐藏的那一个不会被 Visyn 逐帧选 GIF 帧，所以不额外耗电。
@MainActor
final class GCPiPView: UIView {
    enum Tone { case neutral, calm, warn, danger }

    struct AffectionDisplay {
        let total: Int
        let step: Int
        let ruptured: Bool
    }

    private let landscapeView = GCPiPLandscapeView()
    private let portraitView = GCPiPPortraitView()
    private var content = GCPiPContent()

    override init(frame: CGRect) {
        super.init(frame: frame)
        overrideUserInterfaceStyle = .light
        clipsToBounds = true
        backgroundColor = .white
        addSubview(landscapeView)
        addSubview(portraitView)
        isAccessibilityElement = true
        apply()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPortrait(_ portrait: PiPPortrait?) {
        guard portrait?.imageID != content.portrait?.imageID else { return }
        content.portrait = portrait
        apply()
    }

    func show(name: String, emotion: String, advice: String, progress: String,
              tone: Tone, affection: AffectionDisplay?, isLive: Bool) {
        content.name = name
        content.emotion = emotion
        content.advice = advice
        content.progress = progress
        content.tone = tone
        content.affection = affection
        content.isLive = isLive
        accessibilityLabel = "\(name)，好感度 \(affection.map { String($0.total) } ?? "未知")，"
            + "\(emotion)，\(advice)，\(progress)"
        apply()
    }

    private func apply() {
        landscapeView.render(content)
        portraitView.render(content)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let isPortrait = GCPiPLayout(size: bounds.size).isPortrait
        landscapeView.isHidden = isPortrait
        portraitView.isHidden = !isPortrait
        landscapeView.frame = bounds
        portraitView.frame = bounds
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
            "check_history": "先翻记录再回",
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
