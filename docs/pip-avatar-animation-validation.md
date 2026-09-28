# 头像主题色与 GIF 画中画验收

## 本次行为

### 数据流与仓库职责

```
Visyn 采帧 → SeeU 引擎（OCR / 版式 / 会话）→ LongScreenshotInput
  ├─ SeeU LongScreenshotStore：拼接长图
  └─ SeeU SeeUImageHarvester（Galchat 请求 [.avatar, .sticker]）→ SeeUImageHarvest
        ├─ 头像 → Galchat PiPAvatarTracker → PiPPortrait → Visyn VisynPortraitView 渲染立绘
        └─ 表情包 → Galchat StickerTracker →（开启识图时）Synapse 视觉模型解读
                 → 插回 ConversationContext → Jev 判断 / 回复生成 → PiP 文案 + 键盘候选
```

- **SeeU**只做通用图片区域提取：`SeeUImageKind`（`.avatar/.sticker/.photo`，可扩展）、`SeeUImageRequest`、`SeeUImageDetector` 协议、内置 `SeeUChatImageDetector`、`SeeUImageHarvester` actor。输出裁图 JPEG、稳定 `imageID`、前后/同行消息 ID、出现位置数 `evidenceCount`、主色；不含"对方头像""主题色"等业务概念。
- **Visyn**渲染立绘与动图：`VisynPortraitView`（主题底色 + 沿阅读方向淡出的图片，位置可由宿主传入）、`VisynAnimatedImage` / `VisynAnimatedImageView`（按视频时钟选 GIF 帧）。每帧回调递归到所有可见子视图。
- **Synapse**提供 `SynapseChatMessage.user(text:images:)` 多模态消息，走现有 `complete()`。
- **Galchat**只做业务：选哪个头像当立绘、主色怎么混白、表情包放回对话哪里、要不要上传、文案与 OCR 锚点。

### 立绘

- 头像来自与长图存档同一帧的 SeeU 提取结果，不再单独渲染长图局部。条件：已确认来源、单聊（`showsSenderNames` 为 false）、对方一侧、同一头像至少出现在 2 个不同消息位置。
- `PiPPortrait` 把主色按 `rgb × 0.28 + 0.72` 浅化成主题色；未提取到时用默认人物占位和薄荷浅色。结果仅在内存，不上传、不覆盖联系人手动头像。
- 横屏头像在左向右淡出，竖屏头像在上向下淡出；立绘位置用 `GCPiPLayout.avatarFrame` 传给 Visyn，与"好感度"锚点同一套几何。
- `Galchat/Resources/heartbeat.gif` 由 `VisynAnimatedImageView` 播放（15 fps），当前有效聊天且已关联好感度时播放；好感度上升时换成 `heartflutter.gif`（动心），下降时换成 `heartbreak.gif`（心碎），见 `docs/affection-heart-animations.md`；停止、暂停、关系破裂或"减弱动态效果"时停在首帧。
- OCR 仍用 `Galchat`、`AI 估计`、`好感度` 三个锚点推算整个小窗遮挡区。

### 表情包

- 复用设置里的"视觉接口"开关（`GCConfig.visionEnabled`，默认关闭）和 `vision` 路线配置。
- 关闭时：表情包以 `[表情包]` 插入上下文，不上传图片。开启且配置齐全时：把最长边 256 的 JPEG 与附近 4 条消息发给视觉模型，得到 ≤ 20 字含义，插入为 `[表情包：含义]`。
- 含义按 SeeU `imageID` 缓存，同一表情只上传一次；最多 2 个并发，失败 60 秒后最多再试一次。清空记录时保留已解读含义。
- 含义到达后用最近一次 SeeU 输出重建上下文并重新调度分析，键盘候选随新结果更新；`ReplyBundle` 格式不变。

## 变更依赖

本地工程同时依赖相邻 `../Visyn`、`../SeeU` 与 `../Synapse` 的本次源码修改。仅复制 Galchat 仓库、沿用旧包版本会缺少新 API。没有提交或推送任何仓库。

## 已做验证

