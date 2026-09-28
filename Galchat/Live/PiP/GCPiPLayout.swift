import CoreGraphics
import UIKit

/// PiP 几何的统一入口：按窗口形状选横屏或竖屏排版，并提供 OCR 遮挡要用的两个字锚点。
///
/// 具体几何分别在 `GCPiPLandscapeLayout`（`GCPiPLandscapeView.swift`）与
/// `GCPiPPortraitLayout`（`GCPiPPortraitView.swift`）里，视图和这里读的是同一份 frame。
/// `AppFrameExclusion` 用「Galchat」抬头与「好感度」两个锚点反推小窗在录屏里的位置。
nonisolated struct GCPiPLayout: Sendable {
    let size: CGSize

    /// 高宽比达到这个值就用竖屏排版：9 : 22 是 2.44，横屏 414 : 80 与方形都远低于它。
    static let portraitRatio: CGFloat = 1.8

    init(size: CGSize) {
        self.size = size
    }

    var isPortrait: Bool {
        guard size.width > 0, size.height > 0 else { return false }
        return size.height / size.width >= Self.portraitRatio
    }
    var landscape: GCPiPLandscapeLayout { GCPiPLandscapeLayout(size: size) }
    var portrait: GCPiPPortraitLayout { GCPiPPortraitLayout(size: size) }

    var scale: CGFloat { isPortrait ? portrait.scale : landscape.scale }
    /// OCR 锚点字（抬头「Galchat…」）的字号，`AppFrameExclusion` 用它估字框高度。
    var markerFontSize: CGFloat { isPortrait ? portrait.headerFontSize : landscape.headerFontSize }
    /// 抬头标签的 frame。文字左对齐，所以锚点取左边缘而不是中心。
    var headerFrame: CGRect { isPortrait ? portrait.headerFrame : landscape.headerFrame }
    /// 「好感度」标签的 frame。文字居中对齐，锚点取中心。
    var identityFrame: CGRect { isPortrait ? portrait.identityFrame : landscape.identityFrame }

    private var headerAnchor: CGPoint { CGPoint(x: headerFrame.minX, y: headerFrame.midY) }
    private var identityAnchor: CGPoint { CGPoint(x: identityFrame.midX, y: identityFrame.midY) }

    // MARK: - 遮挡区

    /// 「Galchat」与「好感度」两个字锚点 → 整张小窗在录屏里的位置。
    ///
    /// 抬头取 OCR 字框的左边缘（抬头左对齐，名字长短只影响右边缘），「好感度」取中心。
    /// 横屏两锚点横向隔开，竖屏主要纵向隔开，两个方向都能定出缩放；
    /// 普通聊天里同时出现品牌名和「好感度」不会被误判成小窗。
    func occlusionRegion(header: CGRect, identity: CGRect) -> CGRect? {
        guard header.width > 0, header.height > 0, identity.width > 0, identity.height > 0 else { return nil }
        let expectedDX = identityAnchor.x - headerAnchor.x
        let expectedDY = identityAnchor.y - headerAnchor.y
        let expected = (expectedDX * expectedDX + expectedDY * expectedDY).squareRoot()
        let dx = identity.midX - header.minX
        let dy = identity.midY - header.midY
        let actual = (dx * dx + dy * dy).squareRoot()
        guard expected > 0, actual > 0 else { return nil }
        let renderedScale = actual / expected
        guard renderedScale.isFinite, renderedScale > 0.25, renderedScale < 8 else { return nil }
        // 允许字框略偏，但不允许上下/左右颠倒。
        let tolerance = max(header.height, identity.height)
        guard abs(dx - expectedDX * renderedScale) <= tolerance,
              abs(dy - expectedDY * renderedScale) <= tolerance else { return nil }
        return CGRect(x: header.minX - headerAnchor.x * renderedScale,
                      y: header.midY - headerAnchor.y * renderedScale,
                      width: size.width * renderedScale, height: size.height * renderedScale)
    }
}
