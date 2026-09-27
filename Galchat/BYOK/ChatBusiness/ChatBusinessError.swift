import Foundation

/// 聊天输入或模型输出不满足业务规则；不携带 HTTP 状态或模型路线。
nonisolated enum ChatBusinessError: LocalizedError, Sendable {
    case insufficientCandidates(actual: Int)
    case candidateTooLong(maxLength: Int)
    case invalidRankingCandidateCount(expected: Int, actual: Int)
    case missingRankingProbabilities

    var errorDescription: String? {
        switch self {
        case .insufficientCandidates(let actual):
            return "模型只返回了 \(actual) 条有效候选，需要 3 条不重复的回复"
        case .candidateTooLong(let maxLength):
            return "候选回复过长，每条最多支持 \(maxLength) 字，请重新生成"
        case .invalidRankingCandidateCount(let expected, let actual):
            return "排序需要恰好 \(expected) 条候选，当前有 \(actual) 条"
        case .missingRankingProbabilities:
            return "排序结果缺少候选推荐概率"
        }
    }
}
