import Foundation
import Synapse

/// 固定的 Jev 题目集，逐字移植自安卓参考实现（已通过校准的措辞）。
/// instructions/criteria 用英文，聊天正文保持中文。
enum JevQuestions {

    /// 附加到每道题后面，让 background 字段被当作已知上下文而不是跑题内容。
    static let backgroundNote = " Facts given in background are provided context, not off-topic."

    private static func noul(_ instructions: String, trueCase: String, falseCase: String) -> SynapseJSONValue {
        [
            "type": "noul",
            "instructions": .string(instructions + backgroundNote),
            "criteria": ["true": .string(trueCase), "false": .string(falseCase)]
        ]
    }

    private static func choice(_ instructions: String, criteria: [(String, String)]) -> SynapseJSONValue {
        var dict: [String: SynapseJSONValue] = [:]
        for (key, value) in criteria { dict[key] = .string(value) }
        return [
            "type": "choice",
            "instructions": .string(instructions + backgroundNote),
            "criteria": .object(dict)
        ]
    }

    private static func score(_ instructions: String, levels: [String]) -> SynapseJSONValue {
        [
            "type": "score",
            "instructions": .string(instructions + backgroundNote),
            "criteria": .array(levels.map { .string($0) })
        ]
    }

    /// 判断题：7 道冲突/需求判断 + 1 道好感度边际变化。
    ///
    /// `affection_delta` 是后加的第 8 题，前 7 题措辞保持逐字不变——
    /// 它们是已校准的移植。新题只问"最新一轮相对之前的情绪位移"，
    /// 是单步边际值而不是窗口求和，这样重叠窗口对同一尾部会产出同一个值，
    /// 上层才能按消息 id 精确去重（见 `AffectionCommitter`）。
    static func judge() -> [String: SynapseJSONValue] {
        [
            "literal_question": noul(
                "Is the other person's latest message meant purely literally, with no subtext? "
                    + "Judge from the whole thread, not one sentence in isolation.",
                trueCase: "The latest message is a straightforward statement, question, or plan "
                    + "with no implied accusation, test, sarcasm, hint, or unsaid request.",
                falseCase: "There is subtext: a test of whether you remember or care, sarcasm, "
                    + "an implied complaint, a hint they will not say outright, a trap question, "
                    + "an accusation dressed as a question, or a cold/short line that really means blame."
            ),
            "true_intent": choice(
                "What is the other person's true intent in the latest message, given the full conversation? "
                    + "Prefer tone and context over surface wording. "
                    + "If they are checking whether you remember something or still care, choose confirm_you_care "
                    + "even if the words look like a request to 'say it' or to do something. "
                    + "If they already accepted and closed the matter peacefully, choose close_topic. "
                    + "Ending the relationship, deleting you, or 'don't talk to me' is vent_anger, never close_topic.",
                criteria: [
                    ("confirm_you_care", "They are testing whether you remember, pay attention, or still care. "
                        + "Signals: 'did you forget again', 'then say it', 'you better', sarcastic 'busy person', "
                        + "asking you to prove you know a past conversation. "
                        + "If they mainly want a new deliverable or a yes on a time, do not use this."),
                    ("vent_anger", "They are angry or hurt and mainly want the feeling acknowledged. "
                        + "They are blaming or raising the temperature; a specific plan is not the main point yet."),
                    ("request_action", "They want a concrete action, time, deliverable, or commitment from you now, "
                        + "and this is a real ask, not a loyalty test."),
                    ("seek_explanation", "They want a factual explanation of why something happened. "
                        + "They asked why or what is going on, not mainly for an apology or a new plan."),
                    ("casual_chat", "Light talk, banter, sharing, teasing with a laugh, or friendly logistics "
                        + "with no emotional test and no conflict. A friend suggesting a meal time can be this "
                        + "if the thread is warm."),
                    ("close_topic", "Peaceful wrap-up only: they accepted an apology, confirmed a happy plan, said thanks, "
                        + "or clearly signaled they need nothing more. "
                        + "Not a breakup, not 'don't contact me', not sarcastic 'I'm used to it'.")
                ]
            ),
            "danger_level": score(
                "How close is this conversation to a fight or to hurting the relationship? "
                    + "Match the current scene. "
                    + "If they genuinely accepted an apology or confirmed a happy plan, score the cooled-down present, "
                    + "not an earlier complaint. "
                    + "If an ultimatum (break up, report to the boss, stop covering for you) is still in force "
                    + "and has not been withdrawn, stay in that high bin even if the latest line names a specific task.",
                levels: [
                    "Light chat or joking; no complaint, no test, no deadline.",
                    "Mild tease or a small reminder that is easy to laugh off; a clumsy reply would only feel slightly awkward.",
                    "A mild complaint or 'please remember next time' said without heat; they still send warm or practical follow-ups.",
                    "Noticeable unhappiness; they mention being forgotten, ignored, or kept waiting, but still give you a chance to make it right.",
                    "Sarcasm, cold short replies, or 'you better'; they are testing you, and a sloppy or fake-confident reply will escalate.",
                    "Openly upset; they accuse you of not listening or not caring; they expect a real response, not a joke.",
                    "Clearly angry and blaming you; a wrong reply will turn this into a fight.",
                    "Last-chance warning. They will not cover for you, do not want to keep talking unless this changes, "
                        + "or tell you to finish a named checklist yourself because trust is almost gone.",
                    "An ultimatum is already on the table even if they also give a practical next step: "
                        + "break up if you forget again, report you tonight, or stop working together if you miss this.",
                    "Active rupture: they said it is over, told you not to reply, deleted you, or are exploding."
                ]
            ),
            "should_reply_now": noul(
                "Should your next message contain substantive content? "
                    + "Substantive means: admitting a specific known fault, giving a concrete time/plan/deliverable, "
                    + "explaining facts you actually know, or reciting the recalled content they asked you to say. "
                    + "This is NOT 'should you send any message'. Timing is irrelevant. "
                    + "Answer FALSE if the thing they want you to recite or prove is not present in this snippet "
                    + "(you would be guessing). 'Then say it' / 'you better' while you are stalling is FALSE. "
                    + "Answer FALSE if they already accepted and closed the topic. "
                    + "Answer true only if the needed fact, plan, or named fault is already in this snippet.",
                trueCase: "The needed fact, named fault, or named time/place is already in this snippet, "
                    + "and they are waiting for that substance now.",
                falseCase: "Do not put substance in the next message: the recalled content is not in this snippet, "
                    + "they are testing whether you remember, a holding line is enough, "
                    + "saying less is safer, or they already closed the topic."
            ),
            "best_action": choice(
                "What type of next action is best? Do not decide whether to send a message immediately. "
                    + "Ignore timing. Choose only the action type. "
                    + "If they asked you to recall a specific past message or event and you have not shown that you actually remember it, "
                    + "choose check_history - do not apologize or invent a plan instead.",
                criteria: [
                    ("check_history", "Look up prior chat or facts before taking a position. "
                        + "Use when they ask you to repeat, recall, or prove you remember something specific."),
                    ("apologize", "Lead with a sincere apology for a real mistake or hurt already identified. "
                        + "Not for an unnamed forgotten thing when you should first find out what it was."),
                    ("give_commitment", "Give a concrete promise, deadline, or arrangement they asked for "
                        + "in a conflict or work-pressure setting."),
                    ("explain", "Explain what happened or why, without leading with apology or a new plan."),
                    ("acknowledge", "Show you heard them and care, without new facts, an apology, or a plan. "
                        + "Use for light chat or when they mainly need to feel seen."),
                    ("say_less", "Keep it short or add nothing. Extra words would over-explain, reopen a closed topic, "
                        + "or pour fuel on an ultimatum that told you not to talk."),
                    ("make_plan", "Propose or confirm logistics (time, place, task) for a non-conflict request "
                        + "such as a meal or a meeting.")
                ]
            ),
            "she_needs": choice(
                "What does the other person need from you right now? Judge the LATEST message first. "
                    + "If they genuinely accepted (thanks / got it / 没事了 / 那就这样 / 收到了 / 过去了), "
                    + "you MUST choose nothing, even if earlier they wanted action or an apology. "
                    + "Sarcastic 'I'm used to it', 'whatever', 'I don't want to hear it', 'don't bother coming' "
                    + "is NOT genuine satisfaction - do not choose nothing. "
                    + "If they asked you to recap a named time/place/date, choose action. "
                    + "If they are testing whether you remember or still care, and the content is unnamed, choose care.",
                criteria: [
                    ("apology", "They need a sincere apology for hurt or a mistake, and they have not accepted one yet."),
                    ("action", "They need a concrete action, time, commitment, recap of a named fact, or follow-through, "
                        + "and they have not yet accepted one."),
                    ("explanation", "They need a clear explanation of what happened or why, and have not received it."),
                    ("care", "They need proof you remember, listen, or care - a loyalty or attention test - "
                        + "not yet a plan or an apology. Sarcastic 'I am used to it' belongs here, not nothing."),
                    ("nothing", "They need nothing further. Genuine acceptance, a peaceful closed topic, "
                        + "warm casual chat with no ask, or a rupture where they told you not to reply. "
                        + "Not sarcasm pretending to be fine.")
                ]
            ),
            "tension_resolved": noul(
                "Has interpersonal tension already been resolved? "
                    + "Answer true only if there was never tension, or the other person has clearly accepted, "
                    + "cooled down, joked again, or said it is fine. "
                    + "A sarcastic 'you better', an unanswered test, leftover blame, or an open ultimatum means false.",
                trueCase: "No remaining tension: they accepted, joked again, said it's fine, "
                    + "confirmed a happy plan, or the chat was never tense.",
                falseCase: "Tension is still present: they are waiting, testing, angry, sarcastic, "
                    + "issuing an ultimatum, or the issue is open."
            ),
            // 第 8 题：好感度。刻意问"最新这一轮的边际位移"而不是"整体感觉"——
            // 前者对同一尾部是稳定值，上层能按消息 id 精确去重；后者会随窗口滑动漂移。
            "affection_delta": choice(
                "Judging ONLY the other person's LATEST message, how does their feeling toward you shift "
                    + "compared with the mood of the thread immediately before it? "
                    + "Score the marginal change of this one turn; do not re-count warmth or coldness "
                    + "that was already present earlier. Warmth, teasing that invites you in, sharing, "
                    + "or an unprompted kindness is up. Sarcasm, short cold replies, blame, "
                    + "or withdrawal is down. Ordinary logistics is neutral.",
                criteria: [
                    ("warm_up", "Clearly warmer than the turn before: affectionate, grateful, "
                        + "playful teasing that invites you closer, sharing something personal, "
                        + "or an unprompted kindness toward you."),
                    ("slight_up", "A little warmer or more engaged than the turn before: friendly, "
                        + "cooperative, answering with more than the minimum, or softening after coolness. "
                        + "Not affectionate enough to be warm_up."),
                    ("neutral", "No real change in temperature. Plain logistics, factual replies, "
                        + "checking a time or place, or continuing the same mood as before."),
                    ("slight_down", "A little cooler than the turn before: curt, delayed-feeling, "
                        + "mildly disappointed, or noticeably shorter than they were. Not yet hostile."),
                    ("cold_down", "Clearly colder than the turn before: openly cold or dismissive, "
                        + "blaming you, sarcastic, withdrawing, or saying something meant to hurt.")
                ]
            )
        ]
    }

