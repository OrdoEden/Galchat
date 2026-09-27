import Foundation
import Synapse

/// 独立的 Jev 判断调度器；候选由 ReplySuggestionScheduler 消费 onRequest。
@MainActor
final class LiveAnalysisScheduler {
    enum Phase: Equatable {
        case idle, waitingContent, debouncing, analyzing, ready
        case failed(String)
        case skipped(String)
    }

    enum ContextNeed: Equatable {
        case none
        case short(have: Int, want: Int)
        case history
    }

    struct Outcome {
        let request: AnalysisRequest
        var analysis: Analysis?
        var judgeError: String?
        var stale = false
        var conversationID: UUID { request.context.conversationID }
        var revision: Int { request.context.revision }
        var signature: String { request.version.tailSignature }
        var requestID: UUID { request.id }
        var startedAt: Date { request.startedAt }
        var analyzedCount: Int { request.analyzedCount }
        var analyzedFirstID: UUID? { request.analyzedFirstID }
        var isContextRefresh: Bool { request.isContextRefresh }
    }

    /// 批处理静默窗口：对方连发时每来一条重新计时，安静 2.5 秒后合成一批分析；
    /// 从第一条算起最多等 10 秒，持续刷屏也会按时出结果。
    static let batchQuiet: TimeInterval = 2.5
    static let batchMaximum: TimeInterval = 10
    static let contextSettle: Duration = .milliseconds(1500)
    static let autoRunsPerMinute = 6
    static let maxContextRefreshes = 2
    static let historyContextLimit = 50

    private let config = GCConfig.shared
    private let judgeClient = JudgeClient()
    private(set) var phase: Phase = .idle
    private(set) var outcome: Outcome?
    private(set) var currentRequest: AnalysisRequest?
    var onChange: (() -> Void)?
    var onRequest: ((AnalysisRequest) -> Void)?
    var onInvalidate: (() -> Void)?
    /// 判断成功返回后回调。用于好感度计分——放在这里而不是让调度器自己持久化，
    /// 是为了让调度器保持"只管跑题"的单一职责。
    var onJudgeCompleted: ((AnalysisRequest, Analysis) -> Void)?

    private var latest: ConversationContext?
    private var handledTail: String?
    private var debounceTask: Task<Void, Never>?
    private var judgeTask: Task<Void, Never>?
    private var contextTask: Task<Void, Never>?
    private var pendingVersion: ContextVersion?
    private var fingerprints = Set<String>()
    private var refreshes = 0
    private var runTimes = [Date]()
    private var nonScoringTail: String?
    /// 当前批次第一条新消息出现的时间。
    private var batchStartedAt: Date?
    /// 本会话已经分析过的尾部。误识别条目被删掉、尾部退回旧消息时不重复分析。
    private var analyzedTails = Set<String>()
    /// 已分析尾部当时的文字；同一条消息的文字被大幅纠正时允许重分析一次。
    private var analyzedTailText: [String: String] = [:]
    private var correctedTails = Set<String>()
    private static let autoKey = "Galchat.live.autoAnalyze"

