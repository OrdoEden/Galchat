import Foundation

/// 把 OCR 出来的会话标题匹配到已知联系人。
///
/// 这个文件被编译进键盘扩展，因此**不得引用任何主 App 侧的类型**——
/// 调用方把联系人以 `Subject` 的形式传进来。匹配结果也只回传 id 和名字。
///
/// SeeU 的文档明确说标题只是**候选**，绝不是联系人主键——同一段聊天可能被 OCR
/// 成「林小满」「林小满(3)」，而「当前会话」这种兜底标题在任何聊天里都会出现。
/// 所以策略是：高置信度才自动绑定，有歧义就一定交给用户确认。
///
/// 直接用 `SeeU.TextMatch` 会更省事，但它是 SeeU 的内部类型，没有对外暴露；
/// 复制这几十行比为了一个字符串比较去改库的公开接口更干净。
nonisolated enum ContactMatcher {

    /// 自动绑定阈值。低于它不自动绑定，改为让用户确认。
    static let autoBindThreshold = 0.8
    /// 两个联系人得分差距小于这个值时视为有歧义，即使都过阈值也交用户决定。
    static let ambiguityMargin = 0.1
    /// OCR 兜底标题，永远不参与匹配。
    static let anonymousTitles: Set<String> = ["当前会话", "会话", "聊天"]

    /// 参与匹配的对象。主 App 从 `ContactsStore.Contact` 映射过来。
    struct Subject: Equatable, Sendable {
        let id: String
        let displayName: String
        let aliases: [String]
    }

    struct Match: Equatable, Sendable {
        let contactID: String
        let displayName: String
        let score: Double
    }

    enum Outcome: Equatable, Sendable {
        /// 唯一高置信匹配，可静默绑定。
        case autoBind(Match)
        /// 有候选但不确定，需要用户确认。
        case ambiguous([Match])
        /// 没有任何已知联系人像它。
        case unknown
        /// 标题不可信，不参与匹配。
        case untrusted
    }

    /// 标题是否可信到可以用来认人。
    static func isTrusted(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !anonymousTitles.contains(trimmed)
    }

    static func match(title: String, subjects: [Subject]) -> Outcome {
        guard isTrusted(title) else { return .untrusted }
        let key = normalize(title)
        guard !key.isEmpty else { return .untrusted }

        let scored = subjects.compactMap { subject -> Match? in
            let byAlias = subject.aliases.map { similarity(key, normalize($0)) }.max() ?? 0
            // 显示名本身也参与匹配，用户可能建了档但没绑定过别名。
            let byName = similarity(key, normalize(subject.displayName))
            let score = max(byAlias, byName)
            guard score > 0 else { return nil }
            return Match(contactID: subject.id, displayName: subject.displayName, score: score)
        }
        .sorted { $0.score > $1.score }

        guard let best = scored.first else { return .unknown }
        guard best.score >= autoBindThreshold else {
            return .ambiguous(Array(scored.prefix(AffectionProjection.maxSuggestions)))
        }
        // 第二个候选和第一名很接近时，不下自动结论。
        if let second = scored.dropFirst().first, best.score - second.score < ambiguityMargin {
            return .ambiguous(Array(scored.prefix(AffectionProjection.maxSuggestions)))
        }
        return .autoBind(best)
    }

    // MARK: - 归一化与相似度

    /// 标题归一化：去掉空白、标点、emoji 与大小写差异，让「林小满」和「林小满 」
    /// 或「Lin Xiaoman」和「lin xiaoman」能对上。
    ///
    /// 与 `ContactsStore.normalize` 必须保持一致——两处结果不同会让匹配失效。
    static func normalize(_ raw: String) -> String {
        let stripped = raw.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.punctuationCharacters.contains(scalar)
                && !CharacterSet.symbols.contains(scalar)
        }
        return String(String.UnicodeScalarView(stripped)).lowercased()
    }

    /// 归一化的相似度，落在 0...1。
    ///
    /// 取 bigram Dice 与字符级 Jaccard 的较大值，因为中文短名会打穿 bigram：
    /// 「林小满」与「林晓满」的 bigram 集合是 {林小, 小满} 和 {林晓, 晓满}，
    /// 交集为空 → bigram 相似度为 0。只看 bigram 会把这种"明显是同一个人、
    /// 只是 OCR 或昵称差一个字"的情况判成陌生标题，反而更该让用户确认。
    /// 字符级重叠给出 1/3 左右的分数，落进有歧义的区间，正好触发确认。
    ///
    /// 上限 0.9 而不是 1：字符集相同时（「小满林」vs「林小满」）不应当成完全匹配，
    /// 那种情况值得用户看一眼。真正的完全相等在前面已经短路返回 1。
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 1 }
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }

        let bigramScore = dice(bigrams(lhs), bigrams(rhs))
        let characterScore = jaccard(Set(lhs), Set(rhs))
        return min(0.9, max(bigramScore, characterScore))
    }

    private static func dice(_ left: Set<String>, _ right: Set<String>) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return 2 * Double(left.intersection(right).count) / Double(left.count + right.count)
    }

    private static func jaccard(_ left: Set<Character>, _ right: Set<Character>) -> Double {
        guard !left.isEmpty || !right.isEmpty else { return 0 }
        let union = left.union(right).count
        guard union > 0 else { return 0 }
        return Double(left.intersection(right).count) / Double(union)
    }

    private static func bigrams(_ value: String) -> Set<String> {
        let characters = Array(value)
        guard characters.count >= 2 else { return [] }
        var result = Set<String>()
        for index in 0..<(characters.count - 1) {
            result.insert(String(characters[index...index + 1]))
        }
        return result
    }
}
