# Jarvis iOS 业务架构设计

> 文档状态：设计稿
>
> 资料核对日期：2026-09-22。系统版本、SDK 和库实现均为此次核对的快照，实施时需复核。
>
> 适用范围：`jev-chat-jarvis-ios`、本地 `Visyn` Swift Package，以及安卓参考项目 `jev-chat-jarvis`
>
> 本文同时保留原始设计基线和后续实现说明。BYOK、OCR、实时分析、画中画和键盘已有代码；2026-09-24 更新离线全拼键盘及候选状态链路，尚需按 `docs/keyboard-validation.md` 完成 Xcode/真机验收。

> 2026-09-25 框架拆分：OCR、消息合并与长图实现迁入 `../SeeU`；BYOK 凭据、模型协议与 Alamofire 传输迁入 `../Synapse`。Jev 业务题、情绪解释、候选策略和扩展发布保留在 App，联系人/Realm/人设不进入两个库。当前边界与迁移说明见 [框架拆分说明](package-extraction.md)。以下未更新的阶段计划属于历史设计，不代表当前实现或已完成验证。

## 1. 目标与平台边界

Jarvis iOS 的目标是：用户在聊天 App 中阅读消息时，授权 Jarvis 采集屏幕，识别当前会话，生成三条候选回复，并通过 Jarvis 键盘让用户选择一条插入当前输入框。消息最终仍由用户检查和发送。

安卓参考项目的实际链路是“无障碍节点采集或单次截图 OCR → 消息序列合并 → Jev 判断 → 回复生成与排序”。它不是连续录屏后拼接成长图。iOS 应继承消息模型和模型协议，重写采集、OCR、浮窗和文本填入部分。

### 1.1 可以实现的能力

- 通过 ReplayKit/Visyn（旧系统）或 ScreenCaptureKit（新系统）取得用户明确授权的屏幕帧。
- 使用 Apple Vision 在本地识别中文和英文文字。
- 根据文字块、位置、时间和重叠关系合并连续屏幕中的聊天消息。
- 使用三条独立的 BYOK 模型路线：Jev 判断、回复生成、可选的云视觉补充。
- 使用 Visyn PiP 显示只读的摘要、状态和一条推荐结果。
- 提供 Jarvis 自定义中文键盘，顶部横排三个回复候选，下方保留离线拼音、英文、数字和符号输入。

### 1.2 不可按安卓方式实现的能力

- 不能通过公开 iOS API 读取微信、飞书等其他 App 的无障碍节点树。
- 不能可靠获得当前前台 App 的包名、联系人或聊天窗口标识。
- 不能替其他 App 自动滚动、点击发送按钮或调用类似 Android `ACTION_SET_TEXT` 的无障碍动作。
- 不能把候选回复写入 Apple 系统键盘或搜狗等其他输入法的 QuickType 候选栏。Jarvis 键盘只能自己绘制候选区。
- PiP 内容是视频像素，不是可交互的安卓式悬浮窗；候选选择和复制放在 Jarvis 键盘或主 App。

## 2. 当前工程事实

| 项目 | 当前情况 | 设计影响 |
|---|---|---|
| 主 App | `LiveChatCoordinator` 连接 Visyn、SeeU、分析调度与键盘发布 | App 负责采集生命周期、业务策略与 UI |
| 广播扩展 | `GalchatBroadcastExtension/SampleHandler.swift` 是空子类 | 第一版保持 Visyn 传输职责，业务不放在扩展中 |
| Visyn 帧 | 单槽、每约 0.3 秒最多一帧，长边 1280，JPEG 质量 0.7 | 是抽样帧，不是完整录像或可靠的滚动历史 |
| Visyn 接收 | `onFrame` 在主线程回调，消费后删除共享帧 | 回调必须立即交给后台有界流水线，键盘不能读取该邮箱 |
| PiP | UIView 按可配置宽高以 2 倍像素光栅化，默认 414×80 点，内容不可点击 | PiP 只放短摘要和状态；OCR 遮挡区域随尺寸更新 |
| 共享能力 | 主 App 和广播扩展已有 App Group | 可增加独立的键盘共享结果文件 |
| 密钥 | Synapse 提供凭据存取，App 兼容既有 UserDefaults 存储键 | 保持现有存储策略；Keychain 是后续显式迁移选项 |
| 最低版本 | 主 App 为 iOS 16.6，广播扩展为 iOS 26.5 | 开始实现前必须决定统一支持版本并修正工程配置 |
| 工具链 | 当前本机 iPhoneOS SDK 为 26.0 | iOS 27 的 ScreenCaptureKit 路线需升级 Xcode/SDK 后才能编译 |

现有 Visyn 相关实现和配置不要承担业务协议。业务结果使用独立文件命名空间，避免破坏 Visyn 的单槽消费、过期清理和帧校验行为。

## 3. 总体架构

```mermaid
flowchart LR
    U[用户授权与选择会话] --> C[ScreenCaptureProvider]
    C --> F[FramePipeline]
    F --> O[ChatFrameRecognizer: 单屏 OCR]
    O --> A[ChatSessionEngine: 当前文字和可用历史]
    A --> S[ConversationContext: 纯文字输入]
    A --> L[LongScreenshotStore: 独立图片存档]
    S --> J[LiveAnalysisScheduler: Jev 判断]
    S --> R[ReplySuggestionScheduler: 生成和排序]
    J --> H[主 App 判断区]
    J --> I[PiP 情绪与意图]
    R --> K[ReplyBundlePublisher: 键盘共享文件]
    K --> W[Jarvis Keyboard Extension]
    W --> X[textDocumentProxy.insertText]
    X --> Y[用户检查并发送]
```