    /// 对 3 条候选排序的题目。
    static func rankQuestion(candidates: [String]) -> [String: SynapseJSONValue] {
        precondition(candidates.count == 3, "rankQuestion 需要恰好 3 条候选")
        let keys = ["reply_a", "reply_b", "reply_c"]
        var criteria: [String: SynapseJSONValue] = [:]
        for (index, key) in keys.enumerated() { criteria[key] = .string(candidates[index]) }
        return [
            "best_reply": [
                "type": "choice",
                "instructions": .string(
                    "Which candidate reply is the most appropriate next message, "
                        + "given the conversation and the other person's true need? "
                        + "Prefer a reply that matches the best action type. "
                        + "Penalize dismissive, over-promising, or off-topic replies. "
                        + "If the facts are not yet confirmed, prefer the candidate that looks them up "
                        + "instead of faking memory or a vague apology."
                        + backgroundNote
                ),
                "criteria": .object(criteria)
            ]
        ]
    }

    static let rankKeys = ["reply_a", "reply_b", "reply_c"]

    /// 由快照构造 Jev state。
    static func buildState(snapshot: ChatSnapshot, relationship: String) -> SynapseJSONValue {
        let recent = snapshot.recentMessages
        let messages = recent.map { message in
            SynapseJSONValue.object([
                "from": .string(message.speaker.rawValue),
                "text": .string(message.text)
            ])
        }
        return [
            "chat": [
                "relationship": .string(relationship),
                "messages": .array(messages),
                "latest_from": .string(recent.last?.speaker.rawValue ?? Speaker.other.rawValue)
            ]
        ]
    }
}
