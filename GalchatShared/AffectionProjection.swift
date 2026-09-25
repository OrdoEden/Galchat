import Foundation

/// 主 App 写给键盘的好感度读模型。
///
/// 与 `ReplyBundle` 的关键区别：**总分是持久事实，不是观察值**。候选建议会随
/// 录屏暂停/停止而失效（架构文档 §10.2），但「林小满 62」是已经发生过的历史，
/// 不该因为停止录屏就消失。所以键盘读这个文件时**不套 `ReplyBundle.isUsable()` 那套门禁**。
///
/// 这个文件被编译进键盘扩展，因此**不得引用任何主 App 侧的类型**。
nonisolated struct AffectionProjection: Codable, Equatable, Sendable {
    static let currentSchema = 1
    static let fileName = "affection-projection.json"

    /// 键盘内联确认行的选项上限。
    static let maxSuggestions = 3

    /// 本轮变化的读数多久后置灰。总分本身永不置灰。
    static let lastStepDisplayWindow: TimeInterval = 30

    /// 好感度的起评分与范围。
    ///
    /// 这几个常量放在共享层而不是 `AffectionScoring`：键盘只编译 `JarvisShared`，
    /// 引用不到 App target 的类型。`AffectionScoring` 里有一份同值引用，两边必须一致。
    static let initialTotal = 50
    static let minimumTotal = 0
    static let maximumTotal = 100

    struct Suggestion: Codable, Equatable, Sendable {
        let id: String
        let displayName: String
        /// 归一化后的匹配分，用于排序展示。不是好感度。
        let score: Double
    }

    var schemaVersion = AffectionProjection.currentSchema
    var updatedAt: Date
    var activeContactID: String?
    var displayName: String?
    /// 0...100 的累计好感度。
    var total: Int
    /// 最近一轮的 ± 变化（已含饱和与耦合，是界面该显示的那个值）。
    var lastStep: Int
    var lastStepAt: Date?
    /// 破裂未修复状态，用于把读数染红。
    var ruptured: Bool
    /// OCR 出来的会话标题，用于键盘展示"正在和谁聊"。
    var sourceTitle: String
    /// 标题不可信（"当前会话"或仅 OCR 识别）时为 true，键盘提示用户确认。
    var anonymous: Bool
    /// 待用户确认的联系人候选。非空时键盘显示内联确认行。
    var suggestions: [Suggestion]

    /// 当前是否绑定到了具体联系人。
    var hasContact: Bool { activeContactID != nil }

    /// 读数是否仍新鲜。过期只影响 ± 的展示，不影响总分。
    func isStepFresh(now: Date = Date()) -> Bool {
        guard let lastStepAt else { return false }
        return now >= lastStepAt.addingTimeInterval(-5)
            && now < lastStepAt.addingTimeInterval(Self.lastStepDisplayWindow)
    }

    /// 键盘顶部那一行：`♥♥♥ 62 +3`。
    func heartsText(now: Date = Date()) -> String {
        var text = Hearts.text(total: total)
        if lastStep != 0, isStepFresh(now: now) {
            text += " \(lastStep > 0 ? "+" : "−")\(abs(lastStep))"
        }
        return text
    }

    /// 没有绑定联系人、或还没跑过分析时的占位。
    static func placeholder(now: Date = Date()) -> AffectionProjection {
        AffectionProjection(
            updatedAt: now, activeContactID: nil, displayName: nil,
            total: Self.initialTotal, lastStep: 0, lastStepAt: nil, ruptured: false,
            sourceTitle: "", anonymous: true, suggestions: []
        )
    }
}

/// 以 5 颗心表示 0...100 的好感度。键盘和 PiP 共用，避免两处渲染不一致。
nonisolated enum Hearts {
    static let count = 5

    /// 满心数量按五等分向下取整：0 分 0 颗，50 分 2 颗，99 分 4 颗，100 分 5 颗。
    ///
    /// 向下取整而不是四舍五入：向上舍会让 50 分显示 3 颗心（"过半"的错觉），
    /// 而玩家最在意的是"还差多少才到下一颗"。
    static func filled(total: Int) -> Int {
        let clamped = min(max(total, 0), 100)
        return min(count, clamped * count / 100)
    }

    /// `♥♥♥♡♡ 62`。用实心/空心符号而不是颜色，保证在 PiP 的单色小字里也可读。
    static func text(total: Int) -> String {
        let filledCount = filled(total: total)
        let hearts = String(repeating: "♥", count: filledCount)
            + String(repeating: "♡", count: count - filledCount)
        return "\(hearts) \(min(max(total, 0), 100))"
    }
}

/// 读写投影文件。主 App 写；键盘只读 `load()` + 写 `writeDecision(_:)`。
nonisolated enum AffectionProjectionStore {
    static func load() -> AffectionProjection? {
        guard let projection = GalchatSharedFile.read(AffectionProjection.self,
                                                     named: AffectionProjection.fileName),
              projection.schemaVersion == AffectionProjection.currentSchema
        else { return nil }
        return projection
    }

    static func modificationDate() -> Date? {
        GalchatSharedFile.modificationDate(named: AffectionProjection.fileName)
    }

    /// 主 App 专用。
    @discardableResult
    static func write(_ projection: AffectionProjection) -> Bool {
        GalchatSharedFile.write(projection, named: AffectionProjection.fileName)
    }

    // MARK: - 键盘 → 主 App 的确认回传

    /// 键盘唯一会写的东西。主 App 下次轮询时消费并删除。
    ///
    /// 键盘在架构上仍然是"只读候选、不联网、不持密钥"的；这里回传的是一个
    /// 用户点选结果，不含聊天内容，也不改变键盘的能力边界。
    nonisolated struct ContactDecision: Codable, Equatable, Sendable {
        static let currentSchema = 1
        static let fileName = "kb-contact-decision.json"

        enum Resolution: String, Codable, Sendable {
            /// 绑定到已有联系人。
            case existing
            /// 新建联系人。
            case create
            /// 本次不绑定。
            case ignore
        }

        var schemaVersion = ContactDecision.currentSchema
        var resolution: Resolution
        /// `resolution == .existing` 时为目标联系人 id，否则为空。
        var contactID: String?
        /// 决策针对的 OCR 标题，主 App 用它校验是不是同一次会话。
        var sourceTitle: String
        var decidedAt: Date
    }

    @discardableResult
    static func writeDecision(_ decision: ContactDecision) -> Bool {
        GalchatSharedFile.write(decision, named: ContactDecision.fileName)
    }

    static func loadDecision() -> ContactDecision? {
        guard let decision = GalchatSharedFile.read(ContactDecision.self,
                                                   named: ContactDecision.fileName),
              decision.schemaVersion == ContactDecision.currentSchema
        else { return nil }
        return decision
    }

    static func clearDecision() {
        GalchatSharedFile.remove(named: ContactDecision.fileName)
    }
}
