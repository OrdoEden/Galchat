# 实时识别 / 长图拼接 / 语义触发 重设计（草案）

> 状态：设计稿，未实现。涉及 `../SeeU`（识别、账本、长图）与 Galchat `Live/`（批处理、语义闸门、上下文）。

## 0. 现状问题与代码根因

| 现象 | 根因（当前代码） |
|---|---|
| 键盘弹出、没有新内容，也被拼进长图 | `LiveChatCoordinator.pump` 对每个 `longScreenshot != nil` 的帧都 `ingest`；`LongScreenshotStore.ingest` 没有“是否带来新覆盖范围”的判断。键盘弹起时微信把列表上推，`ImageAligner` 能算出位移 → `.extended` → 新增一张条带，还可能按容量挤掉旧条带。 |
| “哈哈哈哈 / 口合口合口合口合 / 口合口合哈哈” 变成多条或来回跳 | `ChatStitcher.merge` 用**文字相似度 ≥ 0.6** 判断是不是同一条；这几种识别结果的二元组相似度≈0 → 同一位置新建条目。幽灵条目只有在 `observations <= 1 && misses >= 3` 时才删除，错字被看到两次后就永久留下。`VisionOCRService` 只取 `topCandidates(1)`，没有候选投票。 |
| 自动分析频繁在不该触发时触发（截图中“自动分析过于频繁，等待一分钟额度恢复”） | `LiveAnalysisScheduler.update` 以 `tailSignature`（id + 文字）变化触发。OCR 抖动、对齐失败另起段（`currentTailMissing` 时 `live = currentMessages`）、键盘帧、翻历史都会改变尾部，每次都重新计时 800ms → 6 次/分钟额度被抖动耗光。 |
| 表情包、头像、图片里的小字混进消息 | 只有行高启发式（`< 0.62/0.72 × 正文行高`）过滤，没有区域级的“这是一张图”的判断；图片区域不占位，里面的文字仍可能组成气泡。 |
| 疑似：PiP 未被排除 | 截图中 PiP 是 “Jarvis · …” 文字横幅，而 `AppFrameExclusion` 需要同时找到 `Galchat` + `AI估计` + `好感度` 三个锚点。如果这就是当前 PiP，它不会被排除，还盖住了导航栏标题（标题为 nil → 回到聊天页时会被当成新会话）。**需确认。** |

总结：**缺少“这一帧有没有带来新东西”的判断**。现在每一帧都同时驱动文字合并、长图和分析；消息身份依赖不稳定的 OCR 文字；分析触发依赖文字。

## 1. 目标管线

```
Visyn 帧
  │
  ① FrameGate（OCR 前，廉价）          稳定性：静止 / 运动中 / 刚稳定
  │  只有“刚稳定”的帧继续
  ② OCR(top-3 候选) + 版式 + [目标检测]
  │
  ③ ViewportTracker                   键盘/输入栏/内容区变化 → viewportOnly
  │
  ④ TranscriptLedger（SeeU）          按几何槽位确定身份，文字靠投票，带状态机
  │
  ⑤ ChangeClassifier                  none / viewportOnly / historyBackfill /
  │                                   newTail / correction / unaligned / switch
  ├──► ⑥a LongScreenshotCommitPolicy  只提交带来新覆盖范围的稳定帧
  │
  └──► ⑥b MessageEventBatcher（App）  防抖窗口，把连发消息合成一批
         │
         ⑦ SemanticGate               只在“确认是正确聊天记录 + 有新消息”时放行
         │
         ⑧ ContextBuilder             完整上下文 + 联系人档案 + 最近会话 → Judge/Reply
```

原则：**长图、文字账本、语义分析三者各自有提交门槛**，不能再是“帧到了就全部更新”。

## 2. 各阶段设计

### ① FrameGate（SeeU，OCR 之前）
- 每帧生成 64×140 灰度缩略图，与上一帧比较平均差 `d`。
- 状态：`identical`（d < ε₁）→ 不跑 OCR，只调用 `confirmStable()` 增加观察次数（`framesSkipped` 字段已有但目前没用上）；`moving`（d > ε₂）→ 丢弃，等待；`settled`（从 moving 回到 d < ε₂ 并连续 2 帧）→ 放行。
- 效果：键盘滑入动画、滚动惯性、气泡弹出动画这类中间帧不再进入识别；OCR 次数也会明显减少。
- 例外：连续 1.5s 都处于 moving（视频、GIF 表情）时，按内容区之外的区域重新判断，避免一直不出结果。

