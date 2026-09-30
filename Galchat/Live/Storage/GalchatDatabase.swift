import Foundation
import GRDB

/// 联系人、好感度历史与最近会话的 SQLite 数据库（GRDB）。
///
/// 设计取舍：
/// - **只放在主 App 沙盒**（Application Support），不放 App Group。键盘和录屏扩展都不读
///   联系人与会话；共享容器里的 SQLite 在 App 挂起时持有文件锁会被系统终止（0xdead10cc）。
/// - `ContactsStore` / `RecentConversationStore` 仍在内存里保留完整文档，对外接口保持同步；
///   这里只负责按“改了哪些行”写入，不再每次整文件重写。
/// - 旧版 `contacts.json` / `recents.json` 首次启动时导入，导入成功后改名为 `.migrated` 备份，不删除。
final class GalchatDatabase {
    static let fileName = "galchat.sqlite"
    /// 好感度历史保留天数。走势最多展示 30 天，多留一些便于以后扩展。
    static let affectionHistoryRetention: TimeInterval = 180 * 24 * 60 * 60

    /// 打开失败时保留错误，由各 Store 转成用户可读的提示并暂停保存。
    static let shared: Result<GalchatDatabase, Error> = Result { try GalchatDatabase() }

    let queue: DatabaseQueue

    private init() throws {
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Galchat", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            // 与旧 JSON 一致：聊天衍生数据不进 iCloud 备份。
            var excluded = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? excluded.setResourceValues(values)
        }
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.label = "Galchat"
        queue = try DatabaseQueue(path: directory.appendingPathComponent(Self.fileName).path,
                                  configuration: configuration)
        try Self.migrator.migrate(queue)
        try queue.write { db in
            try db.execute(sql: "DELETE FROM affection_event WHERE at < ?",
                           arguments: [Date().addingTimeInterval(-Self.affectionHistoryRetention)])
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "app_meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
            try db.create(table: "contact") { t in
                t.primaryKey("id", .text)
                t.column("display_name", .text).notNull()
                t.column("total", .integer).notNull()
                t.column("ruptured", .boolean).notNull().defaults(to: false)
                t.column("last_commit_at", .datetime)
                t.column("created_at", .datetime).notNull()
                t.column("note", .text)
                t.column("persona", .text)
            }
            try db.create(table: "contact_alias") { t in
                t.column("contact_id", .text).notNull().references("contact", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("alias", .text).notNull()
                t.primaryKey(["contact_id", "position"])
            }
            // 头像单独一张表：改备注、计分时不用重写几十 KB 的图片。
            try db.create(table: "contact_avatar") { t in
                t.primaryKey("contact_id", .text).references("contact", onDelete: .cascade)
                t.column("data", .blob).notNull()
            }
            try db.create(table: "scored_turn") { t in
                t.column("contact_id", .text).notNull().references("contact", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("id", .text).notNull()
                t.column("delta", .integer).notNull()
                t.column("clipped", .boolean).notNull()
                t.column("at", .datetime).notNull()
                t.primaryKey(["contact_id", "position"])
            }
            try db.create(table: "affection_event") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("contact_id", .text).notNull().references("contact", onDelete: .cascade)
                t.column("at", .datetime).notNull()
                t.column("delta", .integer).notNull()
                t.column("total_after", .integer).notNull()
                t.column("source", .text).notNull()
                t.column("reason", .text)
            }
            try db.create(index: "affection_event_contact_at", on: "affection_event", columns: ["contact_id", "at"])
            // 会话的 contact_id 不设外键：删除联系人时保留聊天正文，显示为未关联联系人。
            try db.create(table: "conversation") { t in
                t.primaryKey("id", .text)
                t.column("session_id", .text).notNull()
                t.column("conversation_id", .text).notNull()
                t.column("source_title", .text).notNull()
                t.column("source_confirmed", .boolean).notNull()
                t.column("contact_id", .text).indexed()
                t.column("user_bound", .boolean).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(table: "message") { t in
                t.column("conversation_id", .text).notNull().references("conversation", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("id", .text).notNull()
                t.column("speaker", .text).notNull()
                t.column("text", .text).notNull()
                t.column("is_gap", .boolean).notNull()
                t.column("clipped", .boolean).notNull()
                t.column("correction_speaker", .text)
                t.column("correction_text", .text)
                t.primaryKey(["conversation_id", "position"])
            }
        }
        // v2：头像记录来源（聊天自动提取 / 手动选择）；立绘单独一张表，按需读取。
        migrator.registerMigration("v2") { db in
            try db.alter(table: "contact_avatar") { t in t.add(column: "source", .text) }
            try db.create(table: "contact_illustration") { t in
                t.primaryKey("contact_id", .text).references("contact", onDelete: .cascade)
                t.column("data", .blob).notNull()
                t.column("created_at", .datetime).notNull()
            }
        }
        return migrator
    }

    // MARK: - 元数据

    func flag(_ key: String) throws -> Bool {
        try queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_meta WHERE key = ?", arguments: [key]) == "1"
        }
    }

    static func setMeta(_ db: Database, key: String, value: String?) throws {
        if let value {
            try db.execute(sql: "INSERT OR REPLACE INTO app_meta (key, value) VALUES (?, ?)", arguments: [key, value])
        } else {
            try db.execute(sql: "DELETE FROM app_meta WHERE key = ?", arguments: [key])
        }
    }

    /// 导入成功后把旧文件改名保留。改名失败不影响使用：导入标记已写入，不会重复导入。
    static func retireLegacyFile(named name: String) {
        guard let url = GalchatSharedFile.fileURL(named: name) else { return }
        let backup = url.appendingPathExtension("migrated")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }
}

// MARK: - 联系人

extension GalchatDatabase {
    static let activeContactKey = "contacts.activeContactID"
    static let contactsImportedKey = "legacy.contacts.imported"