### 3.1 模块职责

2026-09-24 业务拆分：`ChatFrameRecognizer` 负责 JPEG 解码、Vision、区域排除与版式；`ChatSessionEngine` 负责会话及文本历史匹配，输出当前屏可读消息和可用历史，裁切消息带提示直接进入纯文本上下文，不再被 `textConfirmed`/观察次数无限阻塞。图片的 `ChatLadder`、JPEG 编码和导出全部移入独立 `LongScreenshotStore` actor。协调器先分发文字，再提交有界图片单槽；图片可被更新帧替代，段合并的坐标迁移事件独立累计，不随图片丢弃。

Jev 与回复候选分别维护状态和请求。Jev 完成直接更新 PiP，候选生成和排序完成直接发布键盘，两者不互等；只有同一次请求、同一上下文版本时才给候选附加判断摘要。实时会话页分别展示当前 OCR、长图存档、Jev、候选状态。下列旧架构名为职责参考，以当前具体类型为准。

```text
CaptureSessionCoordinator
├── ScreenCaptureProvider
│   ├── VisynReplayKitProvider       // iOS 16.6–26.x 兼容路线
│   └── ScreenCaptureKitProvider     // iOS 27+，运行时可用性判断
├── FramePipeline                    // 限频、背压、去重、前景/键盘区域策略
├── VisionOCRService                 // VNRecognizeTextRequest，本地处理
├── ChatLayoutParser                 // 标题、气泡、输入区、时间和版式
├── ConversationAssembler            // 跨帧重叠合并与会话隔离
└── AnalysisCoordinator              // Jev 判断、回复生成、排序和取消

Storage
├── KeychainSecretStore              // API Key，只在主 App 使用
├── UserDefaults/App Group config    // 非敏感配置和键盘状态
├── ConversationStore                // 可选的本地历史，默认关闭
└── ReplyBundleStore                 // 键盘只读的短期候选结果

Presentation
├── MainAppViewController            // 设置、状态、识别结果、复制
├── VisynPictureInPicturePresenter   // 只读摘要
└── JarvisKeyboardViewController     // 三个回复候选、离线拼音和普通输入
```

每层只处理一种责任。主 App 页面不直接调用 Vision 或模型网络；键盘扩展不读取屏幕帧、不持有 API Key、不执行 OCR。上述名称表示职责边界，不要求每项都创建独立框架或协议；判断与排序共用 `JevJudgeClient`，不引入数据库或向量检索。键盘的拼音选词使用随扩展打包的本地词库。

当前 Visyn 的 PiP presenter 是库内部实现。第一阶段通过已有 controller 使用；为 ScreenCaptureKit 接入独立 PiP 时，再给 Visyn 增加公开呈现入口，不能直接调用其内部类型。

## 4. 屏幕采集后端

### 4.1 统一输入契约

```text
ScreenCaptureProvider（职责草案，实施时按后端能力定义具体 Swift 类型）
  state / onStateChange   真实采集状态
  onFrame                屏幕帧回调
  prepare                配置授权入口和后端
  presentPermissionUI    由用户完成系统授权
  requestStop            请求停止；完成与取消由真实系统回调确认
```

当前 Visyn 的开始与停止通过系统广播面板确认；不能把包装层的停止请求描述为立即、静默结束系统录屏。业务可以先暂停分析并使推荐失效，再等待广播状态变化。

`CapturedFrame` 至少包含：

```text
sessionID       当前采集会话
frameID         单帧唯一标识
capturedAt      采集时间
image           仅在处理流水线中短暂持有
pixelSize       原始像素尺寸
orientation     方向信息
source          visyn 或 screencapturekit
```

### 4.2 旧系统路线：Visyn/ReplayKit

在 iOS 16.6–26.x 路线中复用当前 Visyn：

```text
ReplayKit Broadcast Extension
  → VisynBroadcastSampleHandler
  → App Group 单帧邮箱
  → VisynCaptureController.onFrame
  → FramePipeline
```

约束：

- 帧被限频、JPEG 压缩并且最多保留一个未消费帧。
- 主 App 挂起期间，Darwin 通知不能唤醒主 App；不能承诺补回中间历史。
- PiP 活跃不等于主 App 永久后台运行。
- 不把完整 OCR 或 LLM 请求放进广播扩展。只有在旧系统真机验证证明需要时，才考虑扩展内做受限 OCR 文本缓存，并设置严格的大小和时间上限。

### 4.3 新系统路线：ScreenCaptureKit

iOS 27+ 可增加独立的 `ScreenCaptureKitProvider`：

```text
SCContentSharingPicker
  → SCStream
  → screen stream output
  → FramePipeline
```

使用 `@available(iOS 27.0, *)` 和运行时 `if #available` 隔离新实现。主 App 不必为持续采集依赖 ReplayKit 扩展；`UIBackgroundModes` 的 `screen-capture` 只表示屏幕采集后台模式，不保证任意网络任务永不终止。

统一入口选择：

```text
if iOS 27+:
    已实现并验证 → ScreenCaptureKitProvider
    尚未支持 → 提示此版本实时采集待适配，保留手动文本分析
else（在已验收的系统范围内）:
    VisynReplayKitProvider
```

