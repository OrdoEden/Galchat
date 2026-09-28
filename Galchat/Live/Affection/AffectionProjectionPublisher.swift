import Foundation

/// 把好感度投影写给键盘。
///
/// 与 `ReplyBundlePublisher` 的节奏差别：候选建议是"当下这一刻的推断"，所以
/// 有 15 秒新鲜度和 120 秒上限；好感度总分是"已经发生过的历史"，没有这两个时限。
/// 唯一有时效的是本轮 ± 读数，它在 `AffectionProjection` 里自己判断。
@MainActor
final class AffectionProjectionPublisher {
    static let shared = AffectionProjectionPublisher()

    /// 两次写入之间的节流。键盘 1 秒轮询一次，没必要跟着刷。
    static let minimumInterval: TimeInterval = 5

    private let store: ContactsStore
    private var lastWrite = Date.distantPast

    /// 最近一次提交产生的 ± 读数。存在内存里供 PiP 直接读，不必为了一个数字回读磁盘。
    private(set) var lastStep: Int = 0
    private(set) var lastStepAt: Date?

    init(store: ContactsStore? = nil) {
        self.store = store ?? .shared
    }

    // MARK: - 发布

    /// 重新计算并写入投影。`step` 传 0 表示"不是刚算完一轮"，只是维持现状。
    func publish(step: Int = 0, suggestions: [AffectionProjection.Suggestion] = []) {
        let now = Date()
        guard now.timeIntervalSince(lastWrite) >= Self.minimumInterval else { return }
        write(step: step, suggestions: suggestions, now: now)
    }

    /// 联系人状态刚变过（新建、绑定、确认），必须立刻可见，绕过节流。
    func publishImmediately(step: Int = 0, suggestions: [AffectionProjection.Suggestion] = []) {
        write(step: step, suggestions: suggestions, now: Date())
    }

    /// 当前该显示的本轮 ±。过期返回 nil，避免旧数字被当成当前变化。
    func currentStep(now: Date = Date()) -> Int? {
        guard let lastStepAt, lastStep != 0 else { return nil }
        return now < lastStepAt.addingTimeInterval(AffectionProjection.lastStepDisplayWindow) ? lastStep : nil
    }

    private func write(step: Int, suggestions: [AffectionProjection.Suggestion], now: Date) {
        let contact = store.activeContact
        if step != 0 {
            lastStep = step
            lastStepAt = now
        }
        let projection = AffectionProjection(
            updatedAt: now,
            activeContactID: contact?.id,
            displayName: contact?.displayName,
            total: contact?.total ?? AffectionScoring.initial,
            lastStep: step,
            lastStepAt: step == 0 ? nil : now,
            ruptured: contact?.rupturedUntilResolved ?? false,
            sourceTitle: currentTitle,
            anonymous: !ContactMatcher.isTrusted(currentTitle),
            suggestions: suggestions
        )
        guard AffectionProjectionStore.write(projection) else { return }
        lastWrite = now
    }

    /// 主 App 当前看到的会话标题。由协调器在每帧识别后更新。
    var currentTitle: String = ""

    // MARK: - 身份解析

    /// 每帧识别后调用，把 OCR 标题匹配到联系人。
    func resolveContact(title: String) {
        let changedTitle = ContactsStore.normalize(currentTitle) != ContactsStore.normalize(title)
        currentTitle = title
        if changedTitle, store.activeContact != nil {
            store.setActiveContact(nil)
        }
        guard ContactMatcher.isTrusted(title) else {
            if store.activeContact != nil { store.setActiveContact(nil) }
            publish()
            return
        }

        switch ContactMatcher.match(title: title, subjects: store.document.contacts.map {
            ContactMatcher.Subject(id: $0.id, displayName: $0.displayName, aliases: $0.aliases)
        }) {
        case .untrusted:
            return
        case .autoBind(let match):
            // 已经是当前联系人就不重复写盘。
            guard store.document.activeContactID != match.contactID else { return }
            store.bind(alias: title, to: match.contactID)
            publishImmediately()
        case .ambiguous(let candidates):
            if store.activeContact != nil { store.setActiveContact(nil) }
            publish(suggestions: candidates.map {
                AffectionProjection.Suggestion(id: $0.contactID, displayName: $0.displayName, score: $0.score)
            })
        case .unknown:
            if store.activeContact != nil { store.setActiveContact(nil) }
            // 没有匹配时仍然要给键盘一个"新建"的机会，所以发一份空候选的投影。
            publish()
        }
    }
}
