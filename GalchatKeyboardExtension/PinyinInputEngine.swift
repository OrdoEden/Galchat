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