Apple 当前文档把 `RPSystemBroadcastPickerView` 和 `RPBroadcastSampleHandler` 标记为 iOS 27 起弃用，后者说明为 “No longer supported”。这不等于符号已禁止编译，也不能据此保证旧广播路线在新系统可用。不得在未经验证时自动回退并宣称全功能兼容。

当前本地 SDK 是 26.0，ScreenCaptureKit 新路线只能在升级工具链后实施。两种后端输出相同的 `CapturedFrame`，下游不感知采集来源。业务分层先落实，不为尚不可编译的新 API 提前生成实现文件。

## 5. OCR 与聊天版式识别

### 5.1 Vision OCR

`VisionOCRService` 使用 `VNRecognizeTextRequest`：

- 默认优先 accurate 模式；性能不足时先降采样频率或缩小识别区域。只有当前系统、request revision 和识别级别确认支持目标语言时才切换 fast。
- 根据 `supportedRecognitionLanguages` 的实际结果选择 `zh-Hans`、`zh-Hant` 和 `en-US`，不假设所有级别都支持中文。不要依赖语言纠错修正中文聊天原文。
- 保存识别文字、归一化 bounding box、置信度和 frameID。
- OCR 在后台串行队列或 actor 中执行，不能阻塞 `VisynCaptureController.onFrame`。
- 同时只处理一帧；新帧到来时，如果上一帧仍在处理，只保留最新候选帧。

```text
CapturedFrame
  → 可选裁剪（排除状态栏、输入框、键盘候选区）
  → Vision request
  → [OCRBlock(text, bounds, confidence)]
```

### 5.2 版式解析

OCR 只负责“有哪些文字以及在哪里”，不负责判断谁说的。`ChatLayoutParser` 负责：

- 识别顶部标题和会话标题候选。
- 过滤时间、系统提示、输入框占位符和键盘区域。
- 依据行距、气泡背景、左右边界、头像邻近关系和连续帧位置聚合消息。
- 无法可靠判断发言人时使用 `unknown`，不要把整屏全部归为“对方”。
- 记录解析的不确定性：`layoutConfidence`、`speakerConfidence`、`note`。

第一版目标是微信单聊；具体系统、微信版本、主题和字体大小通过真机验收后才列为支持范围。飞书、群聊、深色主题和横屏需要单独采样。

### 5.3 防止键盘反馈循环

屏幕采集可能包含 Jarvis 键盘。处理流程应：

1. 结合版式和输入区识别键盘区域，不把固定屏幕高度比例当成所有 App 的准确边界。
2. 先按空间区域排除键盘/PiP；候选文字匹配仅作为区域判断的辅助证据，不能在整屏全局过滤相同文字。用户发送后，相同文本成为正式聊天气泡，必须保留。
3. 不把当前输入框草稿直接当作对方新消息。
4. 键盘展开、候选刷新引起布局变化后，等待稳定画面。无法可靠区分区域时暂停自动分析并提示校正。

## 6. 会话与跨屏消息合并

### 6.1 数据模型

```text
ConversationSnapshot
├── sessionID
├── conversationID       用户选择或本地生成的 opaque ID
├── title                OCR/用户确认的标题
├── messages[]
│   ├── messageID        本地稳定 ID，无法稳定识别时允许临时 ID
│   ├── speaker          me | other | unknown
│   ├── text
│   ├── bounds
│   ├── confidence
│   ├── sourceFrameID
│   └── observedAt
├── source                screen | manual
├── revision              每次有效更新递增
└── note                  识别缺口或无法分边说明
```

### 6.2 合并规则

- 同一帧重复出现：不新增消息。
- 当前屏顶部与上一屏尾部有可靠序列重叠：只追加新的尾部。
- 有文字块运动和相邻帧等证据确认向上浏览历史时：有重叠则补入较早位置，无重叠则保存为较早的独立片段，不追加到新消息尾部。仅凭“无重叠”不能判断滚动方向。
- 快速滚动导致没有重叠：保留为独立片段，并标记上下文可能有缺口。
- 标题改变、版式改变或会话置信度下降：创建新的 `conversationID` 或要求用户确认。
- 相同文字出现两次但位置和序列不同：保留两条，不使用全局字符串集合去重。

OCR 小幅误差允许结合多条相邻消息与几何位置对齐；仅一条短消息相同不足以确认重叠。坐标统一到方向归一化后的屏幕坐标，保留裁剪和缩放变换，避免方向变化后错误合并。不能确认当前聊天页或来源联系人时，不发布可直接插入的新推荐。

不要先把所有图片拼成无限长图再交给 OCR。Visyn 会丢帧，图像拼接不可能保证快速滚动时连续；业务目标是稳定的文字消息序列。

长截图（已实现，2026-09-23，按 `/Downloads/聊天记录` 微信样本校准）：

