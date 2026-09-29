import Foundation
import Synapse

/// 识图路线：把表情包图片与附近聊天文字发给视觉模型，得到一句简短含义。
/// 只在用户开启"视觉接口"后调用；图片为 SeeU 裁出的小尺寸 JPEG。
struct StickerSemanticsClient {
    private let gateway: SynapseGateway

    init(gateway: SynapseGateway = .shared) {
        self.gateway = gateway
    }

    /// 返回不超过 20 字的表情含义；模型返回空文本时抛错。
    func describe(sticker jpeg: Data, nearby: [ContextMessage], route: SynapseModelRoute) async throws -> String {
        let conversation = nearby.filter { !$0.isGap }.suffix(4)
            .map { "\(Self.label($0.speaker))：\($0.text)" }
            .joined(separator: "\n")
        let system = PromptStore.current.sticker
        let text = conversation.isEmpty ? "请解读这个表情包。" : "附近聊天：\n\(conversation)\n\n请解读这个表情包。"
        let response = try await gateway.complete(
            messages: [.system(system), .user(text: text, images: [SynapseImageInput(data: jpeg)])],
            temperature: 0.2, using: route
        )
        let meaning = Self.clean(response.firstContent)
        guard !meaning.isEmpty else { throw EmptyMeaning() }
        return meaning
    }

    struct EmptyMeaning: LocalizedError {
        var errorDescription: String? { "视觉模型没有返回表情含义" }
    }

    private static func label(_ speaker: Speaker) -> String {
        switch speaker {
        case .me: return "我"
        case .other: return "对方"
        case .unknown: return "未知发言人"
        }
    }

    static func clean(_ raw: String) -> String {
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'“”「」[]【】"))
        return String(trimmed.prefix(20))
    }
}
