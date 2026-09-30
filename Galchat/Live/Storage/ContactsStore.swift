import UIKit

/// 联系人档案、好感度台账与好感度历史的持久化。
///
/// 数据存在 `GalchatDatabase`（GRDB / SQLite）里；内存中保留完整 `Document`，
/// 对外的同步查询不变。`save()` 只把与上次成功保存相比有变化的联系人写入数据库，
/// 头像单独存表，改备注或计分时不会重写图片。
///
/// 旧版 App Group 里的 `contacts.json` 在首次启动时导入，成功后改名为 `.migrated` 保留。
@MainActor
final class ContactsStore {
    static let shared = ContactsStore()
    static let changed = Notification.Name("Galchat.ContactsStore.changed")
    static let profileChanged = Notification.Name("Galchat.ContactsStore.profileChanged")

    /// 旧版 JSON 文件名，只用于一次性导入。
    static let legacyFileName = "contacts.json"
    /// 台账保留条数。必须大于 `LiveAnalysisScheduler.historyContextLimit`（50），
    /// 否则一次 `check_history` 刷新就能把整个台账冲掉，导致旧消息被重复计分。
    static let ledgerCapacity = 200
    /// 台账保留时长。更早的记录对应的消息不可能再出现在采集窗口里。
    static let ledgerRetention: TimeInterval = 24 * 60 * 60

    private(set) var document: Document
    private var persisted: Document
    private(set) var lastError: String?
    private var loadError: String?
    private let database: GalchatDatabase?
    /// 尚未落盘的好感度变化，随下一次 `save()` 一起写入。
    private var pendingEvents: [GalchatDatabase.AffectionEvent] = []