- **对齐只看气泡**：微信聊天背景（含照片壁纸）固定不动，只有气泡滚动，所以不做整行像素匹配。每帧先 OCR，`ChatStitcher` 用多条气泡文字 + 位置投票估计偏移，用同屏其他气泡做几何复核，再在气泡文字区域内做 ±8px 像素微调。
- **会移动的长梯**（`ChatLadder`，默认 10 张，设置里可调 3–30 张，调小立即生效）：每级是一帧内容区。已被其他级首尾相接完整覆盖的旧级删除（停住、小幅来回滑动不占额度）；超出上限时从两端里删掉更旧的一端，梯子保持连续。渲染按采集时间从旧到新覆盖，接缝挪到气泡之间的空隙；标题栏取最新一张识别到标题的帧（跳过被通知横幅遮挡的），输入栏取最底部一级。
- **对话列表**独立于长梯：去重、有序、最多 400 条；时间分隔线保留为 `time` 条目，引用回复挂在被引用下方那条消息的 `quote`。长梯掉出的旧画面，其文字仍在列表里。
- 没有重叠时另起片段，不硬拼；翻回重叠位置时自动合并。长图仅存内存，由用户在实时会话页主动导出。

样本回放结果（5 张真实截图、42 帧合成慢速滑动、容量 3 的移动测试、底部新消息）：28/28 条消息顺序和发言方正确，无重复。

### 6.3 分析版本

每个异步分析任务绑定：

```text
sessionID + conversationID + revision
```

切换联系人、停止采集或产生新 revision 时，取消旧任务；即使取消没有及时生效，也必须在 UI 提交结果和写共享文件前再次校验版本，避免旧结果覆盖新会话。同一内容再次请求使用独立 `analysisRequestID`，防止同 revision 的旧请求覆盖更新后的配置或结果。

## 7. BYOK 与模型服务

### 7.1 三路模型配置

| 路线 | 作用 | 请求形态 |
|---|---|---|
| Judge | 真实意图、危险程度、对方需求、是否应回复、最佳行动、冲突状态、字面提问 | Jev Decisions：`model + state + questions`，读取 `answers` |
| Reply | 生成恰好三条中文候选 | OpenAI 兼容 `/chat/completions`，结构化 JSON 数组 |
| Vision（可选） | 图片消息、复杂版式或低置信 OCR 的补充 | 支持图片输入的 OpenAI 兼容接口 |

Jev 题目和 criteria 使用英文，聊天文字保持中文；每次发送的 state 只包含当前会话需要的最近消息和用户允许的上下文。最近消息条数默认 10 条，设置里可调 4–50 条（不含时间分隔线），判断、生成、排序共用。

迁移参考端点：OpenRouter 判断为 `/alpha/decisions`，TypeSafe 判断为 `/v1/systemone`，custom 判断使用明确的完整 URL；Reply 与云 Vision 分别配置 OpenAI 兼容 base URL，再组成 `/chat/completions`。这些是参考项目契约，供应商连通性仍需实施时验证。Rank 使用 Judge 同一路线，不是第四套凭据。

本地模型允许 `speaker=unknown`，但不擅自把它映射成 `other` 或直接发给未验证支持该值的 Jev 契约。关键消息无法分边时，要求用户校正或明确提示上下文不完整；不自动生成可插入建议。聊天文本作为待分析数据传入，不作为应用指令执行。

### 7.2 存储和请求边界

- 当前 API Key 由 Synapse 凭据存储管理，沿用主 App UserDefaults；不写入 App Group。此前 Keychain 条目是原始设计目标，本次不改变既有存储选择。
- App Group 中，Visyn 使用既有临时 JPEG 邮箱，Jarvis 业务目录保存少量配置和短期 `ReplyBundle`。候选和联系人标题本身属于敏感聊天衍生数据，需文件保护、排除备份和失效清理；不把 Keychain secret 复制到共享文件。
- provider、baseURL、model、自动分析开关等普通配置存 UserDefaults。
- 模型请求统一由 Synapse 使用 Alamofire 传输，提供请求超时、任务取消和受限重试。401/403 和参数错误不盲重试；429 按重试策略处理 `Retry-After`。生成类 POST 不自动重发超时请求。
- 服务地址默认 HTTPS；显式绑定凭据与目标服务，不向跨域重定向继续附带 Authorization。
- 日志只记录 provider、状态码、延迟和错误类型，不记录 API Key、完整聊天内容或完整请求 body。
- 三路凭据默认显式绑定服务，不沿用安卓“reply key 为空就继承 judge key”的跨域隐式回退。

### 7.3 分析调度

实时路线（2026-09-24 更新）：单屏可读文字经 800ms 防抖即可分析，不要求上下文达到设定条数，也不要求最后一句来自对方。裁切只附“部分可见”说明，未知发言方保持 unknown，不作为无限等待条件。纯文本 `ConversationContext` 隔离 OCR/图片/观察次数；版本包含采集会话、聊天会话、尾部签名及实际输入窗口指纹。新尾部/会话取消旧请求，已有结果保留并标“上次结果”。Jev 判断和候选生成/排序分别完成、分别更新，不互相等待。普通自动分析和上下文补算共用每分钟 6 次额度。

```text
ConversationContext → AnalysisRequest（同一个文本窗口版本）
   ├── Judge → 完成即更新 PiP 判断
   └── Reply → 生成 3 条 → Rank → 完成即更新 ReplyBundle
截图 → LongScreenshotStore（图片编码和导出独立，不参与上述完成条件）
```

判断失败不应阻塞本地 OCR；回复生成失败时保留判断结果。排序失败时主 App 可以展示“未排序”候选，但不写成已从低到高排序的键盘结果。只有得到有效、非空且不同的三条候选，并完成有效排序，才发布键盘 ready 结果；不拼凑占位回复。

