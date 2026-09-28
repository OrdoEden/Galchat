import Foundation

/// 将独立完成的回复候选发布给键盘，不等待 Jev 判断或长图拼接。
@MainActor
final class ReplyBundlePublisher {
    static let maxLifetime: TimeInterval = 120
    /// 已确认会话的来源新鲜度。比 `recognized` 长一倍——用户已经明确指认过这是谁，
    /// 短暂停顿后不必重新确认。
    static let freshnessConfirmed: TimeInterval = 30
    static let freshness: TimeInterval = 15
    static let renewInterval: TimeInterval = 3

    private var published: ReplyBundle?
    private var lastWrite = Date.distantPast
    private var writeFailed = false

    var isReady: Bool { !writeFailed && published?.isUsable() == true }
    var unavailableReason: String {
        if writeFailed { return "候选共享写入失败，请返回 Galchat 检查" }
        guard let published else { return "等待回复候选" }
        if published.status == .invalid { return published.note ?? "等待回复候选" }
        if Date() >= published.expiresAt { return "候选已过期，请重新分析" }
        if Date() >= published.validUntil { return "等待当前聊天画面更新" }
        return "候选暂不可用"
    }

    init() { write(.invalid(note: "")) }

    func contextWasEdited() {
        invalidate("上下文或人设已更新，请重新分析")
    }

    func refresh(context: ConversationContext?, currentRequest: AnalysisRequest?,
                 judge: LiveAnalysisScheduler.Outcome?, replies: ReplySuggestionScheduler.Outcome?,
                 replyPhase: ReplySuggestionScheduler.Phase, capturing: Bool, captureNote: String) {
        if !capturing { return handleNotCapturing(context: context, captureNote: captureNote) }
        guard let context, !context.tailSignature.isEmpty else {
            return invalidate("本屏尚未识别到可读聊天文字")
        }
        let now = Date()
        let window = context.sourceConfirmed ? Self.freshnessConfirmed : Self.freshness
        guard now >= context.observedAt.addingTimeInterval(-5),
              now < context.observedAt.addingTimeInterval(window) else {
            return invalidate("等待当前聊天画面更新")
        }
        switch replyPhase {
        case .idle: return invalidate("等待回复任务")
        case .generating: return invalidate("正在生成候选文案…")
        case .ranking: return invalidate("正在排序候选文案…")
        case .failed(let reason): return invalidate(reason)
        case .ready: break
        }
        guard let request = currentRequest, let replies, !replies.stale,
              replies.request.id == request.id, replies.request.version == request.version,
              request.version.sessionID == context.sessionID, request.version.conversationID == context.conversationID,
              request.context.contactID == context.contactID,
              request.version.tailSignature == context.tailSignature else {
            return invalidate("当前聊天已更新，等待新的回复候选")
        }
        guard !replies.repliesUnranked, replies.error == nil else {
            return invalidate(replies.error ?? "候选排序尚未完成")
        }
        guard ReplyBundle.hasValidCandidateTexts(replies.replies.map(\.text)) else {
            return invalidate("需要三条不同、长度有效的候选回复")
        }
        let generatedAt = replies.completedAt
        let expiresAt = generatedAt.addingTimeInterval(Self.maxLifetime)
        guard now >= generatedAt.addingTimeInterval(-5), now < expiresAt else {
            return invalidate("候选已过期，请重新分析")
        }
        let validUntil = min(expiresAt, context.observedAt.addingTimeInterval(Self.freshness))
        let summary = judge.flatMap { result -> String? in
            guard !result.stale, result.request.id == request.id,
                  result.request.version == request.version else { return nil }
            return result.analysis.map(JudgeLabels.summary)
        }
        let confidence = context.sourceConfirmed ? "confirmed" : "recognized"
        if var current = published, current.status == .ready, current.analysisRequestID == request.id.uuidString,
           current.sourceTitle == context.sourceTitle, current.sourceConfidence == confidence {
            guard writeFailed || current.summary != summary
                || (validUntil > current.validUntil && now.timeIntervalSince(lastWrite) >= Self.renewInterval) else { return }
            current.summary = summary
            current.validUntil = validUntil
            write(current)
            return
        }
        let candidates = replies.replies.reversed().enumerated().map {
            ReplyBundle.Candidate(id: UUID().uuidString, rank: $0.offset + 1, text: $0.element.text)
        }
        write(ReplyBundle(bundleID: UUID().uuidString, status: .ready, sessionID: context.sessionID.uuidString,
                          conversationID: context.conversationID.uuidString, revision: request.context.revision,
                          analysisRequestID: request.id.uuidString, generatedAt: generatedAt, expiresAt: expiresAt,
                          validUntil: validUntil, sourceTitle: context.sourceTitle, sourceConfidence: confidence,
                          summary: summary, candidates: candidates, note: nil))
    }

    private func invalidate(_ reason: String) {
        guard writeFailed || published?.status != .invalid || published?.note != reason else { return }
        write(.invalid(note: reason))
    }

    /// 录屏暂停/停止时的处理。
    ///
    /// 这里**不再一律作废**候选：录屏停了但用户还在微信里打字，把候选清空会逼他
    /// 重新录屏并重新确认会话。改为在 `expiresAt` 内降级保留并明确标注状态——
    /// 用户看到的是一条可用但"来源已陈旧"的建议，而不是凭空消失。
    /// 超出 `expiresAt` 仍然作废，避免一条过期很久的建议被当成当前结论插入。
    private func handleNotCapturing(context: ConversationContext?, captureNote: String) {
        guard let published, published.status == .ready,
              Date() < published.expiresAt else {
            return invalidate(captureNote)
        }
        guard published.note != captureNote || lastWrite == Date.distantPast else { return }
        var downgraded = published
        downgraded.note = captureNote
        write(downgraded)
    }

    private func write(_ bundle: ReplyBundle) {
        guard ReplyBundleStore.write(bundle) else {
            writeFailed = true
            return
        }
        writeFailed = false
        published = bundle
        lastWrite = Date()
    }
}
