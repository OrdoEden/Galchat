import Foundation

/// 离线全拼词库。按词频提供整词和前缀选词，不读取或保存用户的输入历史。
final class PinyinInputEngine {
    struct Candidate {
        let text: String
        let consumedPinyinCount: Int
    }

    private struct Entry {
        let text: String
        let spelling: String
        let weight: Int
    }

    private lazy var dictionary: [String: [Entry]] = loadDictionary()

    /// 词库里出现过的全部音节（含 nve/lve 别名），用于把输入切成系统那样的 `ni hao`。
    private lazy var syllables: Set<String> = {
        var result = Set<String>()
        for entries in dictionary.values {
            for entry in entries {
                for syllable in entry.spelling.split(separator: " ") {
                    result.insert(String(syllable))
                }
            }
        }
        if result.contains("nue") { result.insert("nve") }
        if result.contains("lue") { result.insert("lve") }
        return result
    }()

    /// 输入框里显示的拼音：按音节用空格隔开，用户输入的 `'` 原样保留。
    ///
    /// 与系统中文键盘一致：`nihao` 显示为 `ni hao`，`nver` 为 `nv er`，
    /// `ttkaix` 为 `t t kai x`，`xi'an` 仍显示 `xi'an`。
    /// 只用于显示——上屏原文时提交的仍是用户实际键入的字母。
    func displaySpelling(for input: String) -> String {
        input.lowercased()
            .split(separator: "'", omittingEmptySubsequences: false)
            .map { segment(Array($0)) }
            .joined(separator: "'")
    }

    /// 所有音节的前缀，用于识别末尾拼到一半的音节（`zhon`）。
    private lazy var syllablePrefixes: Set<String> = {
        var result = Set<String>()
        for syllable in syllables {
            var prefix = ""
            for character in syllable {
                prefix.append(character)
                result.insert(prefix)
            }
        }
        return result
    }()

    /// 动态规划切分：完整音节代价 1，末尾半个音节代价 2，无法成音节的单个字母代价 10。
    /// 取总代价最小的切法——贪心最长匹配会把 `nver` 切成 `nve r`。
    private func segment(_ letters: [Character]) -> String {
        let count = letters.count
        guard count > 0 else { return "" }
        var best = [(cost: Int, pieces: [String])?](repeating: nil, count: count + 1)
        best[count] = (0, [])
        for start in stride(from: count - 1, through: 0, by: -1) {
            var choice: (cost: Int, pieces: [String])?
            func consider(_ end: Int, _ cost: Int) {
                guard let rest = best[end] else { return }
                let total = rest.cost + cost
                if choice == nil || total < choice!.cost {
                    choice = (total, [String(letters[start..<end])] + rest.pieces)
                }
            }
            for end in (start + 1)...min(count, start + 6) {
                let piece = String(letters[start..<end])
                if syllables.contains(piece) {
                    consider(end, 1)
                } else if end == count, syllablePrefixes.contains(piece) {
                    consider(end, 2)
                }
            }
            consider(start + 1, 10)
            best[start] = choice
        }
        return best[0]?.pieces.joined(separator: " ") ?? String(letters)
    }

    func candidates(for input: String) -> [Candidate] {
        let input = input.lowercased().replacingOccurrences(of: "ü", with: "v")
        guard !input.isEmpty, input.count <= 64,
              input.unicodeScalars.allSatisfy({ (97...122).contains($0.value) || $0 == "'" }) else { return [] }
        let letters = Array(input)
        var result: [Candidate] = []
        var seen = Set<String>()
        func append(_ text: String, consumed: Int) {
            if seen.insert("\(consumed):\(text)").inserted {
                result.append(Candidate(text: text, consumedPinyinCount: consumed))
            }
        }

        // 先给出完整词，再给出可逐段提交的较短词；空格可直接选第一个。
        for length in stride(from: letters.count, through: 1, by: -1) {
            let prefix = String(letters.prefix(length))
            let matches = entries(for: prefix)
            var consumed = length
            while consumed < letters.count && letters[consumed] == "'" { consumed += 1 }
            for entry in matches { append(entry.text, consumed: consumed) }
        }
        if !result.contains(where: { $0.consumedPinyinCount == letters.count }),
           let sentence = compose(letters) {
            result.insert(Candidate(text: sentence, consumedPinyinCount: letters.count), at: 0)
        }
        return result
    }

    private func entries(for spelling: String) -> [Entry] {
        let key = spelling.replacingOccurrences(of: "'", with: "")
        guard !key.isEmpty, let entries = dictionary[key] else { return [] }
        guard spelling.contains("'") else { return entries }
        // 西安 xi'an 与先 xian 必须可通过分隔符区分。
        let requested = boundaries(in: spelling, separator: "'")
        return entries.filter { requested.isSubset(of: boundaries(in: $0.spelling, separator: " ")) }
    }

    private func boundaries(in spelling: String, separator: Character) -> Set<Int> {
        var count = 0
        var positions = Set<Int>()
        for character in spelling {
            if character == separator { positions.insert(count) } else { count += 1 }
        }
        // 末尾分隔符只是结束当前音节，并不要求后面必须还有音节。
        positions.remove(count)
        return positions
    }

    /// 最小分词组合：长串全拼可一次提交，也能从前缀候选逐词修正。
    private func compose(_ letters: [Character]) -> String? {
        var best: [Int: (text: String, score: Double)] = [letters.count: ("", 0)]
        for start in stride(from: letters.count - 1, through: 0, by: -1) {
            if letters[start] == "'" { continue }
            for end in (start + 1)...letters.count {
                guard let suffix = best[end],
                      let entry = entries(for: String(letters[start..<end])).first else { continue }
                let score = log(Double(entry.weight + 1)) - log(100_000_000.0) + suffix.score
                if best[start] == nil || score > best[start]!.score {
                    best[start] = (entry.text + suffix.text, score)
                }
            }
        }
        return best[0]?.text
    }

    private func loadDictionary() -> [String: [Entry]] {
        guard let url = Bundle.main.url(forResource: "pinyin", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: [Entry]] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard fields.count == 3, let weight = Int(fields[2]) else { continue }
            let spelling = String(fields[1])
            let entry = Entry(text: String(fields[0]), spelling: spelling, weight: weight)
            // Add aliases by syllable, also for words such as 战略 zhan lve.
            // Whole-input replacement would corrupt 女儿 nv er into nu er.
            var keys = [""]
            for syllable in spelling.split(separator: " ") {
                let options = syllable == "nue" ? ["nue", "nve"] : (syllable == "lue" ? ["lue", "lve"] : [String(syllable)])
                keys = keys.flatMap { prefix in options.map { prefix + $0 } }
            }
            for key in keys { result[key, default: []].append(entry) }
        }
        for key in Array(result.keys) {
            result[key]?.sort { $0.weight == $1.weight ? $0.text < $1.text : $0.weight > $1.weight }
        }
        return result
    }
}