自动分析默认开启，可在实时会话页关闭；关闭、停采、离开聊天页时取消排队与在途任务，暂停前的 OCR 回调另用采集 generation 拦截。用户补历史后停留 1.5 秒，按实际发送窗口指纹去重，同一尾部最多补算两次。跨段缺口作为明确标记保留给模型，不占真实消息额度。无重叠且方向不明的当前片段按独立单屏分析，不让旧历史链冒充当前内容。

## 8. Jarvis 自定义键盘

### 8.1 交互定位

Jarvis 键盘是独立的 `UIInputViewController` 中文键盘扩展，不是系统 QuickType 插件。2026-09-24 起将原来的建议面板改为可正常输入的键盘：

1. 读取主 App 写入的最新候选结果。
2. 在键盘顶部横排三个回复候选；候选失效或分析失败时仍保留全部输入按键。
3. 用户点击后调用 `textDocumentProxy.insertText(_:)`。
4. 本地全拼与可滚动中文选词、英文大小写、数字、符号、删除/长按删除、空格、回车、地球键和收起键盘。

`rank=1/2/3` 保持原共享契约，三个回复从左到右排列，3 为优先推荐并用底色区分。长回复在候选栏截断显示，插入的是完整文本。回复候选与本地拼音候选分开显示，避免中文输入时丢失回复或打字能力。

```text
Jarvis 键盘 · 小王       确认会话       收起
[回复①]          [回复②]          [回复③]
拼音/组合文本     [中文选词，可横向滚动]
q w e r t y u i o p
 a s d f g h j k l
分词 z x c v b n m 删除
123    🌐    中/英    空格    ，    回车
```

键盘按 `needsInputModeSwitchKey` 决定是否提供地球按钮。中文使用全拼，`v` 输入 ü，分词键输入音节分隔符；空格选第一候选，回车先提交尚未选词的拼音原文。组合文本留在键盘内存，确认选词后才插入目标输入框。词库来自 Apache-2.0 的 Rime/Android Pinyin IME（65,125 条字词），许可和来源随扩展打包；不接入第三方运行时，也不保存或上传用户键入历史。当前不支持简拼、模糊音、自学习、语音输入和系统联想服务。

### 8.2 键盘扩展配置

新增 `GalchatKeyboardExtension` target：

```text
NSExtensionPointIdentifier = com.apple.keyboard-service
NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).KeyboardViewController
PrimaryLanguage = zh-CN       // 按键盘扩展的语言/区域配置规则；不同于 OCR 语言标识
RequestsOpenAccess = NO       // 第一版只读共享结果
```

主 App 和键盘 target 使用同一个 App Group entitlement。用户需要在“设置 → 通用 → 键盘 → 键盘”中添加并启用 Jarvis 键盘。

Apple 当前文档允许未开启 Full Access 的键盘只读 containing app 的共享容器，但不能联网或写共享容器。第一版因此不让键盘直接调用 BYOK 模型。主 App 负责预先创建目录与文件，键盘只读打开，不调用隐式建目录的写入型 helper；最低支持系统上的实际行为必须列入真机验证。

### 8.3 ReplyBundle 契约

主 App 通过临时文件加原子替换写入独立文件，例如：

```text
App Group/
└── Jarvis/
    └── reply-bundle.json
```

示例结构：

```json
{
  "schemaVersion": 1,
  "bundleID": "reply-bundle-opaque",
  "status": "ready",
  "sessionID": "capture-session-opaque",
  "conversationID": "conversation-opaque",
  "revision": 42,
  "analysisRequestID": "analysis-request-opaque",
  "generatedAt": "2026-09-22T10:30:00Z",
  "expiresAt": "2026-09-22T10:30:30Z",
  "sourceObservedAt": "2026-09-22T10:30:00Z",
  "validUntil": "2026-09-22T10:30:08Z",
  "sourceTitle": "小王",
  "sourceConfidence": "confirmed",
  "candidates": [
    { "id": "reply-a", "rank": 1, "text": "先稳妥回应" },
    { "id": "reply-b", "rank": 2, "text": "给出具体承诺" },
    { "id": "reply-c", "rank": 3, "text": "表达理解并继续沟通" }
  ]
}
```

键盘读取和按钮点击都要校验：

- `schemaVersion` 是否支持。
- `status=ready`、`sourceConfidence=confirmed/recognized`，且候选数量恰好为三条。recognized 是单屏识别来源，键盘显示待核对提示；两种来源都必须人工确认后才可插入。
- `expiresAt`（推荐的最大有效时间）和 `validUntil`（来源新鲜度）是否均有效。
- 重新读取共享文件，确认 `sessionID + conversationID + revision + analysisRequestID + bundleID` 仍对应展示的候选。按钮绑定稳定的候选 ID 和文本，不用数组下标读取更新后的另一条候选。
- 候选文字是否为空或超过键盘展示上限。
- `documentIdentifier` 只能辅助判断输入文档是否变化，不能当作联系人 ID。

如果版本不匹配，按钮不执行插入，显示“建议已更新，请刷新键盘”。

以上 30 秒推荐有效期、8 秒来源有效期只是首轮调试参数，不是已验证指标。主 App 只有在新帧确认仍是同一会话、同一消息 revision 时才续期 `validUntil`，不得靠 Timer 无条件续期；续期不能超过 `expiresAt`。一旦停采、换会话、来源不确定或内容更新，主 App 原子发布 `status=invalid`、空 candidates（或清理文件），直到新结果就绪。主 App 挂起或被终止时可能没有机会写入失效状态，键盘必须自行按时间失效，不能只相信最后一次 ready。时间字段异常或设备时钟变化导致无法判断时按失效处理。