### ③ ViewportTracker
维护 `Viewport { keyboardVisible, contentTop, contentBottom, inputBarTop }`。
- 键盘状态或 contentBottom 变化超过 5% H → 这一帧标记为 `viewportChanged`。
- `viewportChanged` 帧**只能**：用图像位移更新已有条目的观察次数、确认位置。
- **不能**：新建条目（除非位置在已知实时尾部 `coveredBottom` 以下，即真的来了新消息）、提交长图条带、触发语义。

### ④ TranscriptLedger（替换 `ChatStitcher.merge` 的身份逻辑）

**身份由几何槽位决定，不由文字决定。**
- 槽位键：`(segment, side, top ± tol, 气泡宽度 ± 15%, 气泡颜色)`。在同一槽位看到的就是同一条消息，不管 OCR 读成什么。
- 只有气泡高度变化超过 30%，或颜色/方向变了，才认为槽位上换了一条消息。
- 已有的两条条目重叠在同一槽位时 → 合并，保留得分高的文字，来源证据合并。

**文字靠多帧投票 + 合理性打分。**
- OCR 改为取 `topCandidates(3)`，每个候选带 confidence。
- 候选得分 = Σ(置信度 × 完整度(未裁切=1, 裁切=0.4) × 帧权重) + 合理性加分。
- 合理性（通用规则，不针对单条消息）：
  1. **字数与气泡宽度是否一致**：CJK 字宽 ≈ 正文行高，预期字数 ≈ 行宽/字宽。`口合口合口合口合` 8 字塞进 4 字宽的气泡 → 重罚。这一条最有效。
  2. **偏旁拆字表**：`口合→哈、口阿→啊、口尼→呢、口马→吗、口巴→吧、口那→哪、口恩→嗯、口屋→喔、口斤→听…`。匹配时先规范化成合字形式再比较（所以 `口合口合哈哈` 与 `哈哈哈哈` 相似度为 1）；原文里含拆字模式的候选扣分。
  3. 候选之间互为子串/前缀时，优先完整的那一个。
- **滞回**：显示文字只有在挑战者得分 > 当前得分 × 1.3，且在 ≥ 2 个稳定帧中出现后才切换，切换时发出 `corrected` 事件。不会来回跳。

**条目状态机。**
```
provisional ──(≥2 个稳定帧看到，或 1 帧且置信度≥0.9且合理)──► stable
stable ──(1.5s 内文字没再变)──► committed
任意状态 ──(槽位可见且未裁切的 ≥3 个稳定帧里，匹配率 < 30%)──► retracted（删除）
```
只有 `committed` 的消息才会交给语义层；`provisional` 只用于界面展示（灰色显示）。

### ⑤ ChangeClassifier（SeeU 输出新增字段）
每个稳定帧输出一个 `SeeUChange`：
```swift
enum SeeUChange {
    case none
    case viewportOnly                       // 键盘/输入栏变化
    case historyBackfill(ids: [UUID])       // 往上翻补历史
    case newTail(ids: [UUID])               // 实时尾部下方出现新条目
    case corrected(ids: [UUID])             // 文字投票结果改变
    case retracted(ids: [UUID])
    case unaligned                          // 接不上，另起段
    case conversationSwitch
}
```
`newTail` 只由 `committed` 条目产生，并且要求位置在上一次实时尾部以下。

### ⑥a LongScreenshotCommitPolicy
在 `LiveChatCoordinator` 调用 `images.ingest` 之前（或 SeeU 的 `LongScreenshotStore` 内部）判断：
- 帧必须是 `settled`，且 change ∉ {`viewportOnly`, `none`, `corrected`}；
- **必须带来新覆盖**：`frameTop+offset < ladder.top − minNew` 或 `frameBottom+offset > ladder.bottom + minNew`，其中 `minNew = max(0.5 × 正文行高, 24px)`；
- 定位证据要可靠：文字和图像位移互相印证（`lastOffsetCorroborated`），或者是新段且已有 ≥ 2 条 committed 消息；
- 覆盖范围相同时，优先保留无键盘的帧（内容区更大）；键盘帧不能替换已有条带。

键盘弹起时内容上推，覆盖范围不会超过现有底边，所以这类帧天然会被跳过。

