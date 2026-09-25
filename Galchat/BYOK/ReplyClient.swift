import Foundation
import Synapse

/// 生成路线：任意 OpenAI 兼容 `/chat/completions`。
struct ReplyClient {
    private let config: JarvisConfig
    private let gateway: SynapseGateway

    init(config: JarvisConfig = .shared, gateway: SynapseGateway = .shared) {
        self.config = config
        self.gateway = gateway
    }

    /// 生成恰好 3 条中文候选。不足 3 条或有重复时抛错，不拼凑占位回复——
    /// 占位文案被排序后当成真候选插入输入框，比直接报错危险得多。
    func draft(snapshot: ChatSnapshot, relationship: String, route: SynapseModelRoute? = nil) async throws -> [String] {
        let conversation = snapshot.recentMessages
            .map { "\($0.speaker.label)：\($0.text)" }
            .joined(separator: "\n")
        let system = "你是中文即时通讯回复助手。只输出一个 JSON 数组，含且仅含 3 条候选回复文本，"
            + "三条策略要有区别（例如：一条稳妥承接、一条给具体行动或承诺、一条简短低姿态）。"
            + "每条不超过 40 字，口语、自然、像真人在聊天软件里发消息。不要解释，不要加引号以外的内容，直接输出 JSON 数组。"
        let user = "关系：\(relationship)\n\n最近对话：\n\(conversation)\n\n请给出 3 条候选回复。"
        let content = try await chat(system: system, user: user, temperature: 0.8, route: route)
        return try Self.parseThree(content)
    }

    /// 连通性测试用的最小请求。走和正式生成一样的路径，只是提示词最短。
    func ping() async throws -> String {
        let content = try await chat(
            system: "你是连通性测试助手，只按要求回答，不要解释。",
            user: "请只回复两个字：收到",
            temperature: 0
        )
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func chat(system: String, user: String, temperature: Double, route: SynapseModelRoute? = nil) async throws -> String {
        do {
            let response = try await gateway.complete(messages: [
                SynapseChatMessage(role: "system", content: .string(system)),
                SynapseChatMessage(role: "user", content: .string(user))
            ], temperature: temperature, using: route ?? config.routeSnapshot(for: .reply))
            return response.firstContent
        } catch let error as SynapseError {
            throw APIError(route: .reply, status: error.status, detail: error.detail)
        }
    }

    /// 模型常把 JSON 数组包在解释文字或 markdown 代码块里，所以按首尾方括号截取。
    static func parseThree(_ content: String) throws -> [String] {
        var candidates: [String] = []
        if let start = content.firstIndex(of: "["),
           let end = content.lastIndex(of: "]"),
           start < end {
            let slice = String(content[start...end])
            if let data = slice.data(using: .utf8),
               let parsed = try? JSONDecoder().decode([String].self, from: data) {
                candidates = parsed
            }
        }
        if candidates.isEmpty {
            candidates = content
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-*123. \"'")) }
        }
        let cleaned = candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let unique = NSOrderedSet(array: cleaned).array as? [String] ?? []
        guard unique.count >= 3 else {
            throw APIError(
                route: .reply,
                status: nil,
                detail: "模型只返回了 \(unique.count) 条有效候选，需要 3 条不重复的回复"
            )
        }
        let result = Array(unique.prefix(3))
        guard ReplyBundle.hasValidCandidateTexts(result) else {
            throw APIError(
                route: .reply, status: nil,
                detail: "候选回复过长，每条最多支持 \(ReplyBundle.maxCandidateLength) 字，请重新生成"
            )
        }
        return result
    }
}

private extension Speaker {
    var label: String {
        switch self {
        case .me: return "我"
        case .other: return "对方"
        case .unknown: return "未知发言人"
        }
    }
}
