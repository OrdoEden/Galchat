import CoreGraphics
import UIKit

/// 落地页那张小窗卡片的几何，一套基准单位分别铺到横屏与竖屏内容上。
///
/// 横屏从左到右三段：头像、主列、「爱心 + 分数 + 好感度」。主列自上而下是抬头
/// （「Galchat」＋右侧状态）、情绪、建议，进度条贴卡片底部。
/// 竖屏把同样几段竖着排：分数块独占顶部一整行，头像在其下，然后抬头、姓名、
/// 情绪、建议，进度条与状态贴底。
///
/// 所有 frame 只由 `size` 与 `scale` 推出，彼此不回头依赖，避免相互引用。
/// `avatarFrame` 同时传给 Visyn 的立绘层；`occlusionRegion` 用「Galchat」与
/// 「好感度」两个字锚点反推小窗在录屏里的位置，与 `GCPiPView` 共用这一份几何。
nonisolated struct GCPiPLayout: Sendable {
    let size: CGSize

    /// 横屏基准卡片：落地页 390 宽的小窗等比换算后的内容高度。
    private static let landscapeBaseWidth: CGFloat = 396
    private static let landscapeBaseHeight: CGFloat = 58
    /// 竖屏基准卡片：9 : 19.5 的窄窗。
    private static let portraitBaseWidth: CGFloat = 90
    private static let portraitBaseHeight: CGFloat = 195
    /// 高宽比达到这个值就用竖屏排版：9 : 19.5 是 2.17，方形和长条都远低于它。
    private static let portraitRatio: CGFloat = 1.8

    init(size: CGSize) {
        self.size = size
    }

    var isPortrait: Bool {
        guard size.width > 0, size.height > 0 else { return false }
        return size.height / size.width >= Self.portraitRatio
    }
    var baseWidth: CGFloat { isPortrait ? Self.portraitBaseWidth : Self.landscapeBaseWidth }
    var baseHeight: CGFloat { isPortrait ? Self.portraitBaseHeight : Self.landscapeBaseHeight }
    /// 基准单位 → 实际点数：文字、间距、头像都按它缩放，换形状时比例保持一致。
    var scale: CGFloat {
        guard size.width > 0, size.height > 0 else { return 0.05 }
        return max(0.05, min(size.width / baseWidth, size.height / baseHeight))
    }
    var inset: CGFloat { 8 * scale }
    /// OCR 锚点字（「Galchat」「好感度」「AI 估计」）的字号，`AppFrameExclusion` 用它估字框高度。
    /// 11 点基准，正好是落地页上 11px 的抬头；小窗口随卡片一起缩小。
    var markerFontSize: CGFloat { 11 * scale }
    /// 锚点行的行高：跟着字号走，中文全宽字不会挤出行高。
    var markerHeight: CGFloat { markerFontSize * 1.05 }
    var backgroundCornerRadius: CGFloat { 14 * scale }
    /// 卡片内容宽度（左右各留一个内边距）。
    private var innerWidth: CGFloat { max(0, size.width - 2 * inset) }

    // MARK: - 分数块（爱心 + 分数 + 好感度）

    /// 分数块：横屏是卡片右上角的一小块，竖屏占满顶部一整行。
    /// 里面自上而下是「AI 估计」、爱心与分数、以及贴着底边的「好感度」字锚点。
    private var scoreBlock: CGRect {
        if isPortrait {
            let height = scoreFontSize * 1.25 + markerHeight + 8 * scale
            return CGRect(x: inset, y: inset, width: innerWidth, height: height)
        }
        let width = min(76 * scale, size.width * 0.2)
        return CGRect(x: max(inset, size.width - inset - width), y: inset, width: width,
                      height: max(0, size.height - 2 * inset))
    }
    var identityColumnFrame: CGRect { scoreBlock }
    /// 分数：竖屏 22、横屏 19 的落地页字号；横屏块矮时跟着缩，好让三行都放得下。
    var scoreFontSize: CGFloat {
        guard !isPortrait else { return 22 * scale }
        let available = max(0, scoreBlock.height - markerHeight - 4 * scale)
        return min(19 * scale, available * 0.8)
    }
    /// 爱心与分数那一行的位置：在「AI 估计」下面、「好感度」上面。
    private var scoreHeartRowHeight: CGFloat { scoreFontSize * 1.25 }
    private var scoreHeartRowY: CGFloat { scoreBlock.minY + 2 * scale }
    /// 「好感度」字锚点：贴分数块底边，宽度按三个全宽汉字估。
    var identityFrame: CGRect {
        let width = min(30 * scale, innerWidth)
        return CGRect(x: scoreBlock.midX - width / 2, y: scoreBlock.maxY - markerHeight,
                      width: max(0, width), height: markerHeight)
    }
    var heartFrame: CGRect {
        let height = scoreFontSize * 0.85
        let y = scoreHeartRowY + (scoreHeartRowHeight - height) / 2
        if isPortrait {
            return CGRect(x: scoreBlock.minX, y: y, width: scoreBlock.width * 0.4, height: height)
        }
        return CGRect(x: scoreBlock.minX, y: y, width: min(height, scoreBlock.width), height: height)
    }
    var scoreFrame: CGRect {
        let x = isPortrait ? scoreBlock.minX + scoreBlock.width * 0.4 + 3 * scale : heartFrame.maxX + 3 * scale
        return CGRect(x: x, y: scoreHeartRowY, width: max(0, scoreBlock.maxX - x), height: scoreHeartRowHeight)
    }
    /// 「AI 估计」：横屏放在卡片左下角、头像下面；竖屏并进底部那行「AI 估计 · 进度」，
    /// `canShowInstruction` 会挡住竖屏的单独显示，这里仍给一个合法位置。
    var instructionFrame: CGRect {
        if isPortrait {
            return CGRect(x: scoreBlock.minX, y: scoreBlock.minY, width: scoreBlock.width, height: markerHeight)
        }
        let width = min(38 * scale, max(avatarFrame.width, innerWidth * 0.2))
        let y = min(avatarFrame.maxY + 2 * scale, size.height - inset - markerHeight)
        return CGRect(x: inset, y: max(0, y), width: width, height: markerHeight)
    }

    // MARK: - 头像与主列

    /// 横屏头像贴左上、与分数块同一行，下方给「AI 估计」留出一行；
    /// 竖屏头像在分数块下面。
    var avatarFrame: CGRect {
        let side: CGFloat
        if isPortrait {
            side = min(38 * scale, innerWidth * 0.3)
        } else {
            side = min(38 * scale, max(0, size.height - 2 * inset - markerHeight - 2 * scale))
        }
        let y = isPortrait ? scoreBlock.maxY + 6 * scale : inset
        return CGRect(x: inset, y: y, width: max(0, side), height: max(0, side))
    }
    var avatarCornerRadius: CGFloat { avatarFrame.width * 0.28 }
    /// 主列左边界：横屏缩进到头像右边，竖屏与头像同列。
    var contentX: CGFloat { isPortrait ? inset : avatarFrame.maxX + 10 * scale }
    /// 主列右边界：横屏要让开右上角分数块，否则文字会压到「好感度」上；竖屏只留内边距。
    private var contentTrailing: CGFloat {
        isPortrait ? inset : max(inset, size.width - scoreBlock.minX + 2 * scale)
    }
    /// 主列宽度。左边只由头像推出、右边只由分数块推出，两者都不回头依赖本属性。
    var contentWidth: CGFloat { max(0, size.width - contentX - contentTrailing) }
    /// 抬头行以下（横屏）或头像以下（竖屏）开始排文字。
    private var columnTop: CGFloat { isPortrait ? avatarFrame.maxY + 6 * scale : inset }
    /// 窄到只放得下一个名字时，抬头用「Galchat · 名字」而不留姓名行。
    var isCompact: Bool { contentWidth < 150 * scale }
    /// 抬头写「Galchat · 名字」还是只写品牌：横屏没有姓名行，名字跟在抬头里；
    /// 竖屏的姓名单独占一行（更大更粗），抬头只留品牌。
    var headerShowsName: Bool { !isPortrait || isCompact }

    // MARK: - 主列文字

    /// 抬头行：横屏左边是「Galchat」、右边是状态，两个格子加起来不超过主列；
    /// 竖屏状态在底部那行，抬头独占整行。
    private var stateWidth: CGFloat { canShowState ? min(38 * scale, contentWidth * 0.4) : 0 }
    private var headerRowGap: CGFloat { 4 * scale }
    var headerFrame: CGRect {
        let reserved = stateWidth > 0 ? stateWidth + headerRowGap : 0
        return CGRect(x: contentX, y: columnTop, width: max(0, contentWidth - reserved), height: markerHeight)
    }
    /// 状态文案（等待聊天 / 分析中 / 已更新）：横屏用抬头行右侧那一格，竖屏并进底部那行。
    var stateFrame: CGRect {
        guard !isPortrait else { return footerFrame }
        return CGRect(x: contentX + max(0, contentWidth - stateWidth), y: columnTop, width: stateWidth,
                      height: markerHeight)
    }
    var titleHeight: CGFloat { 15 * scale }
    var emotionHeight: CGFloat { 15 * scale }
    var adviceHeight: CGFloat { 13 * scale }
    /// 三行文字从底部往上排：建议贴进度条，情绪在它上面，姓名再上面；
    /// 抬头钉在主列顶部。每行只依赖进度条位置和固定行高，不反向依赖上一行。
    var adviceFrame: CGRect {
        CGRect(x: contentX, y: trackFrame.minY - adviceHeight - scale, width: contentWidth, height: adviceHeight)
    }
    var emotionFrame: CGRect {
        CGRect(x: contentX, y: adviceFrame.minY - emotionHeight - scale, width: contentWidth, height: emotionHeight)
    }
    /// 姓名行：横屏名字跟在抬头里、与抬头同高（由视图隐藏）；竖屏才真正占一行。
    var titleFrame: CGRect {
        let y = isPortrait ? emotionFrame.minY - titleHeight - 3 * scale : headerFrame.minY
        return CGRect(x: contentX, y: y, width: contentWidth, height: titleHeight)
    }

    // MARK: - 底部进度条

    /// 进度条贴卡片底部，横竖屏都占满主列。
    var trackFrame: CGRect {
        CGRect(x: contentX, y: size.height - inset - 4 * scale, width: contentWidth, height: 4 * scale)
    }
    /// 「AI 估计 · 进度」：竖屏在进度条下面，横屏并进底部那行（与左下角「AI 估计」同排）。
    var footerFrame: CGRect {
        let y = min(trackFrame.maxY + 2 * scale, size.height - inset - markerHeight)
        return CGRect(x: contentX, y: max(0, y), width: contentWidth, height: markerHeight)
    }

    // MARK: - 显示条件

    /// 放不下就整行隐藏：横屏只剩抬头、情绪、建议（名字与状态都在抬头行里），
    /// 竖屏多出姓名与底部状态。
    var canShowTitle: Bool { isPortrait && titleFrame.minY >= headerFrame.maxY }
    var canShowEmotion: Bool { emotionFrame.minY >= headerFrame.maxY }
    var canShowAdvice: Bool { adviceFrame.minY >= headerFrame.maxY }
    var canShowState: Bool { !isPortrait && contentWidth >= 200 * scale }
    var canShowIdentity: Bool { identityFrame.minY >= 0 && identityFrame.maxY <= size.height }
    var canShowFooter: Bool { isPortrait && footerFrame.minY >= adviceFrame.maxY }
    /// 横屏左下角那行「AI 估计」要放得下才显示；竖屏并进底部状态行。
    var canShowInstruction: Bool { !isPortrait && instructionFrame.minY >= avatarFrame.maxY }

    // MARK: - 遮挡区

    /// 「Galchat」与「好感度」两个字锚点 → 整张小窗在录屏里的位置。
    ///
    /// 竖屏时两字框一个在卡片中部、一个在顶部那一行里（竖向隔开），横屏时横向隔开，
    /// 两个方向都能定出缩放。偏移必须与基准几何同向同比例；普通聊天里同时出现品牌名和
    /// 「好感度」不会被误判成小窗。
    func occlusionRegion(header: CGRect, identity: CGRect) -> CGRect? {
        guard header.width > 0, header.height > 0, identity.width > 0, identity.height > 0 else { return nil }
        let expectedDX = identityFrame.midX - headerFrame.midX
        let expectedDY = identityFrame.midY - headerFrame.midY
        let expected = (expectedDX * expectedDX + expectedDY * expectedDY).squareRoot()
        let dx = identity.midX - header.midX
        let dy = identity.midY - header.midY
        let actual = (dx * dx + dy * dy).squareRoot()
        guard expected > 0, actual > 0 else { return nil }
        let renderedScale = actual / expected
        guard renderedScale.isFinite, renderedScale > 0.25, renderedScale < 8 else { return nil }
        // 允许字框略偏，但不允许上下/左右颠倒。
        let tolerance = max(header.height, identity.height)
        guard abs(dx - expectedDX * renderedScale) <= tolerance,
              abs(dy - expectedDY * renderedScale) <= tolerance else { return nil }
        return CGRect(x: header.midX - headerFrame.midX * renderedScale,
                      y: header.midY - headerFrame.midY * renderedScale,
                      width: size.width * renderedScale, height: size.height * renderedScale)
    }
}
