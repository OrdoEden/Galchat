# Galchat iOS

UIKit 聊天辅助 App，使用 Visyn 录屏和画中画，使用 SeeU 识别/拼接聊天截图，通过 Synapse 调用模型。

画中画默认保持横屏长条，首页可选横屏、竖屏、矩形，或输入宽高后点击“应用尺寸”；运行中也可修改，成功后自动记住尺寸。

业务接入架构见 [iOS 业务架构设计](docs/architecture/ios-business-architecture.md)，包括 OCR、跨屏会话合并、BYOK、语义分析、PiP 和 Galchat 自定义键盘。

“人格”页可以选择、新建、编辑、导入和导出人格，也可以选择“不使用人格”。人格包含性格、价值观、看事情的方式和说话习惯。所有内容放在 [Galchat/Personas](Galchat/Personas) 的独立文件里，Swift 只负责加载和保存。

## 人格文件

- 一个文件夹就是一个人格：`manifest.json` 写名称、简介、版本和文件清单，`documents` 按顺序列出要完整发送给模型的 Markdown，`licenseFiles` 列出随包保留、但不发送的许可与署名。照着任意现有文件夹添加即可，不需要修改 Swift。
- **分发格式是 `.personal`**：一个 UTF-8 JSON 单文件，包含清单和全部文字。用户下载后在“文件”、隔空投送或浏览器里点开，选 Galchat 打开即可导入；也可以在“+ → 从文件导入”里选择。编辑页“导出”得到的也是 `.personal`。旧版 JSON、完整文件夹和单个 Markdown 仍可导入。格式、目录约定与写作规范见 [人格文件格式](docs/persona-file-format.md)。
- `python3 scripts/build_personals.py` 把每个文件夹打包成 `dist/personals/<id>.personal`，可直接放到网盘或网站供下载。
- 随 App 附带的人格在首次使用时复制到 `Application Support/Personas/packages/<id>.json`，选择单独存为 `selection.json`。编辑只改本地副本，删除后不会自动补回。已经装过旧版人格的设备不会自动出现新预设，需要导入对应的 `.personal`（或删除 App 重装）。
- 旧版保存的人格自动迁移，原 UserDefaults 留作备份。人格文件损坏时保留原文件并提示错误，暂停写入。
- 包可以在清单里声明 `replyTransform` 做回复后处理（目前只有 `replaceText`：把所有文字换成一个字符，保留空格、标点和表情）。在排序之后、展示和发给键盘之前生成，改写后重复的候选会补上不同的结尾标点。
- 包只支持文字，不执行脚本或访问内容中的链接。清单和文字合计最多 1 MB，实际人格上下文最多 128 KB；超过上限会提示，不偷偷截短。

### 预设人格

| 人格 | 标识 | 风格 | 来源与许可 |
|---|---|---|---|
| 不藏不绕（默认） | `bu-cang-bu-rao` | 平时暖乎乎有网感；对方要真话时结论先行、不绕弯 | 原创文字 |
| 江南深情 | `jiangnan-shenqing` | 嘴上松弛心里认真，真诚直球、会自嘲、给人台阶 | 改写自 MIT 资料，保留 LICENSE |
| 温柔有骨 | `wenrou-yougu` | 先接住情绪、不爱被捧，原则问题平静坚定 | 改写自 MIT 资料，保留 LICENSE |
| 深宫絮语 | `shengong-xuyu` | 古装宫廷腔，端庄含蓄、偶尔摆谱逗人 | 原创文字 |
| 抽象乐子人 | `chouxiang-lezi` | 老网民抽象话，嘴贫一句到位，损人不带脏字 | 原创文字 |
| 远古巨人 | `yuangu-juren` | 远古石像醒来的守护者，话少郑重；回复后处理把所有文字换成“恰”，只留空格和标点的节奏 | 原创文字 |

