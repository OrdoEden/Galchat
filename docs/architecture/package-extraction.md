# SeeU / Synapse 框架拆分

2026-09-25。本文记录本次源码拆分；未执行编译、依赖解析、模型请求或真机运行。包内测试源码需要由开发者在 Xcode 中执行。

## 边界

```text
主 App
├── VisynCapture                 录屏状态、帧、PiP
├── SeeU                         OCR、消息对齐、长图、对话 JSON
├── Synapse                      BYOK、模型路由、协议、网络
├── JevQuestions / JudgeClient   业务问题、领域结果解释、排序策略
├── ReplyClient                  候选提示词与输出规则
├── LiveAnalysisScheduler        判断调度、输入版本与旧结果隔离
├── ReplySuggestionScheduler     独立生成与排序
└── ReplyBundlePublisher         键盘短期结果发布

Broadcast Extension → VisynBroadcast
Keyboard Extension  → ReplyBundle 共享契约
```

两个新包均为单 product、单模块。SeeU 不依赖 Synapse；Synapse 不依赖 SeeU。联系人、长期上下文、人设及 Realm 均属于上层业务，本次不新增相关数据库，也不建立空的存储抽象。

## SeeU

原 App 的 `OCR/` 实现迁入 `../SeeU/Sources/SeeU/`。保持原有气泡文字/几何对齐、片段重连和移动长梯算法，公开会话引擎与独立长图存储。

- `SeeUConversationEngine`：逐张识别、维护短期会话、输出结构化更新。
- `SeeULongScreenshotStore`：独立接收长图输入与片段合并事件、生成图片。
- `EngineUpdate.conversation`：`SeeUConversation` 值快照，提供 JSON 编解码。
- `FrameExclusionPolicy`：宿主提供 OCR 行过滤和遮挡区域，坐标为方向已归一化图片的像素、左上原点。
- `AppFrameExclusion` 留在 App，保留当前 PiP/键盘品牌文字与布局规则。每帧捕获尺寸快照，不从后台识别读取变化中的 UI 状态。

JSON 保留消息/时间/缺口、发言方向、昵称候选、引用、裁切与观察证据。截图时间不是消息发送时间，OCR 名称不是持久联系人 ID。引擎会话 ID 只表示这次识别会话；长期身份匹配需由上层另行实现。

App 从结构化条目派生模型输入，缺口提示与“部分可见”等提示词留在 App。JSON 不包含提示词、API Key 或图片二进制；`LiveChatCoordinator.conversationJSON()` 可向其他业务返回当前原始记录。

实时模式仍由协调器限制为一个在处理帧、一个最新待处理帧。手动批次应逐张 `await process`，不使用实时单槽覆盖输入。图片尺寸/字节超预算、解码或 OCR 失败会抛错；App 显示错误并使候选失效。包内 README 说明输入方向、版式与大小限制，不承诺任意聊天应用或任意超长图片均可识别。

文字更新先于长图存储提交，长图编码不阻塞模型分析。图片可被覆盖，但片段坐标迁移事件按序累计；`captureGeneration` 与长图 `epoch` 分别处理停止分析及存档世代，保留原来的防串会话语义。

## Synapse

`../Synapse` 同时拥有模型配置存取、凭据生命周期、请求快照、Jev Decisions 与 Chat Completions 协议、Alamofire 传输。Alamofire 固定为原工程使用的 5.11.1，由包声明；App 不再直接链接该产品。

Jev 的 `model/state/questions/answers` 属于协议；七道情绪/意图问题、关系背景和 `Analysis` 映射属于 App。Chat Completions 的消息请求/响应属于协议；恰好三条候选、去重、排序解释和键盘校验属于 App。

2026-09-26 配置层继续下沉：`SynapseModelConfiguration` 按宿主提供的用途 ID 管理 provider/baseURL/model、凭据失效与请求快照。App 的 `JarvisConfig` 只组装三路配置对象、提供产品默认值，并保存关系描述、视觉开关、上下文条数、截图容量及业务通知。`APIRoute` 保留业务用途；服务商直接使用 `SynapseProvider`，`SecretStore` 和 `JSONValue` 别名已移除，题目直接使用 `SynapseJSONValue`。

错误按职责分开：通用请求错误直接透传 `SynapseError`，不再由 App 复制 HTTP 状态和错误说明，`APIError` 已删除。候选不足、候选过长、排序候选数量错误和排序概率缺失由 `ChatBusiness/ChatBusinessError` 表达。手动分析页区分判断、回复生成和排序阶段；设置页、实时状态及键盘候选状态按当前操作补充失败文案。取消处理、旧结果隔离和排序失败时保留未排序候选的行为不变。

