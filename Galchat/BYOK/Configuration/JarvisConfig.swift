import Foundation
import Synapse

/// Galchat 产品设置，以及三条业务路线的模型配置入口。
@MainActor
final class JarvisConfig {
    static let shared = JarvisConfig()

    private let defaults: UserDefaults
    let judge: SynapseModelConfiguration
    let reply: SynapseModelConfiguration
    let vision: SynapseModelConfiguration

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 模型配置与凭据使用 Synapse 命名空间，产品设置使用 Galchat 命名空间。
        self.judge = SynapseModelConfiguration(
            id: APIRoute.judge.rawValue, apiProtocol: .jevDecisions,
            defaults: defaults, namespace: "Synapse", defaultProvider: .openRouter
        )
        self.reply = SynapseModelConfiguration(
            id: APIRoute.reply.rawValue, apiProtocol: .chatCompletions,
            defaults: defaults, namespace: "Synapse",
            defaultBaseURL: Defaults.replyBaseURL, defaultModel: Defaults.replyModel
        )
        self.vision = SynapseModelConfiguration(
            id: APIRoute.vision.rawValue, apiProtocol: .chatCompletions,
            defaults: defaults, namespace: "Synapse",
            defaultBaseURL: Defaults.visionBaseURL, defaultModel: Defaults.visionModel
        )
    }

    // MARK: - Vision（可选，默认关闭）

    var visionEnabled: Bool {
        get { defaults.bool(forKey: Keys.visionEnabled) }
        set { defaults.set(newValue, forKey: Keys.visionEnabled) }
    }

    // MARK: - 分析上下文

    var relationship: String {
        get { defaults.trimmedString(Keys.relationship) ?? Defaults.relationship }
        set { defaults.setTrimmed(newValue, forKey: Keys.relationship) }
    }

    // MARK: - 长截图与上下文

    /// 长截图保留的不重复画面张数。越多越占内存（每张约 100 KB JPEG），导出的长图越长。
    var ladderCapacity: Int {
        get { Self.clamp(defaults.object(forKey: Keys.ladderCapacity) as? Int, Defaults.ladderCapacity, Defaults.ladderCapacityRange) }
        set {
            defaults.set(Self.clamp(newValue, Defaults.ladderCapacity, Defaults.ladderCapacityRange), forKey: Keys.ladderCapacity)
            NotificationCenter.default.post(name: JarvisConfig.liveSettingsDidChange, object: self)
        }
    }

    /// 每次分析发给模型的最近聊天条数（不含时间分隔线）。越多上下文越完整，token 消耗也越多。
    var contextMessageCount: Int {
        get { Self.clamp(defaults.object(forKey: Keys.contextMessageCount) as? Int, Defaults.contextMessageCount, Defaults.contextMessageRange) }
        set {
            defaults.set(Self.clamp(newValue, Defaults.contextMessageCount, Defaults.contextMessageRange), forKey: Keys.contextMessageCount)
            NotificationCenter.default.post(name: JarvisConfig.liveSettingsDidChange, object: self)
        }
    }

    static let liveSettingsDidChange = Notification.Name("Galchat.liveSettingsDidChange")

    private static func clamp(_ value: Int?, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value ?? fallback, range.lowerBound), range.upperBound)
    }

    // MARK: - 组合读取

    func configuration(for route: APIRoute) -> SynapseModelConfiguration {
        switch route {
        case .judge: return judge
        case .reply: return reply
        case .vision: return vision
        }
    }

    /// 该路线是否已填齐可发请求的最小配置。
    func isConfigured(_ route: APIRoute) -> Bool {
        configuration(for: route).isConfigured
    }

    /// 一次分析在启动时读取；生成和排序期间不再读取可变设置。
    func routeSnapshot(for route: APIRoute) -> SynapseModelRoute {
        configuration(for: route).snapshot()
    }

    private enum Keys {
        static let visionEnabled = "Galchat.vision.enabled"
        static let relationship = "Galchat.relationship"
        static let ladderCapacity = "Galchat.live.ladderCapacity"
        static let contextMessageCount = "Galchat.live.contextMessageCount"
    }

    enum Defaults {
        static let replyBaseURL = "https://openrouter.ai/api/v1"
        static let replyModel = "deepseek/deepseek-chat-v3.1"
        static let visionBaseURL = "https://openrouter.ai/api/v1"
        static let visionModel = "qwen/qwen2.5-vl-72b-instruct"
        static let relationship = "对方是我的伴侣；from=me 的是我发的，from=other 的是对方发的"
        nonisolated static let ladderCapacity = 10
        nonisolated static let ladderCapacityRange = 3...30
        nonisolated static let contextMessageCount = 10
        nonisolated static let contextMessageRange = 4...50
    }
}

private extension UserDefaults {
    /// 空白值等同未设置，让调用方落到默认值而不是拿到空串去拼 URL。
    func trimmedString(_ key: String) -> String? {
        guard let raw = string(forKey: key) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func setTrimmed(_ value: String, forKey key: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            removeObject(forKey: key)
        } else {
            set(trimmed, forKey: key)
        }
    }
}