键盘出现、文本/选择变化、用户点击“更新显示”时重新读取；屏幕可见时可低频检查文件版本，离开后停止。显示旧候选期间还需安排本地过期处理，不能只在下次打开键盘时才检查。“更新显示”仅刷新缓存，不是调用模型。

这些校验仍不能证明候选对应眼前的聊天：同一 App 可能复用输入框，切会话也可能早于采集识别。每次新激活、输入文档改变或候选版本变化都要求人工确认来源。单屏识别尚未经连续帧确认时使用 recognized，并显示来源待核对；标题被遮挡则显示“当前会话”。ID/尾部签名/请求版本不一致时禁止发布，不能把短期有效期或匿名来源确认当作绝对防串会话保证。

### 8.4 插入草稿的安全规则

`insertText` 在当前光标处插入；如果用户选中了文字，目标 App 可能替换选中内容。键盘不得调用 `deleteBackward` 去清空整段草稿，也不能声称“绝不覆盖”。

当 `selectedText` 可用且非空时，候选按钮应提示“将替换选中内容”或要求用户二次确认；无法取得可靠上下文时，只执行当前光标插入，并让用户在目标 App 中检查。

密码输入框、电话输入框以及禁止第三方键盘的 App 会自动使用系统键盘。主 App 保留用户主动复制兜底：点击复制后写入 `UIPasteboard`，用户返回目标 App 自行粘贴；不后台自动读写剪贴板。

### 8.5 键盘不能承担的工作

- 不能依赖键盘启动来唤醒被挂起的主 App。
- 不能把“刷新”按钮承诺为立即重新调用模型；无有效缓存时显示“暂无新建议”。
- 不能读取完整聊天内容或可靠判断当前聊天联系人。
- 不能读取或消费 Visyn 的屏幕帧邮箱。
- 不保存完整键入历史，不上传用户键入内容；第一版完全不联网。

## 9. PiP 与主 App 展示

已实现（2026-09-25）：画中画固定四行，首页使用 Visyn 的横屏 `414×80`（默认）、竖屏 `80×60`、矩形 `80×80` 预设，或输入自定义宽高后应用。运行中也可更新，成功后通过库的 `save/load` 保存和恢复。①来源会话、情绪/危险分及实际分析条数；②意图与紧张是否缓解；③需求、行动与实质答复建议；④Jev/候选各自的进度或补历史提示。提示变蓝不改变危险色条。滚动、新消息或切会话时保留有来源的旧判断并标“上次结果”，新 Jev 判断完成即替换，不等待回复；候选新上下文开始时失效，独立生成与排序完成后可选用。

引擎用来源、意图、建议的多行准确标签和左对齐/字号/行距组成的簇确认 PiP 区域，窗口可拖动到屏幕下方；不会因为单条聊天以 Jarvis 开头就删掉它。键盘顶部固定写“Jarvis 键盘”，它以下视为键盘区，内容区下限再让出输入栏高度。

`JarvisPiPLayout` 为显示与 OCR 提供共享的行距、边距和内容尺寸。尺寸快照随屏幕帧传入后台识别，避免 OCR 等待期间的比例切换污染几何；更新成功后丢弃待处理旧帧，并暂缓接收一秒过渡帧。系统悬浮窗大小仍受 iOS 限制，用户可双指缩放；内容尺寸不等于悬浮窗的实际尺寸。

Jarvis 键盘已作为 `GalchatKeyboardExtension` target 加入工程（`GalchatShared/ReplyBundle.swift` 由主 App 与键盘共用）。发布只依赖同请求/输入版本的三条有效、已排序候选；不依赖 Jev 判断完成、长图或连续观察次数。单屏来源可为 recognized，标题遮挡显示“当前会话”，两者都必须人工核对后插入。有效期从候选完成开始计 120 秒，来源新鲜度取真实采集时间加 15 秒，最小续写间隔 3 秒；计时器不延长新鲜度。停采、离开聊天页、换会话、开始新上下文任务时写 invalid。共享写入失败不能标记就绪。



PiP 只显示低信息量摘要，例如：

```text
正在识别 · 小王 · 3 秒前
建议先回应对方感受
推荐：我明白你为什么会失望
```

完整判断、三条候选、会话校正、复制和键盘设置放在主 App。PiP 不承担候选点击、复制和输入。

PiP 开关、真实采集状态、分析状态分别管理。关闭 PiP 不自动等于停止采集；特别是 ScreenCaptureKit 路线应独立继续工作。旧系统若因此导致主 App 挂起，则依靠来源有效期降级。进程挂起期间无法保证更新屏幕上的文案，主 App 恢复时重新校验；独立键盘按共享结果的时间失效，不能把缓存标成实时。

## 10. 生命周期和隐私

### 10.1 状态机

```text
采集状态： idle → awaitingUserConsent → broadcasting ↔ paused → stopped / failed
业务状态： waitingFrame → recognizing → contextReady → analyzing → ready / partial / failed
结果状态： unavailable / ready / expired / invalid
PiP 状态： inactive / starting / active / failed
```

