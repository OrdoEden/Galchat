import CoreGraphics

/// 显示与 OCR 共用的几何契约；系统缩放小窗后仍可从行距反推整个遮挡区域。
nonisolated struct JarvisPiPLayout: Sendable {
    let size: CGSize

    var scale: CGFloat { min(size.width / 240, size.height / 80, 4 / 3) }
    var fontSize: CGFloat { 12 * scale }
    var textInset: CGFloat { 19 * scale }
    var rowHeight: CGFloat { 16 * scale }
    var rowStep: CGFloat { 18 * scale }
    var firstRowCenterY: CGFloat { size.height / 2 - 1.5 * rowStep }

    func rowFrame(_ index: Int) -> CGRect {
        CGRect(x: textInset, y: firstRowCenterY + CGFloat(index) * rowStep - rowHeight / 2,
               width: max(0, size.width - textInset - 10 * scale), height: rowHeight)
    }

    /// 好感度轨道的尺寸。贴在底部、四行文字之下，无文字，因此不参与 OCR 遮挡排除。
    ///
    /// 放在底部而不是插成第 5 行：最小尺寸下 5 行文字会挤满内容高度，
    /// 而底部这条只需 3 点高的细线，任何尺寸下都放得下。
    func affectionTrackFrame() -> CGRect {
        let height = 3 * scale
        return CGRect(x: textInset, y: size.height - 4 * scale, width: max(0, size.width - textInset - 10 * scale),
                      height: height)
    }

    func occlusionRegion(header: CGRect, second: CGRect) -> CGRect {
        let renderedScale = (second.midY - header.midY) / (2 * rowStep)
        return CGRect(x: header.minX - textInset * renderedScale,
                      y: header.midY - firstRowCenterY * renderedScale,
                      width: size.width * renderedScale, height: size.height * renderedScale)
    }
}
