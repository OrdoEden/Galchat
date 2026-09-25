import Foundation
import Synapse

@MainActor
final class ReplySuggestionScheduler {
    enum Phase: Equatable {
        case idle, generating, ranking, ready
        case failed(String)
    }

    struct Outcome {
        let request: AnalysisRequest
        let replies: [RankedReply]
        let repliesUnranked: Bool
        let error: String?
        let completedAt: Date
        var stale = false
    }

    private let replyClient = ReplyClient()
    private let judgeClient = JudgeClient()
    private var task: Task<Void, Never>?
    private var requestID: UUID?
    private(set) var phase: Phase = .idle
    private(set) var outcome: Outcome?
    var onChange: (() -> Void)?

    func start(_ request: AnalysisRequest) {
        invalidate()
        requestID = request.id
        guard request.models.reply.isConfigured else {
            return setPhase(.failed("未配置回复接口，只显示判断结果"))
        }
        setPhase(.generating)
        let relationship = request.models.relationship
        task = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            let candidates: [String]
            do {
                candidates = try await self.replyClient.draft(snapshot: request.snapshot, relationship: relationship,
                                                             route: request.models.reply)
            } catch is CancellationError {
                return
            } catch {
                guard self.accepts(request) else { return }
                self.task = nil
                return self.setPhase(.failed(error.localizedDescription))
            }
            guard self.accepts(request) else { return }
            guard request.models.judge.isConfigured else {
                return self.finish(request, candidates.map { RankedReply(text: $0, probability: 0) },
                                   true, "未配置排序接口，候选仅供主界面查看")
            }
            self.setPhase(.ranking)
            do {
                let ranked = try await self.judgeClient.rank(snapshot: request.snapshot,
                                                           relationship: relationship, candidates: candidates,
                                                           route: request.models.judge)
                self.finish(request, ranked, false, nil)
            } catch is CancellationError {
            } catch {
                self.finish(request, candidates.map { RankedReply(text: $0, probability: 0) },
                            true, "排序失败：\(error.localizedDescription)")
            }
        }
    }

    func invalidate() {
        task?.cancel()
        task = nil
        requestID = nil
        if var current = outcome {
            current.stale = true
            outcome = current
        }
        setPhase(.idle)
    }

    private func accepts(_ request: AnalysisRequest) -> Bool { !Task.isCancelled && requestID == request.id }

    private func finish(_ request: AnalysisRequest, _ replies: [RankedReply], _ unranked: Bool, _ error: String?) {
        guard accepts(request) else { return }
        task = nil
        outcome = Outcome(request: request, replies: replies, repliesUnranked: unranked,
                          error: error, completedAt: Date())
        setPhase(.ready)
    }

    private func setPhase(_ phase: Phase) {
        self.phase = phase
        onChange?()
    }
}
