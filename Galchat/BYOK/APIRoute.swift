import Foundation
import Synapse

/// 三条互相独立的模型路线。凭据按路线分别保存，不做跨路线回退。
enum APIRoute: String, CaseIterable {
    case judge
    case reply
    case vision

    var displayName: String {
        switch self {
        case .judge: return "判断接口"
        case .reply: return "回复接口"
        case .vision: return "视觉接口"
        }
    }
}

/// 判断路线的服务商。reply/vision 只需要 OpenAI 兼容 base URL，没有这一层。
enum JudgeProvider: String, CaseIterable {
    case openRouter = "openrouter"
    case typeSafe = "typesafe"
    case custom = "custom"

    var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .typeSafe: return "TypeSafe"
        case .custom: return "自定义"
        }
    }

    var defaultBaseURL: String {
        synapseProvider.defaultDecisionsBaseURL
    }

    var defaultModel: String {
        synapseProvider.defaultDecisionsModel
    }

    /// custom 由用户直接填完整 POST 地址，其余按服务商补路径。
    func endpoint(baseURL: String) -> String {
        synapseProvider.decisionsEndpoint(baseURL: baseURL)
    }

    var synapseProvider: SynapseProvider { SynapseProvider(rawValue: rawValue) ?? .custom }
}

extension String {
    var trimmedTrailingSlash: String {
        var s = self
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