    /// 一次好感度变化。走势和“最近变化”都从这里读。
    struct AffectionEvent: Equatable, Sendable {
        enum Source: String, Sendable { case analysis, manual }
        let contactID: String
        let at: Date
        let delta: Int
        let totalAfter: Int
        let source: Source
        let reason: String?
    }

    func loadContacts() throws -> ContactsStore.Document {
        try queue.read { db in
            var aliases: [String: [String]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT contact_id, alias FROM contact_alias ORDER BY contact_id, position") {
                aliases[row["contact_id"], default: []].append(row["alias"])
            }
            var avatars: [String: (data: Data, source: String?)] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT contact_id, data, source FROM contact_avatar") {
                avatars[row["contact_id"]] = (row["data"], row["source"])
            }
            var ledgers: [String: [ContactsStore.ScoredTurn]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM scored_turn ORDER BY contact_id, position") {
                ledgers[row["contact_id"], default: []].append(
                    ContactsStore.ScoredTurn(id: row["id"], delta: row["delta"], clipped: row["clipped"], at: row["at"]))
            }
            var document = ContactsStore.Document()
            document.contacts = try Row.fetchAll(db, sql: "SELECT * FROM contact ORDER BY created_at").map { row in
                let id: String = row["id"]
                return ContactsStore.Contact(
                    id: id, displayName: row["display_name"], aliases: aliases[id] ?? [],
                    total: row["total"], rupturedUntilResolved: row["ruptured"],
                    lastCommitAt: row["last_commit_at"], createdAt: row["created_at"],
                    ledger: ledgers[id] ?? [], note: row["note"], persona: row["persona"],
                    avatarData: avatars[id]?.data, avatarSource: avatars[id]?.source)
            }
            let active = try String.fetchOne(db, sql: "SELECT value FROM app_meta WHERE key = ?",
                                             arguments: [Self.activeContactKey])
            document.activeContactID = document.contact(id: active)?.id
            return document
        }
    }

