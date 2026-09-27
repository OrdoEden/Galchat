import UIKit

/// 画中画内容：四行，只读。按内容尺寸布局，系统小窗的实际大小由 iOS 管理。
///
///     Jarvis · 小王 · 愤怒/冲突 6/9 · 10 条   ← 会话与情绪程度
///     Jarvis 意图：在试探你是否在乎             ← 意图与紧张状态
///     Jarvis 建议：需要关心 · 先回应感受        ← 需求与行动
///     Jarvis 候选已就绪 · 可上滑补充历史         ← 进度与下一步
///
/// 每行都以 “Jarvis” 开头：引擎在 OCR 结果里找到这个标记后，把整块画中画区域从聊天识别中排除。
@MainActor
final class JarvisPiPView: UIView {
    private let statusLabel = UILabel()
    private let judgeLabel = UILabel()
    private let adviceLabel = UILabel()
    private let actionLabel = UILabel()
    private let badge = UIView()
    /// 好感度轨道。**刻意不放文字**——文字行会被 OCR 读成聊天内容碎片，
    /// 而这里只需要一个视觉指示，无文字就永远不会干扰识别与遮挡排除。
    private let affectionTrack = UIView()
    private let affectionFill = UIView()
    private var actionIsPrompt = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        overrideUserInterfaceStyle = .light
        backgroundColor = .white
        badge.layer.cornerRadius = 4
        affectionTrack.clipsToBounds = true
        affectionTrack.backgroundColor = .systemGray5
        affectionTrack.addSubview(affectionFill)
        for label in [statusLabel, judgeLabel, adviceLabel, actionLabel] {
            label.textColor = .black
            // 单行截断：换行会让画中画文字被 OCR 成不以标记开头的碎片。
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            // 各行字号一致，OCR 才能稳定地从行距推算遮挡区域。
            addSubview(label)
        }
        addSubview(badge)
        addSubview(affectionTrack)
        clipsToBounds = true
        show(status: "Jarvis · 待命", judge: "Jarvis 打开聊天窗口，一屏即可分析", advice: "Jarvis 显示情绪、意图、需求和行动建议", action: "Jarvis 候选生成后可在键盘中插入", tone: .neutral)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let layout = JarvisPiPLayout(size: bounds.size)
        for (index, label) in [statusLabel, judgeLabel, adviceLabel, actionLabel].enumerated() {
            label.frame = layout.rowFrame(index)
        }
        statusLabel.font = .systemFont(ofSize: layout.fontSize, weight: .semibold)
        judgeLabel.font = .systemFont(ofSize: layout.fontSize, weight: .medium)
        adviceLabel.font = .systemFont(ofSize: layout.fontSize)
        actionLabel.font = .systemFont(ofSize: layout.fontSize, weight: actionIsPrompt ? .semibold : .regular)
        badge.frame = CGRect(x: 6 * layout.scale, y: 8 * layout.scale,
                             width: 5 * layout.scale, height: max(0, bounds.height - 16 * layout.scale))
        let track = layout.affectionTrackFrame()
        affectionTrack.frame = track
        affectionTrack.layer.cornerRadius = track.height / 2
        let ratio = CGFloat(min(max(affectionTotal, 0), 100)) / 100
        affectionFill.frame = CGRect(x: 0, y: 0, width: track.width * ratio, height: track.height)
    }

    enum Tone { case neutral, calm, warn, danger }

    private var affectionTotal = AffectionScoring.initial

    /// 好感度的视觉状态。只驱动无文字轨道；数字读数由调用方拼进 `status` 行。
    struct AffectionDisplay {
        let total: Int
        let step: Int
        let ruptured: Bool

        var text: String {
            var text = Hearts.text(total: total)
            if step != 0 { text += " \(step > 0 ? "+" : "−")\(abs(step))" }
            return text
        }
    }

    func show(status: String, judge: String, advice: String, action: String, tone: Tone,
              prompt: Bool = false, affection: AffectionDisplay? = nil) {
        statusLabel.text = status
        judgeLabel.text = judge
        adviceLabel.text = advice
        actionLabel.text = action
        let color: UIColor
        switch tone {
        case .neutral: color = .systemGray3
        case .calm: color = .systemGreen
        case .warn: color = .systemOrange
        case .danger: color = .systemRed
        }
        badge.backgroundColor = color
        actionLabel.textColor = prompt ? .galchatPink : .black
        actionIsPrompt = prompt
        affectionTotal = affection?.total ?? AffectionScoring.initial
        if let affection {
            // 破裂标红，升温标粉，中性/降温保持灰，避免在窄条里靠颜色传达细微差别。
            affectionFill.backgroundColor = affection.ruptured
                ? .systemRed : (affection.step > 0 ? .systemPink : .systemGray)
            affectionTrack.isHidden = false
            affectionFill.isHidden = false
        } else {
            affectionTrack.isHidden = true
            affectionFill.isHidden = true
        }
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