### ⑥b MessageEventBatcher（Galchat，新文件 `Live/Analysis/MessageEventBatcher.swift`）
- 输入：Ledger 的 change 事件。
- **对方** `newTail` → 开一个批次；静默窗口 2.5s（每来一条新消息就重新计时），最长 10s 强制提交。对方连发 5 条只会分析一次。
- **我方** `newTail` → 立即作废在途的建议（说明用户已经回复了），更新上下文，默认不触发 Judge（可配置）。
- `historyBackfill` → 只更新上下文；沿用现有 `considerRefresh` 的“补上下文”逻辑。
- `corrected` → 如果消息在未提交的批次里，静默更新；如果已经分析过，只有当它是**最后一条对方消息**、且规范化后编辑距离 > 0.5（排除拆字类差异）时才重新分析，每条最多一次。
- `viewportOnly / none / unaligned` → 什么都不做。
- **触发键改为 `(conversationID, 最后一条 committed 对方消息的 id)`**，不再包含文字。OCR 读法变化不会再重新触发。

### ⑦ SemanticGate
全部满足才放行，否则 PiP 显示“等待确认：<原因>”：
1. `detection == .chat && confirmed`；
2. 会话身份稳定：标题 ≥ 2 帧一致，且联系人已绑定或标题可信（`ContactMatcher.isTrusted`）；
3. `viewingLiveTail == true`（用户不是在翻历史）；
4. 尾部段已在链上（`currentContextIsIsolated == false`）；
5. 批次非空，而且批次里全是 `committed` 消息；
6. 通过速率限制。额度改为按“批次”计算，不再按“尾部变化”计算。

### ⑧ ContextBuilder（替换 `makeContext` 的拼装）
发给模型的内容：
- **完整上下文**：按链顺序最近 N 条（`contextMessageCount`），本批次的新消息无论如何都要包含；缺口、引用、表情包含义保持现在的标注；每条都带稳定 id，重复识别不会产生重复消息。
- **明确分区**：`【历史】…` / `【本轮新消息】…`，让模型知道要回应的是哪几条。
- **联系人档案**：沿用 `AnalysisModelContext.relationship`（名字、备注、人设、好感度）。
- **最近会话**：从 `RecentConversationStore` 取同一联系人之前会话的最后 K 条或摘要，标注为“往期记录，非当前屏幕”。
- **联系人未确认时**：附上最近联系人候选列表（名字/别名），只用于辅助判断身份，不作为事实。
- 清洗：`provisional`/`retracted` 条目、低于合理性阈值的文字不进入上下文；`clipped` 继续标注。

## 3. 目标检测（表情包 / 头像 / 键盘）

**阶段 A：启发式（现在就做，不依赖模型）**
- `ChatImageDetector` 找到的 avatar/sticker/photo 区域**在账本里占一个槽位**（`kind = .media`）：区域内的 OCR 行全部丢弃，表情包按槽位锚定到前后消息，也就不会再被当成文字气泡。
- 键盘：`Jarvis 键盘` 锚点 + 系统键盘按键行 + 输入栏颜色带，三者任一命中都算；contentBottom 取最保守的值。

**阶段 B：Core ML 检测器（实现已有的 `SeeUImageDetector` 协议，并新增 `SeeULayoutDetector`）**
- 类别：`avatar, sticker, photo, bubble_me, bubble_other, time, system_notice, quote, voice, card(链接/转账/红包), keyboard, input_bar, nav_bar, overlay(PiP/通知横幅)`。
- 模型：YOLO 系列 nano 导出 Core ML（约 6MB，640px 输入，ANE 上约 10–20ms），只在 `settled` 帧上运行。
- 检测结果直接接管：keyboard/input_bar → contentBottom；overlay → 排除区域（不再依赖 PiP 文案，改文案也不会失效）；sticker/photo → 媒体槽位；bubble_* → 方向判断的强证据。
- 训练数据来自下面的回放工具录下的真实帧。

## 4. 回放测试工具（先于算法改动）
真实场景的问题靠单元测试复现不了，需要：
- Debug 开关：把 `settled` 帧（JPEG + 时间戳 + 排除策略快照）写入 App Group 目录，可导出。
- SeeU 增加 `ReplayTests`：按原时间序列喂给引擎，断言最终账本和事件序列。
- 回放场景：键盘弹出/收起且无新消息、对方连发 5 条、“哈哈”抖动、翻历史再回到底部、整屏表情包、切换聊天、PiP 遮挡标题。
- 指标：每分钟误触发次数、同槽位重复条目数、长图条带数、从新消息出现到分析开始的延迟。

