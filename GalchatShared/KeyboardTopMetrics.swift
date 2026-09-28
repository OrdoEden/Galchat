import CoreGraphics

/// 键盘顶部几何常量。主 App 与键盘扩展共用同一个文件。
///
/// 存在的理由：键盘候选条的高度同时被两处依赖——键盘扩展用它布局，
/// `AppFrameExclusion` 用它把候选文字排除在聊天分析之外。写两份常量就会漂移，
/// 而漂移的后果是候选词被当成聊天消息送进模型。改这里即可，两边自动一致。
nonisolated enum KeyboardTopMetrics {
    /// 候选条高度（点）。候选条常驻，与系统键盘一致，空态也占位。
    static let candidateBarHeight: CGFloat = 44
    /// 候选条与第一排按键之间的间距（点）。
    static let candidateBarGap: CGFloat = 8
    /// 第一排按键顶边以上属于键盘的高度：候选条 + 间距。
    static var reservedAboveKeys: CGFloat { candidateBarHeight + candidateBarGap }
}
