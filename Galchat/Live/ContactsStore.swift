import Foundation

/// 联系人档案与好感度台账的持久化。
///
/// 设计取舍：
/// - **单文件**。按联系人拆成多个文件会引入跨文件一致性问题（改两个文件时中途崩溃
///   就留下不自洽的状态），而单文件一次原子写就够。200 条台账约 8 KB，可忽略。
/// - **不引入 Realm / CoreData**。数据量是"几十个联系人 × 几百条记录"，上面还有
///   24 小时裁剪，一个 JSON 文件完全够用，不值得为此加一个数据库依赖和迁移负担。
/// - 与 `ReplyBundleStore` 共用 `GalchatSharedFile` 的落盘方式：同一 App Group 目录、
///   同样的 `.atomic` + 文件保护 + 排除备份。
@MainActor
final class ContactsStore {
    static let shared = ContactsStore()

    static let fileName = "contacts.json"
    /// 台账保留条数。必须大于 `LiveAnalysisScheduler.historyContextLimit`（50），
    /// 否则一次 `check_history` 刷新就能把整个台账冲掉，导致旧消息被重复计分。
    static let ledgerCapacity = 200
    /// 台账保留时长。更早的记录对应的消息不可能再出现在采集窗口里。
    static let ledgerRetention: TimeInterval = 24 * 60 * 60

    private(set) var document: Document

    private init() {
        document = GalchatSharedFile.read(Document.self, named: Self.fileName) ?? Document()
        prune()
    }

    // MARK: - 数据结构

    struct Document: Codable, Sendable {
        static let currentSchema = 1

        var schemaVersion = Document.currentSchema
        var updatedAt = Date()
        /// 当前正在聊的联系人。没有绑定时为 nil。
        var activeContactID: String?
        var contacts: [Contact] = []

        init() {}

        /// 解码时校验版本：未来版本的文件降级读取要显式失败，而不是读出一半。
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let version = try container.decode(Int.self, forKey: .schemaVersion)
            guard version == Document.currentSchema else {
                throw DecodingError.dataCorruptedError(
                    forKey: .schemaVersion, in: container,
                    debugDescription: "不支持的联系人数据结构版本 \(version)")
            }
            updatedAt = try container.decode(Date.self, forKey: .updatedAt)
            activeContactID = try container.decodeIfPresent(String.self, forKey: .activeContactID)
            contacts = try container.decode([Contact].self, forKey: .contacts)
            schemaVersion = version
        }

        func contact(id: String?) -> Contact? {
            guard let id else { return nil }
            return contacts.first { $0.id == id }
        }

