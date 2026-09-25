import Foundation

/// 好感度的纯计算层：把 `affection_delta` 的答案换算成一个数值位移，再套上饱和、
/// 危险度耦合和破裂规则，产出"这一轮实际加了多少"。
///
/// 这里不碰任何状态——累计、去重、持久化都在 `AffectionCommitter`。
/// 拆开是为了让计分语义能单独测：给定同一组答案，任何时候都得到同一个结果。
nonisolated enum AffectionScoring {

    /// 总分范围与初始值。与 `AffectionProjection` 里的同名常量必须一致——
    /// 那三个常量在共享层，键盘也要用。
    static let minimum = AffectionProjection.minimumTotal
    static let maximum = AffectionProjection.maximumTotal
    static let initial = AffectionProjection.initialTotal

    /// 单轮位移的硬钳制，防止一次误判把条推到底。
    static let stepRange = -6...6

    /// 顶部三分之一的饱和起点：从 70 分起，正向增益线性衰减，到 100 归零。
    static let saturationStart = 70

    /// 破裂（danger_level == 9）进入时的一次性扣分。
    static let rupturePenalty = 12

    /// 各档位的语义值。期望值 `Σ p_k · v_k` 落在 [-2, +2]。
    static let values: [String: Double] = [
        "warm_up": 2,
        "slight_up": 1,
        "neutral": 0,
        "slight_down": -1,
        "cold_down": -2
    ]

    /// 期望值 → 界面点数的放大倍数。
    ///
    /// 期望值域是 [-2, +2]，乘 2 后单轮位移落在 [-4, +4]，让一次明确的
    /// 升温/降温在 0-100 的条上大约走 2-4 个点 —— 看得见但不至于一步到顶。
    static let stepScale: Double = 2

    /// 档位顺序，仅用于回退判断和测试。
    static let keys = ["warm_up", "slight_up", "neutral", "slight_down", "cold_down"]

    // MARK: - 原始位移

    /// 从 choice 答案算出期望位移，落在 [-2, +2]。
    ///
    /// 优先用 `probabilities` 求期望：单点采样在档位边界上会跳，而一根不能抖的条
    /// 需要这种平滑。概率缺失（部分服务商不返回）时退化成 `v(choice) * confidence`。
    static func rawStep(_ answer: Choice?) -> Double {
        guard let answer else { return 0 }
        if !answer.probabilities.isEmpty {
            var expected = 0.0
            var total = 0.0
            for (key, probability) in answer.probabilities {
                guard let value = values[key] else { continue }
                expected += value * probability
                total += probability
            }
            // 概率和不为 1 时归一化，避免服务商返回原始 logit 时把条推飞。
            if total > 0, abs(total - 1) > 0.001 {
                expected /= total
            }
            return clamp(expected, -2, 2)
        }
        let value = values[answer.choice] ?? 0
        return clamp(value * clamp(answer.confidence, 0, 1), -2, 2)
    }

    // MARK: - 危险度耦合

    /// 危险度分级对位移的乘数。
    static func dangerMultiplier(danger: Int, ruptured: Bool) -> Double {
        if ruptured { return 1.5 }
        switch danger {
        case ...2: return 1.0
        case 6...8: return 1.25
        default: return 1.0
        }
    }

    /// 危险度高时压制正向增益，但放大负向——冲突中很难真的升温，掉分却很快。
    ///
    /// 平静期的 +20% 只在确认是温暖场景时给（`warmScene`）。曾经写成"只要
    /// danger ≤ 2 就加成"，那是错的：普通的平静对话也会白拿 20%，
    /// 升温变得过于廉价。
    static func positiveMultiplier(danger: Int, ruptured: Bool, warmScene: Bool) -> Double {
        if ruptured { return 0.35 }
        switch danger {
        case ...2: return warmScene ? 1.2 : 1.0
        case 6...8: return 0.7
        default: return 1.0
        }
    }

    /// 顶部三分之一的线性饱和。total 70 时 +4 仍是 +4，85 时变 +2，100 归零。
    static func saturationFactor(total: Int) -> Double {
        guard total >= saturationStart else { return 1 }
        let remaining = Double(maximum - total)
        let span = Double(maximum - saturationStart)
        guard span > 0 else { return 0 }
        return max(0, min(1, remaining / span))
    }

    // MARK: - 应用

    struct Input {
        /// 本轮的原始答案。
        var answer: Choice?
        /// 前值，用于回退和破裂检测。
        var trueIntent: Choice?
        var sheNeeds: Choice?
        var dangerLevel: Score?
        var tensionResolved: Double?
        /// 当前总分。
        var total: Int
        /// 该联系人是否处于破裂未修复状态。
        var ruptured: Bool
    }

    struct Output {
        /// 界面显示的本轮 ±，已包含饱和、耦合与钳制。
        var appliedStep: Int
        /// 套用后的新总分。
        var newTotal: Int
        /// 本轮是否首次进入破裂。
        var didRupture: Bool
        /// 本轮是否解除了破裂。
        var didResolve: Bool
        /// 是否只是维持现状（没有任何位移）。
        var isNeutral: Bool { appliedStep == 0 }
    }

    /// 计分主入口。纯函数，输入相同则输出相同。
    static func apply(_ input: Input) -> Output {
        let danger = normalizedDanger(input.dangerLevel)
        let ruptured = input.ruptured
        let total = clamp(input.total, minimum, maximum)

        var step = resolvedStep(input)

        // 期望值域是 [-2, +2]；乘 2 得到界面上的点数域 [-4, +4]。
        // 这一步曾经漏掉，导致一轮暖意只值 2 点，条走得比设计慢一倍。
        step *= stepScale

        // 破裂检测：仅在之前未破裂、且本轮危险度触顶时发生一次。
        let entersRupture = danger >= 9 && !ruptured
        var didResolve = false

        if entersRupture {
            let newTotal = clamp(total - rupturePenalty, minimum, maximum)
            return Output(appliedStep: -rupturePenalty, newTotal: newTotal,
                          didRupture: true, didResolve: false)
        }

        // 解除：危险度回落且张力明确消解。给 +1 保底——降级必须被奖励，
        // 否则玩家会觉得条是死的，修好关系也看不到反馈。
        if ruptured, danger <= 4, isResolved(input.tensionResolved) {
            didResolve = true
            step = max(step, 1)
        }

        let applied: Int
        if step > 0 {
            let multiplier = positiveMultiplier(danger: danger, ruptured: ruptured,
                                                warmScene: isWarmScene(input))
            let factor = saturationFactor(total: total)
            // 正向饱和时至少保留 +1（除非已到顶），否则玩家看不到任何反馈。
            applied = total >= maximum ? 0 : max(1, Int((step * multiplier * factor).rounded()))
        } else if step < 0 {
            let scaled = step * dangerMultiplier(danger: danger, ruptured: ruptured)
            applied = Int(scaled.rounded())
        } else {
            // 中性：破裂状态下也不额外惩罚，中性就是中性。
            applied = 0
        }

        let clamped = clamp(applied, stepRange.lowerBound, stepRange.upperBound)
        return Output(appliedStep: clamped,
                      newTotal: clamp(total + clamped, minimum, maximum),
                      didRupture: false, didResolve: didResolve)
    }

    /// 解析出 [-2, +2] 的位移，模型漏答时用其余答案做确定性回退。
    ///
    /// 回退存在的意义：追问失败或服务商少返回一个 key 时，条不应该整个卡住不动。
    /// 映射刻意保守——回退只是维持大致方向，不替代真实判断。
    private static func resolvedStep(_ input: Input) -> Double {
        if let answer = input.answer, !answer.choice.isEmpty {
            return rawStep(answer)
        }
        // 回退值同样以"档位值"为单位，之后统一乘 `stepScale`。
        // 取整数档而不是 0.5，因为回退本就信息不足，给半个档位只会让读数出现
        // 解释不了的奇数变化。
        switch input.trueIntent?.choice {
        case "close_topic": return 1
        case "casual_chat": return 1
        case "vent_anger": return -1.5
        case "confirm_you_care": return -0.5
        case "request_action", "seek_explanation": return 0
        default:
            break
        }
        if input.sheNeeds?.choice == "nothing", isResolved(input.tensionResolved) { return 0.5 }
        return 0
    }

    /// 是否是一个明确温暖的场景，用于决定要不要给平静期加成。
    ///
    /// 要求"危险度低 + 意图是闲聊或收尾 + 对方不需要更多"三者同时成立。
    /// 只看危险度是不够的：一条平静的"明天几点"也会满足 danger ≤ 2。
    private static func isWarmScene(_ input: Input) -> Bool {
        guard let intent = input.trueIntent?.choice else { return false }
        let warmIntent = intent == "casual_chat" || intent == "close_topic"
        let noNeed = input.sheNeeds?.choice == nil || input.sheNeeds?.choice == "nothing"
        return warmIntent && noNeed
    }

    /// `tension_resolved` 是 noul 题，回到这里是个 `Double?`（参照既有的
    /// `Analysis.tensionResolved` 用法）。非 nil 即视为已消解。
    private static func isResolved(_ value: Double?) -> Bool {
        guard let value else { return false }
        return value > 0
    }

    private static func normalizedDanger(_ score: Score?) -> Int {
        guard let score else { return 0 }
        return Int(clamp(score.score.rounded(), 0, 9))
    }

    private static func clamp<T: Comparable>(_ value: T, _ low: T, _ high: T) -> T {
        min(max(value, low), high)
    }
}
