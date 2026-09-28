# 实时识别的维护手册

> 面向长期维护。讲清楚**数据怎么流、哪些不变量不能被破坏、出问题怎么定位**。
> 改动识别相关的代码前先读这一份。
>
> 涉及的仓库：`SeeU`（截图 → 对话，本目录的 `../SeeU`）和 Galchat `Live/`（采集、闸门、联系人、分析）。

---

## 1. 一句话模型

**SeeU 负责"这一屏是什么"，Galchat 负责"这个人是谁、这条要不要分析"。**

两个仓库的职责边界不要混：识别精度问题改 SeeU，联系人和分析时机问题改 Galchat。历史上很多 bug 是因为两边都想管会话身份。

---

## 2. 数据流（每一帧）

```
录屏帧（Visyn）
  │
  │  Galchat: LiveChatCoordinator.receive/pump
  │  ・只保留最新一帧（pending 单槽位），OCR 慢时丢帧
  │  ・FrameRecorder 可录制原始帧供回放
  ▼
SeeU: ChatSessionEngine.process(jpeg:…)
  ├ ChatLayoutParser.parse
  │   找标题行、气泡、键盘、输入栏；给"像不像聊天页"打分
  │   产出 ParsedChatFrame（isChat / title / bubbles / contentTop / contentBottom / occluders）
  ├ 会话身份判定           ← 最容易出问题的地方，见 §3
  ├ ChatStitcher.ingest
  │   把这一屏拼进"片段"(segment)；片段按新旧串成"链"(chain)
  │   有重叠 → extended；认回旧段 → rejoined；接不上 → newSegment
  │   产出 StitchPlacement（kind / offset / scrollDelta / segmentID）
  └ makeUpdate
      只取 textConfirmed 的条目组成上下文；产出 EngineUpdate
  ▼
Galchat: LiveChatCoordinator.installContext
  ├ 认联系人（标题匹配 → 档案绑定）
  ├ RecentConversationStore 落盘会话记录
  └ LiveAnalysisScheduler.update  ← 闸门 + 防抖 + 6 次/分钟额度
      ▼
    JudgeClient → AffectionCommitter（计分）→ PiP / 键盘候选
```

### 四个核心概念

| 概念 | 在哪里 | 含义 |
|---|---|---|
| `conversationID` | `ChatSessionEngine` | 会话身份。**由规范化标题映射而来，不是随机 UUID**（见 §3）。上层按 `sessionID:conversationID` 存记录归属和联系人绑定 |
| `textConfirmed` | `ChatStitcher.merge` | 条目被确认后才会进入上下文。规则：未被裁切，或位置由文字证据给出，或**同槽位看到 ≥2 次** |
| `isolated` | `ChatSessionEngine.makeUpdate` | 当前屏的最后一条不在已确认的上下文里 → 上下文塌缩成这一屏，标记未对齐 |
| `semanticHoldReason` | `ConversationContext` | Galchat 侧闸门：未确认聊天页 / 未对齐 / 在翻历史 → 不调用模型 |

---

## 3. 必须守住的不变量

这几条是踩过坑之后定下来的。破坏任何一条，用户会立刻感觉到"联系人乱跳""好感度重算""不出结果"。

### 3.1 会话身份按标题稳定映射，不随机生成

`ChatSessionEngine.identity(for:)`。同一个标题永远得到同一个 `conversationID`，所以 A→B→A 切回来还是原来的 id。

**为什么**：换录屏时只有 `sessionID` 变，会话身份必须稳定，否则 Galchat 里 `RecentConversationStore` 查不到归属，退回标题匹配，匹配不上就自动建新档案，好感度从初始值重算。

只记最近 8 个会话（`rememberedConversations`），被淘汰的会话连同它的片段一起回收（`keepSegments`）。

**破坏方式**：把 `identity(for:)` 改回 `UUID()`；或者在会话切换时调 `resetConversation()`（那会清空拼接器，历史全丢）。

### 3.2 切换会话不重置拼接器

`startConversation` 与 `resetConversation` 现在是两件事：

- `startConversation`：换身份，**保留** `stitcher.segments`，切回来能 rejoin；
- `resetConversation`：真正重新开始（改帧尺寸、`clear()`、见过一次就闪走的未确认会话）。

**为什么**：`ChatStitcher` 本来就有多片段并存和 `bestOtherSegment` 重连，切走时丢掉是浪费，也是"A 聊到一半切 B 再切回来历史没了"的根因。

### 3.3 看不清的帧不改状态

Galchat `LiveChatCoordinator.pump`：只有 `update.detection == .chat` 的帧才走 `installContext` + `scheduler.update`。

**为什么**：键盘过渡帧、弹窗、整屏图片都会让 `makeContext` 返回 nil，而 `installContext(nil)` 会清联系人、`scheduler.update(nil)` 会作废结论。识别失败路径同理，只报告错误。

真实换聊天由 SeeU 给出的新 `conversationID` 表达，不需要靠"这一帧没看清"触发。

