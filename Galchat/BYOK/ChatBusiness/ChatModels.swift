import Foundation

/// 消息的发言方。`unknown` 表示版式无法可靠分边，不擅自归成 `other`。
nonisolated enum Speaker: String, Sendable {
    case me
    case other
    case unknown
}

nonisolated struct ChatMessage: Sendable {
    let speaker: Speaker
    let text: String
    /// 拼接缺口属于上下文，不计入真实消息额度。
    var isGap: Bool = false
}

/// 一次分析的输入。首版来自用户手动粘贴，后续接 OCR 会话层。
nonisolated struct ChatSnapshot: Sendable {
    let messages: [ChatMessage]
    /// 发给模型的最近消息条数（判断、生成、排序共用）。默认 10 条，和安卓参考实现一致；可在设置里调整。
    var contextLimit: Int = GCConfig.Defaults.contextMessageCount

    var recentMessages: [ChatMessage] {
        let limit = max(1, contextLimit)
        let real = messages.indices.filter { !messages[$0].isGap }
        guard let first = real.suffix(limit).first, let last = real.last else { return [] }
        return Array(messages[first...last])
    }
}

/// Jev choice 类型的答案。
nonisolated struct Choice: Sendable {
    let choice: String
    let confidence: Double
    let probabilities: [String: Double]
}

/// Jev score 类型的答案。
nonisolated struct Score: Sendable {
    let score: Double
    let confidence: Double
    let maxLevel: Int
}

/// 排序后的候选回复。`probability` 是 Jev 给出的相对优劣，不是"正确率"。
nonisolated struct RankedReply: Sendable {
    let text: String
    let probability: Double
}

/// 一次判断的完整结果。字段为 nil 表示模型没有返回该项。
nonisolated struct Analysis: Sendable {
    let trueIntent: Choice?
    let dangerLevel: Score?
    let sheNeeds: Choice?
    let shouldReplyNow: Double?
    let bestAction: Choice?
    let tensionResolved: Double?
    let literalQuestion: Double?
    /// 好感度的边际变化档位。只是原始档位，换算成点数与累计由 `AffectionScoring` 负责。
    let affectionDelta: Choice?
    let latencyMs: Int
}
