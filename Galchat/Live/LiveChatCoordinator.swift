import UIKit
import VisynCapture
import SeeU

/// 协调四条独立业务：屏幕识别、长图存档、Jev 判断、回复候选。
/// 图片存档使用独立单槽队列，不作为文本分析或键盘发布的前置条件。
@MainActor
final class LiveChatCoordinator {
    static let shared = LiveChatCoordinator()

    let scheduler = LiveAnalysisScheduler()
    let replyScheduler = ReplySuggestionScheduler()
    private let engine = SeeUConversationEngine()
    private let longScreenshots = SeeULongScreenshotStore()

    private(set) var latest: EngineUpdate?
    private(set) var captureState: VisynBroadcastState = .stopped
    private(set) var framesReceived = 0
    private(set) var framesDropped = 0
    private(set) var currentContext: ConversationContext?
    private var rawContext: ConversationContext?
    private(set) var longScreenshotSummary: [UUID: LongScreenshotSummary] = [:]
    private(set) var isSavingLongScreenshot = false
    private(set) var recognitionError: String?

    private var processing = false
    private var pending: VisynCapturedFrame?
    private var currentSession: UUID?
    private var captureGeneration = 0
    private var screenshotEpoch = UUID()
    private var pendingScreenshot: LongScreenshotInput?
    private var pendingScreenshotMerges: [LongScreenshotMerge] = []
    private var screenshotResetTask: Task<Void, Never>?
    private var observers: [UUID: () -> Void] = [:]
    private var presentationTimer: Timer?
    private let avatars = PiPAvatarTracker()
    private let stickers = StickerTracker()
    /// SeeU 按 Galchat 需要的类别提取图片：对方头像做立绘，表情包进入语义上下文。
    private let images = SeeUImageHarvester(request: SeeUImageRequest(kinds: [.avatar, .sticker]))
    private var latestObservedAt: Date?

    /// 正在分析的数据与最后完成的展示分开，滚动/新消息不会先清空 PiP。
    private struct CompletedPresentation {
        let outcome: LiveAnalysisScheduler.Outcome
        let sourceTitle: String
        var portrait: PiPPortrait?
        var affection: GCPiPView.AffectionDisplay?
    }
    private var completedPresentation: CompletedPresentation?

    private let pipView = GCPiPView()
    private var pictureInPictureContentSize = VisynPictureInPictureSize.landscape
    private var acceptFramesAfter = Date.distantPast
    private let publisher = ReplyBundlePublisher()
    private let affection = AffectionProjectionPublisher.shared
    private let committer = AffectionCommitter()