### 3.4 标题切换要连续两帧，但那一帧的内容不能丢

`ChatSessionEngine` 的标题分支。确认不够两帧时**照常按原会话拼接**，只是暂不换身份。

**为什么**：原来那一帧直接 `return .waiting` 并清空 `currentMessages`。实测在真实截图数据集上，这一条让 `wait` 帧从 18 降到 7、识别到的聊天页从 13 升到 26。这也是"画面一抖结果就清空"的一个独立来源。

计数用 `TextMatch.similarity >= 0.75` 累加，**不要改回字符串全等**：OCR 把同一标题读成两种写法时全等会让计数每帧归零，会话永远切不过去。

### 3.5 被裁切的消息同槽位两次即确认

`ChatStitcher.merge` 里 `!entry.clipped || textBacked || entry.observations >= 2`。

**为什么**：贴着输入栏的最后一条永远拿不到文字佐证（它是裁切的），此前会一直不确认 → 上下文塌缩 → "我发完最后一句却迟迟不出结果"。

注意 `ponytail:` 注释：如果回放里出现图片小字混进上下文，给 `clipped` 补一个文字相似度门槛。

### 3.6 聊天页必须有底部输入栏（带逃生口）

`ChatLayoutParser` 的打分处：`!bottomDetected && !strongLayout` 时直接判为非聊天页。

**为什么**：邮件详情、设置页、行情页都能凑够气泡数和留白分，但都没有贴底输入栏。

`strongLayout`（两侧分侧 + 有标题 + ≥10 条消息 + 边缘比 ≤0.15）是为 TEAMBOOM 这类**输入栏半透明压在壁纸/图片上**的 App 留的逃生口，`detectInputBarTop` 在那种画面上找不到纯色边界。阈值是从真实截图实测出来的，改动前先跑 §5 的探针。

---

## 4. 已知限制与风险

| 限制 | 说明 | 什么情况下要处理 |
|---|---|---|
| **孤立段的误识别清理在截图数据集上不生效** | 「骑手订单页」被误判为聊天页时，因为它能读出画面文字，会被算进上一个会话。真实录屏里这类画面只出现 1~2 帧，会被 `misses >= 3 && misses >= observations` 清掉；数据集每张图只出现一次，清理不触发 | 若真实录屏里也出现长时间停留的"像聊天页的其它 App 页面"，需要给 `segmentOwner` 加重复核：`rejoin` 认回旧段时核对归属 |
| **标题读不出来时的归属** | 沿用原会话。若确实切到了新聊天、但标题一直读不出来，内容会成为孤立段（不分析、不计分、不写记录） | 标题始终读不出的 App |
| **输入栏逃生的阈值是按本案数据调的** | `edgeRatio <= 0.15`、`messages.count >= 10` 来自这一批截图 | 换 App / 换机型后误判变多时，用 §5 的探针重量 |
| **`hasReliableSingleFrameEvidence` 不再参与标题切换** | 单帧证据充分也不再立刻切会话，必须两帧 | 如果某些 App 切聊天后只稳定一帧，需要给它单独放宽 |
| **`ImageAligner` 的 offset 符号** | 实测：内容下移 280px 时返回 `offset = -280`，而它的注释写「当前图 y + offset = 上一图 y」。`scrollDelta` 的约定是"正 = 在看更新的消息"。两者靠实测对齐，没有定论 | 如果回放里发现向上翻历史被接到链的更新一端，查这里 |

---

## 5. 怎么定位问题（重点）

### 5.1 先分层，再动手

看到"识别不准"时，先判断问题在哪一层：

1. **版式层**：画面明明在聊天页，却报 `no(…)`？→ `ChatLayoutParser` 打分。
2. **身份层**：会话 id 在切换；或者同一个聊天出现两个 id？→ `ChatSessionEngine` 会话身份。
3. **内容层**：识别到了但条数不对、有幽灵条目、顺序错？→ `ChatStitcher` 合并与确认。
4. **上层层**：内容对但不出结果、联系人乱跳？→ Galchat 的闸门与联系人解析。

### 5.2 三个现成的工具

> **环境变量都要加 `TEST_RUNNER_` 前缀**：测试代码里读的是不带前缀的名字（`SEEU_DATASET_DIR`），
> 但 xcodebuild 只把带 `TEST_RUNNER_` 前缀的变量传进模拟器里的测试进程。
> 少写这个前缀，测试会静默跳过（报 `skipped` 而不是失败），很容易误以为"跑过了"。

**① 单张图探针**（改版式打分前必用）

临时在 `Tests/SeeUTests/Recognition/` 放一个探针测试，打印 `parsed.chatScore / rejectReason / title / inputBarVisible / 气泡数 / edgeRatio`，
用 `TEST_RUNNER_SEEU_PROBE_FILE=<图路径>` 跑。改完删掉。
`ChatLayoutParser` 里还有一段 `SEEU_LAYOUT_DEBUG` 环境变量控制的打印，需要时可以打开。

**② 截图数据集回归**（改了版式或确认规则后跑）

