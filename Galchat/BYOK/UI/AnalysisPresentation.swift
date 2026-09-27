import UIKit

/// 判断结果与候选回复的展示，手动分析页和实时会话页共用。
enum AnalysisPresentation {

    static func judgeLines(_ analysis: Analysis) -> [String] {
        var lines: [String] = []
        if let intent = analysis.trueIntent {
            lines.append("真实意图：\(intent.choice)（置信度 \(percent(intent.confidence))）")
        }
        if let needs = analysis.sheNeeds {
            lines.append("对方需要：\(needs.choice)")
        }
        if let action = analysis.bestAction {
            lines.append("最佳行动：\(action.choice)")
        }
        if let danger = analysis.dangerLevel {
            lines.append("危险程度：\(Int(danger.score.rounded())) / \(danger.maxLevel)")
        }
        if let reply = analysis.shouldReplyNow {
            lines.append("是否应给出实质内容：\(percent(reply))")
        }
        if let tension = analysis.tensionResolved {
            lines.append("张力已化解：\(percent(tension))")
        }
        if let literal = analysis.literalQuestion {
            lines.append("字面提问：\(percent(literal))")
        }
        return lines
    }

    /// 按文档 §8.1：从上到下推荐程度由低到高，最后一条最高。
    /// `ranked` 为降序；`unranked` 时保持生成顺序，不标“优先推荐”。
    static func fill(
        _ stack: UIStackView, with ranked: [RankedReply], unranked: Bool, enabled: Bool = true,
        onCopy: @escaping (String) -> Void
    ) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let ordered = unranked ? ranked : Array(ranked.reversed())
        for (index, reply) in ordered.enumerated() {
            let note: String
            if unranked {
                note = "未排序"
            } else if index == ordered.count - 1 {
                note = "优先推荐 · 推荐分 \(percent(reply.probability))"
            } else {
                note = "推荐分 \(percent(reply.probability))"
            }
            stack.addArrangedSubview(candidateRow(index: index, text: reply.text, note: note, enabled: enabled, onCopy: onCopy))
        }
    }

    private static func candidateRow(index: Int, text: String, note: String, enabled: Bool, onCopy: @escaping (String) -> Void) -> UIView {
        let container = UIView()
        container.backgroundColor = .secondarySystemBackground
        container.layer.cornerRadius = 12

        let marker = ["①", "②", "③"]
        let textLabel = UILabel()
        textLabel.text = "\(marker[min(index, 2)]) \(text)"
        textLabel.font = .preferredFont(forTextStyle: .body)
        textLabel.numberOfLines = 0
        textLabel.adjustsFontForContentSizeCategory = true

        let noteLabel = makeFootnoteLabel(note)
        let copyButton = UIButton(configuration: .plain())
        copyButton.configuration?.title = "复制"
        copyButton.isEnabled = enabled
        copyButton.accessibilityHint = enabled ? nil : "等待新分析完成"
        copyButton.configuration?.contentInsets = .zero
        // 按钮绑定候选文本本身，不用下标去读可能已经刷新的数组。
        copyButton.addAction(UIAction { _ in
            UIPasteboard.general.string = text
            onCopy(text)
        }, for: .touchUpInside)

        let bottomRow = UIStackView(arrangedSubviews: [noteLabel, UIView(), copyButton])
        bottomRow.alignment = .center
        bottomRow.spacing = 8

        let stack = UIStackView(arrangedSubviews: [textLabel, bottomRow])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14)
        ])
        return container
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
