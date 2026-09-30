import Foundation

/// 仅保存文字；OCR 原文与人工纠正分层，后续识别不会覆盖用户的编辑。
/// 数据存在 `GalchatDatabase`；每次只写入发生变化的会话，不再整文件重写。
/// 旧版 App Group 里的 `recents.json` 首次启动时导入，成功后改名为 `.migrated` 保留。
@MainActor
final class RecentConversationStore {
    static let shared = RecentConversationStore()
    static let changed = Notification.Name("Galchat.RecentConversationStore.changed")
    static let editsChanged = Notification.Name("Galchat.RecentConversationStore.editsChanged")
    static let conversationCapacity = 100
    static let messageCapacity = 500
    static let textCapacity = 2000
    private static let legacyFileName = "recents.json"

    struct Correction: Codable, Equatable, Sendable {
        var speakerRaw: String
        var text: String
    }

    struct Message: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        var speakerRaw: String
        var text: String
        var isGap: Bool
        var clipped: Bool
        var correction: Correction?

        var effectiveSpeaker: Speaker { Speaker(rawValue: correction?.speakerRaw ?? speakerRaw) ?? .unknown }
        var effectiveText: String { correction?.text ?? text }
        var speakerLabel: String {
            switch effectiveSpeaker {
            case .me: return "我"
            case .other: return "对方"
            case .unknown: return "未知发言方"
            }
        }
    }

    struct Conversation: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let sessionID: UUID
        let conversationID: UUID
        var sourceTitle: String
        var sourceConfirmed: Bool
        var contactID: String?
        var userBound: Bool
        var updatedAt: Date
        var messages: [Message]

        var analysisText: String {
            messages.map { message in
                let text = message.effectiveText.components(separatedBy: .newlines).joined(separator: " ")
                if message.isGap { return "[上下文缺口：\(text)]" }
                let clipping = message.clipped && message.correction == nil ? "[原消息被裁切] " : ""
                return "\(message.speakerLabel)：\(clipping)\(text)"
            }.joined(separator: "\n")
        }
    }

    private struct Document: Codable {
        var schemaVersion = 1
        var conversations: [Conversation] = []
    }

    enum StorageError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let message) = self { return message }
            return nil
        }
    }

    private var document = Document()
    private var loadError: String?
    private(set) var lastError: String?
    /// 删除当前正在识别的会话后，本次进程内不再自动重建该存档。
    private var deletedIDs = Set<String>()
    private var recordingSessionID: UUID?

    private let database: GalchatDatabase?

    private init() {
        var database: GalchatDatabase?
        do {
            let opened = try GalchatDatabase.shared.get()
            database = opened
            if try !opened.flag(GalchatDatabase.recentsImportedKey),
               let url = GalchatSharedFile.fileURL(named: Self.legacyFileName),
               FileManager.default.fileExists(atPath: url.path) {
                do {
                    let loaded = try GalchatSharedFile.decoder.decode(Document.self, from: Data(contentsOf: url))
                    guard Self.isValid(loaded) else { throw StorageError.message("会话文件版本或内容不受支持。") }
                    try opened.saveConversations(from: opened.loadConversations(), to: loaded.conversations,
                                                 markImported: true)
                    GalchatDatabase.retireLegacyFile(named: Self.legacyFileName)
                } catch {
                    loadError = "旧版最近会话无法导入，已保留原文件并暂停保存。\(error.localizedDescription)"
                }
            }
            if loadError == nil { document.conversations = try opened.loadConversations() }
        } catch {
            loadError = "会话数据库无法打开，修改暂不会保存。请重新打开应用后再试。\(error.localizedDescription)"
        }
        self.database = database
        lastError = loadError
    }

    private static func isValid(_ loaded: Document) -> Bool {
        loaded.schemaVersion == 1
            && loaded.conversations.count <= Self.conversationCapacity
            && Set(loaded.conversations.map(\.id)).count == loaded.conversations.count
            && loaded.conversations.allSatisfy({ entry in
                entry.id == Self.identifier(sessionID: entry.sessionID, conversationID: entry.conversationID)
                    && entry.messages.count <= Self.messageCapacity
                    && entry.sourceTitle.count <= 200
                    && Set(entry.messages.map(\.id)).count == entry.messages.count
                    && entry.messages.allSatisfy { message in
                        Speaker(rawValue: message.speakerRaw) != nil
                            && message.text.count <= Self.textCapacity
                            && (message.correction.map {
                                Speaker(rawValue: $0.speakerRaw) != nil && $0.text.count <= Self.textCapacity
                            } ?? true)
                    }
            })
    }

    func conversations(contactID: String? = nil) -> [Conversation] {
        document.conversations.filter { contactID == nil || $0.contactID == contactID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func conversation(id: String) -> Conversation? {
        document.conversations.first { $0.id == id }
    }

    func contactID(for context: ConversationContext) -> String? {
        let id = conversation(id: Self.identifier(context))?.contactID
        return ContactsStore.shared.contact(id: id)?.id
    }

    func isDeleted(_ context: ConversationContext) -> Bool {
        deletedIDs.contains(Self.identifier(context))
    }

    func record(_ context: ConversationContext, contactID: String?) {
        if recordingSessionID != context.sessionID {
            deletedIDs.removeAll()
            recordingSessionID = context.sessionID
        }
        let id = Self.identifier(context)
        // 未对齐的单屏不知道和已存记录的先后，不写入，避免把历史片段追加到末尾。
        guard !deletedIDs.contains(id), !context.isIsolated,
              context.messages.contains(where: { !$0.isGap }) else { return }
        var candidate = document
        let existing = conversation(id: id)
        var entry = existing ?? Conversation(
            id: id, sessionID: context.sessionID, conversationID: context.conversationID,
            sourceTitle: String(context.sourceTitle.prefix(200)), sourceConfirmed: context.sourceConfirmed,
            contactID: contactID, userBound: false, updatedAt: context.observedAt, messages: [])
        entry.sourceTitle = String(context.sourceTitle.prefix(200))
        entry.sourceConfirmed = context.sourceConfirmed
        if !entry.userBound { entry.contactID = contactID ?? entry.contactID }
        let incoming = Array(context.messages.suffix(Self.messageCapacity))
        Self.dropRetracted(from: &entry.messages, incoming: incoming)
        var indices = Dictionary(uniqueKeysWithValues: entry.messages.enumerated().map { ($0.element.id, $0.offset) })
        for (position, source) in incoming.enumerated() {
            let oldIndex = indices[source.id]
            let message = Message(
                id: source.id, speakerRaw: source.speaker.rawValue,
                text: String(source.text.prefix(Self.textCapacity)), isGap: source.isGap,
                clipped: source.clipped, correction: oldIndex.flatMap { entry.messages[$0].correction })
            if let oldIndex { entry.messages[oldIndex] = message }
            else {
                // 向上翻历史时，新识别的旧消息插在下一条已知消息之前。
                let nextKnownID = incoming.dropFirst(position + 1).first { next in
                    indices[next.id] != nil
                }?.id
                if let nextKnownID, let nextIndex = indices[nextKnownID] {
                    entry.messages.insert(message, at: nextIndex)
                    indices = Dictionary(uniqueKeysWithValues: entry.messages.enumerated().map { ($0.element.id, $0.offset) })
                } else {
                    indices[source.id] = entry.messages.count
                    entry.messages.append(message)
                }
            }
        }
        entry.messages = Array(entry.messages.suffix(Self.messageCapacity))
        // 帧时间、revision 不参与落盘：相同的识别文本不更新排序，也不重写文件。
        guard entry != existing else { return }
        entry.updatedAt = max(entry.updatedAt, context.observedAt)
        candidate.conversations.removeAll { $0.id == id }
        candidate.conversations.append(entry)
        candidate.conversations.sort { $0.updatedAt > $1.updatedAt }
        candidate.conversations = Array(candidate.conversations.prefix(Self.conversationCapacity))
        do { try persist(candidate, editedConversationID: nil) }
        catch { report(error) }
    }

    /// SeeU 会删除误识别条目、把同一位置的重复条目并成一条。已存记录里夹在本次上下文首尾之间、
    /// 却不在本次上下文中的消息就是被撤回的误识别，删掉；用户纠正过的消息保留。
    static func dropRetracted(from messages: inout [Message], incoming: [ContextMessage]) {
        let ids = Set(incoming.map(\.id))
        guard let first = incoming.first(where: { !$0.isGap })?.id,
              let last = incoming.last(where: { !$0.isGap })?.id,
              let lower = messages.firstIndex(where: { $0.id == first }),
              let upper = messages.lastIndex(where: { $0.id == last }), lower < upper else { return }
        let removable = Set(messages[lower...upper].filter {
            !ids.contains($0.id) && $0.correction == nil && !$0.isGap
        }.map(\.id))
        guard !removable.isEmpty else { return }
        messages.removeAll { removable.contains($0.id) }
    }

    func applyingCorrections(to context: ConversationContext) -> ConversationContext {
        guard let entry = conversation(id: Self.identifier(context)) else { return context }
        let corrections = Dictionary(uniqueKeysWithValues: entry.messages.compactMap { message in
            message.correction.map { (message.id, $0) }
        })
        let messages = context.messages.map { message -> ContextMessage in
            guard !message.isGap, let correction = corrections[message.id] else { return message }
            return ContextMessage(id: message.id, speaker: Speaker(rawValue: correction.speakerRaw) ?? .unknown,
                                  text: correction.text, isGap: message.isGap, clipped: false,
                                  isUserCorrected: true)
        }
        return ConversationContext(
            sessionID: context.sessionID, conversationID: context.conversationID, revision: context.revision,
            sourceTitle: context.sourceTitle, sourceConfirmed: context.sourceConfirmed,
            frameID: context.frameID, observedAt: context.observedAt, messages: messages,
            contactID: ContactsStore.shared.contact(id: entry.contactID)?.id
                ?? ContactsStore.shared.contact(id: context.contactID)?.id,
            isLiveTail: context.isLiveTail, isIsolated: context.isIsolated)
    }

    func correct(conversationID: String, messageID: UUID, speaker: Speaker, text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= Self.textCapacity else {
            throw StorageError.message("消息内容须为 1 到 \(Self.textCapacity) 字。")
        }
        try change(conversationID) { entry in
            guard let index = entry.messages.firstIndex(where: { $0.id == messageID && !$0.isGap }) else {
                throw StorageError.message("此消息已不在保留范围内。")
            }
            entry.messages[index].correction = Correction(speakerRaw: speaker.rawValue, text: text)
        }
    }

    func restore(conversationID: String, messageID: UUID) throws {
        try change(conversationID) { entry in
            guard let index = entry.messages.firstIndex(where: { $0.id == messageID }) else {
                throw StorageError.message("此消息已不在保留范围内。")
            }
            entry.messages[index].correction = nil
        }
    }

    func bind(conversationID: String, contactID: String) throws {
        guard ContactsStore.shared.contact(id: contactID) != nil else {
            throw StorageError.message("此联系人已不存在，请重新选择。")
        }
        try change(conversationID) { entry in
            entry.contactID = contactID
            entry.userBound = true
        }
    }

    func bindCurrent(_ context: ConversationContext, to contactID: String) throws {
        try bind(conversationID: Self.identifier(context), contactID: contactID)
    }

    func delete(conversationID: String) throws {
        var candidate = document
        candidate.conversations.removeAll { $0.id == conversationID }
        let previousDeletedIDs = deletedIDs
        if let recordingSessionID, conversationID.hasPrefix(recordingSessionID.uuidString + ":") {
            deletedIDs.insert(conversationID)
        }
        do { try persist(candidate, editedConversationID: conversationID) }
        catch {
            deletedIDs = previousDeletedIDs
            throw error
        }
    }

    private func change(_ id: String, edit: (inout Conversation) throws -> Void) throws {
        var candidate = document
        guard let index = candidate.conversations.firstIndex(where: { $0.id == id }) else {
            throw StorageError.message("此会话已不在保留范围内。")
        }
        try edit(&candidate.conversations[index])
        guard candidate.conversations[index] != document.conversations[index] else { return }
        candidate.conversations[index].updatedAt = Date()
        try persist(candidate, editedConversationID: id)
    }

    private func persist(_ candidate: Document, editedConversationID: String?) throws {
        if let loadError { throw StorageError.message(loadError) }
        do {
            guard let database else { throw StorageError.message("会话数据库不可用。") }
            try database.saveConversations(from: document.conversations, to: candidate.conversations)
        } catch {
            let error = StorageError.message("会话保存失败，修改尚未保存。请检查设备存储空间后重试。")
            report(error)
            throw error
        }
        document = candidate
        lastError = nil
        NotificationCenter.default.post(name: Self.changed, object: self)
        if let editedConversationID {
            NotificationCenter.default.post(name: Self.editsChanged, object: self,
                                            userInfo: ["conversationID": editedConversationID])
        }
    }

    private func report(_ error: Error) {
        let message = error.localizedDescription
        guard lastError != message else { return }
        lastError = message
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    private static func identifier(_ context: ConversationContext) -> String {
        identifier(sessionID: context.sessionID, conversationID: context.conversationID)
    }

    private static func identifier(sessionID: UUID, conversationID: UUID) -> String {
        "\(sessionID.uuidString):\(conversationID.uuidString)"
    }
}
