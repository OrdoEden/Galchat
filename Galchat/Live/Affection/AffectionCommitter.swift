import Foundation

/// 把一次判断题的结论折算成好感度变化并落盘。
///
/// 这个类型存在的唯一理由是**防止重复计分**。调度器会在滑动窗口上反复重跑判断
/// （800ms debounce、`considerRefresh` 最多扩大两次窗口重跑、手动 `analyzeNow`），
/// 如果每轮都把"本窗口的好感变化"累加，同一批消息会被计 2-4 次；用户来回滚动
/// 屏幕还能刷分。
///
/// 解法：用**最新一条对方消息的 id** 作为提交键，并且把窗口内所有对方消息 id
/// 都写进台账。前提是第 8 道题问的是"最新这一轮的边际位移"——对同一尾部它是个
/// 稳定值，所以按 id 去重是精确的，不是近似。
///
/// 为什么不用现成的 `tailSignature` 或 `windowFingerprint`：
/// - `windowFingerprint` 是窗口（limit + 内容）的函数，`check_history` 刷新用 limit 50、
///   常规用 10，每次滑动都变。它标记的是"这次输入"，而恰恰是这个单位不该被计分。
/// - `tailSignature` 现在只含 id 与发言方，但尾部可能是我方消息；计分只关心对方最新一条，
///   且需要窗口内所有对方消息 id 一起入账。
@MainActor
final class AffectionCommitter {
    static let shared = AffectionCommitter()

    /// 两次提交之间的最小间隔。防的是"同一批内容因为 OCR 抖动被反复判成新内容"。
    /// 取 15 秒是因为判断题本身最多每分钟 6 次，这个下限不会误伤正常的连续对话。
    static let minimumCommitInterval: TimeInterval = 15

    private let store: ContactsStore
    private let publisher: AffectionProjectionPublisher

    /// 默认参数不能写成 `= .shared`：默认参数在**调用方**上下文求值，而 `.shared`
    /// 是 main actor 隔离的，从非隔离上下文引用在 Swift 6 语言模式下是错误。
    init(store: ContactsStore? = nil, publisher: AffectionProjectionPublisher? = nil) {
        self.store = store ?? .shared
        self.publisher = publisher ?? .shared
    }

    /// 判断完成的回调入口。
    func commit(request: AnalysisRequest, analysis: Analysis) {
        // 历史刷新永远不提交：`considerRefresh` 的守卫要求尾部不变，
        // 所以它不可能带来新的尾部消息。显式短路是为了可读性。
        guard !request.isContextRefresh, request.allowsAffectionScoring else { return }

        guard let contactID = request.context.contactID,
              let contact = store.contact(id: contactID) else { return }

        // 提交键：窗口内最新的对方非 gap 消息。
        guard let newestOther = request.context.messages.last(where: {
            !$0.isGap && $0.speaker == .other
        }), !newestOther.isUserCorrected else { return }

        let existing = store.scoredTurn(contactID: contactID, messageID: newestOther.id)

        // 已计分过：只允许在"裁切 → 完整"时重算一次，其余一律不提交。
        if let existing {
            guard existing.clipped, !newestOther.clipped else { return }
        } else if let last = contact.lastCommitAt,
                  Date().timeIntervalSince(last) < Self.minimumCommitInterval {
            // 新消息：受节流约束。已计分的重算路径不受约束（上面已处理）。
            return
        }

        let output = AffectionScoring.apply(.init(
            answer: analysis.affectionDelta,
            trueIntent: analysis.trueIntent,
            sheNeeds: analysis.sheNeeds,
            dangerLevel: analysis.dangerLevel,
            tensionResolved: analysis.tensionResolved,
            total: contact.total,
            ruptured: contact.rupturedUntilResolved
        ))

        let turn = ContactsStore.ScoredTurn(
            id: newestOther.id.uuidString,
            delta: output.appliedStep,
            clipped: newestOther.clipped,
            at: Date()
        )

        if output.didRupture || output.didResolve {
            store.setRuptured(contactID: contactID, output.didRupture)
        }

        if let existing {
            // 重算：替换而非累加。先扣掉旧值再加新值，总分不会翻倍。
            store.replaceScoredTurn(contactID: contactID, turn: turn,
                                    delta: output.appliedStep,
                                    newTotal: contact.total - existing.delta + output.appliedStep)
        } else {
            store.commit(contactID: contactID,
                         turns: scoredTurns(in: request),
                         delta: output.appliedStep,
                         totalBefore: contact.total)
        }

        store.save()
        publisher.publish(step: output.appliedStep)
    }

    /// 把窗口内**所有**对方消息 id 一次性入账。
    ///
    /// 这一步才是防"滚回去刷分"的关键：用户往上滚之后，窗口里最新的对方消息
    /// 是个旧 id，已在台账里 → 不提交。只记尾部那一条做不到这一点。
    private func scoredTurns(in request: AnalysisRequest) -> [ContactsStore.ScoredTurn] {
        let now = Date()
        return request.context.messages
            .filter { !$0.isGap }
            // 只记对方消息：自己发的消息不推进好感度，也不该占用台账额度。
            .filter { $0.speaker == .other }
            .map { message in
                ContactsStore.ScoredTurn(id: message.id.uuidString, delta: 0,
                                         clipped: message.clipped, at: now)
            }
    }
}