    private init() {
        scheduler.onRequest = { [weak self] request in self?.replyScheduler.start(request) }
        scheduler.onInvalidate = { [weak self] in self?.replyScheduler.invalidate() }
        scheduler.onChange = { [weak self] in self?.notify() }
        scheduler.onJudgeCompleted = { [weak self] request, analysis in
            self?.committer.commit(request: request, analysis: analysis)
        }
        replyScheduler.onChange = { [weak self] in self?.notify() }
        stickers.onChange = { [weak self] in self?.rebuildContext() }
        applyLadderCapacity()
        NotificationCenter.default.addObserver(
            forName: GCConfig.liveSettingsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyLadderCapacity() }
        }
        for name in [RecentConversationStore.editsChanged, PersonaStore.changed, ContactsStore.profileChanged] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == RecentConversationStore.editsChanged {
                        guard let context = self.rawContext,
                              note.userInfo?["conversationID"] as? String == "\(context.sessionID.uuidString):\(context.conversationID.uuidString)" else { return }
                    } else if name == ContactsStore.profileChanged {
                        guard let editedID = note.userInfo?["contactID"] as? String,
                              editedID == self.currentContext?.contactID else { return }
                    }
                    self.contextWasEdited()
                }
            }
        }
    }

    private func applyLadderCapacity() {
        let capacity = GCConfig.shared.ladderCapacity
        let store = longScreenshots
        Task { await store.setCapacity(capacity) }
    }

    // MARK: - 采集输入

    func captureStateChanged(_ state: VisynBroadcastState) {
        let previousState = captureState
        captureState = state
        switch state {
        case .broadcasting:
            if previousState == .paused {
                // 暂停期间的结论不能在恢复首帧被静默复用；重新走稳定/分析流程。
                scheduler.reset()
            }
            if presentationTimer == nil {
                // 即使没有新帧也更新过期提示；发布器只允许新 frameID 延长来源有效期。
                presentationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.consumeContactDecision()
                        self?.notify()
                    }
                }
            }
        case .paused:
            captureGeneration += 1
            pending = nil
            currentContext = nil
            rawContext = nil
            scheduler.captureStopped()
            presentationTimer?.invalidate()
            presentationTimer = nil
        case .stopped:
            captureGeneration += 1
            presentationTimer?.invalidate()
            presentationTimer = nil
            pending = nil
            currentSession = nil
            currentContext = nil
            rawContext = nil
            framesReceived = 0
            framesDropped = 0
            scheduler.captureStopped()
        }
        notify()
    }

    func receive(_ frame: VisynCapturedFrame) {
        guard captureState == .broadcasting else { return }
        // 换尺寸后的旧帧和系统窗口过渡帧不能套用新几何。
        guard frame.capturedAt >= acceptFramesAfter else { return }
        if frame.sessionID != currentSession {
            captureGeneration += 1
            // 新的一次录屏重新识别；PiP 仅保留带来源的上次结果供查看。
            currentSession = frame.sessionID
            latest = nil
            recognitionError = nil
            currentContext = nil
            rawContext = nil
            resetLongScreenshots()
            scheduler.reset()
        }
        framesReceived += 1
        if pending != nil { framesDropped += 1 }
        pending = frame
        pump()
    }

    /// 用户主动清空当前识别结果（内存中的会话文字和长截图）。
    func clear() {
        captureGeneration += 1
        pending = nil
        latest = nil
        recognitionError = nil
        currentContext = nil
        rawContext = nil
        completedPresentation = nil
        resetLongScreenshots()
        scheduler.reset()
        Task { await engine.clear() }
        notify()
    }

    private func pump() {
        guard captureState == .broadcasting, !processing, let frame = pending else { return }
        pending = nil
        processing = true
        let engine = engine
        let generation = captureGeneration
        let epoch = screenshotEpoch
        let exclusion = AppFrameExclusion.policy(overlayContentSize: pictureInPictureContentSize)
        Task { [weak self] in
            let output: EngineOutput?
            do {
                output = try await engine.process(
                    jpeg: frame.jpegData, frameID: frame.id, sessionID: frame.sessionID,
                    capturedAt: frame.capturedAt, exclusion: exclusion, epoch: epoch
                )
            } catch {
                guard let self else { return }
                self.processing = false
                if self.captureState == .broadcasting, generation == self.captureGeneration {
                    self.recognitionError = error.localizedDescription
                    self.latest = nil
                    self.currentContext = nil
                    self.rawContext = nil
                    self.scheduler.update(nil)
                    self.notify()
                }
                self.pump()
                return
            }
            guard let self else { return }
            self.processing = false
            if let output, self.captureState == .broadcasting,
               generation == self.captureGeneration, output.update.sessionID == self.currentSession {
                let update = output.update
                self.recognitionError = nil
                self.latest = update
                self.latestObservedAt = frame.capturedAt
                self.installContext(self.makeContext(from: update, observedAt: frame.capturedAt))
                self.scheduler.update(self.currentContext)
                self.notify()
            }
            // 旧采集 generation 不得启动模型，但同 epoch 的已识别图片和合并事件必须存完。
            // 只有清空或新一次录屏更换 epoch，才丢弃这份图片输出。
            if self.screenshotEpoch == epoch, let input = output?.longScreenshot {
                self.pendingScreenshotMerges.append(contentsOf: input.placement.merged.map {
                    LongScreenshotMerge(conversationID: input.conversationID, sourceID: $0.id,
                                        targetID: input.placement.segmentID, shift: $0.shift)
                })
                self.pendingScreenshot = input
                self.pumpLongScreenshot()
            }
            self.pump()
        }
    }

    private func makeContext(from update: EngineUpdate, observedAt: Date) -> ConversationContext? {
        guard update.detection == .chat, let conversationID = update.conversationID else { return nil }
        let conversation = update.conversation
        // SeeU 输出原始结构；缺口/引用的模型提示语属于 App 的分析策略。
        let messages = conversation.contextItems.filter { $0.kind == .message || $0.kind == .gap }.map { message in
            let speaker: Speaker
            switch message.side {
            case .me: speaker = .me
            case .other: speaker = .other
            case .unknown: speaker = .unknown
            }
            let text: String
            if message.kind == .gap {
                text = "【聊天记录缺口：中间有未采集的消息，不要将前后两段视为连续对话】"
            } else {
                text = (message.text ?? "") + (message.quote.map { "（引用：\($0)）" } ?? "")
                    + (message.clipped ? "（此条仅部分可见，请勿推测缺失文字）" : "")
            }
            return ContextMessage(id: message.id, speaker: speaker, text: text,
                                  isGap: message.kind == .gap, clipped: message.clipped)
        }
        return ConversationContext(sessionID: update.sessionID, conversationID: conversationID,
                                   revision: update.revision, sourceTitle: update.title ?? "当前会话",
                                   sourceConfirmed: update.confirmed, frameID: update.frameID,
                                   observedAt: observedAt,
                                   messages: stickers.merge(into: messages, conversationID: conversationID))
    }

    /// 表情包位置或含义变化后，用最近一次 SeeU 输出重建上下文并重新调度分析。
    private func rebuildContext() {
        guard captureState == .broadcasting, let latest, let observedAt = latestObservedAt else { return }
        installContext(makeContext(from: latest, observedAt: observedAt))
        scheduler.update(currentContext)
        notify()
    }

    private func installContext(_ context: ConversationContext?) {
        guard var context else {
            rawContext = nil
            currentContext = nil
            affection.resolveContact(title: "当前会话")
            return
        }
        let contacts = ContactsStore.shared
        let recents = RecentConversationStore.shared
        if recents.isDeleted(context) {
            rawContext = nil
            currentContext = nil
            affection.resolveContact(title: "当前会话")
            return
        }
        let archived = recents.conversation(id: "\(context.sessionID.uuidString):\(context.conversationID.uuidString)")
        if let removedID = archived?.contactID, contacts.contact(id: removedID) == nil {
            // 删除档案后，本次已有会话保持未关联，不能在下一帧自动建回同名档案。
            affection.currentTitle = context.sourceTitle
            if contacts.activeContact != nil {
                contacts.setActiveContact(nil)
                affection.publishImmediately()
            }
        } else if let savedID = recents.contactID(for: context), contacts.contact(id: savedID) != nil {
            // 已确认的会话归属优先于标题匹配，避免先发布另一个人的键盘投影。
            affection.currentTitle = context.sourceTitle
            if contacts.activeContact?.id != savedID {
                contacts.setActiveContact(savedID)
                affection.publishImmediately()
            }
        } else {
            affection.resolveContact(title: context.sourceTitle)
            if context.sourceConfirmed, ContactMatcher.isTrusted(context.sourceTitle),
               !ContactMatcher.normalize(context.sourceTitle).isEmpty {
                let match = ContactMatcher.match(title: context.sourceTitle, subjects: contacts.contacts().map {
                    ContactMatcher.Subject(id: $0.id, displayName: $0.displayName, aliases: $0.aliases)
                })
                if case .unknown = match,
                   let created = try? contacts.createProfile(displayName: context.sourceTitle, alias: context.sourceTitle) {
                    contacts.setActiveContact(created.id)
                    affection.publishImmediately()
                }
            }
        }
        context.contactID = contacts.activeContact?.id
        rawContext = context
        recents.record(context, contactID: context.contactID)
        currentContext = recents.applyingCorrections(to: context)
        consumeContactDecision()
        affection.publish()
    }

    private func consumeContactDecision() {
        guard captureState == .broadcasting, var context = rawContext,
              affection.consumeKeyboardDecision() else { return }
        let contacts = ContactsStore.shared
        guard let contactID = contacts.activeContact?.id else { return }
        do {
            try RecentConversationStore.shared.bindCurrent(context, to: contactID)
        } catch {
            // 确认必须与会话归属一起落盘，否则恢复原归属，避免键盘和模型各认一人。
            contacts.setActiveContact(currentContext?.contactID)
            affection.publishImmediately()
            return
        }
        context.contactID = contactID
        rawContext = context
        currentContext = RecentConversationStore.shared.applyingCorrections(to: context)
        scheduler.contextWasEdited(currentContext)
        publisher.contextWasEdited()
        completedPresentation = nil
    }

    private func contextWasEdited() {
        if var context = rawContext {
            if RecentConversationStore.shared.isDeleted(context) {
                rawContext = nil
                currentContext = nil
                affection.resolveContact(title: "当前会话")
            } else {
                context.contactID = RecentConversationStore.shared.contactID(for: context)
                rawContext = context
                currentContext = RecentConversationStore.shared.applyingCorrections(to: context)
                if ContactsStore.shared.activeContact?.id != context.contactID {
                    ContactsStore.shared.setActiveContact(context.contactID)
                }
            }
        }
        completedPresentation = nil
        scheduler.contextWasEdited(currentContext)
        publisher.contextWasEdited()
        affection.publishImmediately()
        notify()
    }

    private func resetLongScreenshots() {
        screenshotEpoch = UUID()
        pendingScreenshot = nil
        pendingScreenshotMerges = []
        longScreenshotSummary = [:]
        avatars.reset()
        stickers.reset()
        let store = longScreenshots, harvester = images, epoch = screenshotEpoch
        let previousReset = screenshotResetTask
        screenshotResetTask = Task {
            await previousReset?.value
            await store.reset(to: epoch)
            await harvester.reset()
        }
    }

    private func pumpLongScreenshot() {
        guard !isSavingLongScreenshot, let input = pendingScreenshot else { return }
        pendingScreenshot = nil
        isSavingLongScreenshot = true
        let epoch = screenshotEpoch
        let merges = pendingScreenshotMerges
        pendingScreenshotMerges = []
        let store = longScreenshots, harvester = images, reset = screenshotResetTask
        Task { [weak self] in
            await reset?.value
            guard let self else { return }
            // 停录/暂停只停止新采集；已识别图片和不可丢的合并事件允许完成。
            // 清空或新录屏会换 epoch，旧存档结果不得回写新会话。
            if self.screenshotEpoch == epoch {
                await store.ingest(input, merges: merges)
                let summary = await store.summary()
                if self.screenshotEpoch == epoch {
                    self.longScreenshotSummary = summary
                    // 与存档同一帧提取头像和表情包；旧录屏代次或已停止时丢弃结果。
                    let generation = self.captureGeneration
                    let harvest = await harvester.harvest(input)
                    if self.screenshotEpoch == epoch, self.captureGeneration == generation,
                       self.captureState == .broadcasting, !harvest.regions.isEmpty {
                        self.avatars.ingest(harvest, context: self.currentContext)
                        if self.stickers.ingest(harvest, context: self.currentContext) { self.rebuildContext() }
                    }
                }
            }
            self.isSavingLongScreenshot = false
            self.notify()
            self.pumpLongScreenshot()
        }
    }

    // MARK: - 输出

    func observe(_ handler: @escaping () -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    /// 供上层导出或分析原始结构，不包含截图像素、提示词或模型凭据。
    func conversationJSON() throws -> Data? {
        guard captureState == .broadcasting, let latest, latest.detection == .chat,
              let context = currentContext,
              Date().timeIntervalSince(context.observedAt) >= 0,
              Date().timeIntervalSince(context.observedAt) < ReplyBundlePublisher.freshness else { return nil }
        return try latest.conversation.jsonData(prettyPrinted: true)
    }

    func renderLongScreenshot(maxPixelHeight: Int = 16_000) async -> UIImage? {
        let epoch = screenshotEpoch
        await screenshotResetTask?.value
        guard epoch == screenshotEpoch,
              let data = await longScreenshots.render(maxPixelHeight: maxPixelHeight),
              epoch == screenshotEpoch else { return nil }
        return UIImage(data: data)
    }

    /// Visyn 在每个视频帧前调用视图的 GIF 选帧回调。
    func makePiPContent() -> UIView { pipView }

    func pictureInPictureContentSizeDidChange(_ size: CGSize) {
        guard size != pictureInPictureContentSize else { return }
        pictureInPictureContentSize = size
        pending = nil
        captureGeneration += 1
        // 给系统窗口和 OCR 遮挡几何一秒时间完成比例重排。
        acceptFramesAfter = Date().addingTimeInterval(1)
    }

    /// 一行状态，用于首页和画中画。
    var statusLine: String {
        switch captureState {
        case .stopped: return "未在录屏"
        case .paused: return "录屏已暂停"
        case .broadcasting: break
        }
        if let recognitionError { return "识别失败 · \(recognitionError)" }
        guard let latest else { return "等待屏幕画面…" }
        switch latest.detection {
        case .waiting: return "等待屏幕画面…"
        case .notChat(let reason):
            return "未检测到聊天页 · \(reason)"
        case .chat:
            let who = latest.title.map { "「\($0)」" } ?? "聊天页"
            let count = latest.liveMessages.filter { $0.kind == .message }.count
            let gap = latest.segments.count > 1 ? " · \(latest.segments.count) 段" : ""
            return "已识别\(who) · 当前屏 \(latest.currentMessages.count) 条 · 上下文 \(count) 条\(gap)"
        }
    }

    var analysisLine: String {
        switch scheduler.phase {
        case .idle: return latest?.detection == .chat ? "等待对方新消息" : ""
        case .waitingContent: return "本屏尚未识别到可读聊天文字"
        case .debouncing: return "聊天内容有更新，准备分析…"
        case .analyzing: return scheduler.isRefreshingContext ? "正在补充上下文分析…" : "正在分析…"
        case .ready:
            if scheduler.outcome?.stale == true { return "会话有更新，结论可能已过时" }
            return "Jev 判断已完成 · \(replyLine)"
        case .failed(let reason): return "判断失败：\(reason)"
        case .skipped(let reason): return reason
        }
    }

    var replyLine: String {
        switch replyScheduler.phase {
        case .idle: return "等待回复任务"
        case .generating: return "正在生成候选文案"
        case .ranking: return "正在排序候选文案"
        case .ready: return publisher.isReady ? "三条候选已就绪" : publisher.unavailableReason
        case .failed(let reason): return reason
        }
    }

    private func notify() {
        avatars.contextDidChange(currentContext)
        if captureState == .broadcasting, scheduler.phase == .ready,
           let outcome = scheduler.outcome, !outcome.stale,
           let context = currentContext,
           outcome.request.version.sessionID == context.sessionID,
           outcome.conversationID == context.conversationID,
           outcome.signature == context.tailSignature,
           completedPresentation?.outcome.requestID != outcome.requestID {
            completedPresentation = CompletedPresentation(outcome: outcome, sourceTitle: outcome.request.context.sourceTitle,
                                                          portrait: avatars.portrait, affection: makeAffectionDisplay())
        }
        if let context = currentContext,
           let outcome = completedPresentation?.outcome,
           PiPIdentity(outcome.request.context) == PiPIdentity(context) {
            completedPresentation?.portrait = avatars.portrait
            completedPresentation?.affection = makeAffectionDisplay()
        }
        publisher.refresh(
            context: currentContext, currentRequest: scheduler.currentRequest,
            judge: scheduler.outcome, replies: replyScheduler.outcome,
            replyPhase: replyScheduler.phase, capturing: captureState == .broadcasting,
            captureNote: captureState == .paused ? "录屏已暂停" : "录屏已停止"
        )
        updatePiP()
        for handler in observers.values { handler() }
    }

    /// 候选已写给键盘、键盘可以插入。
    var keyboardReady: Bool { publisher.isReady }

    /// Jev 完成即可替换判断，回复候选和长图进度独立展示。
    private func updatePiP() {
        // 切换聊天时不能把旧结论和当前联系人的头像、分数拼在一起。
        let displayed = completedPresentation.flatMap { presentation -> CompletedPresentation? in
            guard let context = currentContext else { return presentation }
            return PiPIdentity(presentation.outcome.request.context) == PiPIdentity(context) ? presentation : nil
        }
        let outcome = displayed?.outcome
        let analysis = outcome?.analysis
        let matchesCurrent = outcome != nil && outcome?.conversationID == currentContext?.conversationID
            && outcome?.request.version.sessionID == currentContext?.sessionID
            && outcome?.signature == currentContext?.tailSignature
        let currentResult = captureState == .broadcasting && matchesCurrent && scheduler.phase == .ready
            && outcome?.requestID == scheduler.outcome?.requestID && scheduler.outcome?.stale == false
        let source = currentContext?.sourceTitle ?? displayed?.sourceTitle ?? latest?.title ?? "当前会话"
        let affectionState = currentContext == nil ? displayed?.affection : makeAffectionDisplay()
        pipView.setPortrait(currentContext == nil ? displayed?.portrait : avatars.portrait)

        var tone: GCPiPView.Tone = .neutral
        var emotion = "等待分析"
        if let danger = analysis?.dangerLevel {
            let level = max(0, min(danger.maxLevel, Int(danger.score.rounded())))
            emotion = JudgeLabels.emotion(level: level, maxLevel: danger.maxLevel)
            let scaled = Double(level) * 9 / Double(max(danger.maxLevel, 1))
            tone = scaled >= 6 ? .danger : (scaled >= 3 ? .warn : .calm)
        } else if outcome?.judgeError != nil {
            emotion = "判断失败"
        }
        let advice = analysis.map { JudgeLabels.advice($0) } ?? "打开聊天，等待分析"
        let progress: String
        if captureState != .broadcasting {
            progress = statusLine + (displayed == nil ? "" : " · 保留上次结果")
        } else if latest?.detection != .chat {
            progress = "等待聊天画面"
        } else if scheduler.phase == .analyzing || scheduler.phase == .debouncing {
            progress = "Jev 分析中"
        } else if case .failed = scheduler.phase {
            progress = publisher.isReady ? "判断失败 · 候选可用" : "判断失败 · 等待重试"
        } else if case .skipped(let reason) = scheduler.phase {
            progress = reason
        } else if currentResult {
            progress = publisher.isReady ? "候选已就绪 · 在键盘选回复" : "分析完成"
        } else {
            progress = displayed == nil ? "等待分析" : "上次结果"
        }
        pipView.show(name: source, emotion: emotion, advice: advice, progress: progress,
                     tone: tone, affection: affectionState,
                     isLive: captureState == .broadcasting && currentContext != nil)
    }

    /// 当前该显示的好感度状态。没绑定联系人时返回 nil——还没认人之前不显示分数，
    /// 否则会把多个人的分数混在一起展示。
    private func makeAffectionDisplay() -> GCPiPView.AffectionDisplay? {
        guard let contact = ContactsStore.shared.activeContact else { return nil }
        // ± 读数只在刚刚算完一轮时显示，避免旧数字被当成当前变化。
        return GCPiPView.AffectionDisplay(total: contact.total,
                                              step: affection.currentStep() ?? 0,
                                              ruptured: contact.rupturedUntilResolved)
    }
}
