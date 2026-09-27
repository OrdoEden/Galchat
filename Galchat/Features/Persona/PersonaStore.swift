import Foundation

@MainActor
final class PersonaStore {
    static let shared = PersonaStore()
    static let changed = Notification.Name("Galchat.PersonaStore.changed")
    private static let key = "Galchat.personaProfiles.v1"

    struct Profile: Codable, Identifiable {
        var id: String
        var name: String
        var identity: String
        var replyStyle: String
    }

    private struct Document: Codable {
        var schemaVersion = 1
        var activeID: String
        var profiles: [Profile]
    }

    private var document: Document
    private(set) var lastError: String?
    private var loadError: String?
    var profiles: [Profile] { document.profiles }
    var activeID: String { document.activeID }
    var prompt: String {
        guard loadError == nil else { return "" }
        guard let profile = profiles.first(where: { $0.id == activeID }) else { return "" }
        return [profile.identity.isEmpty ? nil : "我的人设：\(profile.identity)",
                profile.replyStyle.isEmpty ? nil : "我的回复偏好：\(profile.replyStyle)"].compactMap { $0 }.joined(separator: "\n")
    }

    private init() {
        document = Document(activeID: "natural", profiles: [
            Profile(id: "natural", name: "自然", identity: "", replyStyle: "自然、简洁，像日常聊天。根据上下文回应，不编造个人经历。"),
            Profile(id: "gentle", name: "温柔", identity: "", replyStyle: "温和体贴，先回应对方感受，避免过度承诺和说教。"),
            Profile(id: "direct", name: "直接", identity: "", replyStyle: "清楚直接，表达真实立场与边界，保持尊重，避免绕弯。")
        ])
        if let stored = UserDefaults.standard.object(forKey: Self.key) {
            do {
                guard let data = stored as? Data else {
                    throw ContactsStore.EditError.message("人格数据格式无法识别。")
                }
                let loaded = try JSONDecoder().decode(Document.self, from: data)
                guard loaded.schemaVersion == 1, !loaded.profiles.isEmpty,
                      loaded.profiles.contains(where: { $0.id == loaded.activeID }),
                      Set(loaded.profiles.map(\.id)).count == loaded.profiles.count else {
                    throw ContactsStore.EditError.message("人格数据版本或内容无法识别。")
                }
                document = loaded
            } catch {
                loadError = "人格数据无法读取，已保留原数据并暂停保存。\(error.localizedDescription)"
                lastError = loadError
            }
        }
    }

    func select(id: String) throws {
        guard profiles.contains(where: { $0.id == id }) else { throw ContactsStore.EditError.message("此人格预设不存在。") }
        var next = document
        next.activeID = id
        try persist(next)
    }

    func save(_ profile: Profile) throws {
        var cleaned = profile
        cleaned.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.identity = profile.identity.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.replyStyle = profile.replyStyle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.name.isEmpty, cleaned.name.count <= 50,
              cleaned.identity.count <= 4000, cleaned.replyStyle.count <= 4000,
              !cleaned.identity.isEmpty || !cleaned.replyStyle.isEmpty else {
            throw ContactsStore.EditError.message("请填写名称和至少一项人设或回复偏好。名称最多 50 字，每项描述最多 4000 字。")
        }
        var next = document
        if let index = next.profiles.firstIndex(where: { $0.id == cleaned.id }) { next.profiles[index] = cleaned }
        else { next.profiles.append(cleaned) }
        try persist(next)
    }

    func delete(id: String) throws {
        guard profiles.contains(where: { $0.id == id }) else { throw ContactsStore.EditError.message("此人格预设不存在。") }
        guard profiles.count > 1 else { throw ContactsStore.EditError.message("请至少保留一个人格预设。") }
        var next = document
        next.profiles.removeAll { $0.id == id }
        if next.activeID == id { next.activeID = next.profiles[0].id }
        try persist(next)
    }

    private func persist(_ next: Document) throws {
        if let loadError { throw ContactsStore.EditError.message(loadError) }
        let data = try JSONEncoder().encode(next)
        UserDefaults.standard.set(data, forKey: Self.key)
        guard UserDefaults.standard.data(forKey: Self.key) == data else {
            lastError = "人格设置未能保存，请重试。"
            throw ContactsStore.EditError.message(lastError!)
        }
        document = next
        lastError = nil
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}