三路配置均传入 `namespace: "Synapse"`，使用 `Synapse.<route>.provider/baseURL/model` 和 `Synapse.secret.<route>`；关系描述、视觉开关、上下文条数、截图容量、自动分析开关和设置通知使用 `Galchat.*`。本次直接切换前缀，不迁移、回退读取或删除其他前缀下的旧数据；模型配置和密钥需重新填写，App 设置恢复各自默认值。新包不携带 App 品牌、App Group、PiP 或固定业务用途。

同一轮分析开始时，`AnalysisModelContext` 冻结判断/回复路由及关系背景；判断、生成、排序均使用该快照。请求中的凭据不写入对话 JSON、共享候选或日志。Synapse 配置对象在更换服务商或地址 origin 后清除对应密钥；设置页使用 `save(baseURL:model:apiKey:)`，库拒绝在换域时自动回填原密钥，同时允许用户填写不同的新密钥。页面随后读取配置中的密钥刷新输入框。端点预览复用 Synapse 的拼接方法。

本次保留 UserDefaults 凭据策略，不迁入 Keychain，不删除旧设置。网关负责取消传播、协议校验、请求超时与脱敏错误；业务层继续在结果落地前检查请求 ID 和会话版本。

## 工程与迁移

Synapse 现位于主仓库相邻目录 `../Synapse`，包含独立的 `Package.swift`、源码和测试；主 App 通过本地包引用接入。独立管理不改变业务依赖方向。本次未初始化额外 Git 仓库、提交或推送。

SeeU 使用 Swift 6.2 工具链和 Swift 5 语言模式；Synapse 使用 Swift 5.9 包清单，但其既有 Alamofire 5.11.1 依赖的清单要求 Swift 6.2，整个依赖图仍需 Swift 6.2。两个包显式标注值对象及服务隔离，不继承 App 的默认 MainActor。主 App 的最低系统与扩展 deployment target 未在本次修改；现有最低版本差异仍需单独处理。现有 Package.resolved 保留原 Alamofire 版本，由用户在 Xcode 打开工程时解析新的本地依赖图。

初次拆分已完成静态检查：工程 plist 格式、包路径与产品引用、扩展依赖、模块反向依赖、旧实现移除、文档链接及 `git diff --check`，并有独立只读审查。SeeU 7 项与 Synapse 原有 8 项 XCTest 源码已添加；配置层迁移另补 `SynapseModelConfigurationTests`，覆盖库默认命名空间、读取不改写存储值、服务商切换、凭据失效、表单保存和快照隔离。测试均尚未执行，不构成编译或运行通过的证明。

## Xcode 手动验收

1. 在 Xcode 确认主 App 依赖 `VisynCapture`、`SeeU`、`Synapse`，广播与键盘扩展未新增两包依赖；确认包工具链可用并执行编译及包测试。
2. 单屏聊天即可分析；标题遮挡、裁切气泡、引用、时间标记与未知发言方向仍正确处理。查看 JSON，昵称、引用、裁切和来源均独立于提示词。
3. 重复截图不重复计入同一段；同文不同位置的消息保留；超过六个不重叠片段、反向滚动及片段重连不崩溃。
4. 调整 PiP 尺寸后恢复采集，遮挡按对应帧的尺寸识别。真实聊天提到 App 名称不会被全局过滤。
5. 长图导出较慢时文字分析继续；暂停/停录使旧 OCR、旧网络结果不能恢复候选，图片合并元数据不随单槽覆盖丢失。
6. 导入超预算、无效或方向不支持的图片，收到具体失败原因；顺序批次不静默丢失输入。JSON 编解码能保留结构化证据。
7. 在 Xcode 运行 Synapse 包测试。首次使用新前缀时重新填写模型配置和密钥，并确认 App 设置恢复默认值（视觉关闭、自动分析开启、上下文条数与截图容量均为 10）；保存后关闭并重新打开设置页确认持久化。同 origin 修改路径或模型保留密钥，切换服务商/跨 origin 地址后不自动回填旧密钥；同时填写不同的新密钥可以保存。调整上下文条数与截图容量，确认设置通知仍触发实时更新。
8. 分别验证 Jev 与 Chat Completions，确认生成与排序沿用启动时配置。取消、401/403、429、超时、错误 JSON 的处理符合包说明，错误中不出现密钥或聊天全文。
9. 按 `docs/keyboard-validation.md` 验证情绪与候选独立完成、键盘来源确认与过期失效。
10. 分别在判断、回复生成、排序阶段触发鉴权/超时错误，检查失败文案准确标明操作；设置页显示对应接口测试失败。模型返回不足三条、超长候选或缺少排序概率时，显示聊天业务错误；实时排序失败保留未排序候选供主界面查看，但不发布为键盘可用候选。取消任务不显示为请求失败。
