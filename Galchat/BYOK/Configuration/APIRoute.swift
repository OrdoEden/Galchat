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

extension SynapseProvider {
    var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .typeSafe: return "TypeSafe"
        case .custom: return "自定义"
        }
    }
}
