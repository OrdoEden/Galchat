import Foundation

/// 可注入的提示词包：回复生成、表情包解读的系统提示词，以及 Jev 题目说明、选项判定标准和评分档位的措辞。
///
/// 随 App 附带 `prompts.json`，也可以从资源库远程更新（见 `ResourceCatalog`）。
/// Jev 部分能换的只有措辞；题目 id、题型、选项 key 和档位数是代码约定——`JudgeClient` 按 key 取答案，
/// `AffectionScoring` 按选项 key 计分，PiP 按选项 key 显示中文，`danger_level` 的第 9 档表示破裂。
/// 不符合约定的题目包整体拒绝，不会部分生效。
nonisolated struct PromptPack: Codable, Sendable {
    enum Criteria: Codable, Sendable, Equatable {
        /// noul 的 true/false，或 choice 的各选项。
        case keyed([String: String])
        /// score 的档位，从 0 开始。
        case levels([String])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let levels = try? container.decode([String].self) {
                self = .levels(levels)
            } else {
                self = .keyed(try container.decode([String: String].self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .keyed(let values): try container.encode(values)
            case .levels(let levels): try container.encode(levels)
            }
        }
    }

    struct Question: Codable, Sendable {
        var type: String
        var instructions: String
        /// 排序题的选项是运行时的候选回复，题目包里不写。
        var criteria: Criteria?
    }

    private enum Shape {
        case noul
        case choice(Set<String>)
        case score(levels: Int)
        /// 选项在运行时填入。
        case runtimeChoice
    }

    static let fileName = "prompts.json"
    static let maximumBytes = 200_000

    private static let judgeContract: [String: Shape] = [
        "literal_question": .noul,
        "true_intent": .choice(["confirm_you_care", "vent_anger", "request_action", "seek_explanation", "casual_chat", "close_topic"]),
        "danger_level": .score(levels: 10),
        "should_reply_now": .noul,
        "best_action": .choice(["check_history", "apologize", "give_commitment", "explain", "acknowledge", "say_less", "make_plan"]),
        "she_needs": .choice(["apology", "action", "explanation", "care", "nothing"]),
        "tension_resolved": .noul,
        "affection_delta": .choice(["warm_up", "slight_up", "neutral", "slight_down", "cold_down"])
    ]
    private static let rankContract: [String: Shape] = ["best_reply": .runtimeChoice]

    var schemaVersion: Int
    var version: String
    var backgroundNote: String
    /// 回复生成的系统提示词。输出须是 3 条的 JSON 数组，解析在 `ReplyClient.parseThree`。
    var reply: String
    /// 表情包解读的系统提示词。
    var sticker: String
    var judge: [String: Question]
    var rank: [String: Question]

    enum PackError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let reason): return "提示词包不符合要求：\(reason)" }
        }
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw PackError.invalid("文件超过 200 KB") }
        let pack = try JSONDecoder().decode(Self.self, from: data)
        try pack.validate()
        return pack
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw PackError.invalid("版本暂不支持，可能需要更新 App") }
        guard !version.isEmpty, version.count <= 100, backgroundNote.count <= 500 else {
            throw PackError.invalid("版本号或 backgroundNote 无效")
        }
        guard Self.validTexts([reply, sticker]) else { throw PackError.invalid("reply 或 sticker 为空或过长") }
        try Self.check(judge, against: Self.judgeContract)
        try Self.check(rank, against: Self.rankContract)
    }

    private static func check(_ questions: [String: Question], against contract: [String: Shape]) throws {
        guard Set(questions.keys) == Set(contract.keys) else {
            throw PackError.invalid("题目必须正好是 \(contract.keys.sorted().joined(separator: "、"))")
        }
        for (key, shape) in contract {
            guard let question = questions[key] else { continue }
            let instructions = question.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instructions.isEmpty, question.instructions.count <= 4_000 else {
                throw PackError.invalid("\(key) 的说明为空或超过 4000 字")
            }
            let valid: Bool
            switch (shape, question.criteria) {
            case (.noul, .keyed(let values)):
                valid = question.type == "noul" && Set(values.keys) == ["true", "false"] && Self.validTexts(values.values)
            case (.choice(let keys), .keyed(let values)):
                valid = question.type == "choice" && Set(values.keys) == keys && Self.validTexts(values.values)
            case (.score(let count), .levels(let levels)):
                valid = question.type == "score" && levels.count == count && Self.validTexts(levels)
            case (.runtimeChoice, nil):
                valid = question.type == "choice"
            default:
                valid = false
            }
            guard valid else { throw PackError.invalid("\(key) 的题型或选项与 App 约定不一致") }
        }
    }

    private static func validTexts<S: Sequence>(_ texts: S) -> Bool where S.Element == String {
        texts.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 4_000 }
    }
}

/// 当前生效的提示词包：资源库下载的版本比附带版本新时用下载的，否则用附带的。
enum PromptStore {
    static let changed = Notification.Name("Galchat.PromptStore.changed")

    /// 附带的题目包由 `scripts/check_personas.py` 按同一约定校验，损坏属于打包错误。
    static let bundled: PromptPack = {
        guard let url = Bundle.main.url(forResource: "prompts", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let pack = try? PromptPack.decode(data) else {
            fatalError("随 App 附带的 \(PromptPack.fileName) 缺失或不符合约定")
        }
        return pack
    }()

    private static var downloaded: PromptPack? = loadDownloaded()

    static var current: PromptPack {
        if let downloaded, PersonaPackage.isVersion(downloaded.version, newerThan: bundled.version) { return downloaded }
        return bundled
    }

    /// 校验并保存下载的题目包；不符合约定时抛错，当前题目包保持不变。
    static func install(_ data: Data) throws {
        let pack = try PromptPack.decode(data)
        guard let url = storageURL(create: true) else { throw PromptPack.PackError.invalid("无法保存") }
        try data.write(to: url, options: .atomic)
        downloaded = pack
        NotificationCenter.default.post(name: changed, object: nil)
    }

    private static func loadDownloaded() -> PromptPack? {
        guard let url = storageURL(create: false), let data = try? Data(contentsOf: url) else { return nil }
        return try? PromptPack.decode(data)
    }

    private static func storageURL(create: Bool) -> URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                          appropriateFor: nil, create: create) else { return nil }
        let directory = support.appendingPathComponent("ResourceLibrary", isDirectory: true)
        if create { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        return directory.appendingPathComponent(PromptPack.fileName)
    }
}