所有预设都是虚构的性格原型：不写来源作品、角色、真实人物、主播、平台或社群的名称，不引用影视台词，不冒充任何人，也不虚构用户经历。上游改写部分已删除真实人物的姓名、经历、伴侣、合作方和时间线，只保留抽象的思考方式与表达节奏；无许可或 AGPL 的上游只参考风格描述、不复制文本。每个包的 `NOTICE.txt` 写明来源与改写范围。

静态文件检查可运行 `python3 scripts/check_personas.py`，检查清单、全文引用、体积、工程目录与 `.personal` 类型声明、敏感词，以及 `dist/personals` 是否最新，不编译 iOS。由开发者在 Xcode 验收：

1. 检查主 App bundle 含 `Personas/<id>/manifest.json` 及嵌套 Markdown；扩展不包含人格资源。全新安装有六个人格，默认“不藏不绕”，可以取消使用并删除最后一个。
2. 用测试安装验证旧版自定义修改、已删除标记和损坏数据。升级保留修改与选择；损坏数据报错且原 UserDefaults 不变。
3. 在“文件”里点开 `dist/personals` 中的 `.personal`，应唤起 Galchat 并切到人格页导入；引导未完成时打开，应在完成引导后导入。通过“从文件导入”选择 `.personal`、文件夹、旧 JSON、Markdown 均可导入。重复导入时取消应保留原文，确认才覆盖。导出得到 `<人格名>.personal`，重新导入后正文、许可和来源均保留。
4. 删除当前人格后重启，再导入同一文件，应仍“不使用人格”；文件缺失、路径越界、不支持版本、超大文件应提示错误且不覆盖已有内容。编辑页打开时从外部打开 `.personal`，提示应显示在最上层且不丢弃编辑页。检查小屏、大字体、VoiceOver、文件选择及分享窗口。
5. 同一聊天分别选六个人格和不使用人格，检查模型请求包含所选包的全文；选“远古巨人”时，排序请求仍是原文，最近/键盘/分析页显示的三条均为“恰”加空格标点且互不相同；新回复仍为三条、各不超过 40 字，贴合聊天对象。未实际调用模型验证这些效果。

## 独立 Swift Packages

| 库 | 路径 | 职责 |
|---|---|---|
| Visyn | `../Visyn` | 录屏、帧传输和 PiP，继续使用原有独立仓库 |
| SeeU | [`../SeeU`](../SeeU/README.md) | OCR、聊天版式、跨图消息合并、长图和结构化对话 JSON |
| Synapse | [`../Synapse`](../Synapse/README.md) | BYOK 模型配置与凭据管理、请求快照、Jev/Chat Completions 协议与 Alamofire 传输 |

SeeU 与 Synapse 各自提供一个公开模块，可独立接入其他项目；两者互不依赖。好感度、联系人、人设、情绪判断题、候选生成策略及键盘发布属于 App 业务，未引入两个库。当前没有新增 Realm 或联系人数据库。

Synapse 位于主仓库相邻目录 `../Synapse`，通过本地 Swift Package 引用。SeeU 要求 Swift 6.2 工具链、使用 Swift 5 语言模式；Synapse 的包清单为 Swift 5.9，但既有 Alamofire 5.11.1 依赖要求 Swift 6.2，因此整个工程仍需 Swift 6.2 工具链。两者不继承主 App 的默认 MainActor 隔离。迁移边界、兼容性与手动验收见 [框架拆分说明](docs/architecture/package-extraction.md)。

## 运行

用 Xcode 打开 `Galchat.xcodeproj`，选择 `Galchat` scheme。
项目通过本地 Swift Package 引用 `../Visyn`、`../SeeU` 和 `../Synapse`，请保持这些目录与主仓库位于同一级。
主 App 链接 `VisynCapture`、本地 `SeeU` 和 `Synapse`；Alamofire 由 Synapse 声明依赖。嵌入的 `GalchatBroadcastExtension` 仍只链接 `VisynBroadcast`，键盘扩展不链接两个新库。

主 App 与扩展共用项目级配置：

