import CoreGraphics

/// PiP 与 OCR 共用三个标记的位置；头像、心跳和文案重排不影响遮挡范围推算。
/// `avatarFrame` 同时传给 Visyn 的立绘层，保证立绘与“好感度”锚点使用同一套几何。
nonisolated struct GCPiPLayout: Sendable {
    let size: CGSize

    var isPortrait: Bool { size.height > size.width }
    var scale: CGFloat { max(0.05, min(min(size.width, size.height) / 80, 2)) }
    var inset: CGFloat { 7 * scale }
    var markerHeight: CGFloat { 12 * scale }
    var markerFontSize: CGFloat { min(10 * scale, contentWidth / 4) }
    var identityFrame: CGRect {
        CGRect(x: 3 * scale, y: max(0, avatarFrame.midY - markerHeight / 2),
               width: max(0, avatarFrame.width - 6 * scale), height: markerHeight)
    }
    var avatarFrame: CGRect {
        // 竖向小窗较短（如微信 9 : 19.5）时缩小头像，给标题、好感度和情绪留出约 150×scale 的高度。
        let side = isPortrait
            ? min(size.width, size.height * 0.42, max(size.height * 0.2, size.height - 150 * scale))
            : min(size.height, size.width * 0.4)
        return CGRect(x: 0, y: 0, width: side, height: side)
    }
    var contentX: CGFloat { isPortrait ? inset : avatarFrame.maxX + inset }
    var contentWidth: CGFloat { max(0, size.width - contentX - inset) }
    var headerFrame: CGRect {
        CGRect(x: contentX, y: isPortrait ? avatarFrame.maxY + inset : 3 * scale,
               width: contentWidth, height: markerHeight)
    }
    var footerFrame: CGRect {
        CGRect(x: contentX, y: max(headerFrame.maxY, size.height - markerHeight - 3 * scale),
               width: contentWidth, height: markerHeight)
    }
    var titleFrame: CGRect {
        CGRect(x: contentX, y: headerFrame.maxY + 5 * scale, width: contentWidth, height: 17 * scale)
    }
    var heartFrame: CGRect {
        let side = min(contentWidth * (isPortrait ? 0.55 : 0.25), (isPortrait ? 40 : 27) * scale)
        return CGRect(x: contentX, y: isPortrait ? titleFrame.maxY + 10 * scale : headerFrame.maxY + scale,
                      width: side, height: side)
    }
    var scoreFrame: CGRect {
        let x = heartFrame.maxX + 2 * scale
        return CGRect(x: x, y: heartFrame.minY,
                      width: max(0, min(size.width - inset - x, isPortrait ? size.width : 61 * scale)),
                      height: heartFrame.height)
    }
    var emotionFrame: CGRect {
        if isPortrait {
            return CGRect(x: contentX, y: heartFrame.maxY + 9 * scale, width: contentWidth, height: 17 * scale)
        }
        let x = min(size.width - inset, heartFrame.maxX + 65 * scale)
        return CGRect(x: x, y: heartFrame.minY + 5 * scale,
                      width: max(0, size.width - inset - x), height: 16 * scale)
    }
    var adviceFrame: CGRect {
        CGRect(x: contentX, y: isPortrait ? emotionFrame.maxY + 7 * scale : heartFrame.maxY + scale,
               width: contentWidth, height: (isPortrait ? 42 : 13) * scale)
    }
    var trackFrame: CGRect {
        CGRect(x: contentX, y: footerFrame.minY - 6 * scale, width: contentWidth, height: 3 * scale)
    }
    var progressFrame: CGRect {
        CGRect(x: contentX, y: max(adviceFrame.maxY + 8 * scale, trackFrame.minY - 39 * scale),
               width: contentWidth, height: 30 * scale)
    }
    func occlusionRegion(header: CGRect, footer: CGRect) -> CGRect? {
        let distance = footerFrame.midY - headerFrame.midY
        guard distance > 0 else { return nil }
        let renderedScale = (footer.midY - header.midY) / distance
        guard renderedScale.isFinite, renderedScale > 0 else { return nil }
        return CGRect(x: header.minX - contentX * renderedScale,
                      y: header.midY - headerFrame.midY * renderedScale,
                      width: size.width * renderedScale, height: size.height * renderedScale)
    }
}
