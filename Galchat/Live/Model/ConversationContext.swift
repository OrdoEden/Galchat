import Foundation
import Synapse

/// OCR 的纯文字输出。语义分析不依赖截图、拼接段或观察次数。
nonisolated struct ContextMessage: Sendable {
    let id: UUID
    let speaker: Speaker
    let text: String
    var isGap: Bool = false
    /// 气泡被上下边界裁切，只看到半截。
    ///
    /// 保留成结构化标记而不是只折进 `text`：好感度计分需要知道"这次看到的是不是完整消息"。
    /// 半截消息的语义可能被误判，所以先计分、等它变完整时允许重算一次
    /// （见 `AffectionCommitter`）。发往模型的文本里同样带提示语，那部分在 `makeContext` 拼。
    var clipped: Bool = false
    var isUserCorrected: Bool = false
}

nonisolated struct ConversationContext: Sendable {
    let sessionID: UUID
    let conversationID: UUID
    let revision: Int
    let sourceTitle: String
    let sourceConfirmed: Bool
    let frameID: UUID
    let observedAt: Date
    let messages: [ContextMessage]
    var contactID: String? = nil
    /// 画面停在最新消息附近（不是在翻历史）。只有这时新出现的尾部才代表“对方刚发来”。
    var isLiveTail: Bool = true
    /// 当前屏还没和已知消息链对齐，上下文只有这一屏，不能据此判断“有新消息”。
    var isIsolated: Bool = false

    /// 尾部身份：最后一条消息的稳定 ID 与发言方。**不含文字**——
    /// 同一条消息被 OCR 读成不同写法时不算新消息；文字纠正由 `tailText` 单独判断。
    var tailSignature: String {
        guard let last = messages.last(where: { !$0.isGap }) else { return "" }
        return "\(last.id.uuidString)|\(last.speaker.rawValue)"
    }

    var tailText: String { messages.last(where: { !$0.isGap })?.text ?? "" }

    /// 自动分析的放行条件；不满足时只更新上下文，不调用模型。
    var semanticHoldReason: String? {
        if !sourceConfirmed { return "等待确认聊天页" }
        if isIsolated { return "当前画面还没接上聊天记录，等待对齐" }
        if !isLiveTail { return "正在查看历史消息，回到最新消息后再分析" }
        return nil
    }

    func snapshot(limit: Int) -> ChatSnapshot {
        ChatSnapshot(messages: messages.map {
            ChatMessage(speaker: $0.speaker, text: $0.text, isGap: $0.isGap)
        }, contextLimit: limit)
    }

    func version(for snapshot: ChatSnapshot) -> ContextVersion {
        let fingerprint = snapshot.recentMessages.map {
            "\($0.isGap)|\($0.speaker.rawValue)|\($0.text.utf8.count):\($0.text)"
        }.joined(separator: "|")
        return ContextVersion(sessionID: sessionID, conversationID: conversationID,
                              tailSignature: tailSignature, windowFingerprint: fingerprint)
    }
}

nonisolated struct ContextVersion: Equatable, Sendable {
    let sessionID: UUID
    let conversationID: UUID
    let tailSignature: String
    let windowFingerprint: String
}

nonisolated struct AnalysisRequest: Sendable {
    let id: UUID
    let context: ConversationContext
    let version: ContextVersion
    let snapshot: ChatSnapshot
    let models: AnalysisModelContext
    let startedAt: Date
    let isContextRefresh: Bool
    var allowsAffectionScoring: Bool = true

    var analyzedCount: Int { snapshot.recentMessages.filter { !$0.isGap }.count }
    var analyzedFirstID: UUID? {
        context.messages.filter { !$0.isGap }.suffix(max(1, snapshot.contextLimit)).first?.id
    }
}

/// 同一轮判断、生成和排序使用同一份路由与关系配置，避免设置变化混入在途任务。
nonisolated struct AnalysisModelContext: Sendable {
    let judge: SynapseModelRoute
    let reply: SynapseModelRoute
    let relationship: String
    let persona: String
    /// 与人格提示词同时取快照，在途任务不受中途切换人格影响。
    let replyTransform: PersonaPackage.ReplyTransform?

    @MainActor
    init(config: GCConfig, contactID: String? = nil, relationship: String? = nil) {
        judge = config.routeSnapshot(for: .judge)
        reply = config.routeSnapshot(for: .reply)
        self.relationship = relationship ?? Self.relationship(config: config, contactID: contactID)
        persona = PersonaStore.shared.prompt
        replyTransform = PersonaStore.shared.replyTransform
    }

    @MainActor
    static func relationship(config: GCConfig, contactID: String?) -> String {
        guard let contact = ContactsStore.shared.contact(id: contactID) else { return config.relationship }
        var lines = [config.relationship, "对方档案（用户填写的参考信息）：\(contact.displayName)"]
        if let note = contact.note, !note.isEmpty { lines.append("备注：\(note)") }
        if let persona = contact.persona, !persona.isEmpty { lines.append("对方人设：\(persona)") }
        lines.append("当前好感度记录：\(contact.total)/100，仅作关系背景，不代表事实判断。")
        return lines.joined(separator: "\n")
    }
}
