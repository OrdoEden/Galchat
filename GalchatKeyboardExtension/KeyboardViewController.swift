import UIKit
import SwiftKeyboard

/// Galchat 键盘：`SwiftKeyboard` 提供与系统中文键盘一致的输入体验，
/// 这里只负责把主 App 生成的三条回复建议注入候选条。
///
/// 键盘完全只读：从 App Group 读 `ReplyBundle` 与 `AffectionProjection`，不写任何共享文件。
///
/// 键盘上**没有**品牌文字、好感度或状态行。录屏解析器因此改用按键行定位键盘区域
/// （`AppFrameExclusion`），候选条几何来自 `KeyboardTopMetrics`，两边共用。
final class KeyboardViewController: SwiftKeyboardViewController {
    private var bundle: ReplyBundle?
    private var lastModified: Date?
    private var projection: AffectionProjection?
    private var projectionModified: Date?
    private var timer: Timer?
    /// 已确认的联系人 id。
    ///
    /// 确认挂在联系人上而不是 `bundleID` 上：`bundleID` 每来一轮新的排序结果就会变，
    /// 之前按它清空确认，导致每收到一条新建议就要重新确认一次。
    private var confirmedContactID: String?
    /// 没有绑定联系人时（匿名会话）的最终确认标记。
    private var confirmedAnonymousTitle: String?
    /// 确认时所在的输入框。换聊天窗口即失效。
    private var confirmedDocumentID: String?
    private var pendingReplace: (candidateID: String, until: Date)?

    override var configuration: Configuration {
        Configuration(candidateBarHeight: KeyboardTopMetrics.candidateBarHeight,
                      candidateBarGap: KeyboardTopMetrics.candidateBarGap)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reload(force: true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        pendingReplace = nil
        reload(force: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload(force: false) }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
        timer = nil
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        pendingReplace = nil
        super.selectionDidChange(textInput)
    }

    // MARK: - 回复建议

    override func suggestions() -> [KeyboardSuggestion] {
        guard let usable = bundle, usable.isUsable() else { return [] }
        return usable.candidates.sorted { $0.rank < $1.rank }.enumerated().map { index, candidate in
            KeyboardSuggestion(id: candidate.id, text: candidate.text,
                               accessibilityLabel: "回复建议\(index + 1)：\(candidate.text)")
        }
    }

    override func didSelectSuggestion(_ suggestion: KeyboardSuggestion) {
        let latest = ReplyBundleStore.load()
        guard let shown = bundle, let latest, latest.isUsable(),
              latest.bundleID == shown.bundleID,
              latest.sessionID == shown.sessionID, latest.conversationID == shown.conversationID,
              latest.revision == shown.revision, latest.analysisRequestID == shown.analysisRequestID,
              latest.candidates.contains(where: { $0.id == suggestion.id && $0.text == suggestion.text })
        else {
            reload(force: true)
            showMessage("建议已更新，请重新选择")
            return
        }
        // 首次点击即确认会话——这是替代原「确认会话」按钮的隐式确认。
        // 仍未确认时只置位，再点一次才插入。
        guard isConfirmed() else {
            markConfirmed()
            return
        }
        if let selected = textDocumentProxy.selectedText, !selected.isEmpty {
            if pendingReplace?.candidateID != suggestion.id || (pendingReplace?.until ?? .distantPast) < Date() {
                pendingReplace = (suggestion.id, Date().addingTimeInterval(3))
                showMessage("再点一次这条建议，替换选中的文字")
                return
            }
        }
        pendingReplace = nil
        textDocumentProxy.insertText(suggestion.text)
        showMessage("已插入，可继续修改；请自行发送")
    }

    /// 确认是否成立。
    ///
    /// 两个条件：确认的对象没变（联系人或匿名标题），且输入框没换
    /// （同一个微信窗口里换到另一个人的聊天，`documentIdentifier` 会变）。
    private func isConfirmed() -> Bool {
        guard let usable = bundle, usable.isUsable() else { return false }
        let document = textDocumentProxy.documentIdentifier.uuidString
        if let contactID = projection?.activeContactID {
            return confirmedContactID == contactID && confirmedDocumentID == document
        }
        // 没有绑定联系人：退回按标题确认，并且仍然要求同一个输入框。
        guard let title = confirmedAnonymousTitle else { return false }
        return title == usable.sourceTitle && confirmedDocumentID == document
    }

    /// 记下当前确认状态。`contactID` 为空表示这是一次匿名确认。
    private func markConfirmed() {
        confirmedDocumentID = textDocumentProxy.documentIdentifier.uuidString
        if let contactID = projection?.activeContactID {
            confirmedContactID = contactID
            confirmedAnonymousTitle = nil
        } else {
            confirmedAnonymousTitle = bundle?.sourceTitle
            confirmedContactID = nil
        }
    }

    private func reload(force: Bool) {
        let modified = ReplyBundleStore.modificationDate()
        if force || modified != lastModified {
            lastModified = modified
            let next = ReplyBundleStore.load()
            // 只在**目标对象**变了才清空确认，而不是每次新建议都清。
            if next?.bundleID != bundle?.bundleID {
                pendingReplace = nil
            }
            bundle = next
        }
        // 投影与候选是两个文件、两种生命周期，各自按自己的 mtime 刷新。
        let projectionModifiedNow = AffectionProjectionStore.modificationDate()
        if force || projectionModifiedNow != projectionModified {
            projectionModified = projectionModifiedNow
            projection = AffectionProjectionStore.load()
            // 换联系人了，之前的确认作废。
            if let contactID = projection?.activeContactID, contactID != confirmedContactID {
                confirmedContactID = nil
                confirmedAnonymousTitle = nil
            }
        }
        // 文件没变也可能在宿主挂起期间过期，所以每秒都重新取一次；内容没变时库不会重建按钮。
        reloadSuggestions()
    }
}
