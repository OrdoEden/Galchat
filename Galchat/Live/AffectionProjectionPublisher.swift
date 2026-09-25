import Foundation

/// 把好感度投影写给键盘，并消费键盘回传的联系人确认。
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
    private var lastDecisionAt: Date?
    private var ignoredTitles = Set<String>()

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

    // MARK: - 消费键盘确认

    /// 每帧调用。返回 true 表示联系人状态发生了变化，调用方应刷新 UI。
    @discardableResult
    func consumeKeyboardDecision() -> Bool {
        guard let decision = AffectionProjectionStore.loadDecision() else { return false }
        // 同一次决策只处理一次。键盘可能连续几秒都还没删掉文件。
        if let last = lastDecisionAt, decision.decidedAt <= last { return false }
        lastDecisionAt = decision.decidedAt
        AffectionProjectionStore.clearDecision()

        // 决策针对的是上一次的标题；期间换聊天了就作废。
        guard ContactsStore.normalize(decision.sourceTitle) == ContactsStore.normalize(currentTitle) else {
            return false
        }

        switch decision.resolution {
        case .existing:
            guard let contactID = decision.contactID else { return false }
            store.bind(alias: decision.sourceTitle, to: contactID)
            publishImmediately()
            return true
        case .create:
            let name = decision.sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return false }
            store.createContact(displayName: name, alias: decision.sourceTitle)
            publishImmediately()
            return true
        case .ignore:
            // 本次不绑定。记录标题，避免同一会话里反复弹确认。
            ignoredTitles.insert(ContactsStore.normalize(decision.sourceTitle))
            publishImmediately()
            return false
        }
    }

    // MARK: - 身份解析

    /// 每帧识别后调用，把 OCR 标题匹配到联系人。
    func resolveContact(title: String) {
        currentTitle = title
        guard ContactMatcher.isTrusted(title) else { return }
        let normalized = ContactsStore.normalize(title)
        guard !ignoredTitles.contains(normalized) else { return }

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
            guard store.document.activeContactID == nil else { return }
            publishImmediately(suggestions: candidates.map {
                AffectionProjection.Suggestion(id: $0.contactID, displayName: $0.displayName, score: $0.score)
            })
        case .unknown:
            guard store.document.activeContactID == nil else { return }
            // 没有匹配时仍然要给键盘一个"新建"的机会，所以发一份空候选的投影。
            publishImmediately()
        }
    }
}