```bash
cd ../SeeU && TEST_RUNNER_SEEU_DATASET_DIR=/path/to/截图集 \
  xcodebuild test -scheme SeeU \
  -destination 'platform=iOS Simulator,id=<模拟器 id>' \
  -only-testing:SeeUTests/DatasetTests
```

`xcrun simctl list devices | grep -i iphone` 拿 id。报告写到数据集目录的 `dataset-report.txt`，
逐图一行：`识别结果 conv=会话id title=标题 当前=n 上下文=n iso= live= 拼接方式 尾部文字`。

**看什么**：
- `conv=` 是否只按真实聊天分组（同标题必须同 id）；
- `wait` 帧（是聊天页但没读到内容）多不多；
- `no(…)` 的拒绝原因合不合理；
- 同一会话的 `当前=` 有没有突然归零。

注意：数据集是**离散截图**，不是连续录屏，所以 `iso=y` 很常见、误识别不会被清理，这两个现象在真实录屏里轻得多。不要照着数据集的绝对数字调参。

**③ 真实录屏回放**（验证时序相关的改动，唯一可靠手段）

App 里打开"录制识别帧"，复现问题，导出 `Documents/SeeUReplay/<时间戳>/`，然后：

```bash
cd ../SeeU && TEST_RUNNER_SEEU_REPLAY_DIR=/path/to/那一目录 \
  xcodebuild test -scheme SeeU -destination 'platform=iOS Simulator,id=<id>' \
  -only-testing:SeeUTests/ReplayTests
```

输出 `replay-report.txt` 与 `replay-long.jpg`。日志每帧带 `conv=`（会话 id 前 4 位）、
`place=`（ext / rej / NEW-SEG）、`live=`、`iso=`、`ctx=`、尾部文字。

**这类改动必须用真实录屏验证**：丢帧（帧间隔超过 3 秒的连续性窗口）和"文字与画面都对不上"
这两个条件，合成帧构造不出来。

### 5.3 合成帧测不出什么

`TranscriptStabilityTests` 里的合成帧能测合并规则、确认规则、清理规则。但**测不出**：

- `startSegment` 的"新段继承滚动方向"——真实触发靠丢帧；合成帧里拼接器几乎总会用文字或槽位把帧认回去；
- 视觉位移导致的片段断开——合成位图容易被对齐器在错误偏移上匹配成功。

这类路径不要硬造测试夹具（试过，五轮都没成），交给真实录屏回放。

---

## 6. 改动的验证清单

改识别相关代码后，按顺序跑：

1. `cd ../SeeU && xcodebuild -scheme SeeU -destination 'generic/platform=iOS' build` —— 编译；
2. 全量测试：`-only-testing:SeeUTests`（43 项，含 3 项需环境变量、默认跳过）；
   其中 `DatasetTests` 会跑 59 张图的 OCR，整轮约 2 分钟，其余测试不到 1 秒。
3. 数据集回归：上面的 `DatasetTests`，对比 `dataset-report.txt` 的会话分布与拒绝原因；
4. Galchat 编译：`xcodebuild -scheme Galchat -destination 'generic/platform=iOS' build`；
5. 涉及时序的改动（会话切换、丢帧、键盘、画中画）：真机 + 录屏回放。

---

## 7. 常见症状 → 先查哪里

| 症状 | 先查 |
|---|---|
| 联系人丢失、好感度重算 | Galchat `installContext` / `AffectionProjectionPublisher.resolveContact`；SeeU 的 `identity(for:)` 是否在乱变 |
| 稍一滑动结果就清空 | Galchat `pump` 的 `detection == .chat` 守卫是否还在；`scheduler.update(nil)` 有没有被重新加回来 |
| 我发完最后一句不出结果 | 上下文的尾部是否 `textConfirmed`（§3.5）；`semanticHoldReason` 卡在哪一条；每分钟 6 次的额度是否被抖动耗光 |
| 向上翻历史拼不进来 | 是否走成 `newSegment` 且方向丢失（§5.3，需回放）；`textConfirmed` 是否一直不成立 |
| 别的 App 画面被当成聊天页 | `ChatLayoutParser` 的输入栏否决与 `strongLayout`（§3.6） |
| 画面一抖就重置 | 标题两帧确认那一帧是否又在丢弃内容（§3.4） |

---

## 8. 下一步（按性价比）

1. **`rejoin` 时核对片段归属**：`segmentOwner` 已经记了"片段归哪个会话"，但 `rejoin` 还没用它做否决。这是目前"误判页面被算进上一个会话"的唯一残留路径。
2. **每个片段带上归属，按会话分别组装上下文**：现在是只组装当前会话的上下文。如果要做"在 A 里也能看到 B 的最新消息"这类功能，需要这一步。
3. **确认规则的第二道门槛**：`observations >= 2` 放行了被裁切的条目，如果回放里出现图片小字混入上下文，给 `clipped` 加文字相似度门槛（代码里已标 `ponytail:`）。
4. **`ImageAligner` 的 offset 符号**：见 §4，等回放给出证据再定。