    /// 只写入与上次成功保存相比有变化的联系人。整个保存在一个事务里，失败时全部回滚。
    func saveContacts(from old: ContactsStore.Document, to new: ContactsStore.Document,
                      events: [AffectionEvent], markImported: Bool = false) throws {
        let oldByID = Dictionary(old.contacts.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let newIDs = Set(new.contacts.map(\.id))
        try queue.write { db in
            for id in oldByID.keys where !newIDs.contains(id) {
                try db.execute(sql: "DELETE FROM contact WHERE id = ?", arguments: [id])
            }
            for contact in new.contacts {
                let previous = oldByID[contact.id]
                guard previous != contact else { continue }
                try Self.upsert(contact, in: db, avatarChanged: previous?.avatarData != contact.avatarData
                                    || previous?.avatarSource != contact.avatarSource)
            }
            for event in events where newIDs.contains(event.contactID) {
                try db.execute(sql: """
                    INSERT INTO affection_event (contact_id, at, delta, total_after, source, reason)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [event.contactID, event.at, event.delta, event.totalAfter,
                                     event.source.rawValue, event.reason])
            }
            if old.activeContactID != new.activeContactID || markImported {
                try Self.setMeta(db, key: Self.activeContactKey, value: new.activeContactID)
            }
            if markImported { try Self.setMeta(db, key: Self.contactsImportedKey, value: "1") }
        }
    }

    private static func upsert(_ contact: ContactsStore.Contact, in db: Database, avatarChanged: Bool) throws {
        try db.execute(sql: """
            INSERT INTO contact (id, display_name, total, ruptured, last_commit_at, created_at, note, persona)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              display_name = excluded.display_name, total = excluded.total, ruptured = excluded.ruptured,
              last_commit_at = excluded.last_commit_at, note = excluded.note, persona = excluded.persona
            """, arguments: [contact.id, contact.displayName, contact.total, contact.rupturedUntilResolved,
                             contact.lastCommitAt, contact.createdAt, contact.note, contact.persona])
        try db.execute(sql: "DELETE FROM contact_alias WHERE contact_id = ?", arguments: [contact.id])
        for (position, alias) in contact.aliases.enumerated() {
            try db.execute(sql: "INSERT INTO contact_alias (contact_id, position, alias) VALUES (?, ?, ?)",
                           arguments: [contact.id, position, alias])
        }
        try db.execute(sql: "DELETE FROM scored_turn WHERE contact_id = ?", arguments: [contact.id])
        for (position, turn) in contact.ledger.enumerated() {
            try db.execute(sql: """
                INSERT INTO scored_turn (contact_id, position, id, delta, clipped, at) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [contact.id, position, turn.id, turn.delta, turn.clipped, turn.at])
        }
        guard avatarChanged else { return }
        if let data = contact.avatarData {
            try db.execute(sql: "INSERT OR REPLACE INTO contact_avatar (contact_id, data, source) VALUES (?, ?, ?)",
                           arguments: [contact.id, data, contact.avatarSource])
        } else {
            try db.execute(sql: "DELETE FROM contact_avatar WHERE contact_id = ?", arguments: [contact.id])
        }
    }

    // MARK: 立绘

    func illustrationIDs() throws -> Set<String> {
        try queue.read { db in Set(try String.fetchAll(db, sql: "SELECT contact_id FROM contact_illustration")) }
    }

    func illustration(contactID: String) throws -> Data? {
        try queue.read { db in
            try Data.fetchOne(db, sql: "SELECT data FROM contact_illustration WHERE contact_id = ?", arguments: [contactID])
        }
    }

    func setIllustration(_ data: Data?, contactID: String) throws {
        try queue.write { db in
            if let data {
                try db.execute(sql: "INSERT OR REPLACE INTO contact_illustration (contact_id, data, created_at) VALUES (?, ?, ?)",
                               arguments: [contactID, data, Date()])
            } else {
                try db.execute(sql: "DELETE FROM contact_illustration WHERE contact_id = ?", arguments: [contactID])
            }
        }
    }

    /// `since` 之后的变化（按时间正序），以及它之前的最后一次变化，用来确定走势起点。
    func affectionEvents(contactID: String, since: Date) throws -> (before: AffectionEvent?, events: [AffectionEvent]) {
        try queue.read { db in
            let before = try Row.fetchOne(db, sql: """
                SELECT * FROM affection_event WHERE contact_id = ? AND at < ? ORDER BY at DESC, id DESC LIMIT 1
                """, arguments: [contactID, since]).map(Self.event)
            let events = try Row.fetchAll(db, sql: """
                SELECT * FROM affection_event WHERE contact_id = ? AND at >= ? ORDER BY at, id
                """, arguments: [contactID, since]).map(Self.event)
            return (before, events)
        }
    }

    func latestAffectionEvents(contactID: String, limit: Int) throws -> [AffectionEvent] {
        try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM affection_event WHERE contact_id = ? ORDER BY at DESC, id DESC LIMIT ?
                """, arguments: [contactID, limit]).map(Self.event)
        }
    }

    private static func event(_ row: Row) -> AffectionEvent {
        AffectionEvent(contactID: row["contact_id"], at: row["at"], delta: row["delta"],
                       totalAfter: row["total_after"],
                       source: AffectionEvent.Source(rawValue: row["source"]) ?? .analysis,
                       reason: row["reason"])
    }
}

// MARK: - 最近会话

extension GalchatDatabase {
    static let recentsImportedKey = "legacy.recents.imported"

    func loadConversations() throws -> [RecentConversationStore.Conversation] {
        try queue.read { db in
            var messages: [String: [RecentConversationStore.Message]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM message ORDER BY conversation_id, position") {
                let correctionSpeaker: String? = row["correction_speaker"]
                let correctionText: String? = row["correction_text"]
                let correction = correctionSpeaker.flatMap { speaker in
                    correctionText.map { RecentConversationStore.Correction(speakerRaw: speaker, text: $0) }
                }
                guard let id = UUID(uuidString: row["id"]) else { continue }
                messages[row["conversation_id"], default: []].append(RecentConversationStore.Message(
                    id: id, speakerRaw: row["speaker"], text: row["text"], isGap: row["is_gap"],
                    clipped: row["clipped"], correction: correction))
            }
            return try Row.fetchAll(db, sql: "SELECT * FROM conversation ORDER BY updated_at DESC").compactMap { row in
                guard let sessionID = UUID(uuidString: row["session_id"]),
                      let conversationID = UUID(uuidString: row["conversation_id"]) else { return nil }
                let id: String = row["id"]
                return RecentConversationStore.Conversation(
                    id: id, sessionID: sessionID, conversationID: conversationID,
                    sourceTitle: row["source_title"], sourceConfirmed: row["source_confirmed"],
                    contactID: row["contact_id"], userBound: row["user_bound"], updatedAt: row["updated_at"],
                    messages: messages[id] ?? [])
            }
        }
    }

    /// 只写入有变化的会话；一个会话的消息整体替换（最多 500 行，在一个事务里完成）。
    func saveConversations(from old: [RecentConversationStore.Conversation],
                           to new: [RecentConversationStore.Conversation], markImported: Bool = false) throws {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let newIDs = Set(new.map(\.id))
        try queue.write { db in
            for id in oldByID.keys where !newIDs.contains(id) {
                try db.execute(sql: "DELETE FROM conversation WHERE id = ?", arguments: [id])
            }
            for entry in new {
                let previous = oldByID[entry.id]
                guard previous != entry else { continue }
                try db.execute(sql: """
                    INSERT INTO conversation (id, session_id, conversation_id, source_title, source_confirmed,
                                              contact_id, user_bound, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      source_title = excluded.source_title, source_confirmed = excluded.source_confirmed,
                      contact_id = excluded.contact_id, user_bound = excluded.user_bound,
                      updated_at = excluded.updated_at
                    """, arguments: [entry.id, entry.sessionID.uuidString, entry.conversationID.uuidString,
                                     entry.sourceTitle, entry.sourceConfirmed, entry.contactID,
                                     entry.userBound, entry.updatedAt])
                guard previous?.messages != entry.messages else { continue }
                try db.execute(sql: "DELETE FROM message WHERE conversation_id = ?", arguments: [entry.id])
                for (position, message) in entry.messages.enumerated() {
                    try db.execute(sql: """
                        INSERT INTO message (conversation_id, position, id, speaker, text, is_gap, clipped,
                                             correction_speaker, correction_text)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [entry.id, position, message.id.uuidString, message.speakerRaw,
                                         message.text, message.isGap, message.clipped,
                                         message.correction?.speakerRaw, message.correction?.text])
                }
            }
            if markImported { try Self.setMeta(db, key: Self.recentsImportedKey, value: "1") }
        }
    }
}
