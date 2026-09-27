import Foundation
import Synapse

/// Jev 判断路线：7 道判断题和候选排序题。判断与排序共用同一套凭据。
struct JudgeClient {
    private let config: JarvisConfig
    private let gateway: SynapseGateway

    init(config: JarvisConfig = .shared, gateway: SynapseGateway = .shared) {
        self.config = config
        self.gateway = gateway
    }

    func judge(snapshot: ChatSnapshot, relationship: String, route: SynapseModelRoute? = nil) async throws -> Analysis {
        let started = Date()
        let answers = try await send(
            state: JevQuestions.buildState(snapshot: snapshot, relationship: relationship),
            questions: JevQuestions.judge(), route: route ?? config.routeSnapshot(for: .judge)
        )
        return Analysis(
            trueIntent: Self.parseChoice(answers["true_intent"]),
            dangerLevel: Self.parseScore(answers["danger_level"]),
            sheNeeds: Self.parseChoice(answers["she_needs"]),
            shouldReplyNow: answers["should_reply_now"]?.noul,
            bestAction: Self.parseChoice(answers["best_action"]),
            tensionResolved: answers["tension_resolved"]?.noul,
            literalQuestion: answers["literal_question"]?.noul,
            affectionDelta: Self.parseChoice(answers["affection_delta"]),
            latencyMs: Int(Date().timeIntervalSince(started) * 1000)
        )
    }

    /// 对 3 条候选排序，返回按推荐程度降序的列表。
    func rank(
        snapshot: ChatSnapshot,
        relationship: String,
        candidates: [String],
        route: SynapseModelRoute? = nil
    ) async throws -> [RankedReply] {
        guard candidates.count == JevQuestions.rankKeys.count else {
            throw ChatBusinessError.invalidRankingCandidateCount(
                expected: JevQuestions.rankKeys.count, actual: candidates.count
            )
        }
        let answers = try await send(
            state: JevQuestions.buildState(snapshot: snapshot, relationship: relationship),
            questions: JevQuestions.rankQuestion(candidates: candidates), route: route ?? config.routeSnapshot(for: .judge)
        )
        guard let best = answers["best_reply"], let probabilities = best.probabilities else {
            throw ChatBusinessError.missingRankingProbabilities
        }
        let ranked = candidates.enumerated().map { index, text in
            RankedReply(text: text, probability: probabilities[JevQuestions.rankKeys[index]] ?? 0)
        }
        return ranked.sorted { $0.probability > $1.probability }
    }

    private func send(state: SynapseJSONValue, questions: [String: SynapseJSONValue], route: SynapseModelRoute) async throws -> [String: SynapseDecisionsResponse.Answer] {
        try await gateway.decide(state: state, questions: questions, using: route).answers
    }

    private static func parseChoice(_ answer: SynapseDecisionsResponse.Answer?) -> Choice? {
        guard let answer, let choice = answer.choice else { return nil }
        return Choice(
            choice: choice,
            confidence: answer.confidence ?? 0,
            probabilities: answer.probabilities ?? [:]
        )
    }

    private static func parseScore(_ answer: SynapseDecisionsResponse.Answer?) -> Score? {
        guard let answer, let score = answer.score else { return nil }
        let maxLevel = answer.legend?.keys.compactMap(Int.init).max() ?? 9
        return Score(score: score, confidence: answer.confidence ?? 0, maxLevel: maxLevel)
    }
}