- `VISYN_APP_BUNDLE_IDENTIFIER`：`com.heself.galchat`
- `VISYN_APP_GROUP`：`group.$(VISYN_APP_BUNDLE_IDENTIFIER)` = `group.com.heself.galchat`
- 扩展 Bundle ID：`$(VISYN_APP_BUNDLE_IDENTIFIER).BroadcastExtension` / `.KeyboardExtension`

真机运行前，在 Xcode Signing & Capabilities / Apple Developer 中为两个 Target
配置同一个开发团队，并为两端 App ID 启用同一个已注册的 App Group。
项目已包含两端的 entitlement、Info.plist 参数和主 App 的 Audio 后台模式。
如果使用其他 App Group，在项目 Build Settings 中修改 `VISYN_APP_GROUP`。

## 验证

开发者在 Xcode 中完成构建和运行；自动化修改只做静态检查，不执行构建、依赖安装或模拟器运行。
模拟器可查看页面；ReplayKit 授权、跨 App 采集、后台与画中画需要真机验证。
真机检查：开始录屏 → 在系统面板确认 → 收帧数增加 → 开关画中画 →
切换其他 App → 返回 → 停止录屏 → 确认状态与计数复位；取消授权时应保持待机。
会话文字和长图在内存中处理，用户可主动导出长图。Visyn 的跨进程帧邮箱会临时写入 JPEG；键盘只读取独立的短期候选 JSON。模型密钥沿用现有 UserDefaults 存储策略，旧配置键继续兼容。

## 画中画尺寸

首页直接使用 `VisynPictureInPictureSize` 的三个预设：横屏 `414×80`（默认）、竖屏 `80×60`、矩形 `80×80`。名称与宽高顺序沿用库的约定。自定义尺寸在宽、高输入框中填写，点击“应用尺寸”生效；支持小数，由 Visyn 校验 1～640 点范围并取整，输入框回填实际应用值。

这里设置的是内容布局尺寸和比例，不是系统悬浮窗的精确大小。跨 App 小窗仍由 iOS 管理：单指移动位置，双指缩放；不支持任意拖动系统窗口边框。相同比例的内容同时增大宽高，不保证实际小窗同比例放大。

尺寸通过本地 Visyn 的 `pictureInPictureContentSize` 初始化参数和 `setPictureInPictureContentSize(_:)` 更新，成功后调用 `VisynPictureInPictureSize.save`。下次初始化使用 `load() ?? .landscape` 恢复；采用库默认的 UserDefaults 存储域和键，不再使用上一版 App 自建的尺寸偏好。非法输入不改变已应用尺寸或已保存值。四行文字保持 Galchat 前缀和单行截断；显示与 OCR 共用布局度量，按当前尺寸计算遮挡区域。尺寸变更后暂缓接收一秒屏幕帧，让系统完成比例重排；异步识别使用随帧传入的尺寸快照。

由开发者在 Xcode 真机检查：

1. 无库偏好时默认横屏 `414×80`；依次选择三个预设，确认宽高输入框与系统 PiP 比例同步更新。特别检查两个 80 点宽预设的文字可读性与 OCR 标记识别。
2. 在 PiP 关闭和开启时分别输入 `200×120` 并应用，再输入小数确认回填取整后的尺寸。键盘弹出时输入框和应用按钮可滚动访问。
3. 检查空白、非数字、零、负数和超过 640 的输入：出现错误且不覆盖已保存值。退出并重开 App，确认恢复最后成功应用的尺寸；初始化失败时尺寸控件不可操作。
4. 在不同尺寸下切换到聊天 App，移动和双指缩放 PiP，确认内容继续刷新。检查实时会话和长截图：Galchat 自身文字未被识别成消息，被遮住的聊天不应作为完整消息进入分析。
5. 连续切换比例后立即切回聊天，确认短暂停顿后恢复识别，没有套用旧尺寸的遮挡区域；停止并重启录屏也能恢复。
6. 小屏、横屏、大字体与 VoiceOver 下确认首页可滚动，预设、宽高输入框和应用按钮可访问。