        var activeContact: Contact? { contact(id: activeContactID) }
    }

    struct Contact: Codable, Sendable, Identifiable {
        let id: String
        var displayName: String
        /// 归一化后的标题别名。同一个联系人可能被 OCR 出多种写法。
        var aliases: [String]
        /// 0...100 的累计好感度。
        var total: Int
        var rupturedUntilResolved: Bool
        /// 上次提交时间，用于防刷分的节流。
        var lastCommitAt: Date?
        let createdAt: Date
        var ledger: [ScoredTurn]
    }

    /// 一条已计分记录。用来防止同一轮对话被反复计分。
    struct ScoredTurn: Codable, Sendable {
        /// 消息 id（`ContextMessage.id`）。这是唯一的去重键。
        let id: String
        /// 该轮的 applied step。
        var delta: Int
        /// 计分时该消息是否被裁切。裁切状态下只能看到半截气泡，
        /// 等它变完整时允许重算一次。
        var clipped: Bool
        let at: Date
    }

    // MARK: - 查询

    var activeContact: Contact? { document.activeContact }

    func contact(id: String?) -> Contact? { document.contact(id: id) }

    func contacts() -> [Contact] { document.contacts.sorted { $0.total > $1.total } }

    // MARK: - 变更

    @discardableResult
    func createContact(displayName: String, alias: String?) -> Contact {
        let contact = Contact(
            id: UUID().uuidString,
            displayName: displayName,
            aliases: alias.map { [Self.normalize($0)] } ?? [],
            total: AffectionScoring.initial,
            rupturedUntilResolved: false,
            lastCommitAt: nil,
            createdAt: Date(),
            ledger: []
        )
        document.contacts.append(contact)
        setActiveContact(contact.id)
        save()
        return contact
    }

    func setActiveContact(_ id: String?) {
        document.activeContactID = id
        save()
    }

    /// 把一个 OCR 标题绑到既有联系人。标题同时从其他联系人上摘掉——
    /// 否则同一次会话会在两个人之间来回摇摆。
    func bind(alias rawAlias: String, to contactID: String) {
        let alias = Self.normalize(rawAlias)
        guard !alias.isEmpty else { return }
        for index in document.contacts.indices {
            document.contacts[index].aliases.removeAll { $0 == alias }
        }
        guard let index = document.contacts.firstIndex(where: { $0.id == contactID }) else { return }
        document.contacts[index].aliases.append(alias)
        document.activeContactID = contactID
        save()
    }

    func rename(contactID: String, to name: String) {
        guard let index = document.contacts.firstIndex(where: { $0.id == contactID }) else { return }
        document.contacts[index].displayName = name
        save()
    }

    func delete(contactID: String) {
        document.contacts.removeAll { $0.id == contactID }
        if document.activeContactID == contactID { document.activeContactID = nil }
        save()
    }

    // MARK: - 台账

    /// 该消息 id 是否已计过分。
    func scoredTurn(contactID: String, messageID: UUID) -> ScoredTurn? {
        contact(id: contactID)?.ledger.first { $0.id == messageID.uuidString }
    }

    /// 在既有记录上做**替换**而非累加。用于 `clipped` 翻转后的重算：
    /// 先减掉旧值再加新值，总分不会因为重算而翻倍。
    func replaceScoredTurn(contactID: String, turn: ScoredTurn, delta applied: Int, newTotal: Int) {
        guard let index = document.contacts.firstIndex(where: { $0.id == contactID }) else { return }
        var scratch = document.contacts[index]
        if let turnIndex = scratch.ledger.firstIndex(where: { $0.id == turn.id }) {
            scratch.ledger[turnIndex] = turn
        } else {
            scratch.ledger.append(turn)
        }
        scratch.total = min(max(newTotal, AffectionScoring.minimum), AffectionScoring.maximum)
        scratch.lastCommitAt = Date()
        document.contacts[index] = scratch
    }

    /// 记录一次计分。`delta` 是已经算好的 applied step。
    func commit(contactID: String, turns: [ScoredTurn], delta: Int, totalBefore: Int) {
        guard let index = document.contacts.firstIndex(where: { $0.id == contactID }) else { return }
        var scratch = document.contacts[index]
        for turn in turns where !scratch.ledger.contains(where: { $0.id == turn.id }) {
            scratch.ledger.append(turn)
        }
        scratch.total = min(max(totalBefore + delta, AffectionScoring.minimum), AffectionScoring.maximum)
        scratch.lastCommitAt = Date()
        document.contacts[index] = scratch
        pruneContact(at: index)
    }

    func setRuptured(contactID: String, _ ruptured: Bool) {
        guard let index = document.contacts.firstIndex(where: { $0.id == contactID }) else { return }
        document.contacts[index].rupturedUntilResolved = ruptured
    }

    // MARK: - 落盘与裁剪

    private func prune() {
        for index in document.contacts.indices { pruneContact(at: index) }
    }

    /// 台账裁剪：保留最近 `ledgerCapacity` 条，且丢掉超过保留时长的记录。
    private func pruneContact(at index: Int) {
        guard document.contacts.indices.contains(index) else { return }
        let cutoff = Date().addingTimeInterval(-Self.ledgerRetention)
        var ledger = document.contacts[index].ledger
        ledger.removeAll { $0.at < cutoff }
        if ledger.count > Self.ledgerCapacity {
            ledger = Array(ledger.suffix(Self.ledgerCapacity))
        }
        document.contacts[index].ledger = ledger
    }

    func save() {
        prune()
        document.updatedAt = Date()
        GalchatSharedFile.write(document, named: Self.fileName)
    }

    // MARK: - 归一化

    /// 标题归一化。实现放在共享层 `ContactMatcher`——键盘也要用它判断标题可信度，
    /// 两边各写一份迟早会漂移。
    nonisolated static func normalize(_ raw: String) -> String {
        ContactMatcher.normalize(raw)
    }
}
