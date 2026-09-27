import CoreGraphics
import Foundation
import SeeU

/// App 自身的品牌与 PiP 几何留在适配层；尺寸按每帧快照捕获。
nonisolated enum AppFrameExclusion {
    static func policy(overlayContentSize: CGSize) -> FrameExclusionPolicy {
        FrameExclusionPolicy { lines, frameSize in
            exclude(lines, frameSize: frameSize, overlayContentSize: overlayContentSize)
        }
    }

    private static func exclude(
        _ lines: [OCRLine], frameSize: CGSize, overlayContentSize: CGSize
    ) -> FrameExclusion {
        let keyboardHeader = lines
            .filter { $0.text.hasPrefix("Jarvis 键盘") || $0.text.hasPrefix("Jarvis键盘") }
            .filter { $0.rect.midY > 0.4 * frameSize.height }
            .min { $0.rect.minY < $1.rect.minY }
        let candidates = lines.filter { line in
            line != keyboardHeader
                && (keyboardHeader.map { line.rect.maxY < $0.rect.minY } ?? true)
        }
        let layout = GCPiPLayout(size: overlayContentSize)
        var regions: [CGRect] = []
        for header in candidates {
            let text = header.text.replacingOccurrences(of: " ", with: "")
            guard text == "Galchat" || text.hasPrefix("Galchat·") else { continue }
            for footer in candidates {
                let footerText = footer.text.replacingOccurrences(of: " ", with: "")
                guard footerText == "AI估计" || footerText.hasPrefix("AI估计·"),
                      footer.rect.minY > header.rect.maxY,
                      abs(footer.rect.minX - header.rect.minX) < max(header.rect.height, footer.rect.height),
                      footer.rect.height >= header.rect.height * 0.5,
                      footer.rect.height <= header.rect.height * 2,
                      let region = layout.occlusionRegion(header: header.rect, footer: footer.rect) else { continue }
                let scale = region.width / max(overlayContentSize.width, 1)
                // OCR 字框小于 UILabel；用预期字号限制错误的跨消息配对。
                let expectedHeight = layout.markerFontSize * scale
                guard header.rect.height >= expectedHeight * 0.45,
                      header.rect.height <= expectedHeight * 1.5,
                      region.width <= frameSize.width * 1.05, region.height <= frameSize.height * 1.05 else { continue }
                // 第三个锚点在头像上，与文案列有独立的横向/纵向关系；普通聊天提品牌名不算 PiP。
                let identity = layout.identityFrame
                let expectedX = region.minX + identity.minX * scale
                let expectedY = region.minY + identity.midY * scale
                guard candidates.contains(where: {
                    $0.text.replacingOccurrences(of: " ", with: "") == "好感度"
                        && abs($0.rect.minX - expectedX) <= expectedHeight
                        && abs($0.rect.midY - expectedY) <= expectedHeight * 0.7
                }) else { continue }
                regions.append(region.insetBy(dx: -2, dy: -2)
                    .intersection(CGRect(origin: .zero, size: frameSize)))
            }
        }
        let kept = lines.filter { line in
            if let keyboardHeader, line.rect.minY >= keyboardHeader.rect.minY - 2 { return false }
            return !regions.contains { $0.contains(CGPoint(x: line.rect.midX, y: line.rect.midY)) }
        }
        return FrameExclusion(lines: kept, keyboardTop: keyboardHeader?.rect.minY, occluders: regions)
    }
}
