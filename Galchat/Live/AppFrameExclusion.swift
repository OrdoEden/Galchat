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
            let text = line.text.trimmingCharacters(in: .whitespaces)
            return (text.hasPrefix("Jarvis ") || text.hasPrefix("Jarvis·"))
                && line != keyboardHeader
                && (keyboardHeader.map { line.rect.maxY < $0.rect.minY } ?? true)
        }
        var regions: [CGRect] = []
        for header in candidates where header.text.hasPrefix("Jarvis ·") || header.text.hasPrefix("Jarvis·") {
            let lineHeight = max(header.rect.height, 1)
            let rows = candidates.filter { line in
                line.rect.minY >= header.rect.maxY
                    && line.rect.minY - header.rect.maxY < lineHeight * 5
                    && abs(line.rect.minX - header.rect.minX) < lineHeight * 0.8
                    && line.rect.height >= lineHeight * 0.65
                    && line.rect.height <= lineHeight * 1.25
            }.sorted { $0.rect.minY < $1.rect.minY }
            guard rows.count >= 2 else { continue }
            let first = rows[0], second = rows[1]
            let firstLabels = ["Jarvis 意图", "Jarvis 判断", "Jarvis 识别到", "Jarvis 打开"]
            let secondLabels = ["Jarvis 建议", "Jarvis 分析完成后", "Jarvis 显示情绪"]
            guard firstLabels.contains(where: { first.text.hasPrefix($0) }),
                  secondLabels.contains(where: { second.text.hasPrefix($0) }) else { continue }
            let firstStep = first.rect.midY - header.rect.midY
            let secondStep = second.rect.midY - first.rect.midY
            guard firstStep >= lineHeight, firstStep <= lineHeight * 2.2,
                  abs(firstStep - secondStep) < lineHeight * 0.6 else { continue }
            let layout = JarvisPiPLayout(size: overlayContentSize)
            let region = layout.occlusionRegion(header: header.rect, second: second.rect)
            regions.append(region.intersection(CGRect(origin: .zero, size: frameSize)))
        }
        let kept = lines.filter { line in
            if let keyboardHeader, line.rect.minY >= keyboardHeader.rect.minY - 2 { return false }
            return !regions.contains { $0.contains(CGPoint(x: line.rect.midX, y: line.rect.midY)) }
        }
        return FrameExclusion(lines: kept, keyboardTop: keyboardHeader?.rect.minY, occluders: regions)
    }
}