    private init() {
        var loaded = Document()
        var failure: String?
        var database: GalchatDatabase?
        do {
            let opened = try GalchatDatabase.shared.get()
            database = opened
            if try !opened.flag(GalchatDatabase.contactsImportedKey),
               let url = GalchatSharedFile.fileURL(named: Self.legacyFileName),
               FileManager.default.fileExists(atPath: url.path) {
                do {
                    let legacy = try GalchatSharedFile.decoder.decode(Document.self, from: Data(contentsOf: url))
                    let existing = try opened.loadContacts()
                    try opened.saveContacts(from: existing, to: legacy, events: [], markImported: true)
                    GalchatDatabase.retireLegacyFile(named: Self.legacyFileName)
                } catch {
                    failure = "旧版联系人数据无法导入，已保留原文件并暂停保存。\(error.localizedDescription)"
                }
            }
            if failure == nil { loaded = try opened.loadContacts() }
        } catch {
            failure = "联系人数据库无法打开，修改暂不会保存。请重新打开应用后再试。\(error.localizedDescription)"
        }
        self.database = database
        document = loaded
        persisted = loaded
        loadError = failure
        lastError = failure
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

    struct Contact: Codable, Equatable, Sendable, Identifiable {
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
        var note: String? = nil
        var persona: String? = nil
        var avatarData: Data? = nil
        /// 头像来源：`auto` 来自聊天识别，`manual` 由用户选择；手动头像不会被自动提取覆盖。
        var avatarSource: String? = nil
    }

    /// 一条已计分记录。用来防止同一轮对话被反复计分。
    struct ScoredTurn: Codable, Equatable, Sendable {
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
    func createContact(displayName: String, alias: String?, activate: Bool = true) -> Contact {
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
        if activate { document.activeContactID = contact.id }
        save()
        return contact
    }

    func setActiveContact(_ id: String?) {
        document.activeContactID = id
        save()
    }

    /// 把一个 OCR 标题绑到既有联系人。标题同时从其他联系人上摘掉——
    /// 否则同一次会话会在两个人之间来回摇摆。
    func bind(alias rawAlias: String, to contactID: String, activate: Bool = true) {
        let alias = Self.normalize(rawAlias)
        guard !alias.isEmpty, document.contacts.contains(where: { $0.id == contactID }) else { return }
        for index in document.contacts.indices {
            document.contacts[index].aliases.removeAll { $0 == alias }
        }
        guard let index = document.contacts.firstIndex(where: { $0.id == contactID }) else { return }
        document.contacts[index].aliases.append(alias)
        if activate { document.activeContactID = contactID }
        save()
    }

    func rename(contactID: String, to name: String) {
        guard let index = document.contacts.firstIndex(where: { $0.id == contactID }) else { return }
        document.contacts[index].displayName = name
        save()
    }

    /// 只修改档案字段；编辑期间新写入的计分台账与实时联系人绑定保持最新。
    func edit(contactID: String, displayName: String, note: String, persona: String,
              aliases: [String], total: Int?, avatarData: Data?) throws {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw EditError.message("请输入联系人名称。") }
        guard name.count <= 100, note.count <= 2000, persona.count <= 4000,
              aliases.count <= 30, aliases.allSatisfy({ $0.count <= 100 }) else {
            throw EditError.message("内容过长：名称与单条别名最多 100 字，备注 2000 字，人设 4000 字，别名最多 30 条。")
        }
        guard avatarData == nil || avatarData!.count <= 100_000 else {
            throw EditError.message("头像过大，请重新选择。")
        }
        guard total == nil || (0...100).contains(total!) else {
            throw EditError.message("好感度应在 0 到 100 之间。")
        }
        let normalized = Array(Set(aliases.map(Self.normalize).filter { !$0.isEmpty })).sorted()
        let identifiers = Set(normalized + [Self.normalize(name)])
        if let conflict = document.contacts.first(where: {
            $0.id != contactID && !identifiers.isDisjoint(with: Set($0.aliases.map(Self.normalize) + [Self.normalize($0.displayName)]))
        }) {
            throw EditError.message("名称或识别别名与“\(conflict.displayName)”重复，请修改后保存。")
        }
        guard let index = document.contacts.firstIndex(where: { $0.id == contactID }) else {
            throw EditError.message("此联系人已不存在。")
        }
        document.contacts[index].displayName = name
        document.contacts[index].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        document.contacts[index].persona = persona.trimmingCharacters(in: .whitespacesAndNewlines)
        document.contacts[index].aliases = normalized
        if document.contacts[index].avatarData != avatarData {
            document.contacts[index].avatarData = avatarData
            document.contacts[index].avatarSource = avatarData == nil ? nil : "manual"
        }
        if let total, total != document.contacts[index].total {
            recordEvent(contactID: contactID, from: document.contacts[index].total, to: total,
                        source: .manual, reason: "手动调整")
            document.contacts[index].total = total
        }
        guard save() else { throw EditError.message(lastError ?? "联系人保存失败。") }
        NotificationCenter.default.post(name: Self.profileChanged, object: self, userInfo: ["contactID": contactID])
    }

    enum EditError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let text) = self { return text }
            return nil
        }
    }

    func createProfile(displayName: String, alias: String?) throws -> Contact {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100, (alias?.count ?? 0) <= 100 else {
            throw EditError.message("联系人名称须为 1 到 100 字。")
        }
        let keys = Set(([name] + (alias.map { [$0] } ?? [])).map(Self.normalize).filter { !$0.isEmpty })
        if let conflict = document.contacts.first(where: {
            !keys.isDisjoint(with: Set(($0.aliases + [$0.displayName]).map(Self.normalize)))
        }) {
            throw EditError.message("名称或识别别名与“\(conflict.displayName)”重复，请修改后保存。")
        }
        let created = createContact(displayName: name, alias: alias, activate: false)
        guard contact(id: created.id) != nil else {
            throw EditError.message(lastError ?? "联系人保存失败。")
        }
        return created
    }

    func delete(contactID: String) {
        document.contacts.removeAll { $0.id == contactID }
        if document.activeContactID == contactID { document.activeContactID = nil }
        if save() {
            illustrationIDs.remove(contactID)
            NotificationCenter.default.post(name: Self.profileChanged, object: self, userInfo: ["contactID": contactID])
        }
    }

    func deleteProfile(contactID: String) throws {
        guard contact(id: contactID) != nil else { throw EditError.message("此联系人已不存在。") }
        delete(contactID: contactID)
        if let lastError { throw EditError.message(lastError) }
    }

    // MARK: - 头像与立绘

    /// 识别聊天时得到的对方头像。只在联系人没有手动头像时保存。
    func adoptChatAvatar(_ image: UIImage, contactID: String) {
        guard let index = document.contacts.firstIndex(where: { $0.id == contactID }),
              document.contacts[index].avatarSource != "manual",
              let data = Self.avatarJPEG(image), data != document.contacts[index].avatarData else { return }
        document.contacts[index].avatarData = data
        document.contacts[index].avatarSource = "auto"
        save()
    }

    /// 与编辑页相同的上限（100 KB）：缩到 256 像素内再压 JPEG。
    private static func avatarJPEG(_ image: UIImage) -> Data? {
        let side: CGFloat = 256
        let scale = min(1, side / max(image.size.width, image.size.height, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.8).flatMap { $0.count <= 100_000 ? $0 : resized.jpegData(compressionQuality: 0.5) }
    }

    private lazy var illustrationIDs: Set<String> = (try? database?.illustrationIDs()) ?? []
    private let illustrationCache = NSCache<NSString, UIImage>()

    func hasIllustration(_ contactID: String) -> Bool { illustrationIDs.contains(contactID) }

    func illustration(for contactID: String) -> UIImage? {
        guard hasIllustration(contactID) else { return nil }
        if let cached = illustrationCache.object(forKey: contactID as NSString) { return cached }
        guard let image = (try? database?.illustration(contactID: contactID)).flatMap({ $0 }).flatMap(UIImage.init(data:)) else { return nil }
        illustrationCache.setObject(image, forKey: contactID as NSString)
        return image
    }

    /// 传 nil 删除立绘。
    func setIllustration(_ data: Data?, contactID: String) throws {
        guard let database else { throw EditError.message("联系人数据库不可用。") }
        try database.setIllustration(data, contactID: contactID)
        illustrationCache.removeObject(forKey: contactID as NSString)
        if data == nil { illustrationIDs.remove(contactID) } else { illustrationIDs.insert(contactID) }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    // MARK: - 台账

    /// 该消息 id 是否已计过分。
    func scoredTurn(contactID: String, messageID: UUID) -> ScoredTurn? {
        contact(id: contactID)?.ledger.first { $0.id == messageID.uuidString }
    }

    /// 在既有记录上做**替换**而非累加。用于 `clipped` 翻转后的重算：
    /// 先减掉旧值再加新值，总分不会因为重算而翻倍。
    func replaceScoredTurn(contactID: String, turn: ScoredTurn, delta applied: Int, newTotal: Int,
                           reason: String? = nil) {
        guard let index = document.contacts.firstIndex(where: { $0.id == contactID }) else { return }
        var scratch = document.contacts[index]
        let before = scratch.total
        if let turnIndex = scratch.ledger.firstIndex(where: { $0.id == turn.id }) {
            scratch.ledger[turnIndex] = turn
        } else {
            scratch.ledger.append(turn)
        }
        scratch.total = min(max(newTotal, AffectionScoring.minimum), AffectionScoring.maximum)
        scratch.lastCommitAt = Date()
        document.contacts[index] = scratch
        recordEvent(contactID: contactID, from: before, to: scratch.total, source: .analysis, reason: reason)
    }

    /// 记录一次计分。`delta` 是已经算好的 applied step。
    func commit(contactID: String, turns: [ScoredTurn], delta: Int, totalBefore: Int, reason: String? = nil) {
        guard let index = document.contacts.firstIndex(where: { $0.id == contactID }) else { return }
        var scratch = document.contacts[index]
        for turn in turns where !scratch.ledger.contains(where: { $0.id == turn.id }) {
            scratch.ledger.append(turn)
        }
        let before = scratch.total
        scratch.total = min(max(totalBefore + delta, AffectionScoring.minimum), AffectionScoring.maximum)
        scratch.lastCommitAt = Date()
        document.contacts[index] = scratch
        pruneContact(at: index)
        recordEvent(contactID: contactID, from: before, to: scratch.total, source: .analysis, reason: reason)
    }

    /// 只记录真正改变了分数的变化；0 分变化对走势和“最近变化”都没有意义。
    private func recordEvent(contactID: String, from before: Int, to after: Int,
                             source: GalchatDatabase.AffectionEvent.Source, reason: String?) {
        guard before != after else { return }
        pendingEvents.append(.init(contactID: contactID, at: Date(), delta: after - before,
                                   totalAfter: after, source: source, reason: reason))
    }

    // MARK: - 好感度历史

    /// 最近 `days` 天每天结束时的好感度，最后一个值是今天（即当前分数）。
    /// 没有任何变化记录时是一条水平线。
    func affectionTrend(contactID: String, days: Int) -> [Int] {
        guard let contact = contact(id: contactID), days > 0 else { return [] }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today),
              let history = try? database?.affectionEvents(contactID: contactID, since: start) else {
            return Array(repeating: contact.total, count: days)
        }
        var value = history.before?.totalAfter
            ?? history.events.first.map { $0.totalAfter - $0.delta }
            ?? contact.total
        var events = history.events[...]
        var points: [Int] = []
        for offset in 0..<days {
            guard let dayEnd = calendar.date(byAdding: .day, value: offset + 1, to: start) else { break }
            while let event = events.first, event.at < dayEnd {
                value = event.totalAfter
                events = events.dropFirst()
            }
            points.append(value)
        }
        // 未保存的变化或手动修改的分数以内存为准。
        if !points.isEmpty { points[points.count - 1] = contact.total }
        return points
    }

    /// 最近的好感度变化，最新在前。
    func recentAffectionEvents(contactID: String, limit: Int = 3) -> [GalchatDatabase.AffectionEvent] {
        (try? database?.latestAffectionEvents(contactID: contactID, limit: limit)) ?? []
    }

    /// 今天的累计变化。
    func affectionChangeToday(contactID: String) -> Int {
        let start = Calendar.current.startOfDay(for: Date())
        let saved = (try? database?.affectionEvents(contactID: contactID, since: start).events) ?? []
        return saved.reduce(0) { $0 + $1.delta }
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

    @discardableResult
    func save() -> Bool {
        if let loadError {
            document = persisted
            pendingEvents.removeAll()
            lastError = loadError
            return false
        }
        prune()
        document.updatedAt = Date()
        do {
            guard let database else { throw EditError.message("联系人数据库不可用。") }
            try database.saveContacts(from: persisted, to: document, events: pendingEvents)
        } catch {
            document = persisted
            pendingEvents.removeAll()
            lastError = "联系人保存失败，修改尚未保存。请检查设备存储空间后重试。"
            return false
        }
        pendingEvents.removeAll()
        persisted = document
        lastError = nil
        NotificationCenter.default.post(name: Self.changed, object: self)
        return true
    }

    // MARK: - 归一化

    /// 标题归一化。实现放在共享层 `ContactMatcher`——键盘也要用它判断标题可信度，
    /// 两边各写一份迟早会漂移。
    nonisolated static func normalize(_ raw: String) -> String {
        ContactMatcher.normalize(raw)
    }
}

/// 识别到、但还没有归属联系人的头像。
///
/// 录屏里识别出对方头像时，用户可能还没把这轮会话绑定到某个联系人；
/// 直接丢掉的话，绑定之后就要再等一次识别。这里先按同一套压缩规则写一张小图，
/// 绑定后由 `LiveChatCoordinator` 取走并写进联系人；不覆盖手动头像。
enum PendingChatAvatar {
    private static let fileName = "pending-avatar.jpg"

    static var latest: UIImage? {
        guard let url = GalchatSharedFile.fileURL(named: fileName),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    static func stash(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        guard let url = GalchatSharedFile.fileURL(named: fileName) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func clear() {
        GalchatSharedFile.remove(named: fileName)
    }
}
