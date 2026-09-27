import Foundation
import SeeU
import UIKit

/// PiP 头像的业务身份：同一录屏会话、同一聊天、同一联系人绑定才共用头像与分数。
nonisolated struct PiPIdentity: Equatable, Sendable {
    let sessionID: UUID
    let conversationID: UUID
    let contactID: String?

    init(_ context: ConversationContext) {
        sessionID = context.sessionID
        conversationID = context.conversationID
        contactID = context.contactID
    }
}

/// Galchat 从 SeeU 图片区域里挑出的立绘，交给 Visyn 渲染。
struct PiPPortrait {
    let imageID: UUID
    let image: UIImage
    /// 浅化后的主题色：头像主色混入白色，保证深色文字可读。
    let tint: UIColor

    static let defaultTint = UIColor(red: 0.88, green: 0.94, blue: 0.90, alpha: 1)

    init?(region: SeeUImageRegion) {
        guard let image = UIImage(data: region.jpegData) else { return nil }
        imageID = region.imageID
        self.image = image
        tint = region.dominantColor.map {
            UIColor(red: CGFloat($0.red * 0.28 + 0.72), green: CGFloat($0.green * 0.28 + 0.72),
                    blue: CGFloat($0.blue * 0.28 + 0.72), alpha: 1)
        } ?? Self.defaultTint
    }
}

/// 立绘选择策略（业务规则）；像素识别由 SeeU 完成，渲染由 Visyn 完成。
///
/// - 只取已确认来源单聊里对方一侧的头像，且至少在两个不同消息位置出现过。
/// - 检测到群聊昵称后该会话不再推断头像。
/// - 结果只保存在内存，不上传、不覆盖联系人手动头像。
@MainActor
final class PiPAvatarTracker {
    private(set) var portrait: PiPPortrait?
    private var identity: PiPIdentity?
    private var groupConversationIDs = Set<UUID>()
    static let minimumEvidence = 2

    /// 清空记录或新录屏时调用。
    func reset() {
        identity = nil
        portrait = nil
        groupConversationIDs = []
    }

    /// 当前会话切换时清掉旧联系人的立绘，避免跨联系人回写。
    func contextDidChange(_ context: ConversationContext?) {
        let next = context.map(PiPIdentity.init)
        guard next != identity else { return }
        identity = next
        portrait = nil
    }

    /// 返回 true 表示立绘发生变化。
    @discardableResult
    func ingest(_ harvest: SeeUImageHarvest, context: ConversationContext?) -> Bool {
        contextDidChange(context)
        if harvest.showsSenderNames, let id = harvest.conversationID {
            groupConversationIDs.insert(id)
            if context?.conversationID == id, portrait != nil {
                portrait = nil
                return true
            }
        }
        guard let context, context.sourceConfirmed,
              context.sessionID == harvest.sessionID, context.conversationID == harvest.conversationID,
              !groupConversationIDs.contains(context.conversationID) else { return false }
        let best = harvest.regions(of: .avatar)
            .filter { $0.side == .other && $0.evidenceCount >= Self.minimumEvidence }
            .max { $0.evidenceCount < $1.evidenceCount }
        guard let best, best.imageID != portrait?.imageID, let next = PiPPortrait(region: best) else { return false }
        portrait = next
        return true
    }
}
