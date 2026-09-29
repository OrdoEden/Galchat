import Foundation
import Synapse

/// Jev 题目：措辞与评分标准来自注入的题目包（`PromptStore.current`），这里只负责拼成请求。
/// instructions/criteria 用英文，聊天正文保持中文。
enum JevQuestions {

    private static var pack: PromptPack { PromptStore.current }

    private static func question(_ question: PromptPack.Question, criteria: SynapseJSONValue) -> SynapseJSONValue {
        [
            "type": .string(question.type),
            // backgroundNote 附加到每道题后面，让 background 字段被当作已知上下文而不是跑题内容。
            "instructions": .string(question.instructions + pack.backgroundNote),
            "criteria": criteria
        ]
    }

    private static func encode(_ criteria: PromptPack.Criteria?) -> SynapseJSONValue {
        switch criteria {
        case .keyed(let values): return .object(values.mapValues { .string($0) })
        case .levels(let levels): return .array(levels.map { .string($0) })
        case nil: return .object([:])
        }
    }

    /// 判断题：7 道冲突/需求判断 + 1 道好感度边际变化（`affection_delta`，见 `AffectionCommitter`）。
    /// 题目与选项的 key 由 `PromptPack.judgeContract` 固定，校验不通过的题目包不会被加载。
    static func judge() -> [String: SynapseJSONValue] {
        pack.judge.mapValues { question($0, criteria: encode($0.criteria)) }
    }

    /// 对 3 条候选排序的题目；候选文本作为选项填进 criteria。
    static func rankQuestion(candidates: [String]) -> [String: SynapseJSONValue] {
        precondition(candidates.count == rankKeys.count, "rankQuestion 需要恰好 3 条候选")
        var criteria: [String: SynapseJSONValue] = [:]
        for (index, key) in rankKeys.enumerated() { criteria[key] = .string(candidates[index]) }
        return pack.rank.mapValues { question($0, criteria: .object(criteria)) }
    }

    static let rankKeys = ["reply_a", "reply_b", "reply_c"]

    /// 由快照构造 Jev state。
    static func buildState(snapshot: ChatSnapshot, relationship: String) -> SynapseJSONValue {
        let recent = snapshot.recentMessages
        let messages = recent.map { message in
            SynapseJSONValue.object([
                "from": .string(message.speaker.rawValue),
                "text": .string(message.text)
            ])
        }
        return [
            "chat": [
                "relationship": .string(relationship),
                "messages": .array(messages),
                "latest_from": .string(recent.last?.speaker.rawValue ?? Speaker.other.rawValue)
            ]
        ]
    }
}
