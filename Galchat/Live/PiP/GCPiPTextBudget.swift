import Foundation

/// 每种 PiP 能放下的字数，以及按预算裁剪文案的规则。
///
/// 宽度用「字宽单位」估算：1 = 一个汉字（或全角标点）宽，英文与数字约 0.6，空格与「·」约 0.3。
/// 预算来自各自排版里文字框的宽度 ÷ 字号，留了少量余量（见 `docs/design/pip-portrait/`）。
///
/// 裁剪原则：宁可整段丢弃也不在词中间断开；只有单段本身就放不下时才截断加「…」。
nonisolated struct GCPiPTextBudget: Sendable, Equatable {
    /// 名字（竖屏：头像下一行；横屏：跟在「Galchat · 」后面）。
    let name: Double
    /// 情绪（不含变化值）。
    let emotion: Double
    /// 建议每行的宽度与行数。竖屏一段一行；横屏单行，各段用「 · 」连接。
    let adviceLine: Double
    let adviceLines: Int
    /// 状态文案；0 表示不显示（竖屏只保留分析中的粉点）。
    let status: Double

    /// 竖屏 90 × 220：右列 58pt / 11pt 字 → 名字 5；气泡正文 60pt / 11.5pt → 情绪 5、
    /// 60pt / 9.5pt → 建议每行 6，气泡高度放得下 3 行。
    static let portrait = GCPiPTextBudget(name: 5, emotion: 5, adviceLine: 6, adviceLines: 3, status: 0)
    /// 横屏 414 × 80：主列约 252pt。抬头行 = 「Galchat · 」+ 名字 6（12pt）+ 状态 9（10.5pt）；
    /// 情绪 15pt 粗体后面还要跟变化值 → 8；建议 12pt 单行 → 20。
    static let landscape = GCPiPTextBudget(name: 6, emotion: 8, adviceLine: 20, adviceLines: 1, status: 9)

    // MARK: - 裁剪

    func fitName(_ text: String) -> String { Self.truncate(text, to: name) }
    func fitEmotion(_ text: String) -> String { Self.truncate(text, to: emotion) }

    /// 状态只取第一个分句（「候选已就绪 · 在键盘选回复」→「候选已就绪」），仍放不下再截断。
    func fitStatus(_ text: String) -> String {
        guard status > 0 else { return "" }
        if Self.width(text) <= status { return text }
        let first = Self.clauses(text).first ?? text
        return Self.truncate(first, to: status)
    }

    /// 建议按行返回。多行时一段一行，过长的段在「，」处或按字换行；
    /// 单行时尽量多放几段，用「 · 」连接。行数用完后剩下的段整段丢弃。
    func fitAdvice(_ text: String) -> [String] {
        let segments = text.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !segments.isEmpty, adviceLines > 0 else { return [] }

        if adviceLines == 1 {
            var line = ""
            for segment in segments {
                let candidate = line.isEmpty ? segment : line + " · " + segment
                if Self.width(candidate) <= adviceLine { line = candidate } else { break }
            }
            return [line.isEmpty ? Self.truncate(segments[0], to: adviceLine) : line]
        }

        var lines: [String] = []
        for segment in segments {
            let wrapped = Self.wrap(segment, to: adviceLine)
            let room = adviceLines - lines.count
            guard room > 0 else { break }
            // 一段要占的行比剩下的多：已有内容就整段丢弃；这是第一段就截断显示。
            if wrapped.count > room {
                if lines.isEmpty {
                    lines = Array(wrapped.prefix(room))
                    lines[room - 1] = Self.truncate(lines[room - 1] + "…", to: adviceLine, force: true)
                }
                break
            }
            lines += wrapped
        }
        return lines
    }

    // MARK: - 字宽

    static func width(_ text: String) -> Double {
        text.unicodeScalars.reduce(0) { $0 + width(of: $1) }
    }

    private static func width(of scalar: Unicode.Scalar) -> Double {
        switch scalar.value {
        case 0x20, 0xB7: return 0.3                       // 空格、「·」
        case 0x30...0x39, 0x41...0x5A: return 0.62         // 数字、大写
        case 0x21...0x7E: return 0.55                      // 其余 ASCII
        default: return 1                                  // 汉字、全角标点、「…」、emoji
        }
    }

    /// 截断到预算内，末尾加「…」。`force` 表示已经带了「…」、只需把正文缩到放得下。
    static func truncate(_ text: String, to budget: Double, force: Bool = false) -> String {
        var body = force && text.hasSuffix("…") ? String(text.dropLast()) : text
        if !force && width(body) <= budget { return body }
        let ellipsis = width("…")
        while !body.isEmpty && width(body) + ellipsis > budget { body.removeLast() }
        body = body.trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? "…" : body + "…"
    }

    /// 按分句切：「 · 」、中文逗号/冒号/分号，以及半角冒号。分隔后的标点留在前一句末尾会占宽，丢掉。
    private static func clauses(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for character in text {
            if "·，,：:；;".contains(character) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { parts.append(trimmed) }
                current = ""
            } else {
                current.append(character)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { parts.append(trimmed) }
        return parts
    }

    /// 一段文字折成若干行：先在「，」后折（逗号留在行尾），仍太长再按字折。
    private static func wrap(_ text: String, to budget: Double) -> [String] {
        guard width(text) > budget else { return [text] }
        var pieces: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if "，、；".contains(character) { pieces.append(current); current = "" }
        }
        if !current.isEmpty { pieces.append(current) }

        var lines: [String] = []
        var line = ""
        for piece in pieces {
            if width(line + piece) <= budget {
                line += piece
                continue
            }
            if !line.isEmpty { lines.append(line); line = "" }
            for character in piece {
                if width(line + String(character)) > budget { lines.append(line); line = "" }
                line.append(character)
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }
}
