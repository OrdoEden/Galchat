import Foundation

/// 主 App 与 Galchat 键盘之间的候选回复契约（架构文档 §8.3）。
///
/// 主 App 通过临时文件 + 原子替换写入 App Group 里的 `Galchat/reply-bundle.json`；
/// 键盘只读，不联网、不持有 API Key、不读屏幕帧。键盘每次展示和点击都要重新校验。
nonisolated struct ReplyBundle: Codable, Equatable, Sendable {
    static let currentSchema = 1
    static let maxCandidateLength = 120

    static func hasValidCandidateTexts(_ texts: [String]) -> Bool {
        texts.count == 3 && Set(texts).count == 3
            && texts.allSatisfy {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.count <= maxCandidateLength
            }
    }

    enum Status: String, Codable, Sendable {
        case ready
        case invalid
    }

    struct Candidate: Codable, Equatable, Sendable {
        let id: String
        /// 展示次序：1 最低，3 最高（优先推荐）。
        let rank: Int
        let text: String
    }

    var schemaVersion = ReplyBundle.currentSchema
    var bundleID: String
    var status: Status
    var sessionID: String
    var conversationID: String
    var revision: Int
    var analysisRequestID: String
    var generatedAt: Date
    /// 推荐的最长有效时间，不会被续期超过。
    var expiresAt: Date
    /// 来源新鲜度：主 App 仍看到同一会话、同一内容时才续期。
    var validUntil: Date
    var sourceTitle: String
    var sourceConfidence: String
    /// 判断结论的一句话摘要，键盘顶部展示。
    var summary: String?
    var candidates: [Candidate]
    /// invalid 时的原因（展示用）。
    var note: String?

    static func invalid(note: String) -> ReplyBundle {
        let now = Date()
        return ReplyBundle(
            bundleID: UUID().uuidString, status: .invalid, sessionID: "", conversationID: "", revision: 0,
            analysisRequestID: "", generatedAt: now, expiresAt: now, validUntil: now,
            sourceTitle: "", sourceConfidence: "unknown", summary: nil, candidates: [], note: note
        )
    }

    /// 键盘可以插入的条件。时间异常（设备时钟回拨到生成之前）一律视为失效。
    func isUsable(now: Date = Date()) -> Bool {
        schemaVersion == Self.currentSchema
            && status == .ready
            && ["confirmed", "recognized"].contains(sourceConfidence)
            && Self.hasValidCandidateTexts(candidates.map(\.text))
            && now >= generatedAt.addingTimeInterval(-5)
            && now < expiresAt
            && now < validUntil
    }
}

/// 读写 `reply-bundle.json`。主 App 负责建目录和写；键盘只调用 `load()`。
nonisolated enum ReplyBundleStore {
    static let fileName = "reply-bundle.json"

    /// App Group 标识来自 Info.plist 的 `VisynAppGroupIdentifier`（主 App 与键盘都配置了同一个值）。
    static var fileURL: URL? { GalchatSharedFile.fileURL(named: fileName) }

    static func load() -> ReplyBundle? {
        GalchatSharedFile.read(ReplyBundle.self, named: fileName)
    }

    static func modificationDate() -> Date? {
        GalchatSharedFile.modificationDate(named: fileName)
    }

    /// 主 App 专用：原子写入，设文件保护并排除备份（候选和联系人标题属于敏感的聊天衍生数据）。
    @discardableResult
    static func write(_ bundle: ReplyBundle) -> Bool {
        GalchatSharedFile.write(bundle, named: fileName)
    }
}