采集可以在模型请求期间继续收帧；这些状态不是互斥的单线流程。新一次采集生成新 `sessionID`；只有有效会话内容、身份或分析输入发生变化时递增 `revision`。`recognizing → analyzing → ready` 等展示状态变化不能递增内容版本，否则结果会在提交时使自身失效。停止/切会话使旧结果失效，同版本重试通过 `analysisRequestID` 隔离。

### 10.2 数据最小化

- 默认只保存当前会话短期消息；长期历史和联系人知识库由用户主动开启。
- 不保存录像或截图历史；但现有 Visyn 为跨进程传输会将一张 JPEG 临时写入 App Group。消费后删除，未消费帧由扩展定时清理；两进程均被终止时可能残留到下次启动，启动时须清理，不能宣称“完全不落盘”。
- Visyn 临时目录与业务候选文件均应启用设备文件保护并排除备份。停止采集后不再发布新的候选结论；已生成且未超过 `expiresAt` 的候选可降级保留并明确标注「录屏已暂停」，避免用户仅因切出应用就丢失可用建议。保护级别应与实际后台需求一致。
  - 判据：候选是"对当下聊天状态的推断"，会过期；好感度总分是"已经发生过的历史"，不过期。因此录屏停止后仍展示总分，但不作废已生成候选、也不再生成新候选。降级保留必须带可见标注，不能让陈旧结论看起来像刚分析出来的结果。
- 云视觉和模型请求前显示数据用途，允许用户关闭远端处理。
- 录屏必须由系统授权并有清晰的录屏状态指示；不得绕过系统授权。
- API Key、完整聊天内容、候选全文不得写入日志、崩溃上报或 Git。

## 11. 实施阶段

### 阶段 A：工程和采集基线

- 确定最低支持版本；如果继续支持 iOS 16.6，先把广播扩展从 26.5 对齐到兼容版本。
- 先建立采集与业务的边界并接现有 Visyn；实际新增第二后端时再按契约提取共同接口。
- 真机验证收帧、暂停、停止、PiP、切换 App、返回和采集恢复。

### 阶段 B：本地 OCR 与单聊会话

- 增加 Vision OCR 和后台有界流水线。
- 先适配一个聊天 App 的稳定版式。
- 输出 `ConversationSnapshot`，实现重复屏、滚动重叠和低置信度提示。
- 先手动触发分析，不默认每帧自动调用模型。

### 阶段 C：BYOK 与语义分析

- Keychain secret store。
- Judge/Rank 共用一个客户端，Reply 独立客户端；预留独立 Cloud Vision 配置，按后续需求接入。
- 取消、重试、超时和 revision 校验。
- 主 App 结果页展示判断和三条排序后的候选。

### 阶段 D：Jarvis 键盘

- 新增 Keyboard Extension target、Info.plist、App Group entitlement。
- 主 App 原子写 `ReplyBundle`。
- 键盘只读 bundle，顶部横排三个回复候选并调用 `insertText`；下方离线全拼和普通输入独立可用。
- 增加过期、版本冲突、选中文本和不可用输入框处理。
- 保留复制按钮和地球键切换提示。

### 阶段 E：新系统采集和扩展能力

- 升级到支持 iOS 27 API 的 Xcode/SDK。
- 实现 `ScreenCaptureKitProvider`，与 Visyn 后端共用 OCR 和会话层。
- 根据真机数据决定是否需要扩展内低频 OCR、云视觉、长图导出或键盘 Full Access。

## 12. 真机验收清单

### 采集与 OCR

- 系统授权、取消授权和重新授权。
- 微信单聊中文小字、深色主题、横屏和键盘展开。
- 慢滚、快滚、重复画面、向上翻历史和中间丢帧。
- 输入框草稿、Jarvis 键盘候选和底部系统键盘不会被 OCR 当成新消息。
- 无法识别发言人时显示 `unknown` 或明确提示，不自动归为对方。

### 模型与上下文

- Judge、Reply、Cloud Vision 三路及复用 Judge 的 Rank 使用正确 endpoint、model 和 Keychain secret；未启用 Cloud Vision 时不上传图片。
- 超时、429、5xx、取消和切换会话时旧结果不会覆盖新结果。
- 密钥不出现在日志、共享文件和崩溃信息中。
- 关闭云视觉后仍能使用本地 OCR 和基础分析。

### 键盘

- 设置中启用 Jarvis 键盘，使用地球键切换。
- 三条候选按低到高展示，点击后插入当前输入框。
- 光标位置、选中文字、空输入框和已有草稿均可预期处理。
- 结果过期、来源新鲜度过期、停止采集或 revision 冲突时不可插入旧候选；主 App 被强制结束也不能无限沿用最后一份 ready。
- 同一输入框被不同联系人复用时，来源提示和用户确认生效；排序升序、同分、排序失败和模型返回不足三条分别验证。
- 切换到密码框、电话框或禁止第三方键盘的 App 时复制兜底仍可用。
- 未开启 Full Access 时，键盘仍能读取主 App 的最新共享结果；不能联网刷新，并显示相应提示。

### PiP 与后台

- PiP 只显示短摘要；关闭后更新 PiP 状态，采集状态由真实采集后端决定，不无条件改成停止。
- 主 App 挂起、恢复、被系统终止后，不把旧结果标记为实时。
- 检查 PiP 自身是否进入屏幕采集画面，必要时在采集裁剪/排除规则中处理。