## 5. 分阶段落地

| 阶段 | 内容 | 风险 |
|---|---|---|
| P0 速效 | 触发键改为消息 id；长图“无新覆盖不提交”；同槽位条目合并；Batcher 静默窗口；确认并修复 PiP 排除 | 低，主要是 App 层与 Store 层 |
| P1 | 回放工具；FrameGate；Ledger 状态机；OCR top-3 + 合理性打分 + 滞回；ChangeClassifier | 中，改动 SeeU 核心合并逻辑 |
| P2 | SemanticGate + ContextBuilder（分区、联系人、最近会话）；纠错重分析策略 | 低–中 |
| P3 | Core ML 版式检测器与数据标注 | 需要数据与训练 |

## 6. 已确认的决策（2026-09-27）
1. 我方发出新消息后**也触发**一次 Judge（与对方消息走同一批处理窗口）。
2. “最近联系人”两者都要：当前联系人的往期会话 + 联系人未确认时的最近联系人候选。
3. 批处理窗口：静默 2.5s，最长 10s。
4. 截图中的 “Jarvis ·” 文字横幅是旧版画中画，`AppFrameExclusion` 不需要改。
5. SeeU JSON 允许升级到 schemaVersion 2（P1 引入 `change` 与条目 `status`）。

## 7. 进度

### P0 已完成（未提交）
SeeU：
- `TextMatch`：口字旁拆字折叠（“口合口合哈哈” ≡ “哈哈哈哈”）；按行宽证据修复拆字原文（`repairSplitRadicals`，版式解析时逐行调用）。
- `TranscriptEntry.observe`：读法投票加滞回（挑战者 ≥2 票且 > 当前 1.5 倍才切换），同一规范化文字优先保留不含拆字的原文。
- `ChatStitcher`：文字对不上时按槽位（方向、位置、高度、横向重合）认同一条消息；缺席次数 ≥3 且 ≥ 观察次数即删除误识别条目；同一位置重叠的条目合并（`collapseOverlapping`）；合段去重同样按槽位。
- `ChatSessionEngine`：当前屏与历史条目按槽位兜底匹配，避免 OCR 抖动让上下文变成“孤立段”；当前屏文字使用投票结果。
- `isViewingLiveTail`：最新一条只要仍在可见区即可（键盘弹起、被输入栏压住半截都算）。
- 长图：`ChatLadder.add` / `LongScreenshotStore.ingest` 只接受至少补上 max(24px, 半行) 新区域的帧，键盘帧、静止帧、抖动帧不再加入；返回是否加入。
- 键盘：从键盘顶部向上按色带找输入栏顶部（跳过键盘薄边），不再用固定 0.045H；用真实截图验证输入栏顶部 1103px，末条“…立绘的功能”不再被裁掉。
- 测试：`TranscriptStabilityTests`（8 项）；`ReplayTests`（设置 `TEST_RUNNER_SEEU_REPLAY_DIR` 时回放真实帧，输出 `replay-report.txt` / `replay-long.jpg`）。

Galchat：
- `ConversationContext.tailSignature` 只含 id + 发言方；新增 `tailText`、`isLiveTail`、`isIsolated`、`semanticHoldReason`。
- `LiveAnalysisScheduler`：语义闸门（未确认 / 未对齐 / 翻历史时不调用模型也不作废结论）；2.5s/10s 批处理；已分析过的尾部不重复分析；同一条消息文字被大幅纠正（相似度 < 0.5）时最多重分析一次。
- `RecentConversationStore`：未对齐的单屏不落盘；夹在上下文首尾之间却已被 SeeU 删除/合并的误识别消息从存档移除（用户纠正过的保留）。
- `FrameRecorder` + 实时会话页“录制识别帧（调试）”开关，帧与遮挡旁注写入 Documents/SeeUReplay，可在“文件”App / Finder 导出。

### 下一步
- P1：FrameGate（缩略图稳定性）、条目状态机与 `SeeUChange`、OCR top-3 候选、schemaVersion 2。
- P2：ContextBuilder（【历史】/【本轮新消息】分区、往期会话、最近联系人候选）。
- P3：Core ML 版式检测。
