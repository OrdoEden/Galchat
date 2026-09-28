import CoreGraphics
import Foundation
import SeeU

/// App 自身的品牌与 PiP 几何留在适配层；尺寸按每帧快照捕获。
nonisolated enum AppFrameExclusion {
    static func policy(overlayContentSize: CGSize,
                       screenSize: CGSize) -> FrameExclusionPolicy {
        FrameExclusionPolicy { lines, frameSize in
            exclude(lines, frameSize: frameSize, overlayContentSize: overlayContentSize,
                    screenSize: screenSize)
        }
    }

    /// 键盘首排按键以上（候选条 + 间距）占屏幕高度的比例。
    ///
    /// 推导而不是写死：保留高度是点值（`KeyboardTopMetrics.reservedAboveKeys`），
    /// 屏幕高度也取点值，两者相除得到比例，再乘到像素坐标的帧上——这样换机型、
    /// 转屏或改键盘顶部结构都自动跟着走，不需要手改常量。
    ///
    /// `screenSize` 取当前展示方向的 `UIScreen` 点尺寸；为 0 时回退到保守值。
    static func candidateBarRatio(screenSize: CGSize) -> CGFloat {
        guard screenSize.height > 0 else { return 0.08 }
        return KeyboardTopMetrics.reservedAboveKeys / screenSize.height
    }

    /// 单个按键文字是否像键盘键。
    ///
    /// OCR 有时把整行读成一行 `qwertyuiop`，有时逐键读成单字符，两种都要认。
    private static func isKeyLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // shift 开启时键帽显示大写，所以大小写都认。
        if trimmed.count == 1, let scalar = trimmed.lowercased().unicodeScalars.first,
           (97...122).contains(scalar.value) { return true }
        return rowStrings.contains(trimmed.lowercased()) || anchors.contains(trimmed)
    }

    private static let rowStrings: Set<String> = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private static let anchors: Set<String> = ["空格", "选定", "换行", "确认", "发送", "搜索", "123", "拼音", "#+="]

    /// 键盘顶边。
    ///
    /// 键盘扩展里已经没有品牌文字，所以改认**按键行**本身：`qwertyuiop` / `asdfghjkl`
    /// 这类整行字符只在键盘上出现，聊天正文里的普通单词不会三行都匹配。
    ///
    /// 返回最靠上那排按键的顶边减去候选条高度——切线因此落在候选条之上，
    /// 候选文字（回复建议、拼音候选）不会被当成聊天内容。
    private static func keyboardTop(in lines: [OCRLine], frameSize: CGSize,
                                    screenSize: CGSize) -> CGFloat? {
        let keys = lines.filter { line in
            guard line.rect.midY > 0.45 * frameSize.height else { return false }
            return isKeyLine(line.text)
        }
        // 单个字母在聊天正文里也常见；至少要凑成一行按键才认。
        guard keys.count >= 3, let top = keys.map(\.rect.minY).min() else { return nil }
        let candidateBar = frameSize.height * candidateBarRatio(screenSize: screenSize)
        // 候选条落在画面中线以上说明这是误判（正文里的英文单词），放弃锚点。
        let cut = top - candidateBar
        return cut > frameSize.height * 0.5 ? cut : nil
    }

    static func exclude(
        _ lines: [OCRLine], frameSize: CGSize, overlayContentSize: CGSize,
        screenSize: CGSize
    ) -> FrameExclusion {
        let keyboardTop = keyboardTop(in: lines, frameSize: frameSize, screenSize: screenSize)
        let candidates = lines.filter { line in
            keyboardTop.map { line.rect.maxY < $0 } ?? true
        }
        let layout = GCPiPLayout(size: overlayContentSize)
        let normalised = { (text: String) in text.replacingOccurrences(of: " ", with: "") }
        var regions: [CGRect] = []
        for header in candidates {
            let text = normalised(header.text)
            guard text == "Galchat" || text.hasPrefix("Galchat·") else { continue }
            for identity in candidates {
                // 第三个锚点是头像上的「好感度」，与品牌名有独立的横向/纵向关系：
                // 横屏在品牌名右侧，竖屏在它上方隔开一段；普通聊天提品牌名不算 PiP。
                guard normalised(identity.text) == "好感度",
                      identity.rect.midX > header.rect.minX,
                      abs(identity.rect.height - header.rect.height) <= header.rect.height,
                      let region = layout.occlusionRegion(header: header.rect, identity: identity.rect)
                else { continue }
                let scale = region.width / max(overlayContentSize.width, 1)
                // OCR 字框小于 UILabel；用预期字号限制错误的跨消息配对。
                let expectedHeight = layout.markerFontSize * scale
                guard header.rect.height >= expectedHeight * 0.45,
                      header.rect.height <= expectedHeight * 1.5,
                      region.width <= frameSize.width * 1.05, region.height <= frameSize.height * 1.05 else { continue }
                regions.append(region.insetBy(dx: -2, dy: -2)
                    .intersection(CGRect(origin: .zero, size: frameSize)))
            }
        }
        let kept = lines.filter { line in
            if let keyboardTop, line.rect.minY >= keyboardTop - 2 { return false }
            return !regions.contains { $0.contains(CGPoint(x: line.rect.midX, y: line.rect.midY)) }
        }
        return FrameExclusion(lines: kept, keyboardTop: keyboardTop, occluders: regions)
    }
}