## 13. 默认决策与待验证项

先按以下默认值推进实现，不为一般选项增加不必要的确认步骤：

| 事项 | 当前设计默认值 | 后续调整条件 |
|---|---|---|
| 三条候选排序 | 推荐程度从低到高，第三条最高 | 用户明确排序含义不同 |
| 首个聊天场景 | 微信单聊 | 单聊验收后增加群聊、QQ、飞书 |
| 长期历史 | 关闭；当前会话在内存中累积 | 用户主动开启，并配置保留与删除策略 |
| Cloud Vision | 关闭 | 用户开启且指定提供商与凭据 |
| Keyboard Full Access | 不请求；只读候选 | 后续确需键盘联网或写共享状态 |
| 最低系统 | 暂以主 App 的 16.6 为兼容目标 | 工程配置修正与目标设备验收后确定支持范围；iOS 27 路线需 SDK 升级 |
| 实时自动分析 | 关闭 | 会话/说话人识别稳定并由用户开启 |

必须通过设备证据解决的事项：旧系统 PiP 期间主 App 的持续运行、共享容器只读能力在最低系统的表现、1280/0.7 帧对中文 OCR 的影响、目标 App 对键盘的兼容性。开启屏幕采集和键盘不代表这些验证已经通过。

## 14. 证据与参考资料

### 14.1 本地源码

- [iOS 采集入口 ViewController](/Users/heself/Desktop/Code/jev-chat-jarvis-ios/jev-chat-jarvis-ios/ViewController.swift)：`configureCapture`、`onFrame` 和 `makePiPContent`。
- [iOS 工程配置](/Users/heself/Desktop/Code/jev-chat-jarvis-ios/Galchat.xcodeproj/project.pbxproj)：主 App 与广播扩展的 deployment target、本地 Visyn package 引用。
- [Visyn 广播帧传输](/Users/heself/Desktop/Code/Visyn/Sources/VisynBroadcast/VisynBroadcastSampleHandler.swift)：节流、方向归一化、JPEG 编码与单槽背压。
- [Visyn 主 App 接收](/Users/heself/Desktop/Code/Visyn/Sources/VisynCapture/VisynCaptureController.swift)：主线程回调、消费即删与过期过滤。
- [Visyn PiP](/Users/heself/Desktop/Code/Visyn/Sources/VisynCapture/VisynPictureInPicturePresenter.swift)：UIView 转视频帧、系统 PiP。
- [Visyn 生命周期说明](/Users/heself/Desktop/Code/Visyn/README.md)：临时文件、过期清理、挂起和触摸限制。
- [安卓配置](/Users/heself/Desktop/Code/jev-chat-jarvis/app/src/main/java/com/jev/probe/core/Prefs.kt)：三路 provider、endpoint 和当前密钥存储。
- [安卓截图](/Users/heself/Desktop/Code/jev-chat-jarvis/app/src/main/java/com/jev/probe/capture/ocr/ScreenCapture.kt)：无障碍单次截图。
- [安卓业务调度](/Users/heself/Desktop/Code/jev-chat-jarvis/app/src/main/java/com/jev/probe/capture/ChatCaptureService.kt)：`runAnalysis`、OCR 和填入。
- [安卓跨屏合并](/Users/heself/Desktop/Code/jev-chat-jarvis/app/src/main/java/com/jev/probe/core/kb/KbStore.kt)：`appendLog` 的消息序列重叠合并。
- [安卓判断协议](/Users/heself/Desktop/Code/jev-chat-jarvis/app/src/main/java/com/jev/probe/jev/JudgeClient.kt)、[判断题与 state](/Users/heself/Desktop/Code/jev-chat-jarvis/app/src/main/java/com/jev/probe/jev/JevQuestions.kt)、[回复生成](/Users/heself/Desktop/Code/jev-chat-jarvis/app/src/main/java/com/jev/probe/jev/ReplyClient.kt)：迁移请求和解析语义的依据。

### 14.2 Apple 官方资料

- [Accessibility for UIKit](https://developer.apple.com/documentation/uikit/accessibility-for-uikit)：本 App 的无障碍支持。
- [Recognizing Text in Images](https://developer.apple.com/documentation/vision/recognizing-text-in-images)：本地 OCR、语言和坐标。
- [Keychain services](https://developer.apple.com/documentation/security/keychain-services)：凭据存储。
- [Creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard)：独立键盘扩展和切换入口。
- [Configuring open access](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard)：当前文档明确默认允许只读共享容器，网络与写入需要 Full Access；不要沿用旧归档页的相反描述。
- [Handling text interactions](https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards)：`textDocumentProxy` 插入、选择与有限上下文。
- [Configuring a custom keyboard interface](https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface)：安全输入和宿主 App 限制。
- [Capturing screen content on iOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios)：iOS 27+ 示例与后台采集模式。
- [RPSystemBroadcastPickerView](https://developer.apple.com/documentation/replaykit/rpsystembroadcastpickerview)、[RPBroadcastSampleHandler](https://developer.apple.com/documentation/replaykit/rpbroadcastsamplehandler)：ReplayKit 版本边界。
- [Configuring background execution modes](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes)：后台模式的用途与平台要求。

本设计基于静态源码与文档核对。没有执行 iOS 构建、包安装、真机运行、外部模型请求或上架审核；验收清单描述后续工作，不是已完成的验证结果。