    var isRefreshingContext: Bool { phase == .analyzing && currentRequest?.isContextRefresh == true }
    var autoAnalyze: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.autoKey)
            invalidate()
            if newValue {
                update(latest)
            } else {
                setPhase(.skipped("自动分析已关闭，可手动分析"))
            }
        }
    }

    func update(_ context: ConversationContext?) {
        let old = latest
        latest = context
        guard let context else {
            invalidate()
            return setPhase(.idle)
        }
        if old?.sessionID != context.sessionID || old?.conversationID != context.conversationID
            || old?.contactID != context.contactID {
            invalidate()
            refreshes = 0
            fingerprints.removeAll()
            batchStartedAt = nil
            analyzedTails.removeAll()
            analyzedTailText.removeAll()
            correctedTails.removeAll()
        }
        guard !context.tailSignature.isEmpty, context.messages.contains(where: {
            !$0.isGap && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            invalidate()
            return setPhase(.waitingContent)
        }
        if nonScoringTail == scoringKey(context) {
            if let currentRequest, matches(context, currentRequest.context) { return }
            if currentRequest != nil { invalidate() }
            handledTail = context.tailSignature
            return setPhase(.skipped("上下文已更新，可手动分析或等待新消息"))
        }
        // 语义闸门：没确认聊天页、画面没接上记录、在翻历史时只更新上下文，不动已有结论，也不调用模型。
        if let hold = context.semanticHoldReason {
            if debounceTask != nil {
                debounceTask?.cancel()
                debounceTask = nil
                handledTail = nil
            }
            if phase != .analyzing { setPhase(.skipped(hold)) }
            return
        }
        let correction = isSignificantCorrection(context)
        if context.tailSignature == handledTail && !correction {
            // 从闸门暂停回到最新消息、尾部没变：恢复原结论的展示。
            if case .skipped = phase, let outcome, !outcome.stale,
               outcome.request.context.tailSignature == context.tailSignature {
                setPhase(.ready)
            }
            considerRefresh(context)
            return
        }
        // 尾部退回已分析过的消息（误识别条目被删、翻上去又回来）：不是新消息。
        if analyzedTails.contains(context.tailSignature) && !correction {
            handledTail = context.tailSignature
            if outcome?.request.context.tailSignature == context.tailSignature, outcome?.stale == false {
                return setPhase(.ready)
            }
            return setPhase(.skipped("没有新消息，可手动分析"))
        }
        if correction { correctedTails.insert(context.tailSignature) }
        invalidate()
        refreshes = 0
        fingerprints.removeAll()
        guard autoAnalyze else { return setPhase(.skipped("自动分析已关闭，可手动分析")) }
        guard canRun() else { return setPhase(.skipped("自动分析过于频繁，等待一分钟额度恢复")) }
        handledTail = context.tailSignature
        let now = Date()
        // 被闸门打断后遗留的旧批次（很久以前开始）不能让新消息立即触发。
        let started = batchStartedAt.flatMap {
            now.timeIntervalSince($0) <= Self.batchMaximum + Self.batchQuiet ? $0 : nil
        } ?? now
        batchStartedAt = started
        let delay = max(0, min(Self.batchQuiet, Self.batchMaximum - now.timeIntervalSince(started)))
        setPhase(.debouncing)
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            guard !Task.isCancelled, let self, self.autoAnalyze,
                  let latest = self.latest, self.matches(latest, context),
                  latest.semanticHoldReason == nil else { return }
            self.debounceTask = nil
            guard self.canRun() else {
                self.handledTail = nil
                return self.setPhase(.skipped("自动分析过于频繁，等待一分钟额度恢复"))
            }
            self.runTimes.append(Date())
            self.run(latest, limit: self.config.contextMessageCount)
        }
    }

    /// 已分析过的最后一条消息，文字被纠正得面目全非（不是个别字的抖动），且这条还没因纠正重跑过。
    private func isSignificantCorrection(_ context: ConversationContext) -> Bool {
        let key = context.tailSignature
        guard analyzedTails.contains(key), !correctedTails.contains(key),
              let before = analyzedTailText[key] else { return false }
        return Self.similarity(before, context.tailText) < 0.5
    }

    /// 规范化后的字符二元组 Dice 相似度（0...1）。
    static func similarity(_ a: String, _ b: String) -> Double {
        func clean(_ text: String) -> [Character] {
            Array(text.lowercased().filter { $0.isLetter || $0.isNumber })
        }
        let x = clean(a), y = clean(b)
        if x == y { return 1 }
        guard x.count >= 2, y.count >= 2 else { return x.isEmpty || y.isEmpty ? 0 : (Set(x) == Set(y) ? 1 : 0) }
        var grams: [String: Int] = [:]
        for i in 0..<(x.count - 1) { grams[String(x[i...i + 1]), default: 0] += 1 }
        var hits = 0
        for i in 0..<(y.count - 1) {
            let key = String(y[i...i + 1])
            if let n = grams[key], n > 0 { hits += 1; grams[key] = n - 1 }
        }
        return 2 * Double(hits) / Double(x.count + y.count - 2)
    }

    func analyzeNow() {
        guard let latest, !latest.tailSignature.isEmpty else {
            return setPhase(.failed("还没有可分析的聊天内容"))
        }
        let limit = outcome?.analysis?.bestAction?.choice == "check_history"
            ? Self.historyContextLimit : config.contextMessageCount
        invalidate()
        handledTail = latest.tailSignature
        run(latest, limit: limit)
    }

    var contextNeed: ContextNeed {
        guard let outcome, !outcome.stale, phase == .ready,
              refreshes < Self.maxContextRefreshes else { return .none }
        if outcome.analysis?.bestAction?.choice == "check_history" { return .history }
        let want = config.contextMessageCount
        return outcome.analyzedCount < want ? .short(have: outcome.analyzedCount, want: want) : .none
    }

    private func considerRefresh(_ context: ConversationContext) {
        guard autoAnalyze, phase == .ready, let outcome, !outcome.stale,
              matches(context, outcome.request.context), let first = outcome.analyzedFirstID,
              refreshes < Self.maxContextRefreshes else { return }
        let messages = context.messages.filter { !$0.isGap }
        guard let firstIndex = messages.firstIndex(where: { $0.id == first }), firstIndex > 0 else { return }
        let need = contextNeed
        guard need != .none else { return }
        let limit = need == .history ? Self.historyContextLimit : config.contextMessageCount
        let version = context.version(for: context.snapshot(limit: limit))
        guard !fingerprints.contains(version.windowFingerprint),
              version != pendingVersion || contextTask == nil else { return }
        contextTask?.cancel()
        pendingVersion = version
        let requestID = outcome.requestID
        contextTask = Task { [weak self] in
            try? await Task.sleep(for: Self.contextSettle)
            guard !Task.isCancelled, let self else { return }
            defer {
                if self.pendingVersion == version {
                    self.contextTask = nil
                    self.pendingVersion = nil
                }
            }
            guard self.autoAnalyze, self.phase == .ready,
                  self.outcome?.requestID == requestID, self.outcome?.stale == false,
                  self.refreshes < Self.maxContextRefreshes,
                  let latest = self.latest,
                  latest.version(for: latest.snapshot(limit: limit)) == version,
                  !self.fingerprints.contains(version.windowFingerprint), self.canRun() else { return }
            self.refreshes += 1
            self.runTimes.append(Date())
            self.run(latest, limit: limit, contextRefresh: true)
        }
    }

    func reset() {
        invalidate()
        latest = nil
        outcome = nil
        refreshes = 0
        fingerprints.removeAll()
        batchStartedAt = nil
        analyzedTails.removeAll()
        analyzedTailText.removeAll()
        correctedTails.removeAll()
        setPhase(.idle)
    }

    func captureStopped() {
        invalidate()
        latest = nil
        batchStartedAt = nil
        setPhase(.idle)
    }

    /// 修改档案或纠正已有文字只作废旧结果；保存本身不触发模型请求和计分。
    func contextWasEdited(_ context: ConversationContext?) {
        invalidate()
        latest = context
        handledTail = context?.tailSignature
        nonScoringTail = context.map(scoringKey)
        setPhase(.skipped("上下文已更新，可手动分析或等待新消息"))
    }

    private func scoringKey(_ context: ConversationContext) -> String {
        "\(context.sessionID)|\(context.conversationID)|\(context.messages.last(where: { !$0.isGap })?.id.uuidString ?? "")"
    }

    private func run(_ context: ConversationContext, limit: Int, contextRefresh: Bool = false) {
        judgeTask?.cancel()
        let snapshot = context.snapshot(limit: limit)
        let request = AnalysisRequest(id: UUID(), context: context, version: context.version(for: snapshot),
                                      snapshot: snapshot, models: AnalysisModelContext(config: config, contactID: context.contactID),
                                      startedAt: Date(), isContextRefresh: contextRefresh,
                                      allowsAffectionScoring: nonScoringTail != scoringKey(context))
        currentRequest = request
        fingerprints.insert(request.version.windowFingerprint)
        batchStartedAt = nil
        analyzedTails.insert(context.tailSignature)
        analyzedTailText[context.tailSignature] = context.tailText
        markStale()
        setPhase(.analyzing)
        // 候选订阅独立于判断配置与完成时间，两个分支只共享输入版本。
        onRequest?(request)
        guard currentRequest?.id == request.id else { return }
        guard request.models.judge.isConfigured else {
            return setPhase(.failed("未配置判断接口，候选生成仍可独立运行"))
        }
        judgeTask = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            do {
                let analysis = try await self.judgeClient.judge(snapshot: snapshot,
                                                              relationship: request.models.relationship,
                                                              route: request.models.judge)
                guard self.accepts(request) else { return }
                self.outcome = Outcome(request: request, analysis: analysis)
                self.judgeTask = nil
                // 先计分再进入 ready：计分要落盘，且失败不应影响判断结果的展示。
                self.onJudgeCompleted?(request, analysis)
                self.setPhase(.ready)
                if let latest = self.latest { self.considerRefresh(latest) }
            } catch is CancellationError {
            } catch {
                guard self.accepts(request) else { return }
                self.judgeTask = nil
                self.setPhase(.failed(error.localizedDescription))
            }
        }
    }

    private func accepts(_ request: AnalysisRequest) -> Bool {
        guard !Task.isCancelled, currentRequest?.id == request.id, let latest else { return false }
        return matches(latest, request.context)
    }

    private func matches(_ a: ConversationContext, _ b: ConversationContext) -> Bool {
        a.sessionID == b.sessionID && a.conversationID == b.conversationID
            && a.contactID == b.contactID && a.tailSignature == b.tailSignature
    }

    private func invalidate() {
        debounceTask?.cancel()
        debounceTask = nil
        contextTask?.cancel()
        contextTask = nil
        judgeTask?.cancel()
        judgeTask = nil
        pendingVersion = nil
        currentRequest = nil
        handledTail = nil
        markStale()
        onInvalidate?()
    }

    private func markStale() {
        if var current = outcome, !current.stale {
            current.stale = true
            outcome = current
        }
    }

    private func canRun() -> Bool {
        let now = Date()
        runTimes.removeAll { now.timeIntervalSince($0) > 60 }
        return runTimes.count < Self.autoRunsPerMinute
    }

    private func setPhase(_ phase: Phase) {
        self.phase = phase
        onChange?()
    }
}