- 静态追踪 GIF 解码、逐帧回调、资源同步文件组、联系人切换、暂停与清空、长图局部渲染和 OCR 几何。
- Pillow 解码实际 GIF：96×96、14 个存储帧、总时长 1680 ms、透明背景、无限循环；编码器合并了停留时间内重复帧。已目视检查多帧图。
- Galchat、Visyn、SeeU 的 `git diff --check`。
- 独立静态审查后的三个问题已修复：矩形窗口 OCR 标记截断、超长图头像被过度缩小、仅两个普通聊天短语误触发整块 OCR 排除。
- 已新增但未运行 XCTest：SeeU `testBodyViewportMatchesFullCompositionAcrossSeamAndExclusions`；Visyn `testAnimationPreparationIsCapturedWithMatchingTimingAndRejectsInvalidFrameRate`。
- 解耦后新增但未运行 XCTest：SeeU `ImageRegionTests`（头像几何、像素工具、表情包定位、遮挡拒绝、消息锚点）；Visyn `VisynPortraitTests`（立绘几何、GIF 选帧、子视图帧回调）；Synapse `testMultimodalUserMessageEncodesTextThenInlineImages`。

遵循全局 iOS 约定，未执行 Xcode 构建、Swift 编译、依赖安装、模拟器、App 运行或 iOS 测试。下列内容需开发者在 Xcode 真机验证。

## 真机步骤

1. 用 Xcode 打开本工程，确认相邻 Visyn / SeeU 使用本地更新源码；检查主 App Copy Bundle Resources 含 `heartbeat.gif`、`heartflutter.gif`、`heartbreak.gif`。
2. 开始采集并进入单聊，露出标题和至少两条对方消息的完整头像。确认取到的是左侧对方头像，右侧自己的头像不参与；背景随头像主色变化。
3. 用真人、猫咪、卡通、黑白头像分别检查；单个头像、纯色头像、群聊、头像被 PiP 遮挡时应回退或保留当前可信图，不能拿消息图片冒充头像。
4. 选横屏 414×80：头像位于左边，向右平滑融入底色，分数、情绪、短建议和底部当前状态可读。选竖屏 90×220（Visyn 预设，9 : 22）：头像位于顶部并向下融入底色，名称、心跳、分数、情绪与进度纵向排列；不能只是横图旋转或缩小。
5. 选矩形 80×80、自定义 200×120 / 120×240、极小合法尺寸；确认无崩溃、没有越界内容，尺寸不足时次要信息隐藏。极小尺寸不承诺 OCR 可读性；推荐使用正常预设。
6. 观察心跳至少 30 秒，切到微信后台继续观察；单次心跳应有两次轻微放大，不能静止或残影。开关 PiP、暂停恢复、快速横竖切换、系统“减弱动态效果”分别检查。
7. A/B 联系人快速切换、手动重新绑定、删除会话、清空记录、结束并重新录屏；确认旧头像/主题/分数不会回写到新联系人。暂停显示的历史头像必须对应标注的来源。
8. 导出完整长图，确认头像/表情包提取没有改变原来的完整导出或接缝。
11. 表情包（识图关闭）：对方和自己各发一个表情包，确认分析上下文出现 `[表情包]` 且位置在正确的两条消息之间，没有网络请求；照片、红包、转账卡片是否被误判需记录。
12. 表情包（识图开启并填好视觉接口）：确认同一表情只请求一次，含义以 `[表情包：…]` 出现，随后 PiP 建议和键盘候选刷新；断网或密钥错误时不影响文字分析。
9. 拖动/缩放 PiP 到聊天上方、下方与侧边，检查实时消息/导出长图：小窗内名称、数值、建议不进入聊天，遮挡处按不完整处理。聊天发送“Jarvis”“Jarvis AI”“Galchat”“AI 估计”“好感度”等普通文本，确认不被整块误删。
10. 留意 Vision 矩形命中率、OCR 是否正确分出三个锚点、CPU/温度、15 fps 的后台持续时间；这些需要真机证据，静态审查不能保证。异常时记录窗口比例、截图和来源状态以便定位。
