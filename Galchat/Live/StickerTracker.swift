import Foundation
import SeeU
import Synapse

/// 表情包进入聊天上下文的业务编排：
/// SeeU 给出图片与前后消息 → 这里记住出现位置 → 可选地请视觉模型解读 → 插回文字上下文，
/// 供 Jev 判断与回复生成使用。解读结果按 SeeU 的 `imageID` 缓存，同一表情只上传一次。
@MainActor
final class StickerTracker {
    private struct Occurrence {
        let id: UUID
        let imageID: UUID
        let side: BubbleSide
        var after: UUID?
        var before: UUID?
    }

    private enum Meaning {
        case pending
        case failed(attempts: Int, at: Date)
        case ready(String)
    }

    /// 解读完成、上下文需要重建时回调。
    var onChange: (() -> Void)?

    private var conversationID: UUID?
    private var occurrences: [Occurrence] = []
    private var images: [UUID: Data] = [:]
    private var meanings: [UUID: Meaning] = [:]
    private var generation = 0
    private let client = StickerSemanticsClient()
    static let occurrenceLimit = 60
    static let imageLimit = 120

    /// 新录屏或清空记录时调用；已解读的含义保留，避免重复上传同一表情。
    func reset() {
        conversationID = nil
        occurrences = []
        images = [:]
        generation += 1
        meanings = meanings.filter { if case .ready = $0.value { return true } else { return false } }
    }

    /// 记录一帧里的表情包。返回 true 表示上下文中的表情包集合发生了变化。
    @discardableResult
    func ingest(_ harvest: SeeUImageHarvest, context: ConversationContext?) -> Bool {
        guard let conversationID = harvest.conversationID, conversationID == context?.conversationID else { return false }
        if self.conversationID != conversationID {
            self.conversationID = conversationID
            occurrences = []
        }
        var changed = false
        for region in harvest.regions(of: .sticker) {
            // 至少要有一个锚点，否则无法放回对话顺序。
            guard region.precedingMessageID != nil || region.followingMessageID != nil else { continue }
            if images[region.imageID] == nil {
                images[region.imageID] = region.jpegData
                if images.count > Self.imageLimit, let stale = images.keys.first(where: { id in
                    !occurrences.contains { $0.imageID == id }
                }) {
                    images.removeValue(forKey: stale)
                }
            }
            if let index = occurrences.firstIndex(where: { existing in
                existing.imageID == region.imageID && existing.side == region.side
                    && ((region.precedingMessageID != nil && existing.after == region.precedingMessageID)
                        || (region.followingMessageID != nil && existing.before == region.followingMessageID))
            }) {
                // 同一次出现：补全另一侧锚点（例如之后又来了新消息）。
                if occurrences[index].after == nil, let after = region.precedingMessageID {
                    occurrences[index].after = after
                    changed = true
                }
                if occurrences[index].before == nil, let before = region.followingMessageID {
                    occurrences[index].before = before
                    changed = true
                }
                continue
            }
            occurrences.append(Occurrence(id: UUID(), imageID: region.imageID, side: region.side,
                                          after: region.precedingMessageID, before: region.followingMessageID))
            if occurrences.count > Self.occurrenceLimit { occurrences.removeFirst(occurrences.count - Self.occurrenceLimit) }
            changed = true
        }
        if changed, let context { requestMeanings(context: context) }
        return changed
    }

    /// 把表情包按锚点插回文字消息序列。找不到锚点的出现暂不插入。
    func merge(into messages: [ContextMessage], conversationID: UUID) -> [ContextMessage] {
        guard conversationID == self.conversationID, !occurrences.isEmpty else { return messages }
        var result = messages
        for occurrence in occurrences {
            guard !result.contains(where: { $0.id == occurrence.id }) else { continue }
            let message = ContextMessage(id: occurrence.id, speaker: Self.speaker(occurrence.side),
                                         text: text(for: occurrence.imageID))
            if let after = occurrence.after, let index = result.firstIndex(where: { $0.id == after }) {
                // 同一锚点后已有表情包时排在它们后面，保持出现顺序。
                var insert = index + 1
                while insert < result.count, occurrences.contains(where: { $0.id == result[insert].id }) { insert += 1 }
                result.insert(message, at: insert)
            } else if let before = occurrence.before, let index = result.firstIndex(where: { $0.id == before }) {
                result.insert(message, at: index)
            }
        }
        return result
    }

    // MARK: - 解读

    private func text(for imageID: UUID) -> String {
        if case .ready(let meaning) = meanings[imageID] { return "[表情包：\(meaning)]" }
        return "[表情包]"
    }

    private func requestMeanings(context: ConversationContext) {
        let config = GCConfig.shared
        guard config.visionEnabled, config.isConfigured(.vision) else { return }
        let route = config.routeSnapshot(for: .vision)
        for imageID in Set(occurrences.map(\.imageID)) {
            switch meanings[imageID] {
            case .ready, .pending: continue
            case .failed(let attempts, let at):
                guard attempts < 2, Date().timeIntervalSince(at) > 60 else { continue }
            case nil: break
            }
            guard let jpeg = images[imageID],
                  meanings.values.filter({ if case .pending = $0 { return true } else { return false } }).count < 2
            else { continue }
            let attempts: Int
            if case .failed(let previous, _) = meanings[imageID] { attempts = previous } else { attempts = 0 }
            meanings[imageID] = .pending
            let nearby = context.messages, generation = generation
            Task { [weak self, client] in
                let result: Result<String, Error>
                do { result = .success(try await client.describe(sticker: jpeg, nearby: nearby, route: route)) }
                catch { result = .failure(error) }
                guard let self else { return }
                switch result {
                case .success(let meaning): self.meanings[imageID] = .ready(meaning)
                case .failure: self.meanings[imageID] = .failed(attempts: attempts + 1, at: Date())
                }
                guard generation == self.generation else { return }
                if case .success = result { self.onChange?() }
            }
        }
    }

    private static func speaker(_ side: BubbleSide) -> Speaker {
        switch side {
        case .me: return .me
        case .other: return .other
        case .unknown: return .unknown
        }
    }
}
